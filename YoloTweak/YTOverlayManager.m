#import "YTOverlayManager.h"
#import "YTScreenDetector.h"
#import "YTTouchSynthesizer.h"

static const CGFloat YTBallSize = 58.0;
static const CGFloat YTEdgeMargin = 12.0;

@interface YTPassthroughWindow : UIWindow
@end

@implementation YTPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    // Let the host application receive touches in the transparent area.
    if (view == self || view == self.rootViewController.view) {
        return nil;
    }
    return view;
}

@end

@interface YTOverlayViewController : UIViewController
@end

@implementation YTOverlayViewController

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end

@interface YTOverlayManager () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) YTPassthroughWindow *overlayWindow;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIVisualEffectView *menuView;
@property (nonatomic, strong) UIView *dimmingView;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL menuVisible;
@property (nonatomic, assign) CGPoint panStartCenter;
@property (nonatomic, strong) UILabel *diagnosticLabel;
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *replayButton;
@property (nonatomic, strong) UILabel *recordStatusLabel;
@end

@implementation YTOverlayManager

+ (instancetype)sharedManager {
    static YTOverlayManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.started) {
            self.started = YES;
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserver:self
                      selector:@selector(applicationBecameActive:)
                          name:UIApplicationDidBecomeActiveNotification
                        object:nil];
            if (@available(iOS 13.0, *)) {
                [center addObserver:self
                          selector:@selector(sceneBecameActive:)
                              name:UISceneDidActivateNotification
                            object:nil];
            }
        }
        [self installOverlayIfNeeded];
    });
}

- (void)applicationBecameActive:(NSNotification *)notification {
    [self installOverlayIfNeeded];
}

- (void)sceneBecameActive:(NSNotification *)notification {
    [self installOverlayIfNeeded];
}

- (UIWindowScene *)activeWindowScene API_AVAILABLE(ios(13.0)) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (scene.activationState == UISceneActivationStateForegroundInactive) {
            fallback = windowScene;
        }
    }
    return fallback;
}

- (void)installOverlayIfNeeded {
    NSAssert(NSThread.isMainThread, @"Overlay must be installed on the main thread.");

    if (self.overlayWindow) {
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = [self activeWindowScene];
            if (scene && self.overlayWindow.windowScene != scene) {
                self.overlayWindow.windowScene = scene;
                self.overlayWindow.frame = scene.coordinateSpace.bounds;
            }
        }
        self.overlayWindow.hidden = NO;
        return;
    }

    CGRect frame = UIScreen.mainScreen.bounds;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (!scene) {
            // A scene notification will call this method again.
            return;
        }
        self.overlayWindow = [[YTPassthroughWindow alloc] initWithWindowScene:scene];
        frame = scene.coordinateSpace.bounds;
    } else {
        self.overlayWindow = [[YTPassthroughWindow alloc] initWithFrame:frame];
    }

    self.overlayWindow.frame = frame;
    self.overlayWindow.backgroundColor = UIColor.clearColor;
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 100.0;
    self.overlayWindow.rootViewController = [[YTOverlayViewController alloc] init];
    self.overlayWindow.hidden = NO;

    [self buildFloatingButton];
    [self buildMenu];
    [[YTScreenDetector sharedDetector]
        attachToOverlayView:self.overlayWindow.rootViewController.view
            excludingWindow:self.overlayWindow];
}

- (void)buildFloatingButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(CGRectGetWidth(self.overlayWindow.bounds) - YTBallSize - YTEdgeMargin,
                              CGRectGetHeight(self.overlayWindow.bounds) * 0.38,
                              YTBallSize,
                              YTBallSize);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleTopMargin |
                              UIViewAutoresizingFlexibleBottomMargin;
    button.backgroundColor = [UIColor colorWithRed:0.12 green:0.55 blue:1.0 alpha:0.96];
    button.layer.cornerRadius = YTBallSize * 0.5;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.72].CGColor;
    button.layer.borderWidth = 2.0;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowRadius = 9.0;
    button.layer.shadowOffset = CGSizeMake(0, 4);

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:23
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [UIImage systemImageNamed:@"scope" withConfiguration:config];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"打开 Yolo 菜单";

    [button addTarget:self
               action:@selector(floatingButtonTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = YES;
    [button addGestureRecognizer:pan];

    [self.overlayWindow.rootViewController.view addSubview:button];
    self.floatingButton = button;
}

- (UILabel *)labelWithText:(NSString *)text
                      font:(UIFont *)font
                     color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = font;
    label.textColor = color;
    return label;
}

- (UIStackView *)menuRowWithTitle:(NSString *)title
                           detail:(NSString *)detail
                           toggle:(UISwitch *)toggle {
    UILabel *titleLabel = [self labelWithText:title
                                         font:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]
                                        color:UIColor.labelColor];
    UILabel *detailLabel = [self labelWithText:detail
                                          font:[UIFont systemFontOfSize:12 weight:UIFontWeightRegular]
                                         color:UIColor.secondaryLabelColor];
    detailLabel.numberOfLines = 2;

    UIStackView *labels =
        [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, detailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 3;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labels, toggle]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14;
    return row;
}

- (void)buildMenu {
    UIView *root = self.overlayWindow.rootViewController.view;

    UIView *dimmingView = [[UIView alloc] init];
    dimmingView.translatesAutoresizingMaskIntoConstraints = NO;
    dimmingView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22];
    dimmingView.alpha = 0;
    dimmingView.hidden = YES;
    [dimmingView addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped:)]];
    [root insertSubview:dimmingView belowSubview:self.floatingButton];
    [NSLayoutConstraint activateConstraints:@[
        [dimmingView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [dimmingView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [dimmingView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [dimmingView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.dimmingView = dimmingView;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *menu = [[UIVisualEffectView alloc] initWithEffect:blur];
    menu.translatesAutoresizingMaskIntoConstraints = NO;
    menu.layer.cornerRadius = 22;
    menu.layer.cornerCurve = kCACornerCurveContinuous;
    menu.clipsToBounds = YES;
    menu.alpha = 0;
    menu.hidden = YES;
    menu.transform = CGAffineTransformMakeScale(0.86, 0.86);

    UILabel *title = [self labelWithText:@"Yolo 工具"
                                    font:[UIFont systemFontOfSize:21 weight:UIFontWeightBold]
                                   color:UIColor.labelColor];
    UILabel *subtitle = [self labelWithText:@"悬浮控制中心"
                                       font:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]
                                      color:UIColor.secondaryLabelColor];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
           forState:UIControlStateNormal];
    close.tintColor = UIColor.tertiaryLabelColor;
    [close addTarget:self action:@selector(closeButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];

    UIView *heading = [[UIView alloc] init];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    [heading addSubview:title];
    [heading addSubview:subtitle];
    [heading addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:heading.topAnchor],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
        [subtitle.bottomAnchor constraintEqualToAnchor:heading.bottomAnchor],
        [close.trailingAnchor constraintEqualToAnchor:heading.trailingAnchor],
        [close.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:32],
        [close.heightAnchor constraintEqualToConstant:32],
    ]];

    UISwitch *detectionSwitch = [[UISwitch alloc] init];
    detectionSwitch.onTintColor = [UIColor colorWithRed:0.12 green:0.55 blue:1 alpha:1];
    [detectionSwitch addTarget:self
                        action:@selector(detectionSwitchChanged:)
              forControlEvents:UIControlEventValueChanged];

    UISwitch *boxesSwitch = [[UISwitch alloc] init];
    boxesSwitch.on = YES;
    boxesSwitch.onTintColor = [UIColor colorWithRed:0.12 green:0.55 blue:1 alpha:1];
    [boxesSwitch addTarget:self
                    action:@selector(boxesSwitchChanged:)
          forControlEvents:UIControlEventValueChanged];

    UISwitch *aimLineSwitch = [[UISwitch alloc] init];
    aimLineSwitch.on = YES;
    aimLineSwitch.onTintColor = [UIColor colorWithRed:0.12 green:0.55 blue:1 alpha:1];
    [aimLineSwitch addTarget:self
                      action:@selector(aimLineSwitchChanged:)
            forControlEvents:UIControlEventValueChanged];

    UISwitch *autoAimSwitch = [[UISwitch alloc] init];
    autoAimSwitch.onTintColor = [UIColor colorWithRed:1.0 green:0.36 blue:0.18 alpha:1];
    [autoAimSwitch addTarget:self
                      action:@selector(autoAimSwitchChanged:)
            forControlEvents:UIControlEventValueChanged];

    UISwitch *touchEditorSwitch = [[UISwitch alloc] init];
    touchEditorSwitch.onTintColor = [UIColor colorWithRed:1.0 green:0.66 blue:0.12 alpha:1];
    [touchEditorSwitch addTarget:self
                          action:@selector(touchEditorSwitchChanged:)
                forControlEvents:UIControlEventValueChanged];

    UIButton *testButton = [UIButton buttonWithType:UIButtonTypeSystem];
    testButton.translatesAutoresizingMaskIntoConstraints = NO;
    [testButton setTitle:@"测试触摸滑动" forState:UIControlStateNormal];
    testButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    testButton.tintColor = UIColor.whiteColor;
    testButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.55 blue:1.0 alpha:0.9];
    testButton.layer.cornerRadius = 10;
    testButton.contentEdgeInsets = UIEdgeInsetsMake(10, 0, 10, 0);
    [testButton addTarget:self
                   action:@selector(testButtonTapped:)
         forControlEvents:UIControlEventTouchUpInside];

    UILabel *diagLabel = [self labelWithText:@"点击上方按钮运行诊断"
                                        font:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]
                                       color:UIColor.secondaryLabelColor];
    diagLabel.numberOfLines = 0;
    self.diagnosticLabel = diagLabel;

    // --- Recording button ---
    UIButton *recordBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    recordBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [recordBtn setTitle:@"● 录制触摸" forState:UIControlStateNormal];
    recordBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    recordBtn.tintColor = UIColor.whiteColor;
    recordBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.22 blue:0.18 alpha:0.9];
    recordBtn.layer.cornerRadius = 10;
    recordBtn.contentEdgeInsets = UIEdgeInsetsMake(10, 0, 10, 0);
    [recordBtn addTarget:self
                  action:@selector(recordButtonTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    self.recordButton = recordBtn;

    // --- Replay button ---
    UIButton *replayBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    replayBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [replayBtn setTitle:@"▶ 重放录制" forState:UIControlStateNormal];
    replayBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    replayBtn.tintColor = UIColor.whiteColor;
    replayBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.72 blue:0.36 alpha:0.9];
    replayBtn.layer.cornerRadius = 10;
    replayBtn.contentEdgeInsets = UIEdgeInsetsMake(10, 0, 10, 0);
    [replayBtn addTarget:self
                  action:@selector(replayButtonTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    self.replayButton = replayBtn;

    // --- Recording status label ---
    UILabel *recLabel = [self labelWithText:@"录制真实触摸后重放，测试是否有效"
                                       font:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]
                                      color:UIColor.secondaryLabelColor];
    recLabel.numberOfLines = 0;
    self.recordStatusLabel = recLabel;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        heading,
        [self menuRowWithTitle:@"实时识别" detail:@"打开后开始处理画面" toggle:detectionSwitch],
        [self menuRowWithTitle:@"显示识别框" detail:@"在目标周围显示类别与置信度" toggle:boxesSwitch],
        [self menuRowWithTitle:@"最近目标连线" detail:@"从准心连到最近的目标中心" toggle:aimLineSwitch],
        [self menuRowWithTitle:@"自动瞄准" detail:@"按目标偏移量连续滑动视角" toggle:autoAimSwitch],
        [self menuRowWithTitle:@"编辑触摸位置" detail:@"开启后拖动橙色触摸点" toggle:touchEditorSwitch],
        testButton,
        diagLabel,
        recordBtn,
        replayBtn,
        recLabel,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;

    [menu.contentView addSubview:stack];
    [root insertSubview:menu belowSubview:self.floatingButton];
    [NSLayoutConstraint activateConstraints:@[
        [menu.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [menu.centerYAnchor constraintEqualToAnchor:root.centerYAnchor],
        [menu.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor
                                                        constant:20],
        [menu.trailingAnchor constraintLessThanOrEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor
                                                       constant:-20],
        [menu.widthAnchor constraintEqualToConstant:310],
        [stack.leadingAnchor constraintEqualToAnchor:menu.contentView.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:menu.contentView.trailingAnchor constant:-22],
        [stack.topAnchor constraintEqualToAnchor:menu.contentView.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:menu.contentView.bottomAnchor constant:-24],
    ]];
    self.menuView = menu;
}

- (void)floatingButtonTapped:(UIButton *)sender {
    [self setMenuVisible:!self.menuVisible animated:YES];
}

- (void)backgroundTapped:(UITapGestureRecognizer *)recognizer {
    [self setMenuVisible:NO animated:YES];
}

- (void)closeButtonTapped:(UIButton *)sender {
    [self setMenuVisible:NO animated:YES];
}

- (void)setMenuVisible:(BOOL)visible animated:(BOOL)animated {
    if (self.menuVisible == visible) {
        return;
    }
    self.menuVisible = visible;

    if (visible) {
        self.dimmingView.hidden = NO;
        self.menuView.hidden = NO;
        [self.overlayWindow.rootViewController.view bringSubviewToFront:self.menuView];
        [self.overlayWindow.rootViewController.view bringSubviewToFront:self.floatingButton];
    }

    void (^changes)(void) = ^{
        self.dimmingView.alpha = visible ? 1.0 : 0.0;
        self.menuView.alpha = visible ? 1.0 : 0.0;
        self.menuView.transform = visible ? CGAffineTransformIdentity :
                                           CGAffineTransformMakeScale(0.86, 0.86);
        self.floatingButton.transform = visible ?
            CGAffineTransformMakeRotation((CGFloat)M_PI_4) : CGAffineTransformIdentity;
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        if (!visible) {
            self.dimmingView.hidden = YES;
            self.menuView.hidden = YES;
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.25
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *root = self.overlayWindow.rootViewController.view;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.panStartCenter = self.floatingButton.center;
        [self setMenuVisible:NO animated:YES];
    }

    CGPoint translation = [pan translationInView:root];
    CGPoint center = CGPointMake(self.panStartCenter.x + translation.x,
                                 self.panStartCenter.y + translation.y);
    UIEdgeInsets safe = root.safeAreaInsets;
    CGFloat half = YTBallSize * 0.5;
    center.x = MAX(safe.left + half + YTEdgeMargin,
                   MIN(CGRectGetWidth(root.bounds) - safe.right - half - YTEdgeMargin, center.x));
    center.y = MAX(safe.top + half + YTEdgeMargin,
                   MIN(CGRectGetHeight(root.bounds) - safe.bottom - half - YTEdgeMargin, center.y));
    self.floatingButton.center = center;

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat leftX = safe.left + half + YTEdgeMargin;
        CGFloat rightX = CGRectGetWidth(root.bounds) - safe.right - half - YTEdgeMargin;
        center.x = center.x < CGRectGetMidX(root.bounds) ? leftX : rightX;
        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.35
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.floatingButton.center = center;
        } completion:nil];
    }
}

- (void)detectionSwitchChanged:(UISwitch *)sender {
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTDetectionEnabledDidChangeNotification"
                      object:self
                    userInfo:@{@"enabled": @(sender.isOn)}];
}

- (void)boxesSwitchChanged:(UISwitch *)sender {
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTDetectionBoxesDidChangeNotification"
                      object:self
                    userInfo:@{@"enabled": @(sender.isOn)}];
}

- (void)aimLineSwitchChanged:(UISwitch *)sender {
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTAimLineEnabledDidChangeNotification"
                      object:self
                    userInfo:@{@"enabled": @(sender.isOn)}];
}

- (void)autoAimSwitchChanged:(UISwitch *)sender {
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTAutoAimEnabledDidChangeNotification"
                      object:self
                    userInfo:@{@"enabled": @(sender.isOn)}];
}

- (void)touchEditorSwitchChanged:(UISwitch *)sender {
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTTouchPositionEditingDidChangeNotification"
                      object:self
                    userInfo:@{@"enabled": @(sender.isOn)}];
}

- (UIWindow *)hostWindowForDiagnostic {
    return [YTTouchSynthesizer bestHostWindowExcluding:self.overlayWindow];
}

- (void)testButtonTapped:(UIButton *)sender {
    self.diagnosticLabel.text = @"诊断中…";
    self.diagnosticLabel.textColor = UIColor.secondaryLabelColor;

    // Close the menu so the test swipe is visible on the host app.
    [self setMenuVisible:NO animated:YES];

    // Delay so the menu close animation (0.28s) finishes before the
    // synchronous diagnostic blocks the main thread with usleep.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *hostWindow = [self hostWindowForDiagnostic];
        NSString *report = [YTTouchSynthesizer runDiagnosticInWindow:hostWindow];

        self.diagnosticLabel.text = report;
        self.diagnosticLabel.textColor = UIColor.labelColor;
        // Reopen the menu so the user can read the report.
        [self setMenuVisible:YES animated:YES];
    });
}

#pragma mark - Recording & Replay

- (void)recordButtonTapped:(UIButton *)sender {
    if ([YTTouchSynthesizer isRecording]) {
        // Stop recording.
        NSUInteger count = [YTTouchSynthesizer stopRecording];
        [sender setTitle:@"● 录制触摸" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.85 green:0.22 blue:0.18 alpha:0.9];
        self.recordStatusLabel.text =
            [NSString stringWithFormat:@"已录制 %lu 个事件\n%@", (unsigned long)count,
             [YTTouchSynthesizer recordedEventsSummary]];
        self.recordStatusLabel.textColor = UIColor.labelColor;
    } else {
        // Start recording — close menu so user can interact with the host app.
        [YTTouchSynthesizer startRecording];
        [sender setTitle:@"■ 停止录制" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.95 green:0.30 blue:0.25 alpha:1.0];
        self.recordStatusLabel.text = @"录制中… 在游戏里滑动，然后点悬浮球回来停止";
        self.recordStatusLabel.textColor = [UIColor colorWithRed:0.95 green:0.30 blue:0.25 alpha:1.0];
        [self setMenuVisible:NO animated:YES];
    }
}

- (void)replayButtonTapped:(UIButton *)sender {
    NSUInteger count = [YTTouchSynthesizer recordedEventCount];
    if (count == 0) {
        self.recordStatusLabel.text = @"没有录制内容，请先录制";
        self.recordStatusLabel.textColor = UIColor.secondaryLabelColor;
        return;
    }

    // Close the menu so we can see the replay effect on the host app.
    [self setMenuVisible:NO animated:YES];

    self.recordStatusLabel.text =
        [NSString stringWithFormat:@"重放中… %lu 个事件", (unsigned long)count];
    self.recordStatusLabel.textColor = [UIColor colorWithRed:0.18 green:0.72 blue:0.36 alpha:1.0];

    // Delay so the menu close animation finishes before replay starts.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [YTTouchSynthesizer replayRecording];

        // Reopen the menu after a short delay so the user can see the result.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.recordStatusLabel.text =
                [NSString stringWithFormat:@"重放完成\n%@", [YTTouchSynthesizer recordedEventsSummary]];
            self.recordStatusLabel.textColor = UIColor.labelColor;
            [self setMenuVisible:YES animated:YES];
        });
    });
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installOverlayIfNeeded];
        self.overlayWindow.hidden = NO;
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setMenuVisible:NO animated:NO];
        self.overlayWindow.hidden = YES;
    });
}

@end

__attribute__((constructor))
static void YTStartOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTOverlayManager sharedManager] start];
    });
}
