#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Synthesizes touches inside the host application via UITouch private setters
/// + UIEvent + sendEvent.
///
/// Uses `_setLocationInWindow:resetPrevious:` (private setter that updates all
/// derived coordinates) and `systemUptime` (seconds, not mach_absolute_time)
/// to construct touches that UIKit will properly deliver.
///
/// A single swipe reuses one UITouch object across down/move/up so the host
/// sees a continuous finger rather than disconnected taps.
@interface YTTouchSynthesizer : NSObject

+ (BOOL)isAvailable;

/// One-shot swipe from `start` to `end` in window coordinates.
+ (void)swipeFromPoint:(CGPoint)start
                toPoint:(CGPoint)end
              inWindow:(UIWindow *)window
              duration:(NSTimeInterval)duration;

/// Low-level primitives. touchDown/touchUp must share the same key so the
/// same UITouch object is reused. Pass nil to auto-allocate.
+ (NSNumber *)allocTouchKey;
+ (void)touchDownAtPoint:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key;
+ (void)touchMoveTo:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key;
+ (void)touchUpAtPoint:(CGPoint)point inWindow:(UIWindow *)window key:(nullable NSNumber *)key;

/// Release all active synthetic touches (recovery).
+ (void)reset;

/// Finds the best host window for touch injection.
/// Skips overlay/system windows (UITextEffectsWindow, pass-through windows,
/// hidden, transparent, or tiny windows) and returns the first real app window.
+ (nullable UIWindow *)bestHostWindowExcluding:(UIWindow *)overlayWindow;

/// Runs a full diagnostic pass and returns a human-readable report.
+ (NSString *)runDiagnosticInWindow:(UIWindow *)window;

// ===========================================================================
// MARK: - Recording & Replay
//
// Captures real touch events from the system by swizzling sendEvent:.
// Each captured touch's location, phase, and timing are stored for replay.
// ===========================================================================

/// Swizzles UIApplication.sendEvent: at load time to intercept real touches.
/// Called automatically from +load; no need to call manually.
+ (void)installEventHook;

+ (BOOL)isRecording;
+ (BOOL)isReplaying;

/// Start capturing real touch events.  Clears any previous recording.
+ (void)startRecording;

/// Stop capturing and return the number of events recorded.
+ (NSUInteger)stopRecording;

+ (NSUInteger)recordedEventCount;

/// Returns a short human-readable summary of the recording.
+ (NSString *)recordedEventsSummary;

/// Replays the recorded touch events with original timing.
+ (void)replayRecording;

+ (void)clearRecording;

@end

NS_ASSUME_NONNULL_END
