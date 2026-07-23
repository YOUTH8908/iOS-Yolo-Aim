#import "YTScreenDetector.h"

#import <CoreML/CoreML.h>
#import <ReplayKit/ReplayKit.h>
#import <Vision/Vision.h>
#import <dlfcn.h>

// ReplayKit normally supplies 30/60 FPS. Only keep the newest frame while an
// inference is running, so latency stays low and frames never queue up.
static NSTimeInterval const YTMinimumFrameInterval = 1.0 / 120.0;
static float const YTMinimumConfidence = 0.25f;
static CGFloat const YTBoxSmoothingSpeed = 30.0;

@interface YTDetectionBox : NSObject
@property (nonatomic, assign) CGRect normalizedRect;
@property (nonatomic, assign) CGRect targetRect;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, assign) float confidence;
@property (nonatomic, assign) CGFloat opacity;
@property (nonatomic, assign) CGFloat targetOpacity;
@property (nonatomic, assign) CGVector centerVelocity;
@property (nonatomic, assign) CFTimeInterval lastTargetUpdate;
@property (nonatomic, assign) NSInteger missedDetections;
@end

@implementation YTDetectionBox
@end

@interface YTDetectionOverlayView : UIView
@property (nonatomic, copy) NSArray<YTDetectionBox *> *boxes;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval previousDisplayTime;
@end

@implementation YTDetectionOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        _boxes = @[];
        _displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(displayLinkTick:)];
        _displayLink.preferredFramesPerSecond = 60;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        _displayLink.paused = YES;
    }
    return self;
}

- (void)setBoxes:(NSArray<YTDetectionBox *> *)boxes {
    NSMutableArray<YTDetectionBox *> *tracked = [_boxes mutableCopy] ?: [NSMutableArray array];
    CFTimeInterval now = CACurrentMediaTime();
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];

    // Build all possible pairs first, then assign the strongest global pairs.
    // This avoids order-dependent swaps when several targets cross each other.
    for (NSInteger trackIndex = 0; trackIndex < (NSInteger)tracked.count; trackIndex++) {
        YTDetectionBox *track = tracked[trackIndex];
        CGFloat predictionTime = MIN(MAX(now - track.lastTargetUpdate, 0), 0.12);
        CGRect predicted = CGRectOffset(track.targetRect,
                                        track.centerVelocity.dx * predictionTime,
                                        track.centerVelocity.dy * predictionTime);
        CGPoint predictedCenter = CGPointMake(CGRectGetMidX(predicted),
                                              CGRectGetMidY(predicted));

        for (NSInteger detectionIndex = 0;
             detectionIndex < (NSInteger)boxes.count;
             detectionIndex++) {
            YTDetectionBox *detection = boxes[detectionIndex];
            CGRect incoming = detection.normalizedRect;
            CGRect intersection = CGRectIntersection(predicted, incoming);
            CGFloat intersectionArea = CGRectIsNull(intersection) ? 0 :
                CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
            CGFloat predictedArea = MAX(0.00001,
                CGRectGetWidth(predicted) * CGRectGetHeight(predicted));
            CGFloat incomingArea = MAX(0.00001,
                CGRectGetWidth(incoming) * CGRectGetHeight(incoming));
            CGFloat unionArea = predictedArea + incomingArea - intersectionArea;
            CGFloat iou = intersectionArea / MAX(unionArea, 0.00001);

            CGPoint incomingCenter = CGPointMake(CGRectGetMidX(incoming),
                                                 CGRectGetMidY(incoming));
            CGFloat distance = hypot(incomingCenter.x - predictedCenter.x,
                                     incomingCenter.y - predictedCenter.y);
            CGFloat targetScale = MAX(0.035,
                (sqrt(predictedArea) + sqrt(incomingArea)) * 0.5);
            CGFloat motionScore = exp(-distance / (targetScale * 1.8));
            CGFloat sizePenalty = MIN(1.0, fabs(log(incomingArea / predictedArea)));
            CGFloat score = iou * 0.62 + motionScore * 0.38 - sizePenalty * 0.10;

            if (score > 0.10) {
                [candidates addObject:@{
                    @"track": @(trackIndex),
                    @"detection": @(detectionIndex),
                    @"score": @(score),
                }];
            }
        }
    }

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"score"] compare:a[@"score"]];
    }];

    NSMutableIndexSet *matchedTracks = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *matchedDetections = [NSMutableIndexSet indexSet];
    for (NSDictionary *candidate in candidates) {
        NSInteger trackIndex = [candidate[@"track"] integerValue];
        NSInteger detectionIndex = [candidate[@"detection"] integerValue];
        if ([matchedTracks containsIndex:trackIndex] ||
            [matchedDetections containsIndex:detectionIndex]) {
            continue;
        }

        YTDetectionBox *track = tracked[trackIndex];
        YTDetectionBox *detection = boxes[detectionIndex];
        CFTimeInterval delta = MAX(1.0 / 120.0,
                                   MIN(now - track.lastTargetUpdate, 0.25));
        CGPoint oldCenter = CGPointMake(CGRectGetMidX(track.targetRect),
                                        CGRectGetMidY(track.targetRect));
        CGPoint newCenter = CGPointMake(CGRectGetMidX(detection.normalizedRect),
                                        CGRectGetMidY(detection.normalizedRect));
        CGVector measuredVelocity =
            CGVectorMake((newCenter.x - oldCenter.x) / delta,
                         (newCenter.y - oldCenter.y) / delta);
        track.centerVelocity = CGVectorMake(
            track.centerVelocity.dx * 0.55 + measuredVelocity.dx * 0.45,
            track.centerVelocity.dy * 0.55 + measuredVelocity.dy * 0.45);

        // Predict a short distance ahead to compensate for inference/display
        // latency while keeping the box stable when motion stops.
        CGFloat predictionLead = 0.030;
        track.targetRect = CGRectOffset(detection.normalizedRect,
                                        track.centerVelocity.dx * predictionLead,
                                        track.centerVelocity.dy * predictionLead);
        CGFloat targetWidth = MIN(1.0, MAX(0.001, CGRectGetWidth(track.targetRect)));
        CGFloat targetHeight = MIN(1.0, MAX(0.001, CGRectGetHeight(track.targetRect)));
        track.targetRect = CGRectMake(
            MIN(MAX(CGRectGetMinX(track.targetRect), 0), 1.0 - targetWidth),
            MIN(MAX(CGRectGetMinY(track.targetRect), 0), 1.0 - targetHeight),
            targetWidth,
            targetHeight);
        track.targetOpacity = 1.0;
        track.label = detection.label;
        track.confidence = detection.confidence;
        track.lastTargetUpdate = now;
        track.missedDetections = 0;
        [matchedTracks addIndex:trackIndex];
        [matchedDetections addIndex:detectionIndex];
    }

    for (NSInteger index = 0; index < (NSInteger)tracked.count; index++) {
        if (![matchedTracks containsIndex:index]) {
            YTDetectionBox *track = tracked[index];
            track.missedDetections += 1;
            track.centerVelocity = CGVectorMake(track.centerVelocity.dx * 0.72,
                                                track.centerVelocity.dy * 0.72);
            // Tolerate two missed detections to prevent crowd flicker.
            if (track.missedDetections > 2) {
                track.targetOpacity = 0;
            }
        }
    }

    for (NSInteger index = 0; index < (NSInteger)boxes.count; index++) {
        if ([matchedDetections containsIndex:index]) {
            continue;
        }
        YTDetectionBox *incoming = boxes[index];
        incoming.targetRect = incoming.normalizedRect;
        incoming.opacity = 0;
        incoming.targetOpacity = 1;
        incoming.lastTargetUpdate = now;
        incoming.missedDetections = 0;
        [tracked addObject:incoming];
    }

    _boxes = [tracked copy];
    self.previousDisplayTime = 0;
    self.displayLink.paused = NO;
    [self setNeedsDisplay];
}

- (CGFloat)interpolate:(CGFloat)current target:(CGFloat)target amount:(CGFloat)amount {
    return current + (target - current) * amount;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    CFTimeInterval delta = self.previousDisplayTime > 0 ?
        link.timestamp - self.previousDisplayTime : link.duration;
    self.previousDisplayTime = link.timestamp;
    CGFloat amount = 1.0 - exp(-YTBoxSmoothingSpeed * MIN(delta, 0.05));

    NSMutableArray<YTDetectionBox *> *remaining = [NSMutableArray array];
    BOOL stillAnimating = NO;
    for (YTDetectionBox *box in self.boxes) {
        CGRect current = box.normalizedRect;
        CGRect target = box.targetRect;
        box.normalizedRect = CGRectMake(
            [self interpolate:current.origin.x target:target.origin.x amount:amount],
            [self interpolate:current.origin.y target:target.origin.y amount:amount],
            [self interpolate:current.size.width target:target.size.width amount:amount],
            [self interpolate:current.size.height target:target.size.height amount:amount]);
        box.opacity = [self interpolate:box.opacity
                                  target:box.targetOpacity
                                  amount:amount];

        if (box.targetOpacity > 0 || box.opacity > 0.025) {
            [remaining addObject:box];
        }
        if (fabs(box.opacity - box.targetOpacity) > 0.01 ||
            fabs(box.normalizedRect.origin.x - target.origin.x) > 0.0005 ||
            fabs(box.normalizedRect.origin.y - target.origin.y) > 0.0005 ||
            fabs(box.normalizedRect.size.width - target.size.width) > 0.0005 ||
            fabs(box.normalizedRect.size.height - target.size.height) > 0.0005) {
            stillAnimating = YES;
        }
    }
    _boxes = [remaining copy];
    [self setNeedsDisplay];
    if (!stillAnimating && self.boxes.count == 0) {
        link.paused = YES;
        self.previousDisplayTime = 0;
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) {
        return;
    }

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    UIColor *boxColor = [UIColor colorWithRed:1.0 green:0.22 blue:0.18 alpha:1.0];

    CGContextSetLineWidth(context, 2.5);
    CGContextSetStrokeColorWithColor(context, boxColor.CGColor);
    CGContextSetLineJoin(context, kCGLineJoinRound);

    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    };

    for (YTDetectionBox *box in self.boxes) {
        CGContextSaveGState(context);
        CGContextSetAlpha(context, box.opacity);
        CGRect normalized = box.normalizedRect;
        CGRect screenRect = CGRectMake(normalized.origin.x * width,
                                       (1.0 - CGRectGetMaxY(normalized)) * height,
                                       normalized.size.width * width,
                                       normalized.size.height * height);
        screenRect = CGRectIntersection(CGRectInset(self.bounds, 1, 1), screenRect);
        if (CGRectIsNull(screenRect) || CGRectIsEmpty(screenRect)) {
            CGContextRestoreGState(context);
            continue;
        }

        CGContextStrokeRect(context, screenRect);

        NSString *text = [NSString stringWithFormat:@"%@  %.0f%%",
                          box.label.length ? box.label : @"item",
                          box.confidence * 100.0f];
        CGSize textSize = [text sizeWithAttributes:attributes];
        CGFloat labelHeight = ceil(textSize.height) + 6;
        CGFloat labelWidth = ceil(textSize.width) + 10;
        CGFloat labelY = MAX(1, CGRectGetMinY(screenRect) - labelHeight);
        CGRect labelRect = CGRectMake(CGRectGetMinX(screenRect),
                                      labelY,
                                      MIN(labelWidth, width - CGRectGetMinX(screenRect) - 1),
                                      labelHeight);

        [boxColor setFill];
        UIBezierPath *background =
            [UIBezierPath bezierPathWithRoundedRect:labelRect cornerRadius:4];
        [background fill];
        [text drawAtPoint:CGPointMake(CGRectGetMinX(labelRect) + 5,
                                      CGRectGetMinY(labelRect) + 3)
           withAttributes:attributes];
        CGContextRestoreGState(context);
    }
}

@end

@interface YTScreenDetector ()
@property (nonatomic, weak) UIWindow *overlayWindow;
@property (nonatomic, strong) YTDetectionOverlayView *drawingView;
@property (nonatomic, strong) VNCoreMLRequest *visionRequest;
@property (nonatomic, strong) dispatch_queue_t inferenceQueue;
@property (nonatomic, strong) RPScreenRecorder *screenRecorder;
@property (nonatomic, strong) NSTimer *captureWatchdogTimer;
@property (nonatomic, strong) NSTimer *compositorCaptureTimer;
@property (nonatomic, strong) UILabel *performanceLabel;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL showsBoxes;
@property (nonatomic, assign) BOOL inferenceInProgress;
@property (nonatomic, assign) BOOL captureStarting;
@property (nonatomic, assign) BOOL ownsScreenCapture;
@property (nonatomic, assign) CFTimeInterval lastProcessedFrameTime;
@property (nonatomic, assign) CFTimeInterval lastReplayKitFrameWallTime;
@property (nonatomic, assign) CFTimeInterval lastReplayKitStartAttemptTime;
@property (nonatomic, assign) CFTimeInterval inferenceStartTime;
@property (nonatomic, assign) CFTimeInterval lastInferenceCompletionTime;
@property (nonatomic, assign) double latencyMillisecondsEMA;
@property (nonatomic, assign) double framesPerSecondEMA;
@end

@implementation YTScreenDetector

+ (instancetype)sharedDetector {
    static YTScreenDetector *detector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [[self alloc] initPrivate];
    });
    return detector;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _inferenceQueue =
            dispatch_queue_create("com.dzyolo.YoloTweak.inference", DISPATCH_QUEUE_SERIAL);
        _screenRecorder = RPScreenRecorder.sharedRecorder;
        _screenRecorder.microphoneEnabled = NO;
        _screenRecorder.cameraEnabled = NO;
        _showsBoxes = YES;

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                  selector:@selector(detectionEnabledChanged:)
                      name:@"YTDetectionEnabledDidChangeNotification"
                    object:nil];
        [center addObserver:self
                  selector:@selector(boxVisibilityChanged:)
                      name:@"YTDetectionBoxesDidChangeNotification"
                    object:nil];
        [center addObserver:self
                  selector:@selector(applicationDidEnterBackground:)
                      name:UIApplicationDidEnterBackgroundNotification
                    object:nil];
        [center addObserver:self
                  selector:@selector(applicationDidBecomeActive:)
                      name:UIApplicationDidBecomeActiveNotification
                    object:nil];
        [center addObserver:self
                  selector:@selector(screenCaptureStateChanged:)
                      name:UIScreenCapturedDidChangeNotification
                    object:nil];
    }
    return self;
}

- (void)attachToOverlayView:(UIView *)overlayView
            excludingWindow:(UIWindow *)overlayWindow {
    NSAssert(NSThread.isMainThread, @"Detection overlay must be attached on the main thread.");
    self.overlayWindow = overlayWindow;

    if (!self.drawingView) {
        YTDetectionOverlayView *view =
            [[YTDetectionOverlayView alloc] initWithFrame:overlayView.bounds];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        [overlayView insertSubview:view atIndex:0];
        self.drawingView = view;
    } else if (self.drawingView.superview != overlayView) {
        [self.drawingView removeFromSuperview];
        self.drawingView.frame = overlayView.bounds;
        [overlayView insertSubview:self.drawingView atIndex:0];
    }

    if (!self.performanceLabel) {
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.userInteractionEnabled = NO;
        label.text = @"YOLO  -- ms  •  -- FPS";
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
        label.font = [UIFont monospacedDigitSystemFontOfSize:12
                                                     weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.layer.cornerRadius = 8;
        label.clipsToBounds = YES;
        [overlayView insertSubview:label aboveSubview:self.drawingView];
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:overlayView.safeAreaLayoutGuide.topAnchor
                                            constant:8],
            [label.trailingAnchor constraintEqualToAnchor:overlayView.safeAreaLayoutGuide.trailingAnchor
                                                 constant:-12],
            [label.heightAnchor constraintEqualToConstant:28],
            [label.widthAnchor constraintGreaterThanOrEqualToConstant:158],
        ]];
        self.performanceLabel = label;
    }

    [self loadModelIfNeeded];
}

- (void)loadModelIfNeeded {
    if (self.visionRequest) {
        return;
    }

    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *modelURL = [bundle URLForResource:@"best" withExtension:@"mlmodelc"];
    if (!modelURL) {
        NSLog(@"[YoloTweak] best.mlmodelc is missing from the framework resources.");
        return;
    }

    NSError *error = nil;
    MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
    configuration.computeUnits = MLComputeUnitsAll;
    MLModel *model = [MLModel modelWithContentsOfURL:modelURL
                                      configuration:configuration
                                              error:&error];
    if (!model) {
        NSLog(@"[YoloTweak] Core ML model load error: %@", error);
        return;
    }

    VNCoreMLModel *visionModel = [VNCoreMLModel modelForMLModel:model error:&error];
    if (!visionModel) {
        NSLog(@"[YoloTweak] Vision model load error: %@", error);
        return;
    }

    __weak typeof(self) weakSelf = self;
    VNCoreMLRequest *request =
        [[VNCoreMLRequest alloc] initWithModel:visionModel
                            completionHandler:^(VNRequest *finishedRequest, NSError *requestError) {
        [weakSelf processResults:finishedRequest.results error:requestError];
    }];
    // A screenshot is stretched to 640×640. The normalized results therefore map
    // directly back to the full screen, independent of the device aspect ratio.
    request.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;
    self.visionRequest = request;
}

- (void)detectionEnabledChanged:(NSNotification *)notification {
    BOOL enabled = [notification.userInfo[@"enabled"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.enabled = enabled;
        if (enabled) {
            self.performanceLabel.text = @"YOLO  启动中…";
            [self loadModelIfNeeded];
            [self startCaptureWatchdog];
            [self startScreenCapture];
        } else {
            [self stopCaptureWatchdog];
            [self stopCompositorCapture];
            [self stopScreenCapture];
            self.drawingView.boxes = @[];
            self.performanceLabel.text = @"YOLO  已停止";
        }
    });
}

- (void)boxVisibilityChanged:(NSNotification *)notification {
    BOOL visible = [notification.userInfo[@"enabled"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.showsBoxes = visible;
        self.drawingView.hidden = !visible;
        if (!visible) {
            self.drawingView.boxes = @[];
        }
    });
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self stopCaptureWatchdog];
    [self stopCompositorCapture];
    [self stopScreenCapture];
    self.drawingView.boxes = @[];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (self.enabled) {
        [self startCaptureWatchdog];
        [self startScreenCapture];
    }
}

- (void)screenCaptureStateChanged:(NSNotification *)notification {
    if (!self.enabled) {
        return;
    }
    // Control Center recording and ReplayKit live capture share one recorder.
    // The watchdog switches to compositor frames if the live callback stalls.
    [self evaluateCaptureHealth];
}

- (void)startScreenCapture {
    if (!self.enabled || self.captureStarting || self.ownsScreenCapture) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastReplayKitStartAttemptTime > 0 &&
        now - self.lastReplayKitStartAttemptTime < 1.5) {
        return;
    }
    self.lastReplayKitStartAttemptTime = now;
    if (!self.visionRequest) {
        NSLog(@"[YoloTweak] Screen capture was not started because the model is not loaded.");
        return;
    }

    RPScreenRecorder *recorder = self.screenRecorder;
    if (!recorder.isAvailable) {
        NSLog(@"[YoloTweak] ReplayKit screen capture is not available.");
        return;
    }
    if (recorder.isRecording && !self.ownsScreenCapture) {
        NSLog(@"[YoloTweak] Another ReplayKit recording session is already active.");
        return;
    }

    self.captureStarting = YES;
    self.lastProcessedFrameTime = 0;
    self.lastReplayKitFrameWallTime = CACurrentMediaTime();
    self.lastInferenceCompletionTime = 0;
    self.latencyMillisecondsEMA = 0;
    self.framesPerSecondEMA = 0;
    __weak typeof(self) weakSelf = self;
    [recorder startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer,
                                        RPSampleBufferType bufferType,
                                        NSError *captureError) {
        typeof(self) self = weakSelf;
        if (!self) {
            return;
        }
        if (captureError) {
            NSLog(@"[YoloTweak] ReplayKit frame error: %@", captureError);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.ownsScreenCapture = NO;
                [self startCompositorCapture];
            });
            return;
        }
        if (bufferType == RPSampleBufferTypeVideo) {
            [self processReplayKitVideoBuffer:sampleBuffer];
        }
    } completionHandler:^(NSError *startError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.captureStarting = NO;
            self.ownsScreenCapture = startError == nil;
            if (startError) {
                NSLog(@"[YoloTweak] ReplayKit start error: %@", startError);
                self.performanceLabel.text = @"YOLO  录屏启动失败";
                [self startCompositorCapture];
            } else {
                NSLog(@"[YoloTweak] ReplayKit screen detection started.");
                self.performanceLabel.text = @"YOLO  检测中…";
            }
        });
    }];
}

- (void)stopScreenCapture {
    self.captureStarting = NO;
    self.lastProcessedFrameTime = 0;
    if (!self.ownsScreenCapture) {
        return;
    }

    self.ownsScreenCapture = NO;
    [self.screenRecorder stopCaptureWithHandler:^(NSError *error) {
        if (error) {
            NSLog(@"[YoloTweak] ReplayKit stop error: %@", error);
        }
    }];
}

- (void)startCaptureWatchdog {
    if (self.captureWatchdogTimer) {
        return;
    }
    self.captureWatchdogTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.25
                                         target:self
                                       selector:@selector(evaluateCaptureHealth)
                                       userInfo:nil
                                        repeats:YES];
    self.captureWatchdogTimer.tolerance = 0.04;
}

- (void)stopCaptureWatchdog {
    [self.captureWatchdogTimer invalidate];
    self.captureWatchdogTimer = nil;
}

- (void)evaluateCaptureHealth {
    if (!self.enabled ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }

    CFTimeInterval silence =
        CACurrentMediaTime() - self.lastReplayKitFrameWallTime;
    if (silence > 0.55) {
        [self startCompositorCapture];
    }

    if (!self.screenRecorder.isRecording && !self.captureStarting) {
        self.ownsScreenCapture = NO;
        // Retry ReplayKit after a Control Center recording finishes.
        [self startScreenCapture];
    }
}

- (void)startCompositorCapture {
    if (self.compositorCaptureTimer || !self.enabled) {
        return;
    }
    self.performanceLabel.text = @"YOLO  兼容录屏模式";
    self.compositorCaptureTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                         target:self
                                       selector:@selector(processCompositorFrame)
                                       userInfo:nil
                                        repeats:YES];
    self.compositorCaptureTimer.tolerance = 0.002;
}

- (void)stopCompositorCapture {
    [self.compositorCaptureTimer invalidate];
    self.compositorCaptureTimer = nil;
}

- (CGImageRef)copyCompositedScreenImage CF_RETURNS_RETAINED {
    typedef CGImageRef (*YTGetScreenImageFunction)(void);
    static YTGetScreenImageFunction getScreenImage;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        getScreenImage = (YTGetScreenImageFunction)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    });

    if (getScreenImage) {
        CGImageRef image = getScreenImage();
        if (image) {
            return CGImageCreateCopy(image);
        }
    }

    // UIKit fallback for hosts where the compositor snapshot symbol is absent.
    CGSize size = self.overlayWindow.bounds.size;
    if (size.width < 1 || size.height < 1) {
        return nil;
    }
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIWindowScene *scene = self.overlayWindow.windowScene;
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor blackColor] setFill];
        [context fillRect:(CGRect){CGPointZero, size}];
        for (UIWindow *window in scene.windows) {
            if (window != self.overlayWindow && !window.hidden && window.alpha > 0.01) {
                [window drawViewHierarchyInRect:window.frame afterScreenUpdates:NO];
            }
        }
    }];
    return image.CGImage ? CGImageCreateCopy(image.CGImage) : nil;
}

- (void)processCompositorFrame {
    if (!self.enabled || self.inferenceInProgress || !self.visionRequest) {
        return;
    }

    CGImageRef image = [self copyCompositedScreenImage];
    if (!image) {
        return;
    }
    self.inferenceInProgress = YES;
    self.inferenceStartTime = CACurrentMediaTime();
    VNCoreMLRequest *request = self.visionRequest;
    dispatch_async(self.inferenceQueue, ^{
        @autoreleasepool {
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCGImage:image
                                                   orientation:kCGImagePropertyOrientationUp
                                                       options:@{}];
            NSError *error = nil;
            [handler performRequests:@[request] error:&error];
            if (error) {
                NSLog(@"[YoloTweak] Compositor detection error: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.inferenceInProgress = NO;
                });
            }
            CGImageRelease(image);
        }
    });
}

- (CGImagePropertyOrientation)orientationForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CFTypeRef value = CMGetAttachment(sampleBuffer,
                                      (__bridge CFStringRef)RPVideoSampleOrientationKey,
                                      NULL);
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        return (CGImagePropertyOrientation)[(__bridge NSNumber *)value unsignedIntValue];
    }
    return kCGImagePropertyOrientationUp;
}

- (void)processReplayKitVideoBuffer:(CMSampleBufferRef)sampleBuffer {
    self.lastReplayKitFrameWallTime = CACurrentMediaTime();
    if (self.compositorCaptureTimer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopCompositorCapture];
        });
    }
    if (!self.enabled || self.inferenceInProgress || !self.visionRequest) {
        return;
    }

    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CFTimeInterval seconds = CMTimeGetSeconds(timestamp);
    if (isfinite(seconds) &&
        self.lastProcessedFrameTime > 0 &&
        seconds - self.lastProcessedFrameTime < YTMinimumFrameInterval) {
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }

    self.lastProcessedFrameTime = seconds;
    self.inferenceInProgress = YES;
    self.inferenceStartTime = CACurrentMediaTime();
    CGImagePropertyOrientation orientation = [self orientationForSampleBuffer:sampleBuffer];
    CVPixelBufferRetain(pixelBuffer);

    VNCoreMLRequest *request = self.visionRequest;
    dispatch_async(self.inferenceQueue, ^{
        @autoreleasepool {
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                                         orientation:orientation
                                                             options:@{}];
            NSError *error = nil;
            [handler performRequests:@[request] error:&error];
            if (error) {
                NSLog(@"[YoloTweak] Detection error: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.inferenceInProgress = NO;
                });
            }
            CVPixelBufferRelease(pixelBuffer);
        }
    });
}

- (void)processResults:(NSArray<VNObservation *> *)results error:(NSError *)error {
    CFTimeInterval completionTime = CACurrentMediaTime();
    double latency = MAX(0, (completionTime - self.inferenceStartTime) * 1000.0);
    if (self.latencyMillisecondsEMA <= 0) {
        self.latencyMillisecondsEMA = latency;
    } else {
        self.latencyMillisecondsEMA =
            self.latencyMillisecondsEMA * 0.80 + latency * 0.20;
    }

    if (self.lastInferenceCompletionTime > 0) {
        double interval = completionTime - self.lastInferenceCompletionTime;
        if (interval > 0) {
            double currentFPS = 1.0 / interval;
            if (self.framesPerSecondEMA <= 0) {
                self.framesPerSecondEMA = currentFPS;
            } else {
                self.framesPerSecondEMA =
                    self.framesPerSecondEMA * 0.80 + currentFPS * 0.20;
            }
        }
    }
    self.lastInferenceCompletionTime = completionTime;

    NSMutableArray<YTDetectionBox *> *boxes = [NSMutableArray array];
    if (!error) {
        for (VNObservation *observation in results) {
            if (![observation isKindOfClass:VNRecognizedObjectObservation.class]) {
                continue;
            }

            VNRecognizedObjectObservation *object =
                (VNRecognizedObjectObservation *)observation;
            VNClassificationObservation *topLabel = object.labels.firstObject;
            if (!topLabel || topLabel.confidence < YTMinimumConfidence) {
                continue;
            }

            YTDetectionBox *box = [[YTDetectionBox alloc] init];
            box.normalizedRect = object.boundingBox;
            box.label = topLabel.identifier.length ? topLabel.identifier : @"item";
            box.confidence = topLabel.confidence;
            [boxes addObject:box];
        }

        // Some Core ML/OS combinations expose an NMS pipeline as two raw
        // MLMultiArray outputs instead of VNRecognizedObjectObservation values.
        // Parse those outputs as a fallback so boxes are still rendered.
        if (boxes.count == 0) {
            MLMultiArray *confidenceArray = nil;
            MLMultiArray *coordinatesArray = nil;
            for (VNObservation *observation in results) {
                if (![observation isKindOfClass:VNCoreMLFeatureValueObservation.class]) {
                    continue;
                }
                VNCoreMLFeatureValueObservation *feature =
                    (VNCoreMLFeatureValueObservation *)observation;
                MLMultiArray *array = feature.featureValue.multiArrayValue;
                if ([feature.featureName isEqualToString:@"confidence"]) {
                    confidenceArray = array;
                } else if ([feature.featureName isEqualToString:@"coordinates"]) {
                    coordinatesArray = array;
                }
            }
            [boxes addObjectsFromArray:
                [self boxesFromConfidence:confidenceArray coordinates:coordinatesArray]];
        }
    } else {
        NSLog(@"[YoloTweak] Vision request error: %@", error);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.inferenceInProgress = NO;
        self.drawingView.boxes = self.enabled && self.showsBoxes ? boxes : @[];
        if (self.enabled) {
            self.performanceLabel.text =
                [NSString stringWithFormat:@"YOLO  %.0f ms  •  %.1f FPS",
                                           self.latencyMillisecondsEMA,
                                           self.framesPerSecondEMA];
        }
    });
}

- (double)valueInArray:(MLMultiArray *)array row:(NSInteger)row column:(NSInteger)column {
    NSInteger offset = row * array.strides[0].integerValue +
                       column * array.strides[1].integerValue;
    return [array[offset] doubleValue];
}

- (NSArray<YTDetectionBox *> *)boxesFromConfidence:(MLMultiArray *)confidence
                                       coordinates:(MLMultiArray *)coordinates {
    if (!confidence || !coordinates ||
        confidence.shape.count < 2 || coordinates.shape.count < 2) {
        return @[];
    }

    NSInteger rows = MIN(confidence.shape[0].integerValue,
                         coordinates.shape[0].integerValue);
    NSInteger coordinateColumns = coordinates.shape[1].integerValue;
    if (rows <= 0 || coordinateColumns < 4) {
        return @[];
    }

    NSMutableArray<YTDetectionBox *> *boxes = [NSMutableArray array];
    for (NSInteger row = 0; row < rows; row++) {
        // This model has one real class ("item"). The remaining confidence
        // columns are zero-padding added by the Core ML NMS exporter.
        float score = (float)[self valueInArray:confidence row:row column:0];
        if (score < YTMinimumConfidence) {
            continue;
        }

        CGFloat centerX = [self valueInArray:coordinates row:row column:0];
        CGFloat centerY = [self valueInArray:coordinates row:row column:1];
        CGFloat width = [self valueInArray:coordinates row:row column:2];
        CGFloat height = [self valueInArray:coordinates row:row column:3];

        // Core ML NMS coordinates are normalized center-x/center-y/width/height.
        // Convert the image's top-left Y axis to Vision's bottom-left Y axis.
        CGRect normalized = CGRectMake(centerX - width * 0.5,
                                       1.0 - centerY - height * 0.5,
                                       width,
                                       height);
        normalized = CGRectIntersection(CGRectMake(0, 0, 1, 1), normalized);
        if (CGRectIsNull(normalized) || CGRectIsEmpty(normalized)) {
            continue;
        }

        YTDetectionBox *box = [[YTDetectionBox alloc] init];
        box.normalizedRect = normalized;
        box.label = @"item";
        box.confidence = score;
        [boxes addObject:box];
    }
    return boxes;
}

@end
