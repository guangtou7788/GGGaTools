#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// v0.1.0: visible injection test, using public UIKit APIs only.
@interface GGGaTestOverlay : UIView <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIButton *bubble;
@property(nonatomic, assign) BOOL positioned;
@end

@implementation GGGaTestOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        self.bubble.frame = CGRectMake(0, 0, 56, 56);
        self.bubble.backgroundColor = [UIColor colorWithRed:1 green:0.81 blue:0.18 alpha:1];
        [self.bubble setTitle:@"嘎" forState:UIControlStateNormal];
        [self.bubble setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
        self.bubble.titleLabel.font = [UIFont boldSystemFontOfSize:23];
        self.bubble.layer.cornerRadius = 28;
        self.bubble.layer.shadowColor = UIColor.blackColor.CGColor;
        self.bubble.layer.shadowOpacity = 0.22;
        self.bubble.layer.shadowRadius = 5;
        self.bubble.layer.shadowOffset = CGSizeMake(0, 2);
        self.bubble.accessibilityLabel = @"GGGaTools 悬浮测试按钮";
        [self.bubble addTarget:self action:@selector(showTest) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        pan.delegate = self;
        [self.bubble addGestureRecognizer:pan];
        [self addSubview:self.bubble];
    }
    return self;
}
- (CGPoint)clampedCenter:(CGPoint)point {
    UIEdgeInsets inset = self.safeAreaInsets;
    CGFloat left = inset.left + 36, right = MAX(left, self.bounds.size.width - inset.right - 36);
    CGFloat top = inset.top + 36, bottom = MAX(top, self.bounds.size.height - inset.bottom - 36);
    return CGPointMake(MIN(MAX(point.x, left), right), MIN(MAX(point.y, top), bottom));
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.positioned) {
        self.bubble.center = CGPointMake(self.bounds.size.width - 42, self.bounds.size.height * 0.38);
        self.positioned = YES;
    }
    self.bubble.center = [self clampedCenter:self.bubble.center];
}
// Only the button receives touches. Chat fields and scrolling remain reachable.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self];
    self.bubble.center = [self clampedCenter:CGPointMake(self.bubble.center.x + delta.x, self.bubble.center.y + delta.y)];
    [pan setTranslation:CGPointZero inView:self];
}
- (void)showTest {
    UIViewController *controller = self.window.rootViewController;
    while (controller) {
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *next = ((UINavigationController *)controller).visibleViewController;
            if (!next) break;
            controller = next;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *next = ((UITabBarController *)controller).selectedViewController;
            if (!next) break;
            controller = next;
        } else { break; }
    }
    if (!controller || [controller isKindOfClass:UIAlertController.class] || !controller.view.window) return;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    NSString *message = [NSString stringWithFormat:@"悬浮按钮已运行 ✅\n版本：0.1.0\nApp：%@\niOS：%@\n\n请测试拖动、切换页面、后台返回和输入聊天。", bundle, UIDevice.currentDevice.systemVersion];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"GGGaTools 注入测试" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制测试信息" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = message;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
@end

@interface GGGaTestManager : NSObject
@property(nonatomic, strong) NSMapTable<UIWindow *, GGGaTestOverlay *> *overlays;
@property(nonatomic, strong) NSTimer *timer;
- (void)refresh;
@end

@implementation GGGaTestManager
- (instancetype)init {
    self = [super init];
    if (self) {
        self.overlays = [NSMapTable weakToStrongObjectsMapTable];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(onNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(onNotification:) name:UISceneDidActivateNotification object:nil];
        [nc addObserver:self selector:@selector(onNotification:) name:UIWindowDidBecomeKeyNotification object:nil];
        // A modest foreground watchdog restores the button after host view changes.
        self.timer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(onTimer:) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        [self refresh];
    }
    return self;
}
- (void)onNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}
- (void)onTimer:(NSTimer *)timer { [self refresh]; }
- (void)attachToWindow:(UIWindow *)window {
    if (!window || window.hidden || window.alpha < 0.01 || !window.rootViewController || window.windowLevel != UIWindowLevelNormal) return;
    GGGaTestOverlay *overlay = [self.overlays objectForKey:window];
    if (!overlay) {
        overlay = [[GGGaTestOverlay alloc] initWithFrame:window.bounds];
        [self.overlays setObject:overlay forKey:window];
    }
    if (overlay.superview != window) [window addSubview:overlay];
    overlay.frame = window.bounds;
    [window bringSubviewToFront:overlay];
}
- (void)refresh {
    UIApplication *app = UIApplication.sharedApplication;
    if (app.applicationState != UIApplicationStateActive) return;
    BOOL foundScene = NO;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        foundScene = YES;
        UIWindow *candidate = nil;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.01 || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (!candidate || window.isKeyWindow) candidate = window;
            if (window.isKeyWindow) break;
        }
        [self attachToWindow:candidate];
    }
    if (!foundScene) {
        for (UIWindow *window in app.windows) {
            if (window.isKeyWindow) { [self attachToWindow:window]; break; }
        }
    }
}
@end

__attribute__((constructor)) static void GGGaToolsInitialize(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"appex"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            static GGGaTestManager *manager;
            if (!manager) manager = [[GGGaTestManager alloc] init];
            NSLog(@"[GGGaTools] 0.1.0 loaded");
        });
    }
}
