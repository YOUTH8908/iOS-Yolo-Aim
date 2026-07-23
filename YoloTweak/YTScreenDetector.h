#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the bundled YOLO Core ML model against the host application's visible UI.
@interface YTScreenDetector : NSObject

+ (instancetype)sharedDetector;
- (void)attachToOverlayView:(UIView *)overlayView
            excludingWindow:(UIWindow *)overlayWindow;

@end

NS_ASSUME_NONNULL_END
