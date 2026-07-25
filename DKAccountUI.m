#import "DKAccountUI.h"
#import "DKAccountManager.h"
#import "DKPushNotificationBridge.h"
#import "DKContentFilterBypass.h"
#import "DKLogManager.h"
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>

extern NSString* DKGetVersion(void);

// ============================================================
// UI 常量
// ============================================================
static const CGFloat kFloatingButtonSize = 40.0;
static const CGFloat kFloatingButtonMargin = 20.0;
static const CGFloat kMenuWidth = 220.0;
static const CGFloat kMenuRowHeight = 48.0;
static const CGFloat kMenuCornerRadius = 12.0;
static const CGFloat kMenuMaxVisibleRows = 6;

// 隐藏按钮的小指示条
static const CGFloat kHiddenIndicatorSize = 6.0;

// 手势安装重试间隔和最大重试次数
static const NSTimeInterval kGestureInstallRetryInterval = 0.5;
static const NSInteger kGestureInstallMaxRetries = 20;

// ============================================================
// 关联对象 Key
// ============================================================
static char kDKFloatingButtonKey;
static char kDKMenuViewKey;
static char kDKGestureKey;
static char kDKHiddenIndicatorKey;
static char kDKLogViewerKey;
static char kDKBadgeLabelKey;

@interface DKAccountUI () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *targetWindow;
@property (nonatomic, assign) BOOL isMenuVisible;
@property (nonatomic, assign) BOOL isFloatingButtonVisible;
@property (nonatomic, assign) NSInteger gestureInstallRetryCount;

// 私有方法声明
- (UIWindow *)_keyWindow;
- (UIViewController *)_rootViewController;
- (void)_showToast:(NSString *)message;
- (void)_promptAddAccount;
- (void)_promptDeleteAccount:(NSString *)accountName;
- (void)_promptRenameAccount:(NSString *)accountName;
- (void)_promptClearMultiAccountData;
- (void)_showLogViewer;
- (void)_hideLogViewer;
- (void)_clearLogsAndRefresh;
- (void)_exportLogs;
- (void)_filterLogs:(UIButton *)sender;
- (void)_toggleContentFilter;
- (void)_handleMenuItemTap:(UITapGestureRecognizer *)gesture;
- (void)_handleMenuItemLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)_handleButtonTap:(UIButton *)sender;
- (void)_handleDoubleTap:(UITapGestureRecognizer *)gesture;
- (void)_handlePan:(UIPanGestureRecognizer *)gesture;
- (void)_applicationDidFinishLaunching:(NSNotification *)notification;
- (void)_sceneDidActivate:(NSNotification *)notification;
- (void)_accountDidChange:(NSNotification *)notification;
- (void)_tryInstallGestureWithRetry;
- (void)_installGestureRecognizer;
- (void)_deviceDidShake:(NSNotification *)notification;
- (void)_setupShakeDetection;
- (void)_showHiddenIndicator;
- (void)_hideHiddenIndicator;
- (void)_handleIndicatorTap:(UITapGestureRecognizer *)gesture;
- (void)_handleLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation DKAccountUI

+ (instancetype)sharedInstance {
    static DKAccountUI *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKAccountUI alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isMenuVisible = NO;
        _isFloatingButtonVisible = NO;
        _gestureInstallRetryCount = 0;
    }
    return self;
}

#pragma mark - Setup

- (void)setup {
    NSLog(@"[DK] DKAccountUI setup 开始");
    
    // 监听应用启动完成通知（兼容 AppDelegate 和 SceneDelegate）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_applicationDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
    
    // iOS 13+ SceneDelegate 兼容：监听 scene 激活
    if (@available(iOS 13.0, *)) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_sceneDidActivate:)
                                                     name:UISceneDidActivateNotification
                                                   object:nil];
    }
    
    // 监听账号切换通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_accountDidChange:)
                                                 name:@"DKAccountDidChangeNotification"
                                               object:nil];
    
    // 监听设备摇晃
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_deviceDidShake:)
                                                     name:@"DKDeviceDidShakeNotification"
                                                   object:nil];
    
    // 立即尝试安装（如果应用已经启动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _tryInstallGestureWithRetry];
    });
    
    NSLog(@"[DK] DKAccountUI setup 完成");
}

- (void)_applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"[DK] 收到 UIApplicationDidFinishLaunchingNotification");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _tryInstallGestureWithRetry];
    });
}

- (void)_sceneDidActivate:(NSNotification *)notification {
    NSLog(@"[DK] 收到 UISceneDidActivateNotification");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _tryInstallGestureWithRetry];
    });
}

- (void)_accountDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshMenu];
        [self refreshFloatingBadge];
        NSString *newAccount = notification.userInfo[@"newAccount"];
        if (newAccount) {
            [[DKPushNotificationBridge sharedInstance] clearNotificationsForAccount:newAccount];
        }
    });
}

#pragma mark - 手势安装（带重试机制）

- (void)_tryInstallGestureWithRetry {
    UIWindow *keyWindow = [self _keyWindow];
    
    if (!keyWindow) {
        self.gestureInstallRetryCount++;
        if (self.gestureInstallRetryCount < kGestureInstallMaxRetries) {
            NSLog(@"[DK] Window 尚未就绪，%ld 秒后重试 (%ld/%ld)",
                  (long)kGestureInstallRetryInterval,
                  (long)self.gestureInstallRetryCount,
                  (long)kGestureInstallMaxRetries);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kGestureInstallRetryInterval * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
                [self _tryInstallGestureWithRetry];
            });
        } else {
            NSLog(@"[DK] ⚠️ 手势安装重试次数耗尽，window 仍然不可用");
        }
        return;
    }
    
    // 成功获取 window，安装手势
    [self _installGestureRecognizer];
}

- (void)_installGestureRecognizer {
    UIWindow *keyWindow = [self _keyWindow];
    if (!keyWindow) {
        NSLog(@"[DK] ⚠️ _installGestureRecognizer: keyWindow 为 nil");
        return;
    }
    
    // 如果已经安装过，跳过
    UILongPressGestureRecognizer *existingGesture = objc_getAssociatedObject(keyWindow, &kDKGestureKey);
    if (existingGesture) {
        NSLog(@"[DK] 手势已安装，跳过");
        return;
    }
    
    self.targetWindow = keyWindow;
    
    // ============================================================
    // 三指长按手势
    // ============================================================
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
                                              initWithTarget:self
                                              action:@selector(_handleLongPress:)];
    gesture.numberOfTouchesRequired = 3;
    gesture.minimumPressDuration = 1.0;
    // 不设置 delegate（避免未实现协议方法导致手势被静默拒绝）
    // gesture.delegate = (id<UIGestureRecognizerDelegate>)self;
    
    // 确保手势能同时与其他手势识别
    gesture.cancelsTouchesInView = NO;
    
    [keyWindow addGestureRecognizer:gesture];
    objc_setAssociatedObject(keyWindow, &kDKGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    NSLog(@"[DK] ✅ 三指长按手势已安装到 window: %@", keyWindow);
    
    // 同时添加摇晃检测（备用触发方式）
    [self _setupShakeDetection];
}

#pragma mark - 摇晃检测（备用触发）

- (void)_setupShakeDetection {
    // 摇晃检测已实现在 Tweak.x 的 UIApplication sendEvent: Hook 中。
    // 此处保留方法体以兼容旧代码，实际摇晃拦截不在此文件。
    NSLog(@"[DK] 摇晃检测已就绪（通过 UIApplication sendEvent: 拦截）");
}

- (void)_deviceDidShake:(NSNotification *)notification {
    NSLog(@"[DK] 检测到设备摇晃，显示悬浮按钮");
    [self showFloatingButton];
}

// 公开方法：外部调用触发（可通过 Activator 等工具绑定，或由 sendEvent: Hook 触发）
- (void)triggerShowFloatingButton {
    NSLog(@"[DK] 外部触发显示悬浮按钮");
    [self showFloatingButton];
}

#pragma mark - 手势处理

- (void)_handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSLog(@"[DK] 🔥 三指长按触发！");
        
        // 触觉反馈
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        
        if (self.isMenuVisible) {
            [self hideAccountMenu];
        }
        
        [self showFloatingButton];
    }
}

#pragma mark - 隐藏指示条

- (void)_showHiddenIndicator {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        [self _hideHiddenIndicator];
        
        UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(
            keyWindow.bounds.size.width - kHiddenIndicatorSize - 2,
            keyWindow.bounds.size.height / 2.0 - 20,
            kHiddenIndicatorSize,
            40
        )];
        indicator.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.5];
        indicator.layer.cornerRadius = kHiddenIndicatorSize / 2.0;
        indicator.clipsToBounds = YES;
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(_handleIndicatorTap:)];
        [indicator addGestureRecognizer:tap];
        
        [keyWindow addSubview:indicator];
        objc_setAssociatedObject(keyWindow, &kDKHiddenIndicatorKey, indicator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        indicator.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{
            indicator.alpha = 1.0;
        }];
    });
}

- (void)_hideHiddenIndicator {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        UIView *indicator = objc_getAssociatedObject(keyWindow, &kDKHiddenIndicatorKey);
        if (indicator) {
            [UIView animateWithDuration:0.2 animations:^{
                indicator.alpha = 0;
            } completion:^(BOOL finished) {
                [indicator removeFromSuperview];
            }];
            objc_setAssociatedObject(keyWindow, &kDKHiddenIndicatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

- (void)_handleIndicatorTap:(UITapGestureRecognizer *)gesture {
    [self showFloatingButton];
}

#pragma mark - 悬浮按钮

- (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) {
            NSLog(@"[DK] ⚠️ showFloatingButton: keyWindow 为 nil");
            return;
        }
        
        // 直接同步移除旧按钮（不能用 hideFloatingButton，它异步，会移除刚创建的新按钮）
        UIButton *existingButton = objc_getAssociatedObject(keyWindow, &kDKFloatingButtonKey);
        if (existingButton) {
            [existingButton removeFromSuperview];
            objc_setAssociatedObject(keyWindow, &kDKFloatingButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        self.isFloatingButtonVisible = NO;
        
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat screenWidth = keyWindow.bounds.size.width;
        CGFloat screenHeight = keyWindow.bounds.size.height;
        
        button.frame = CGRectMake(screenWidth - kFloatingButtonSize - kFloatingButtonMargin,
                                   screenHeight - kFloatingButtonSize - kFloatingButtonMargin - 100,
                                   kFloatingButtonSize,
                                   kFloatingButtonSize);
        button.layer.cornerRadius = kFloatingButtonSize / 2.0;
        button.clipsToBounds = YES;
        
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = button.bounds;
        gradient.colors = @[(id)[UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0].CGColor,
                            (id)[UIColor colorWithRed:0.1 green:0.4 blue:0.9 alpha:1.0].CGColor];
        gradient.startPoint = CGPointMake(0, 0);
        gradient.endPoint = CGPointMake(1, 1);
        gradient.cornerRadius = kFloatingButtonSize / 2.0;
        [button.layer insertSublayer:gradient atIndex:0];
        
        button.layer.shadowColor = [UIColor blackColor].CGColor;
        button.layer.shadowOffset = CGSizeMake(0, 4);
        button.layer.shadowRadius = 8;
        button.layer.shadowOpacity = 0.3;
        
        [button setTitle:@"DK" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                        initWithTarget:self
                                        action:@selector(_handlePan:)];
        [button addGestureRecognizer:pan];
        
        [button addTarget:self
                   action:@selector(_handleButtonTap:)
         forControlEvents:UIControlEventTouchUpInside];
        
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
                                              initWithTarget:self
                                              action:@selector(_handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [button addGestureRecognizer:doubleTap];
        
        [keyWindow addSubview:button];
        objc_setAssociatedObject(keyWindow, &kDKFloatingButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 角标标签（总未读通知数）
        CGFloat badgeSize = 22.0;
        UILabel *badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(kFloatingButtonSize - badgeSize + 6, -4, badgeSize, badgeSize)];
        badgeLabel.backgroundColor = [UIColor redColor];
        badgeLabel.textColor = [UIColor whiteColor];
        badgeLabel.font = [UIFont boldSystemFontOfSize:11];
        badgeLabel.textAlignment = NSTextAlignmentCenter;
        badgeLabel.layer.cornerRadius = badgeSize / 2.0;
        badgeLabel.clipsToBounds = YES;
        badgeLabel.hidden = YES;
        badgeLabel.tag = 9998;
        [button addSubview:badgeLabel];
        objc_setAssociatedObject(button, &kDKBadgeLabelKey, badgeLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        [self _hideHiddenIndicator];
        
        button.transform = CGAffineTransformMakeScale(0.1, 0.1);
        button.alpha = 0;
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            button.transform = CGAffineTransformIdentity;
            button.alpha = 1.0;
        } completion:^(BOOL finished) {
            [self refreshFloatingBadge];
        }];
        
        self.isFloatingButtonVisible = YES;
        NSLog(@"[DK] ✅ 悬浮按钮已显示");
    });
}

- (void)refreshFloatingBadge {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        UIButton *button = objc_getAssociatedObject(keyWindow, &kDKFloatingButtonKey);
        if (!button) return;
        
        UILabel *badgeLabel = objc_getAssociatedObject(button, &kDKBadgeLabelKey);
        if (!badgeLabel) return;
        
        NSInteger totalBadge = [[DKPushNotificationBridge sharedInstance] totalBadgeCount];
        if (totalBadge <= 0) {
            badgeLabel.hidden = YES;
        } else {
            badgeLabel.hidden = NO;
            badgeLabel.text = totalBadge > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)totalBadge];
        }
    });
}

- (void)hideFloatingButton {
    [self hideFloatingButtonAnimated:YES];
}

- (void)hideFloatingButtonAnimated:(BOOL)animated {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        UIButton *button = objc_getAssociatedObject(keyWindow, &kDKFloatingButtonKey);
        if (button) {
            if (animated) {
                [UIView animateWithDuration:0.2 animations:^{
                    button.transform = CGAffineTransformMakeScale(0.1, 0.1);
                    button.alpha = 0;
                } completion:^(BOOL finished) {
                    [button removeFromSuperview];
                }];
            } else {
                [button removeFromSuperview];
            }
            objc_setAssociatedObject(keyWindow, &kDKFloatingButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        
        self.isFloatingButtonVisible = NO;
        [self _showHiddenIndicator];
    });
}

- (void)toggleFloatingButton {
    if (self.isFloatingButtonVisible) {
        [self hideFloatingButton];
    } else {
        [self showFloatingButton];
    }
}

- (void)_handlePan:(UIPanGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    
    button.center = CGPointMake(button.center.x + translation.x,
                                 button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGFloat margin = kFloatingButtonMargin;
        CGFloat screenWidth = button.superview.bounds.size.width;
        CGFloat screenHeight = button.superview.bounds.size.height;
        CGFloat safeTop = button.superview.safeAreaInsets.top;
        CGFloat safeBottom = button.superview.safeAreaInsets.bottom;
        
        CGPoint finalCenter = button.center;
        
        if (finalCenter.x < -kFloatingButtonSize / 2.0 ||
            finalCenter.x > screenWidth + kFloatingButtonSize / 2.0) {
            [self hideFloatingButtonAnimated:YES];
            [self _showHiddenIndicator];
            return;
        }
        
        if (finalCenter.x < screenWidth / 2.0) {
            finalCenter.x = margin + kFloatingButtonSize / 2.0;
        } else {
            finalCenter.x = screenWidth - margin - kFloatingButtonSize / 2.0;
        }
        
        finalCenter.y = MAX(safeTop + kFloatingButtonSize / 2.0,
                            MIN(finalCenter.y, screenHeight - safeBottom - kFloatingButtonSize / 2.0));
        
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            button.center = finalCenter;
        } completion:nil];
    }
}

- (void)_handleButtonTap:(UIButton *)sender {
    if (self.isMenuVisible) {
        [self hideAccountMenu];
    } else {
        [self showAccountMenu];
    }
}

- (void)_handleDoubleTap:(UITapGestureRecognizer *)gesture {
    NSLog(@"[DK] 双击悬浮按钮 — 隐藏");
    [self hideAccountMenu];
    [self hideFloatingButtonAnimated:YES];
    [self _showToast:@"悬浮按钮已隐藏，三指长按可重新呼出"];
}

#pragma mark - 账号菜单

- (void)showAccountMenu {
    // 调用者已在主线程，无需 dispatch_async
    UIWindow *keyWindow = [self _keyWindow];
    if (!keyWindow) return;
    
    // 同步移除旧菜单
    UIView *oldMenu = objc_getAssociatedObject(keyWindow, &kDKMenuViewKey);
    if (oldMenu) {
        [oldMenu removeFromSuperview];
        objc_setAssociatedObject(keyWindow, &kDKMenuViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self.isMenuVisible = NO;
    
    [[DKAccountManager sharedManager] refreshAccountList];
        
        NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
        NSString *currentAccount = [[DKAccountManager sharedManager] currentAccountName];
        NSString *designatedDefault = [[DKAccountManager sharedManager] designatedDefaultAccountName];
        
        NSMutableArray *menuItems = [NSMutableArray arrayWithObject:@"➕ 添加账号"];
        
        // 添加默认账号（原始 TRAE 登录）
        NSString *defaultDisplayName = designatedDefault
            ? @"📱 默认账号（原始）"
            : @"📱 默认账号";
        [menuItems addObject:defaultDisplayName];
        
        // 添加其他账号（标记指定默认）
        [menuItems addObjectsFromArray:accounts];
        
        BOOL filterEnabled = [DKContentFilterBypass sharedInstance].enabled;
        NSString *filterLabel = filterEnabled ? @"🔒 敏感词过滤: 开" : @"🔓 敏感词过滤: 关";
        [menuItems addObject:filterLabel];

        [menuItems addObject:@"🧹 清理多开数据"];
        [menuItems addObject:@"📋 查看日志"];
        [menuItems addObject:[NSString stringWithFormat:@"ℹ️ 当前版本 v%@", DKGetVersion() ?: @"unknown"]];
        [menuItems addObject:@"👁 隐藏图标"];
        
        NSInteger rowCount = menuItems.count;
        CGFloat menuHeight = MIN(rowCount * kMenuRowHeight, kMenuMaxVisibleRows * kMenuRowHeight);
        BOOL scrollable = rowCount > kMenuMaxVisibleRows;
        
        UIButton *floatBtn = objc_getAssociatedObject(keyWindow, &kDKFloatingButtonKey);
        CGFloat menuX = floatBtn ? floatBtn.frame.origin.x - kMenuWidth + kFloatingButtonSize : keyWindow.bounds.size.width - kMenuWidth - kFloatingButtonMargin;
        CGFloat menuY = floatBtn ? floatBtn.frame.origin.y - menuHeight - 10 : keyWindow.bounds.size.height / 2.0 - menuHeight / 2.0;
        
        menuX = MAX(10, MIN(menuX, keyWindow.bounds.size.width - kMenuWidth - 10));
        menuY = MAX(keyWindow.safeAreaInsets.top + 10, MIN(menuY, keyWindow.bounds.size.height - keyWindow.safeAreaInsets.bottom - menuHeight - 10));
        
        UIView *menuContainer = [[UIView alloc] initWithFrame:CGRectMake(menuX, menuY, kMenuWidth, menuHeight)];
        menuContainer.backgroundColor = [UIColor clearColor];
        menuContainer.layer.cornerRadius = kMenuCornerRadius;
        menuContainer.clipsToBounds = YES;
        
        if (@available(iOS 13.0, *)) {
            UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.frame = menuContainer.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [menuContainer addSubview:blurView];
        } else {
            menuContainer.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.95];
        }
        
        menuContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        menuContainer.layer.shadowOffset = CGSizeMake(0, 8);
        menuContainer.layer.shadowRadius = 16;
        menuContainer.layer.shadowOpacity = 0.4;
        menuContainer.layer.masksToBounds = NO;
        
        UIView *contentView = menuContainer;
        if (scrollable) {
            UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:menuContainer.bounds];
            scrollView.contentSize = CGSizeMake(kMenuWidth, rowCount * kMenuRowHeight);
            scrollView.showsVerticalScrollIndicator = YES;
            scrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
            [menuContainer addSubview:scrollView];
            contentView = scrollView;
        }
        
        for (NSInteger i = 0; i < rowCount; i++) {
            NSString *item = menuItems[i];
            BOOL isAddAccount = (i == 0);
            BOOL isDefaultAccount = (i == 1);
            BOOL isFilterToggle = (i == rowCount - 5);
            BOOL isClearData = (i == rowCount - 4);
            BOOL isLogViewer = (i == rowCount - 3);
            BOOL isVersionInfo = (i == rowCount - 2);
            BOOL isHideOption = (i == rowCount - 1);
            BOOL isCurrentAccount = [item isEqualToString:currentAccount] ||
                                    (isDefaultAccount && [currentAccount isEqualToString:[[DKAccountManager sharedManager] defaultAccountName]]);
            
            UIView *rowView = [[UIView alloc] initWithFrame:CGRectMake(0, i * kMenuRowHeight, kMenuWidth, kMenuRowHeight)];
            
            if (i > 0) {
                UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(12, 0, kMenuWidth - 24, 0.5)];
                separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
                [rowView addSubview:separator];
            }
            
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, kMenuWidth - 50, kMenuRowHeight)];
            label.text = item;
            label.textColor = isAddAccount ? [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0] :
                              isHideOption ? [UIColor colorWithWhite:0.6 alpha:1.0] :
                              isVersionInfo ? [UIColor colorWithWhite:0.75 alpha:1.0] :
                              isClearData ? [UIColor colorWithRed:1.0 green:0.35 blue:0.25 alpha:1.0] :
                              isFilterToggle ? [UIColor colorWithRed:1.0 green:0.75 blue:0.3 alpha:1.0] :
                              isLogViewer ? [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:1.0] :
                              [UIColor whiteColor];
            label.font = [UIFont systemFontOfSize:15];
            
            if (isAddAccount) {
                label.font = [UIFont boldSystemFontOfSize:15];
            }
            
            if (isVersionInfo) {
                label.font = [UIFont systemFontOfSize:13];
            }

            if (isCurrentAccount && !isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo && !isLogViewer) {
                label.text = [NSString stringWithFormat:@"✓ %@", item];
                label.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:1.0];
            }

            [rowView addSubview:label];
            
            if (!isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo && !isLogViewer) {
                // 优先使用徽章数（来自 applicationIconBadgeNumber hook），
                // 回退到推送通知未读数（来自推送 payload 解析）
                NSInteger badgeCount = [[DKPushNotificationBridge sharedInstance] badgeCountForAccount:item];
                NSInteger unread = [[DKPushNotificationBridge sharedInstance] unreadCountForAccount:item];
                NSInteger total = badgeCount > 0 ? badgeCount : unread;
                if (total > 0) {
                    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(kMenuWidth - 42, 12, 24, 24)];
                    badge.backgroundColor = [UIColor redColor];
                    badge.textColor = [UIColor whiteColor];
                    badge.text = total > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)total];
                    badge.font = [UIFont boldSystemFontOfSize:11];
                    badge.textAlignment = NSTextAlignmentCenter;
                    badge.layer.cornerRadius = 12;
                    badge.clipsToBounds = YES;
                    [rowView addSubview:badge];
                }
            }
            
            rowView.tag = i;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                            initWithTarget:self
                                            action:@selector(_handleMenuItemTap:)];
            [rowView addGestureRecognizer:tap];
            
            if (!isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo && !isLogViewer) {
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
                                                            initWithTarget:self
                                                            action:@selector(_handleMenuItemLongPress:)];
                longPress.minimumPressDuration = 1.0;
                [rowView addGestureRecognizer:longPress];
            }
            
            [contentView addSubview:rowView];
        }
        
        [keyWindow addSubview:menuContainer];
        objc_setAssociatedObject(keyWindow, &kDKMenuViewKey, menuContainer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        menuContainer.transform = CGAffineTransformMakeScale(0.8, 0.8);
        menuContainer.alpha = 0;
        [UIView animateWithDuration:0.25
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            menuContainer.transform = CGAffineTransformIdentity;
            menuContainer.alpha = 1.0;
        } completion:nil];
        
        self.isMenuVisible = YES;
}

- (void)hideAccountMenu {
    UIWindow *keyWindow = [self _keyWindow];
    if (!keyWindow) return;
    
    UIView *menuView = objc_getAssociatedObject(keyWindow, &kDKMenuViewKey);
    if (menuView) {
        [UIView animateWithDuration:0.2 animations:^{
            menuView.transform = CGAffineTransformMakeScale(0.8, 0.8);
            menuView.alpha = 0;
        } completion:^(BOOL finished) {
            [menuView removeFromSuperview];
        }];
        objc_setAssociatedObject(keyWindow, &kDKMenuViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    self.isMenuVisible = NO;
}

- (void)refreshMenu {
    if (self.isMenuVisible) {
        [self hideAccountMenu];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showAccountMenu];
        });
    }
}

- (void)cleanup {
    [self hideFloatingButton];
    [self hideAccountMenu];
    [self _hideHiddenIndicator];
}

#pragma mark - 菜单项交互

- (void)_handleMenuItemTap:(UITapGestureRecognizer *)gesture {
    NSInteger index = gesture.view.tag;
    [self hideAccountMenu];
    
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    // 0: add, 1: default, 2..N+1: accounts, N+2: filter, N+3: clear, N+4: logs, N+5: version, N+6: hide
    NSInteger totalItems = 1 + 1 + accounts.count + 5;
    
    if (index == 0) {
        [self _promptAddAccount];
    } else if (index == 1) {
        // 切换到默认账号（原始 TRAE 登录）
        BOOL switched = [[DKAccountManager sharedManager] switchToDefaultAccount];
        if (switched) {
            [self _showToast:@"已切换到默认账号"];
        } else {
            // switchToDefaultAccount 返回 NO 说明 _currentAccountName 已经是默认账号名，
            // 但 UI 可能仍显示子账号登录页（上一次 exit(0) 未正常执行或状态异常）。
            // 直接强制退出，下次启动时 %ctor 会通过 ensureDataOwnershipForAccount
            // 恢复默认账号数据到沙盒，确保用户回到默认账号主界面。
            NSLog(@"[DK] switchToDefaultAccount 返回 NO，当前 _currentAccountName=%@，强制重启恢复默认账号",
                  [[DKAccountManager sharedManager] currentAccountName]);
            [self _showToast:@"正在恢复默认账号..."];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                sync();
                exit(0);
            });
        }
    } else if (index == totalItems - 1) {
        [self hideFloatingButtonAnimated:YES];
        [self _showToast:@"悬浮按钮已隐藏，三指长按可重新呼出"];
    } else if (index == totalItems - 2) {
        [self _showToast:[NSString stringWithFormat:@"当前版本 v%@", DKGetVersion() ?: @"unknown"]];
    } else if (index == totalItems - 3) {
        [self _showLogViewer];
    } else if (index == totalItems - 4) {
        [self _promptClearMultiAccountData];
    } else if (index == totalItems - 5) {
        [self _toggleContentFilter];
    } else {
        NSInteger accountIndex = index - 2;
        if (accountIndex < accounts.count) {
            NSString *accountName = accounts[accountIndex];
            BOOL switched = [[DKAccountManager sharedManager] switchToAccount:accountName];
            if (switched) {
                [self _showToast:[NSString stringWithFormat:@"已切换到: %@", accountName]];
            } else {
                [self _showToast:[NSString stringWithFormat:@"当前已是: %@", accountName]];
            }
        }
    }
}

- (void)_handleMenuItemLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    
    NSInteger index = gesture.view.tag;
    // 0: add, 1: default (can't delete), 2..N+1: accounts
    if (index <= 1) return; // 添加账号和默认账号不能操作
    
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    NSString *accountName = accounts[index - 2];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:accountName
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"自定义重命名"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [self _promptRenameAccount:accountName];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"设为默认账号"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [[DKAccountManager sharedManager] promptSetDesignatedDefaultForAccount:accountName];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"删除当前账号"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            [self _promptDeleteAccount:accountName];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        
        UIViewController *rootVC = [self _rootViewController];
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

#pragma mark - 敏感词过滤开关

- (void)_toggleContentFilter {
    DKContentFilterBypass *bypass = [DKContentFilterBypass sharedInstance];
    bypass.enabled = !bypass.enabled;
    
    NSString *status = bypass.enabled ? @"已开启" : @"已关闭";
    [self _showToast:[NSString stringWithFormat:@"敏感词过滤绕过 %@", status]];
    
    NSLog(@"[DK] 敏感词过滤绕过: %@", bypass.enabled ? @"ON" : @"OFF");
}

#pragma mark - 日志查看器

- (void)_showLogViewer {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        // 移除旧日志查看器
        UIView *oldViewer = objc_getAssociatedObject(keyWindow, &kDKLogViewerKey);
        if (oldViewer) {
            [oldViewer removeFromSuperview];
        }
        
        NSArray *allLogs = [[DKLogManager sharedInstance] allLogs];
        NSUInteger logCount = [[DKLogManager sharedInstance] logCount];
        
        CGFloat screenWidth = keyWindow.bounds.size.width;
        CGFloat screenHeight = keyWindow.bounds.size.height;
        CGFloat safeTop = keyWindow.safeAreaInsets.top;
        CGFloat safeBottom = keyWindow.safeAreaInsets.bottom;
        
        // 背景遮罩
        UIView *container = [[UIView alloc] initWithFrame:keyWindow.bounds];
        container.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        container.tag = 9999;
        
        UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(_hideLogViewer)];
        bgTap.cancelsTouchesInView = NO;
        bgTap.delegate = (id<UIGestureRecognizerDelegate>)self;
        [container addGestureRecognizer:bgTap];
        
        // 日志面板
        CGFloat panelY = safeTop + 60;
        CGFloat panelHeight = screenHeight - safeTop - safeBottom - 100;
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(10, panelY, screenWidth - 20, panelHeight)];
        panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98];
        panel.layer.cornerRadius = 14;
        panel.clipsToBounds = YES;
        panel.tag = 9998;  // 用于 bgTap delegate 判断
        [container addSubview:panel];
        
        // 标题栏
        UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panel.bounds.size.width, 44)];
        titleBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        [panel addSubview:titleBar];
        
        // 标题
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 150, 44)];
        titleLabel.text = [NSString stringWithFormat:@"📋 日志 (%lu条)", (unsigned long)logCount];
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [titleBar addSubview:titleLabel];
        
        // 清空按钮
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(panel.bounds.size.width - 175, 0, 55, 44);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.35 blue:0.25 alpha:1.0] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:14];
        [clearBtn addTarget:self action:@selector(_clearLogsAndRefresh) forControlEvents:UIControlEventTouchUpInside];
        [titleBar addSubview:clearBtn];
        
        // 导出按钮
        UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        exportBtn.frame = CGRectMake(panel.bounds.size.width - 120, 0, 55, 44);
        [exportBtn setTitle:@"导出" forState:UIControlStateNormal];
        [exportBtn setTitleColor:[UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        exportBtn.titleLabel.font = [UIFont systemFontOfSize:14];
        [exportBtn addTarget:self action:@selector(_exportLogs) forControlEvents:UIControlEventTouchUpInside];
        [titleBar addSubview:exportBtn];
        
        // 关闭按钮
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(panel.bounds.size.width - 55, 0, 50, 44);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [closeBtn addTarget:self action:@selector(_hideLogViewer) forControlEvents:UIControlEventTouchUpInside];
        [titleBar addSubview:closeBtn];
        
        // 过滤器标签栏
        UIView *filterBar = [[UIView alloc] initWithFrame:CGRectMake(0, 44, panel.bounds.size.width, 38)];
        filterBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        filterBar.tag = 9997;  // 用于快速查找
        [panel addSubview:filterBar];
        
        NSArray *filterLabels = @[@"全部", @"🔓敏感词", @"❌错误", @"📋信息"];
        for (NSInteger i = 0; i < filterLabels.count; i++) {
            UIButton *filterBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            CGFloat btnWidth = panel.bounds.size.width / filterLabels.count;
            filterBtn.frame = CGRectMake(i * btnWidth, 0, btnWidth, 38);
            [filterBtn setTitle:filterLabels[i] forState:UIControlStateNormal];
            [filterBtn setTitleColor:(i == 0) ? [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0] : [UIColor lightGrayColor] forState:UIControlStateNormal];
            filterBtn.titleLabel.font = [UIFont systemFontOfSize:13];
            filterBtn.tag = 1000 + i;
            [filterBtn addTarget:self action:@selector(_filterLogs:) forControlEvents:UIControlEventTouchUpInside];
            [filterBar addSubview:filterBtn];
        }
        
        // 日志文本
        UITextView *textView = [[UITextView alloc] initWithFrame:CGRectMake(8, 86, panel.bounds.size.width - 16, panel.bounds.size.height - 92)];
        textView.backgroundColor = [UIColor clearColor];
        textView.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        textView.editable = NO;
        textView.selectable = YES;
        textView.showsVerticalScrollIndicator = YES;
        textView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        textView.tag = 2000;
        
        // 显示日志内容
        if (allLogs.count == 0) {
            textView.text = @"暂无日志\n\n提示：日志捕获可能尚未启动，请重启应用后查看。";
            textView.textColor = [UIColor grayColor];
        } else {
            // 默认显示最近 500 条
            NSUInteger showCount = MIN(allLogs.count, 500);
            NSArray *recentLogs = [allLogs subarrayWithRange:NSMakeRange(allLogs.count - showCount, showCount)];
            textView.text = [recentLogs componentsJoinedByString:@"\n"];
        }
        
        [panel addSubview:textView];
        
        [keyWindow addSubview:container];
        objc_setAssociatedObject(keyWindow, &kDKLogViewerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 滚动到底部
        if (textView.text.length > 0) {
            NSRange bottom = NSMakeRange(textView.text.length - 1, 1);
            [textView scrollRangeToVisible:bottom];
        }
        
        // 动画
        container.alpha = 0;
        panel.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [UIView animateWithDuration:0.25 animations:^{
            container.alpha = 1.0;
            panel.transform = CGAffineTransformIdentity;
        }];
    });
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // 点击在面板区域时不触发背景遮罩的关闭手势
    UIView *hitView = touch.view;
    while (hitView) {
        if (hitView.tag == 9998) return NO;
        hitView = hitView.superview;
    }
    return YES;
}

- (void)_hideLogViewer {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        UIView *container = objc_getAssociatedObject(keyWindow, &kDKLogViewerKey);
        if (container) {
            [UIView animateWithDuration:0.2 animations:^{
                container.alpha = 0;
            } completion:^(BOOL finished) {
                [container removeFromSuperview];
            }];
            objc_setAssociatedObject(keyWindow, &kDKLogViewerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

- (void)_clearLogsAndRefresh {
    [[DKLogManager sharedInstance] clearLogs];
    [self _hideLogViewer];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _showLogViewer];
    });
}

- (void)_exportLogs {
    // 导出全部日志为 zip 压缩包，然后用系统分享面板分享
    NSString *filePath = [[DKLogManager sharedInstance] exportLogsToZip];
    if (!filePath) {
        [self _showToast:@"导出失败"];
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *fileURL = [NSURL fileURLWithPath:filePath];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc]
                                                  initWithActivityItems:@[fileURL]
                                                  applicationActivities:nil];
        
        // iPad 兼容
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            activityVC.popoverPresentationController.sourceView = [self _keyWindow];
            activityVC.popoverPresentationController.sourceRect = CGRectMake(
                [self _keyWindow].bounds.size.width / 2,
                [self _keyWindow].bounds.size.height / 2,
                0, 0);
        }
        
        UIViewController *rootVC = [self _rootViewController];
        [rootVC presentViewController:activityVC animated:YES completion:nil];
        
        [self _showToast:[NSString stringWithFormat:@"日志已导出: %@", [filePath lastPathComponent]]];
    });
}

- (void)_filterLogs:(UIButton *)sender {
    NSInteger filterIndex = sender.tag - 1000;
    UIWindow *keyWindow = [self _keyWindow];
    if (!keyWindow) return;
    
    UIView *container = objc_getAssociatedObject(keyWindow, &kDKLogViewerKey);
    if (!container) return;
    
    UITextView *textView = [container viewWithTag:2000];
    if (!textView) return;
    
    // 更新过滤器按钮颜色
    UIView *filterBar = [container viewWithTag:9997];
    if (filterBar) {
        for (UIButton *btn in filterBar.subviews) {
            if ([btn isKindOfClass:[UIButton class]]) {
                NSInteger tag = btn.tag - 1000;
                [btn setTitleColor:(tag == filterIndex) ? [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0] : [UIColor lightGrayColor] forState:UIControlStateNormal];
            }
        }
    }
    
    NSArray *filteredLogs = nil;
    switch (filterIndex) {
        case 0: // 全部
            filteredLogs = [[DKLogManager sharedInstance] allLogs];
            break;
        case 1: // 敏感词
            filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"🔓"];
            if (filteredLogs.count == 0) {
                filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"敏感词"];
            }
            if (filteredLogs.count == 0) {
                filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"983"];
            }
            break;
        case 2: // 错误
            filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"❌"];
            if (filteredLogs.count == 0) {
                filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"error"];
            }
            if (filteredLogs.count == 0) {
                filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"⚠️"];
            }
            break;
        case 3: // 信息
            filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"📋"];
            if (filteredLogs.count == 0) {
                filteredLogs = [[DKLogManager sharedInstance] logsContaining:@"✅"];
            }
            break;
    }
    
    if (filteredLogs.count == 0) {
        textView.text = [NSString stringWithFormat:@"没有匹配的日志"];
        textView.textColor = [UIColor grayColor];
    } else {
        NSUInteger showCount = MIN(filteredLogs.count, 500);
        NSArray *recent = [filteredLogs subarrayWithRange:NSMakeRange(filteredLogs.count - showCount, showCount)];
        textView.text = [recent componentsJoinedByString:@"\n"];
        textView.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    }
}

#pragma mark - 添加账号弹窗

- (void)_promptAddAccount {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加账号"
                                                                       message:@"请输入新账号名称"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"账号名称";
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
        UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"添加"
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text;
            if (name.length > 0) {
                BOOL success = [[DKAccountManager sharedManager] addAccountWithName:name];
                if (success) {
                    [[DKAccountManager sharedManager] switchToAccount:name];
                    [self _showToast:[NSString stringWithFormat:@"账号 %@ 已添加并切换", name]];
                } else {
                    [self _showToast:@"添加失败，账号可能已存在"];
                }
            }
        }];
        
        [alert addAction:cancelAction];
        [alert addAction:confirmAction];
        
        UIViewController *rootVC = [self _rootViewController];
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - 删除账号确认

- (void)_promptDeleteAccount:(NSString *)accountName {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除账号"
                                                                       message:[NSString stringWithFormat:@"确定要删除账号 \"%@\" 吗？此操作不可撤销。", accountName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
        UIAlertAction *deleteAction = [UIAlertAction actionWithTitle:@"删除"
                                                               style:UIAlertActionStyleDestructive
                                                             handler:^(UIAlertAction *action) {
            BOOL success = [[DKAccountManager sharedManager] deleteAccountWithName:accountName];
            if (success) {
                [self _showToast:[NSString stringWithFormat:@"账号 %@ 已删除", accountName]];
            }
        }];
        
        [alert addAction:cancelAction];
        [alert addAction:deleteAction];
        
        UIViewController *rootVC = [self _rootViewController];
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - 重命名账号

- (void)_promptRenameAccount:(NSString *)accountName {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名账号"
                                                                       message:[NSString stringWithFormat:@"当前名称: %@", accountName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.text = accountName;
            textField.placeholder = @"输入新名称";
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
        UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确定"
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction *action) {
            NSString *newName = alert.textFields.firstObject.text;
            newName = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (newName.length > 0 && ![newName isEqualToString:accountName]) {
                BOOL success = [[DKAccountManager sharedManager] renameAccount:accountName toName:newName];
                if (success) {
                    [self _showToast:[NSString stringWithFormat:@"已重命名为: %@", newName]];
                } else {
                    [self _showToast:@"重命名失败，名称可能已存在或无效"];
                }
            }
        }];
        
        [alert addAction:cancelAction];
        [alert addAction:confirmAction];
        
        UIViewController *rootVC = [self _rootViewController];
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - 清理多开数据确认

- (void)_promptClearMultiAccountData {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理多开数据"
                                                                       message:@"将删除所有添加的多开账号、账号快照和未读计数，但保留默认账号原始数据。清理后建议重启应用。"
                                                                preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];

        UIAlertAction *clearAction = [UIAlertAction actionWithTitle:@"确认清理"
                                                              style:UIAlertActionStyleDestructive
                                                            handler:^(UIAlertAction *action) {
            BOOL success = [[DKAccountManager sharedManager] clearAllMultiAccountData];
            if (success) {
                [self _showToast:@"多开数据已清理，默认账号已保留"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    exit(0);
                });
            } else {
                [self _showToast:@"清理失败，请稍后重试"];
            }
        }];

        [alert addAction:cancelAction];
        [alert addAction:clearAction];

        UIViewController *rootVC = [self _rootViewController];
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Toast 提示

- (void)_showToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        UILabel *toast = [[UILabel alloc] init];
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont systemFontOfSize:14];
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;
        
        CGSize size = [message sizeWithAttributes:@{NSFontAttributeName: toast.font}];
        CGFloat toastWidth = MIN(size.width + 32, keyWindow.bounds.size.width - 40);
        CGFloat toastHeight = size.height + 20;
        toast.frame = CGRectMake((keyWindow.bounds.size.width - toastWidth) / 2.0,
                                  keyWindow.bounds.size.height - 100,
                                  toastWidth, toastHeight);
        
        [keyWindow addSubview:toast];
        
        toast.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{
            toast.alpha = 1.0;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:1.5 options:0 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        }];
    });
}

#pragma mark - 辅助方法

- (UIWindow *)_keyWindow {
    // iOS 13+ 使用 connectedScenes
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            return window;
                        }
                    }
                    // 如果没有 keyWindow，返回第一个 window
                    if (windowScene.windows.count > 0) {
                        return windowScene.windows.firstObject;
                    }
                }
            }
        }
    }
    
    // Fallback
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (kw) return kw;
    
    // 最后的 fallback：遍历所有 window
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) return window;
    }
    if ([UIApplication sharedApplication].windows.count > 0) {
        return [UIApplication sharedApplication].windows.firstObject;
    }
    
    return nil;
}

- (UIViewController *)_rootViewController {
    UIWindow *keyWindow = [self _keyWindow];
    UIViewController *rootVC = keyWindow.rootViewController;
    
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    
    return rootVC;
}

@end
