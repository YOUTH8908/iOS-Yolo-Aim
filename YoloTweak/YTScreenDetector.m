#import "YTScreenDetector.h"
#import "YTTouchSynthesizer.h"

#import <CoreML/CoreML.h>
#import <ReplayKit/ReplayKit.h>
#import <Vision/Vision.h>
#import <dlfcn.h>

// Detection is deliberately capped below the game's render rate. Interpolation
// keeps boxes smooth while leaving CPU/GPU/Neural Engine time for the host.
static double const YTMaximumDetectionFPS = 15.0;
static float const YTMinimumConfidence = 0.25f;
static CGFloat const YTBoxSmoothingSpeed = 30.0;
static CFTimeInterval const YTAutoAimInterval = 0.28;
static CGFloat const YTAutoAimGain = 0.55;
static CGFloat const YTTouchSquareSize = 150.0;
// Swipe speed in points-per-second. Duration is derived from the swipe
// distance divided by this speed, clamped to [min, max]. This keeps every
// swipe at a consistent, moderate pace — never too fast.
static CGFloat const YTAutoAimSwipeSpeed = 380.0;
static CGFloat const YTAutoAimMinDuration = 0.12;
static CGFloat const YTAutoAimMaxDuration = 0.24;

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
@property (nonatomic, assign) CGRect detectionRegion;
@property (nonatomic, assign) BOOL showsDetectionRegion;
@property (nonatomic, assign) BOOL showsBoxes;
@property (nonatomic, assign) BOOL showsAimLine;
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
        _detectionRegion = CGRectMake(0.25, 0.25, 0.5, 0.5);
        _showsBoxes = YES;
        _showsAimLine = YES;
        _displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(displayLinkTick:)];
        _displayLink.preferredFramesPerSecond = 60;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        _displayLink.paused = YES;
    }
    return self;
}

- (void)setDetectionRegion:(CGRect)detectionRegion {
    if (CGRectEqualToRect(_detectionRegion, detectionRegion)) {
        return;
    }
    _detectionRegion = detectionRegion;
    [self setNeedsDisplay];
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

            if (score > 0.25) {
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
            // Tolerate one missed detection to prevent crowd flicker.
            if (track.missedDetections > 1) {
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

    // Deduplicate tracks: merge overlapping tracks to prevent multiple boxes
    // for the same physical target (the main cause of "duplicate boxes").
    if (tracked.count > 1) {
        NSMutableArray<YTDetectionBox *> *deduped = [NSMutableArray array];
        for (YTDetectionBox *box in tracked) {
            BOOL duplicate = NO;
            for (YTDetectionBox *kept in deduped) {
                CGRect intersection = CGRectIntersection(box.targetRect, kept.targetRect);
                if (CGRectIsNull(intersection)) continue;
                CGFloat interArea = CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
                CGFloat boxArea = CGRectGetWidth(box.targetRect) * CGRectGetHeight(box.targetRect);
                CGFloat keptArea = CGRectGetWidth(kept.targetRect) * CGRectGetHeight(kept.targetRect);
                CGFloat unionArea = boxArea + keptArea - interArea;
                CGFloat iou = interArea / MAX(unionArea, 0.00001);
                if (iou > 0.3) {
                    duplicate = YES;
                    // Merge velocity into the surviving track.
                    kept.centerVelocity = CGVectorMake(
                        kept.centerVelocity.dx * 0.5 + box.centerVelocity.dx * 0.5,
                        kept.centerVelocity.dy * 0.5 + box.centerVelocity.dy * 0.5);
                    break;
                }
            }
            if (!duplicate) {
                [deduped addObject:box];
            }
        }
        [tracked removeAllObjects];
        [tracked addObjectsFromArray:deduped];
    }

    _boxes = [tracked copy];
    self.previousDisplayTime = 0;
    self.displayLink.paused = NO;
    [self setNeedsDisplay];
}

- (CGFloat)interpolate:(CGFloat)current target:(CGFloat)target amount:(CGFloat)amount {
    return current + (target - current) * amount;
}

- (void)advanceAnimationAtTime:(CFTimeInterval)time delta:(CFTimeInterval)frameDelta {
    CFTimeInterval delta = self.previousDisplayTime > 0 ?
        time - self.previousDisplayTime : frameDelta;
    self.previousDisplayTime = time;
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
    if (!stillAnimating) {
        self.displayLink.paused = YES;
        self.previousDisplayTime = 0;
    }
}

- (void)displayLinkTick:(CADisplayLink *)link {
    CFTimeInterval delta = self.previousDisplayTime > 0 ?
        link.timestamp - self.previousDisplayTime : link.duration;
    [self advanceAnimationAtTime:link.timestamp delta:delta];
    [self setNeedsDisplay];
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
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:13
                                                       weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    };

    CGContextSetLineWidth(context, 2.5);
    CGContextSetStrokeColorWithColor(context, boxColor.CGColor);
    CGContextSetLineJoin(context, kCGLineJoinRound);

    if (self.showsDetectionRegion) {
        CGContextSaveGState(context);
        CGContextSetLineWidth(context, 2.0);
        CGContextSetStrokeColorWithColor(
            context, [UIColor colorWithRed:0.15 green:0.85 blue:1.0 alpha:0.88].CGColor);
        CGFloat dashPattern[] = {8, 5};
        CGContextSetLineDash(context, 0, dashPattern, 2);
        CGContextStrokeEllipseInRect(context, CGRectInset(self.bounds, 2, 2));
        CGContextRestoreGState(context);
    }

    if (self.showsAimLine) {
        CGPoint origin = CGPointMake(width * 0.5, height * 0.5);
        YTDetectionBox *nearest = nil;
        CGFloat nearestDistance = CGFLOAT_MAX;
        CGPoint nearestPoint = CGPointZero;
        CGRect region = self.detectionRegion;
        for (YTDetectionBox *box in self.boxes) {
            if (box.opacity < 0.12) {
                continue;
            }
            CGPoint normalizedCenter =
                CGPointMake(CGRectGetMidX(box.normalizedRect),
                            CGRectGetMidY(box.normalizedRect));
            CGPoint localCenter = CGPointMake(
                (normalizedCenter.x - region.origin.x) / region.size.width * width,
                (1.0 - (normalizedCenter.y - region.origin.y) / region.size.height) * height);
            CGFloat distance = hypot(localCenter.x - origin.x,
                                     localCenter.y - origin.y);
            if (distance < nearestDistance) {
                nearestDistance = distance;
                nearest = box;
                nearestPoint = localCenter;
            }
        }

        CGContextSaveGState(context);
        UIColor *lineColor = [UIColor colorWithRed:0.12 green:0.88 blue:1.0 alpha:0.94];
        CGContextSetStrokeColorWithColor(context, lineColor.CGColor);
        CGContextSetFillColorWithColor(context, lineColor.CGColor);
        CGContextSetLineWidth(context, 2.0);
        CGContextFillEllipseInRect(context, CGRectMake(origin.x - 3.5,
                                                        origin.y - 3.5,
                                                        7, 7));
        if (nearest) {
            CGContextMoveToPoint(context, origin.x, origin.y);
            CGContextAddLineToPoint(context, nearestPoint.x, nearestPoint.y);
            CGContextStrokePath(context);
            CGContextFillEllipseInRect(context, CGRectMake(nearestPoint.x - 3,
                                                            nearestPoint.y - 3,
                                                            6, 6));
        }
        CGContextRestoreGState(context);
    }

    if (!self.showsBoxes) {
        return;
    }
    for (YTDetectionBox *box in self.boxes) {
        CGContextSaveGState(context);
        CGContextSetAlpha(context, box.opacity);
        CGRect normalized = box.normalizedRect;
        CGRect region = self.detectionRegion;
        CGFloat localX = (normalized.origin.x - region.origin.x) / region.size.width;
        CGFloat localY = (normalized.origin.y - region.origin.y) / region.size.height;
        CGFloat localWidth = normalized.size.width / region.size.width;
        CGFloat localHeight = normalized.size.height / region.size.height;
        CGRect screenRect = CGRectMake(localX * width,
                                       (1.0 - localY - localHeight) * height,
                                       localWidth * width,
                                       localHeight * height);
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
        CGRect labelRect = CGRectMake(
            CGRectGetMinX(screenRect),
            labelY,
            MIN(labelWidth, width - CGRectGetMinX(screenRect) - 1),
            labelHeight);
        [boxColor setFill];
        [[UIBezierPath bezierPathWithRoundedRect:labelRect cornerRadius:4] fill];
        [text drawAtPoint:CGPointMake(CGRectGetMinX(labelRect) + 5,
                                      CGRectGetMinY(labelRect) + 3)
           withAttributes:attributes];
        CGContextRestoreGState(context);
    }
}

@end

@interface YTTouchPositionView : UIView
@end

@implementation YTTouchPositionView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 5;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.accessibilityLabel = @"滑动操作区域";
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGRect box = CGRectInset(self.bounds, 3, 3);

    UIColor *strokeColor = [UIColor colorWithRed:1.0 green:0.53 blue:0.12 alpha:0.96];
    UIColor *fillColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.08 alpha:0.16];

    UIBezierPath *boxPath = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:10];
    [fillColor setFill];
    [boxPath fill];
    [strokeColor setStroke];
    boxPath.lineWidth = 2.5;
    [boxPath stroke];

    // Center crosshair marking the swipe origin inside the square.
    CGContextSetStrokeColorWithColor(context, strokeColor.CGColor);
    CGContextSetLineWidth(context, 1.5);
    CGContextMoveToPoint(context, center.x, CGRectGetMinY(box));
    CGContextAddLineToPoint(context, center.x, CGRectGetMaxY(box));
    CGContextMoveToPoint(context, CGRectGetMinX(box), center.y);
    CGContextAddLineToPoint(context, CGRectGetMaxX(box), center.y);
    CGContextStrokePath(context);
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
@property (nonatomic, strong) YTTouchPositionView *touchPositionView;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL showsBoxes;
@property (nonatomic, assign) BOOL showsAimLine;
@property (nonatomic, assign) BOOL autoAimEnabled;
@property (nonatomic, assign) BOOL touchPositionEditing;
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
@property (nonatomic, assign) CGRect currentDetectionRegion;
@property (nonatomic, assign) CGPoint touchPositionNormalized;
@property (nonatomic, assign) CFTimeInterval lastAutoAimTime;
@property (nonatomic, assign) CGPoint lockedTargetCenter;
@property (nonatomic, assign) BOOL hasLockedTarget;
@property (nonatomic, assign) CFTimeInterval lockedTargetLastSeenTime;
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
        _showsAimLine = YES;
        _currentDetectionRegion = CGRectMake(0.25, 0.25, 0.5, 0.5);
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        CGFloat savedX = [defaults doubleForKey:@"YTAimTouchPositionX"];
        CGFloat savedY = [defaults doubleForKey:@"YTAimTouchPositionY"];
        _touchPositionNormalized = (savedX > 0 && savedY > 0) ?
            CGPointMake(savedX, savedY) : CGPointMake(0.80, 0.72);

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
                  selector:@selector(aimLineVisibilityChanged:)
                      name:@"YTAimLineEnabledDidChangeNotification"
                    object:nil];
        [center addObserver:self
                  selector:@selector(autoAimEnabledChanged:)
                      name:@"YTAutoAimEnabledDidChangeNotification"
                    object:nil];
        [center addObserver:self
                  selector:@selector(touchPositionEditingChanged:)
                      name:@"YTTouchPositionEditingDidChangeNotification"
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
        CGRect region = self.currentDetectionRegion;
        CGRect drawingFrame = CGRectMake(
            region.origin.x * CGRectGetWidth(overlayView.bounds),
            (1.0 - CGRectGetMaxY(region)) * CGRectGetHeight(overlayView.bounds),
            region.size.width * CGRectGetWidth(overlayView.bounds),
            region.size.height * CGRectGetHeight(overlayView.bounds));
        YTDetectionOverlayView *view =
            [[YTDetectionOverlayView alloc] initWithFrame:drawingFrame];
        view.clipsToBounds = YES;
        [overlayView insertSubview:view atIndex:0];
        self.drawingView = view;
    } else if (self.drawingView.superview != overlayView) {
        [self.drawingView removeFromSuperview];
        [overlayView insertSubview:self.drawingView atIndex:0];
    }
    self.drawingView.detectionRegion = self.currentDetectionRegion;
    self.drawingView.showsBoxes = self.showsBoxes;
    self.drawingView.showsAimLine = self.showsAimLine;
    CGRect region = self.currentDetectionRegion;
    self.drawingView.frame = CGRectMake(
        region.origin.x * CGRectGetWidth(overlayView.bounds),
        (1.0 - CGRectGetMaxY(region)) * CGRectGetHeight(overlayView.bounds),
        region.size.width * CGRectGetWidth(overlayView.bounds),
        region.size.height * CGRectGetHeight(overlayView.bounds));

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

    if (!self.touchPositionView) {
        YTTouchPositionView *touchView =
            [[YTTouchPositionView alloc] initWithFrame:CGRectMake(0, 0, YTTouchSquareSize, YTTouchSquareSize)];
        touchView.hidden = YES;
        touchView.userInteractionEnabled = YES;
        [touchView addGestureRecognizer:
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleTouchPositionPan:)]];
        [overlayView insertSubview:touchView aboveSubview:self.drawingView];
        self.touchPositionView = touchView;
    } else if (self.touchPositionView.superview != overlayView) {
        [self.touchPositionView removeFromSuperview];
        [overlayView insertSubview:self.touchPositionView aboveSubview:self.drawingView];
    }
    self.touchPositionView.center = CGPointMake(
        self.touchPositionNormalized.x * CGRectGetWidth(overlayView.bounds),
        self.touchPositionNormalized.y * CGRectGetHeight(overlayView.bounds));
    self.touchPositionView.hidden = !self.touchPositionEditing;

    [self loadModelIfNeeded];
}

- (void)loadModelIfNeeded {
    if (self.visionRequest) {
        return;
    }

    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *modelURL = [bundle URLForResource:@"best320" withExtension:@"mlmodelc"];
    if (!modelURL) {
        NSLog(@"[YoloTweak] best320.mlmodelc is missing from the framework resources.");
        return;
    }

    NSError *error = nil;
    MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
    // Keep Core ML off the GPU so it does not contend with the game's renderer.
    configuration.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
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
        self.drawingView.showsDetectionRegion = enabled;
        [self.drawingView setNeedsDisplay];
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
        self.drawingView.showsBoxes = visible;
        [self.drawingView setNeedsDisplay];
    });
}

- (void)aimLineVisibilityChanged:(NSNotification *)notification {
    BOOL visible = [notification.userInfo[@"enabled"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.showsAimLine = visible;
        self.drawingView.showsAimLine = visible;
        [self.drawingView setNeedsDisplay];
    });
}

- (void)autoAimEnabledChanged:(NSNotification *)notification {
    BOOL enabled = [notification.userInfo[@"enabled"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.autoAimEnabled = enabled;
        self.lastAutoAimTime = 0;
        self.hasLockedTarget = NO;
    });
}

- (void)touchPositionEditingChanged:(NSNotification *)notification {
    BOOL editing = [notification.userInfo[@"enabled"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.touchPositionEditing = editing;
        self.touchPositionView.hidden = !editing;
        if (editing && self.touchPositionView.superview) {
            [self.touchPositionView.superview bringSubviewToFront:self.touchPositionView];
        }
    });
}

- (void)handleTouchPositionPan:(UIPanGestureRecognizer *)pan {
    UIView *container = self.touchPositionView.superview;
    if (!container) {
        return;
    }
    CGPoint translation = [pan translationInView:container];
    CGPoint center = self.touchPositionView.center;
    center.x += translation.x;
    center.y += translation.y;
    [pan setTranslation:CGPointZero inView:container];
    CGFloat half = CGRectGetWidth(self.touchPositionView.bounds) * 0.5;
    UIEdgeInsets safe = container.safeAreaInsets;
    center.x = MAX(safe.left + half,
                   MIN(CGRectGetWidth(container.bounds) - safe.right - half, center.x));
    center.y = MAX(safe.top + half,
                   MIN(CGRectGetHeight(container.bounds) - safe.bottom - half, center.y));
    self.touchPositionView.center = center;
    self.touchPositionNormalized = CGPointMake(
        center.x / MAX(1, CGRectGetWidth(container.bounds)),
        center.y / MAX(1, CGRectGetHeight(container.bounds)));

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setDouble:self.touchPositionNormalized.x forKey:@"YTAimTouchPositionX"];
        [defaults setDouble:self.touchPositionNormalized.y forKey:@"YTAimTouchPositionY"];
    }
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
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
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

- (CFTimeInterval)desiredDetectionInterval {
    CFTimeInterval baseInterval = 1.0 / YTMaximumDetectionFPS;
    if (self.latencyMillisecondsEMA <= 0) {
        return baseInterval;
    }
    // Reserve roughly 35% breathing room between inferences. This prevents
    // continuous ANE/CPU saturation and sharply reduces thermal pressure.
    CFTimeInterval loadAwareInterval =
        self.latencyMillisecondsEMA / 1000.0 * 1.35;
    return MIN(0.14, MAX(baseInterval, loadAwareInterval));
}

- (BOOL)orientationSwapsWidthAndHeight:(CGImagePropertyOrientation)orientation {
    return orientation == kCGImagePropertyOrientationLeft ||
           orientation == kCGImagePropertyOrientationRight ||
           orientation == kCGImagePropertyOrientationLeftMirrored ||
           orientation == kCGImagePropertyOrientationRightMirrored;
}

- (CGRect)detectionRegionForPixelWidth:(size_t)pixelWidth
                           pixelHeight:(size_t)pixelHeight
                           orientation:(CGImagePropertyOrientation)orientation {
    if ([self orientationSwapsWidthAndHeight:orientation]) {
        size_t temporary = pixelWidth;
        pixelWidth = pixelHeight;
        pixelHeight = temporary;
    }
    if (pixelWidth == 0 || pixelHeight == 0) {
        return CGRectMake(0.25, 0.25, 0.5, 0.5);
    }

    // Crop a centered 640×640 source-pixel square. Vision then scales only
    // this region to the model's 320×320 input.
    CGFloat cropPixels = MIN(640.0, MIN((CGFloat)pixelWidth, (CGFloat)pixelHeight));
    CGFloat normalizedWidth = cropPixels / (CGFloat)pixelWidth;
    CGFloat normalizedHeight = cropPixels / (CGFloat)pixelHeight;
    return CGRectMake((1.0 - normalizedWidth) * 0.5,
                      (1.0 - normalizedHeight) * 0.5,
                      normalizedWidth,
                      normalizedHeight);
}

- (void)useDetectionRegion:(CGRect)region {
    self.currentDetectionRegion = region;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.drawingView.detectionRegion = region;
        UIView *container = self.drawingView.superview;
        if (container) {
            self.drawingView.frame = CGRectMake(
                region.origin.x * CGRectGetWidth(container.bounds),
                (1.0 - CGRectGetMaxY(region)) * CGRectGetHeight(container.bounds),
                region.size.width * CGRectGetWidth(container.bounds),
                region.size.height * CGRectGetHeight(container.bounds));
        }
    });
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
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastProcessedFrameTime > 0 &&
        now - self.lastProcessedFrameTime < [self desiredDetectionInterval]) {
        return;
    }

    CGImageRef image = [self copyCompositedScreenImage];
    if (!image) {
        return;
    }
    CGRect detectionRegion =
        [self detectionRegionForPixelWidth:CGImageGetWidth(image)
                              pixelHeight:CGImageGetHeight(image)
                              orientation:kCGImagePropertyOrientationUp];
    [self useDetectionRegion:detectionRegion];
    self.lastProcessedFrameTime = now;
    self.inferenceInProgress = YES;
    self.inferenceStartTime = now;
    VNCoreMLRequest *request = self.visionRequest;
    dispatch_async(self.inferenceQueue, ^{
        @autoreleasepool {
            request.regionOfInterest = detectionRegion;
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
    CFTimeInterval now = CACurrentMediaTime();
    self.lastReplayKitFrameWallTime = now;
    if (self.compositorCaptureTimer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopCompositorCapture];
        });
    }
    if (!self.enabled || self.inferenceInProgress || !self.visionRequest) {
        return;
    }

    if (self.lastProcessedFrameTime > 0 &&
        now - self.lastProcessedFrameTime < [self desiredDetectionInterval]) {
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }

    self.lastProcessedFrameTime = now;
    self.inferenceInProgress = YES;
    self.inferenceStartTime = now;
    CGImagePropertyOrientation orientation = [self orientationForSampleBuffer:sampleBuffer];
    CGRect detectionRegion =
        [self detectionRegionForPixelWidth:CVPixelBufferGetWidth(pixelBuffer)
                              pixelHeight:CVPixelBufferGetHeight(pixelBuffer)
                              orientation:orientation];
    [self useDetectionRegion:detectionRegion];
    CVPixelBufferRetain(pixelBuffer);

    VNCoreMLRequest *request = self.visionRequest;
    dispatch_async(self.inferenceQueue, ^{
        @autoreleasepool {
            request.regionOfInterest = detectionRegion;
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

- (CGRect)fullImageRectFromRegionLocalRect:(CGRect)localRect {
    CGRect region = self.currentDetectionRegion;
    return CGRectMake(region.origin.x + localRect.origin.x * region.size.width,
                      region.origin.y + localRect.origin.y * region.size.height,
                      localRect.size.width * region.size.width,
                      localRect.size.height * region.size.height);
}

- (NSArray<YTDetectionBox *> *)boxesInsideCircularRegion:
    (NSArray<YTDetectionBox *> *)boxes {
    CGRect region = self.currentDetectionRegion;
    CGFloat radiusX = region.size.width * 0.5;
    CGFloat radiusY = region.size.height * 0.5;
    if (radiusX <= 0 || radiusY <= 0) {
        return @[];
    }

    NSMutableArray<YTDetectionBox *> *filtered = [NSMutableArray array];
    CGPoint regionCenter = CGPointMake(CGRectGetMidX(region), CGRectGetMidY(region));
    for (YTDetectionBox *box in boxes) {
        CGPoint center = CGPointMake(CGRectGetMidX(box.normalizedRect),
                                     CGRectGetMidY(box.normalizedRect));
        CGFloat normalizedX = (center.x - regionCenter.x) / radiusX;
        CGFloat normalizedY = (center.y - regionCenter.y) / radiusY;
        if (normalizedX * normalizedX + normalizedY * normalizedY <= 1.0) {
            [filtered addObject:box];
        }
    }
    return filtered;
}

- (UIWindow *)hostWindowForTouchInjection {
    return [YTTouchSynthesizer bestHostWindowExcluding:self.overlayWindow];
}

- (YTDetectionBox *)nearestBoxToScreenCenter:(NSArray<YTDetectionBox *> *)boxes {
    YTDetectionBox *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (YTDetectionBox *box in boxes) {
        CGPoint center = CGPointMake(CGRectGetMidX(box.normalizedRect),
                                     CGRectGetMidY(box.normalizedRect));
        CGFloat distance = hypot(center.x - 0.5, center.y - 0.5);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearest = box;
        }
    }
    return nearest;
}

/// Non-Maximum Suppression: removes overlapping detections, keeping the one
/// with highest confidence. Prevents duplicate boxes for the same target.
- (NSArray<YTDetectionBox *> *)nonMaxSuppression:(NSArray<YTDetectionBox *> *)boxes
                                    iouThreshold:(CGFloat)threshold {
    if (boxes.count <= 1) return boxes;

    NSArray *sorted = [boxes sortedArrayUsingComparator:
        ^NSComparisonResult(YTDetectionBox *a, YTDetectionBox *b) {
            return b.confidence > a.confidence ? NSOrderedDescending :
                   (b.confidence < a.confidence ? NSOrderedAscending : NSOrderedSame);
        }];

    NSMutableArray<YTDetectionBox *> *result = [NSMutableArray array];
    for (YTDetectionBox *current in sorted) {
        BOOL suppressed = NO;
        for (YTDetectionBox *kept in result) {
            CGRect intersection = CGRectIntersection(current.normalizedRect, kept.normalizedRect);
            if (CGRectIsNull(intersection)) continue;
            CGFloat interArea = CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
            CGFloat curArea = CGRectGetWidth(current.normalizedRect) * CGRectGetHeight(current.normalizedRect);
            CGFloat keptArea = CGRectGetWidth(kept.normalizedRect) * CGRectGetHeight(kept.normalizedRect);
            CGFloat unionArea = curArea + keptArea - interArea;
            CGFloat iou = interArea / MAX(unionArea, 0.00001);
            if (iou > threshold) {
                suppressed = YES;
                break;
            }
        }
        if (!suppressed) {
            [result addObject:current];
        }
    }
    return result;
}

- (void)performAutoAimForBoxes:(NSArray<YTDetectionBox *> *)boxes {
    if (!self.enabled || !self.autoAimEnabled || self.touchPositionEditing ||
        boxes.count == 0) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastAutoAimTime > 0 && now - self.lastAutoAimTime < YTAutoAimInterval) {
        return;
    }

    // --- Locked target with hysteresis ---
    // Maintain a persistent lock on the current target so the aim doesn't
    // flip between nearby boxes every frame. Only re-acquire when the locked
    // target hasn't been seen for 0.6s.
    YTDetectionBox *target = nil;

    if (self.hasLockedTarget) {
        CFTimeInterval lockAge = now - self.lockedTargetLastSeenTime;
        if (lockAge < 0.6) {
            // Find the tracked box closest to our locked center.
            CGFloat bestDist = CGFLOAT_MAX;
            for (YTDetectionBox *box in boxes) {
                if (box.opacity < 0.3) continue;
                CGPoint center = CGPointMake(CGRectGetMidX(box.targetRect),
                                             CGRectGetMidY(box.targetRect));
                CGFloat dist = hypot(center.x - self.lockedTargetCenter.x,
                                     center.y - self.lockedTargetCenter.y);
                if (dist < 0.12 && dist < bestDist) {
                    bestDist = dist;
                    target = box;
                }
            }
        }
        if (!target) {
            self.hasLockedTarget = NO;
        }
    }

    // No lock — acquire the nearest visible tracked box to screen center.
    if (!target) {
        CGFloat nearestDistance = CGFLOAT_MAX;
        for (YTDetectionBox *box in boxes) {
            if (box.opacity < 0.3) continue;
            CGPoint center = CGPointMake(CGRectGetMidX(box.targetRect),
                                         CGRectGetMidY(box.targetRect));
            CGFloat distance = hypot(center.x - 0.5, center.y - 0.5);
            if (distance < nearestDistance) {
                nearestDistance = distance;
                target = box;
            }
        }
    }

    UIWindow *hostWindow = [self hostWindowForTouchInjection];
    if (!target || !hostWindow || ![YTTouchSynthesizer isAvailable]) {
        return;
    }

    // Update lock state so next frame tries to follow this same target.
    self.lockedTargetCenter = CGPointMake(CGRectGetMidX(target.targetRect),
                                          CGRectGetMidY(target.targetRect));
    self.lockedTargetLastSeenTime = now;
    self.hasLockedTarget = YES;

    // --- Velocity prediction ---
    // Predict where the target will be when the swipe finishes, so we aim
    // ahead of moving targets instead of always chasing their old position.
    NSTimeInterval predictionTime = YTAutoAimInterval * 0.5;
    CGFloat predictedCenterX = CGRectGetMidX(target.targetRect) +
                               target.centerVelocity.dx * predictionTime;
    CGFloat predictedCenterY = CGRectGetMidY(target.targetRect) +
                               target.centerVelocity.dy * predictionTime;
    predictedCenterX = MAX(0, MIN(1, predictedCenterX));
    predictedCenterY = MAX(0, MIN(1, predictedCenterY));

    CGSize size = hostWindow.bounds.size;
    CGPoint targetPoint = CGPointMake(predictedCenterX * size.width,
                                      (1.0 - predictedCenterY) * size.height);
    CGPoint sightCenter = CGPointMake(size.width * 0.5, size.height * 0.5);
    CGVector correction = CGVectorMake(targetPoint.x - sightCenter.x,
                                       targetPoint.y - sightCenter.y);
    CGFloat distance = hypot(correction.dx, correction.dy);
    if (distance < 7.0) {
        return;
    }

    CGFloat scale = YTAutoAimGain;
    CGFloat squareRadius = YTTouchSquareSize * 0.5 - 8.0;
    if (distance * scale > squareRadius) {
        scale = squareRadius / distance;
    }
    CGPoint start = CGPointMake(self.touchPositionNormalized.x * size.width,
                                self.touchPositionNormalized.y * size.height);
    CGPoint end = CGPointMake(start.x + correction.dx * scale,
                              start.y + correction.dy * scale);
    // Keep the swipe end point inside the touch square.
    end.x = MAX(start.x - squareRadius, MIN(start.x + squareRadius, end.x));
    end.y = MAX(start.y - squareRadius, MIN(start.y + squareRadius, end.y));
    if (hypot(end.x - start.x, end.y - start.y) < 3.0) {
        return;
    }

    // Derive a uniform-speed duration from the swipe distance so every swipe
    // moves at the same moderate pace.
    CGFloat swipeDistance = hypot(end.x - start.x, end.y - start.y);
    NSTimeInterval swipeDuration = swipeDistance / YTAutoAimSwipeSpeed;
    swipeDuration = MAX(YTAutoAimMinDuration, MIN(YTAutoAimMaxDuration, swipeDuration));

    self.lastAutoAimTime = now;
    [YTTouchSynthesizer swipeFromPoint:start
                               toPoint:end
                              inWindow:hostWindow
                              duration:swipeDuration];
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
            // Vision reports Core ML observations relative to regionOfInterest.
            box.normalizedRect =
                [self fullImageRectFromRegionLocalRect:object.boundingBox];
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
    boxes = [[self nonMaxSuppression:boxes iouThreshold:0.45] mutableCopy];
    boxes = [[self boxesInsideCircularRegion:boxes] mutableCopy];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.inferenceInProgress = NO;
        self.drawingView.boxes = self.enabled ? boxes : @[];
        // Use tracked boxes (with velocity + smoothing) for auto-aim instead
        // of raw detections — this prevents the aim from jittering between
        // duplicate raw boxes and gives us velocity for prediction.
        [self performAutoAimForBoxes:self.drawingView.boxes];
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
        normalized = [self fullImageRectFromRegionLocalRect:normalized];

        YTDetectionBox *box = [[YTDetectionBox alloc] init];
        box.normalizedRect = normalized;
        box.label = @"item";
        box.confidence = score;
        [boxes addObject:box];
    }
    return boxes;
}

@end
