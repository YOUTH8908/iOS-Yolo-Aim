#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages the floating entry button and its menu.
@interface YTOverlayManager : NSObject

+ (instancetype)sharedManager;
- (void)start;
- (void)show;
- (void)hide;

@end

NS_ASSUME_NONNULL_END
