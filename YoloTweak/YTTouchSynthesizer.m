#import "YTTouchSynthesizer.h"

#import <objc/message.h>
#import <objc/runtime.h>

// ============================================================================
// MARK: - Synthetic touch flag (prevents recording our own injected events)
//
// Set to YES on the current thread before sendEvent: and cleared after.
// The swizzled sendEvent: checks this flag and skips recording when active.
// ============================================================================

static NSString *const kSimulatingKey = @"_ytSimulating";

static void YTSetSimulating(BOOL simulating) {
    if (simulating) {
        [NSThread currentThread].threadDictionary[kSimulatingKey] = @YES;
    } else {
        [[NSThread currentThread].threadDictionary removeObjectForKey:kSimulatingKey];
    }
}

static BOOL YTIsSimulating(void) {
    return [[NSThread currentThread].threadDictionary[kSimulatingKey] boolValue];
}

// ============================================================================
// MARK: - YTRecordedEvent
// ============================================================================

@interface YTRecordedEvent : NSObject
@property (nonatomic, assign) UITouchPhase phase;
@property (nonatomic, assign) CGPoint locationInWindow;
@property (nonatomic, assign) CGPoint previousLocationInWindow;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, assign) NSTimeInterval relativeTime;
@property (nonatomic, assign) NSUInteger touchHash;
@property (nonatomic, copy) NSString *touchIdentifier;
@end

@implementation YTRecordedEvent
@end

// ============================================================================
// MARK: - Recording state (file-scope statics)
// ============================================================================

static BOOL sRecording = NO;
static BOOL sReplaying = NO;
static NSTimeInterval sRecordStartTime = 0;
static NSMutableArray<YTRecordedEvent *> *sRecordedEvents = nil;
static NSMutableDictionary<NSNumber *, NSString *> *sTouchIdentifiers = nil;
static int64_t sNextTouchId = 1;

// ============================================================================
// MARK: - YTTouchSynthesizer
// ============================================================================

@interface YTTouchSynthesizer ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UITouch *> *activeTouches;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIWindow *> *activeWindows;
@property (nonatomic, assign) int64_t nextKey;
@property (nonatomic, strong) dispatch_queue_t swipeQueue;
+ (void)recordEvent:(UIEvent *)event;
@end

// ============================================================================
// MARK: - UIApplication swizzle (sendEvent: interception)
// ============================================================================

@interface UIApplication (YTRecording)
- (void)yt_recordedSendEvent:(UIEvent *)event;
@end

@implementation UIApplication (YTRecording)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [UIApplication class];
        SEL original = @selector(sendEvent:);
        SEL swizzled = @selector(yt_recordedSendEvent:);
        Method origMethod = class_getInstanceMethod(cls, original);
        Method swizMethod = class_getInstanceMethod(cls, swizzled);
        if (origMethod && swizMethod) {
            method_exchangeImplementations(origMethod, swizMethod);
            NSLog(@"[YoloTweak] sendEvent: swizzled OK");
        }
    });
}

- (void)yt_recordedSendEvent:(UIEvent *)event {
    if (sRecording && !sReplaying && !YTIsSimulating() && event.allTouches.count > 0) {
        @try {
            [YTTouchSynthesizer recordEvent:event];
        } @catch (NSException *e) {
            NSLog(@"[YoloTweak] record exception: %@", e);
        }
    }
    // Call original (which is now yt_recordedSendEvent: due to swizzle).
    [self yt_recordedSendEvent:event];
}

@end

@implementation YTTouchSynthesizer

+ (instancetype)sharedInstance {
    static YTTouchSynthesizer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeTouches = [NSMutableDictionary dictionary];
        _activeWindows = [NSMutableDictionary dictionary];
        _nextKey = 1;
        _swipeQueue = dispatch_queue_create("com.yolotweak.swipe", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// ============================================================================
// MARK: - Availability
// ============================================================================

+ (BOOL)isAvailable {
    return [UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)];
}

+ (BOOL)isSystemOrOverlayWindow:(UIWindow *)window
                    overlayWindow:(UIWindow *)overlayWindow {
    if (window == overlayWindow) return YES;
    if (window.hidden || window.alpha < 0.01) return YES;
    NSString *className = NSStringFromClass([window class]);
    if ([className containsString:@"TextEffects"]) return YES;
    if ([className containsString:@"Passthrough"]) return YES;
    if (window.bounds.size.width < 100 || window.bounds.size.height < 100) return YES;
    return NO;
}

+ (nullable UIWindow *)bestHostWindowExcluding:(UIWindow *)overlayWindow {
    NSMutableArray<UIWindow *> *candidates = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            [candidates addObjectsFromArray:ws.windows];
        }
    }
    if (candidates.count == 0) {
        [candidates addObjectsFromArray: UIApplication.sharedApplication.windows];
    }

    // Pass 1: prefer key window if it's a real app window.
    for (UIWindow *window in candidates) {
        if ([self isSystemOrOverlayWindow:window overlayWindow:overlayWindow]) continue;
        if (window.isKeyWindow) return window;
    }

    // Pass 2: largest non-system window.
    UIWindow *best = nil;
    CGFloat bestArea = 0;
    for (UIWindow *window in candidates) {
        if ([self isSystemOrOverlayWindow:window overlayWindow:overlayWindow]) continue;
        CGFloat area = window.bounds.size.width * window.bounds.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = window;
        }
    }
    return best;
}

// ============================================================================
// MARK: - Public primitives
// ============================================================================

+ (NSNumber *)allocTouchKey {
    return [[self sharedInstance] allocKey:nil];
}

+ (void)touchDownAtPoint:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key {
    [[self sharedInstance] performTouchDownAtPoint:point inWindow:window key:key];
}

+ (void)touchMoveTo:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key {
    [[self sharedInstance] performTouchMoveTo:point inWindow:window key:key];
}

+ (void)touchUpAtPoint:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key {
    [[self sharedInstance] performTouchUpAtPoint:point inWindow:window key:key];
}

+ (void)reset {
    [[self sharedInstance] resetState];
}

// ============================================================================
// MARK: - Swipe (path-sampled down -> move... -> up)
// ============================================================================

+ (void)swipeFromPoint:(CGPoint)start
                toPoint:(CGPoint)end
              inWindow:(UIWindow *)window
              duration:(NSTimeInterval)duration {
    if (!window || ![self isAvailable]) {
        NSLog(@"[YoloTweak] swipe ABORT: window=%p isAvailable=%d", window, [self isAvailable]);
        return;
    }
    if (duration < 0.008) duration = 0.008;

    YTTouchSynthesizer *inst = [self sharedInstance];
    dispatch_async(inst.swipeQueue, ^{
        NSNumber *key = [inst allocKey:nil];

        NSInteger steps = (NSInteger)(duration / 0.010);
        if (steps < 6) steps = 6;
        if (steps > 60) steps = 60;

        NSTimeInterval stepDuration = duration / (double)steps;
        NSTimeInterval t0 = CACurrentMediaTime();

        NSLog(@"[YoloTweak] swipe start (%.0f,%.0f)->(%.0f,%.0f) steps=%ld dur=%.0fms",
              start.x, start.y, end.x, end.y, (long)steps, duration * 1000);

        [inst performTouchDownAtPoint:start inWindow:window key:key];

        for (NSInteger i = 1; i < steps; i++) {
            CGFloat progress = (CGFloat)i / (CGFloat)steps;
            CGPoint point = CGPointMake(start.x + (end.x - start.x) * progress,
                                        start.y + (end.y - start.y) * progress);
            NSTimeInterval targetTime = t0 + stepDuration * (CGFloat)i;
            NSTimeInterval delta = targetTime - CACurrentMediaTime();
            if (delta > 0.001) {
                usleep((useconds_t)(delta * 1000000.0));
            }
            [inst performTouchMoveTo:point inWindow:window key:key];
        }

        NSTimeInterval endDelta = (t0 + duration) - CACurrentMediaTime();
        if (endDelta > 0.001) {
            usleep((useconds_t)(endDelta * 1000000.0));
        }
        [inst performTouchUpAtPoint:end inWindow:window key:key];
        NSLog(@"[YoloTweak] swipe done");
    });
}

// ============================================================================
// MARK: - Core: UITouch creation via private setters
//
// KEY DIFFERENCES from the old approach:
// 1. _setLocationInWindow:resetPrevious: (updates ALL derived coordinates)
//    instead of KVC _locationInWindow (only updates the raw ivar)
// 2. systemUptime (seconds) instead of mach_absolute_time (raw mach ticks)
//    — UIKit expects seconds; raw mach values cause sendEvent to discard
//      the touch as stale/invalid
// 3. dispatch_async to main instead of dispatch_sync — the main queue is
//    serial so ordering is preserved, and async avoids deadlock risk
// ============================================================================

- (NSNumber *)allocKey:(NSNumber *)hint {
    if (hint) return hint;
    NSNumber *key = @(self.nextKey);
    self.nextKey += 1;
    return key;
}

/// Update touch location via the private setter that syncs all derived fields.
/// resetPrevious=NO keeps the previous location for delta calculation.
- (void)updateTouchLocation:(UITouch *)touch point:(CGPoint)point {
    if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]) {
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(
            touch, @selector(_setLocationInWindow:resetPrevious:), point, NO);
    }
}

/// Update touch phase and timestamp.
/// CRITICAL: timestamp must be systemUptime (seconds), NOT mach_absolute_time.
- (void)updateTouchPhase:(UITouch *)touch phase:(UITouchPhase)phase {
    if ([touch respondsToSelector:@selector(setPhase:)]) {
        ((void (*)(id, SEL, UITouchPhase))objc_msgSend)(
            touch, @selector(setPhase:), phase);
    }
    if ([touch respondsToSelector:@selector(setTimestamp:)]) {
        NSTimeInterval timestamp = [[NSProcessInfo processInfo] systemUptime];
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(
            touch, @selector(setTimestamp:), timestamp);
    }
}

/// Create a UITouch through private setters (not KVC).
- (UITouch *)createTouchAtPoint:(CGPoint)point inWindow:(UIWindow *)window phase:(UITouchPhase)phase {
    UITouch *touch = [[UITouch alloc] init];

    // setWindow:
    if ([touch respondsToSelector:@selector(setWindow:)]) {
        [touch performSelector:@selector(setWindow:) withObject:window];
    }

    // _setLocationInWindow:resetPrevious: (resetPrevious=YES for new touch)
    if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]) {
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(
            touch, @selector(_setLocationInWindow:resetPrevious:), point, YES);
    }

    // hitTest -> setView:
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!hitView) hitView = window;
    if ([touch respondsToSelector:@selector(setView:)]) {
        [touch performSelector:@selector(setView:) withObject:hitView];
    }

    // setPhase:
    if ([touch respondsToSelector:@selector(setPhase:)]) {
        ((void (*)(id, SEL, UITouchPhase))objc_msgSend)(
            touch, @selector(setPhase:), phase);
    }

    // _setIsFirstTouchForView: (or _setIsTapToClick: as fallback)
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            touch, @selector(_setIsFirstTouchForView:), YES);
    } else if ([touch respondsToSelector:@selector(_setIsTapToClick:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            touch, @selector(_setIsTapToClick:), YES);
    }

    // setTimestamp: (systemUptime in SECONDS, not mach_absolute_time)
    if ([touch respondsToSelector:@selector(setTimestamp:)]) {
        NSTimeInterval timestamp = [[NSProcessInfo processInfo] systemUptime];
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(
            touch, @selector(setTimestamp:), timestamp);
    }

    // setGestureView:
    if ([touch respondsToSelector:@selector(setGestureView:)]) {
        [touch performSelector:@selector(setGestureView:) withObject:hitView];
    }

    return touch;
}

/// Build a UIEvent using the app's shared _touchesEvent.
- (UIEvent *)eventWithTouches:(NSArray *)touches {
    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *event = nil;

    if ([app respondsToSelector:@selector(_touchesEvent)]) {
        event = ((id (*)(id, SEL))objc_msgSend)(app, @selector(_touchesEvent));
    }
    if (!event) {
        NSLog(@"[YoloTweak] _touchesEvent returned nil");
        return nil;
    }

    if ([event respondsToSelector:@selector(_clearTouches)]) {
        ((void (*)(id, SEL))objc_msgSend)(event, @selector(_clearTouches));
    }

    if ([event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) {
        for (UITouch *touch in touches) {
            ((void (*)(id, SEL, UITouch *, BOOL))objc_msgSend)(
                event, @selector(_addTouch:forDelayedDelivery:), touch, NO);
        }
    }

    return event;
}

/// Send touch event via sendEvent: on the main thread (async).
- (void)sendTouchEventWithTouch:(UITouch *)touch inWindow:(UIWindow *)window point:(CGPoint)point {
    void (^work)(void) = ^{
        YTSetSimulating(YES);

        UIEvent *event = [self eventWithTouches:@[touch]];
        if (event) {
            [UIApplication.sharedApplication sendEvent:event];
        } else {
            // Fallback: direct view touches delivery.
            UIView *targetView = [window hitTest:point withEvent:nil] ?: window;
            NSSet *touches = [NSSet setWithObject:touch];
            if (touch.phase == UITouchPhaseBegan) {
                [targetView touchesBegan:touches withEvent:nil];
            } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                [targetView touchesEnded:touches withEvent:nil];
            } else if (touch.phase == UITouchPhaseMoved) {
                [targetView touchesMoved:touches withEvent:nil];
            }
        }

        YTSetSimulating(NO);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

// ============================================================================
// MARK: - Down / Move / Up
// ============================================================================

- (void)performTouchDownAtPoint:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key {
    if (!window) return;
    void (^work)(void) = ^{
        YTSetSimulating(YES);
        NSNumber *k = [self allocKey:key];
        UITouch *touch = [self createTouchAtPoint:point inWindow:window phase:UITouchPhaseBegan];
        [self sendTouchEventWithTouch:touch inWindow:window point:point];
        self.activeTouches[k] = touch;
        self.activeWindows[k] = window;
        YTSetSimulating(NO);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

- (void)performTouchMoveTo:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key {
    if (!window) return;
    void (^work)(void) = ^{
        YTSetSimulating(YES);
        NSNumber *k = [self allocKey:key];
        UITouch *touch = self.activeTouches[k];
        if (!touch) {
            touch = [self createTouchAtPoint:point inWindow:window phase:UITouchPhaseMoved];
            self.activeTouches[k] = touch;
            self.activeWindows[k] = window;
        }
        [self updateTouchLocation:touch point:point];
        [self updateTouchPhase:touch phase:UITouchPhaseMoved];
        [self sendTouchEventWithTouch:touch inWindow:window point:point];
        YTSetSimulating(NO);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

- (void)performTouchUpAtPoint:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key {
    if (!window) return;
    void (^work)(void) = ^{
        YTSetSimulating(YES);
        NSNumber *k = [self allocKey:key];
        UITouch *touch = self.activeTouches[k];
        if (!touch) {
            touch = [self createTouchAtPoint:point inWindow:window phase:UITouchPhaseEnded];
        }
        [self updateTouchLocation:touch point:point];
        [self updateTouchPhase:touch phase:UITouchPhaseEnded];
        [self sendTouchEventWithTouch:touch inWindow:window point:point];
        [self.activeTouches removeObjectForKey:k];
        [self.activeWindows removeObjectForKey:k];
        YTSetSimulating(NO);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

- (void)resetState {
    void (^work)(void) = ^{
        YTSetSimulating(YES);
        for (NSNumber *key in self.activeTouches.allKeys) {
            UITouch *touch = self.activeTouches[key];
            UIWindow *window = self.activeWindows[key];
            if (touch && window) {
                [self updateTouchPhase:touch phase:UITouchPhaseEnded];
                CGPoint pt = CGPointZero;
                @try { pt = [[touch valueForKey:@"_locationInWindow"] CGPointValue]; } @catch (...) {}
                [self sendTouchEventWithTouch:touch inWindow:window point:pt];
            }
        }
        [self.activeTouches removeAllObjects];
        [self.activeWindows removeAllObjects];
        YTSetSimulating(NO);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

// ============================================================================
// MARK: - Diagnostic
// ============================================================================

+ (NSString *)runDiagnosticInWindow:(UIWindow *)window {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"=== 触摸诊断 ===\n"];

    if (!window) {
        [report appendString:@"X hostWindow = nil\n"];
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            [report appendFormat:@"  - %@ lvl=%.0f hidden=%d alpha=%.2f key=%d bounds=%@\n",
                NSStringFromClass([w class]), w.windowLevel, w.hidden, w.alpha,
                w.isKeyWindow, NSStringFromCGRect(w.bounds)];
        }
        return report;
    }
    [report appendFormat:@"OK hostWindow: %@ %@\n",
        NSStringFromClass([window class]), NSStringFromCGRect(window.bounds)];

    // Check private API availability
    UIApplication *app = UIApplication.sharedApplication;
    BOOL hasTouchesEvent = [app respondsToSelector:@selector(_touchesEvent)];
    [report appendFormat:@"%@ _touchesEvent: %@\n",
        hasTouchesEvent ? @"OK" : @"X", hasTouchesEvent ? @"available" : @"missing"];

    UITouch *testTouch = [[UITouch alloc] init];
    BOOL hasSetLocation = [testTouch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)];
    BOOL hasSetPhase = [testTouch respondsToSelector:@selector(setPhase:)];
    BOOL hasSetTimestamp = [testTouch respondsToSelector:@selector(setTimestamp:)];
    [report appendFormat:@"%@ _setLocationInWindow:resetPrevious: %@\n",
        hasSetLocation ? @"OK" : @"X", hasSetLocation ? @"OK" : @"missing"];
    [report appendFormat:@"%@ setPhase: %@\n",
        hasSetPhase ? @"OK" : @"X", hasSetPhase ? @"OK" : @"missing"];
    [report appendFormat:@"%@ setTimestamp: %@\n",
        hasSetTimestamp ? @"OK" : @"X", hasSetTimestamp ? @"OK" : @"missing"];

    BOOL canSendEvent = [app respondsToSelector:@selector(sendEvent:)];
    [report appendFormat:@"%@ sendEvent: %@\n",
        canSendEvent ? @"OK" : @"X", canSendEvent ? @"OK" : @"missing"];

    BOOL pipelineOK = window && hasTouchesEvent && hasSetLocation && hasSetPhase && hasSetTimestamp && canSendEvent;
    if (!pipelineOK) {
        [report appendString:@"\nX Pipeline incomplete\n"];
        return report;
    }

    [report appendString:@"\nOK Pipeline complete, running test swipe...\n"];

    // Test swipe: left-to-right horizontal swipe in the middle of the screen
    CGSize size = window.bounds.size;
    CGPoint start = CGPointMake(size.width * 0.25, size.height * 0.5);
    CGPoint end = CGPointMake(size.width * 0.75, size.height * 0.5);

    [self swipeFromPoint:start toPoint:end inWindow:window duration:0.35];

    [report appendFormat:@"Swipe (%.0f,%.0f)->(%.0f,%.0f) sent\n",
        start.x, start.y, end.x, end.y];
    [report appendString:@"\nObserve if the screen responds to the swipe"];

    return report;
}

// ===========================================================================
// MARK: - Recording & Replay
// ===========================================================================

+ (void)installEventHook {
    NSLog(@"[YoloTweak] installEventHook — swizzle already installed via +load");
}

+ (BOOL)isRecording { return sRecording; }
+ (BOOL)isReplaying { return sReplaying; }

+ (void)startRecording {
    if (sRecording) return;
    if (!sRecordedEvents) {
        sRecordedEvents = [NSMutableArray array];
    } else {
        [sRecordedEvents removeAllObjects];
    }
    if (!sTouchIdentifiers) {
        sTouchIdentifiers = [NSMutableDictionary dictionary];
    } else {
        [sTouchIdentifiers removeAllObjects];
    }
    sNextTouchId = 1;
    sRecording = YES;
    sRecordStartTime = CACurrentMediaTime();
    NSLog(@"[YoloTweak] Recording STARTED");
}

+ (NSUInteger)stopRecording {
    if (!sRecording) return sRecordedEvents.count;
    sRecording = NO;
    NSUInteger count = sRecordedEvents.count;
    NSLog(@"[YoloTweak] Recording STOPPED — %lu events", (unsigned long)count);
    return count;
}

+ (NSUInteger)recordedEventCount {
    return sRecordedEvents.count;
}

+ (NSString *)recordedEventsSummary {
    NSUInteger count = sRecordedEvents.count;
    if (count == 0) return @"No recording";

    YTRecordedEvent *first = sRecordedEvents.firstObject;
    YTRecordedEvent *last = sRecordedEvents.lastObject;
    NSTimeInterval duration = last.relativeTime - first.relativeTime;

    return [NSString stringWithFormat:
        @"%lu events | %.2fs\n"
        @"first: phase=%ld (%.0f,%.0f)\n"
        @"last:  phase=%ld (%.0f,%.0f)",
        (unsigned long)count, duration,
        (long)first.phase, first.locationInWindow.x, first.locationInWindow.y,
        (long)last.phase, last.locationInWindow.x, last.locationInWindow.y];
}

+ (void)clearRecording {
    sRecording = NO;
    [sRecordedEvents removeAllObjects];
    [sTouchIdentifiers removeAllObjects];
}

/// Captures a real touch event from the swizzled sendEvent:.
+ (void)recordEvent:(UIEvent *)event {
    if (!event.allTouches || event.allTouches.count == 0) return;

    NSTimeInterval relTime = CACurrentMediaTime() - sRecordStartTime;
    UIWindow *window = nil;

    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseStationary) continue;

        if (!window) {
            @try { window = [touch valueForKey:@"_window"]; } @catch (...) {}
            if (!window) window = touch.window;
        }

        CGPoint loc = [touch locationInView:window];

        // Assign a stable identifier per UITouch pointer.
        NSNumber *ptrKey = @((uintptr_t)touch);
        NSString *identifier = sTouchIdentifiers[ptrKey];
        if (!identifier) {
            identifier = [NSString stringWithFormat:@"t%lld", sNextTouchId];
            sNextTouchId += 1;
            sTouchIdentifiers[ptrKey] = identifier;
        }

        YTRecordedEvent *rec = [[YTRecordedEvent alloc] init];
        rec.phase = touch.phase;
        rec.locationInWindow = loc;
        rec.previousLocationInWindow = [touch previousLocationInView:window];
        rec.relativeTime = relTime;
        rec.touchHash = [touch hash];
        rec.touchIdentifier = identifier;
        rec.window = window;

        [sRecordedEvents addObject:rec];

        if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
            [sTouchIdentifiers removeObjectForKey:ptrKey];
        }
    }
}

+ (void)replayRecording {
    NSUInteger count = sRecordedEvents.count;
    if (count == 0) {
        NSLog(@"[YoloTweak] replay: nothing to replay");
        return;
    }

    NSLog(@"[YoloTweak] Replay START — %lu events", (unsigned long)count);
    sReplaying = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSTimeInterval t0 = CACurrentMediaTime();
        NSTimeInterval firstRel = sRecordedEvents.firstObject.relativeTime;

        // Pre-allocate touch keys per identifier.
        NSMutableDictionary<NSString *, NSNumber *> *keyMap = [NSMutableDictionary dictionary];
        int64_t nextKeyId = 1;
        for (YTRecordedEvent *rec in sRecordedEvents) {
            if (!keyMap[rec.touchIdentifier]) {
                keyMap[rec.touchIdentifier] = @(nextKeyId);
                nextKeyId += 1;
            }
        }

        for (NSUInteger i = 0; i < sRecordedEvents.count; i++) {
            YTRecordedEvent *rec = sRecordedEvents[i];

            NSTimeInterval target = t0 + (rec.relativeTime - firstRel);
            NSTimeInterval delta = target - CACurrentMediaTime();
            if (delta > 0.001) {
                usleep((useconds_t)(delta * 1000000.0));
            }

            UIWindow *window = rec.window;
            if (!window || window.hidden) {
                window = [self bestHostWindowExcluding:nil];
            }
            if (!window) continue;

            NSNumber *key = keyMap[rec.touchIdentifier];
            if (!key) key = @(0);

            switch (rec.phase) {
                case UITouchPhaseBegan:
                    [self touchDownAtPoint:rec.locationInWindow inWindow:window key:key];
                    break;
                case UITouchPhaseMoved:
                    [self touchMoveTo:rec.locationInWindow inWindow:window key:key];
                    break;
                case UITouchPhaseEnded:
                case UITouchPhaseCancelled:
                    [self touchUpAtPoint:rec.locationInWindow inWindow:window key:key];
                    break;
                default:
                    break;
            }
        }

        sReplaying = NO;
        NSLog(@"[YoloTweak] Replay DONE — %lu events", (unsigned long)count);
    });
}

@end
