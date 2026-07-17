#import "DKAccountUI.h"
#import "DKAccountManager.h"
#import "DKPushNotificationBridge.h"
#import "DKContentFilterBypass.h"
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

@interface DKAccountUI ()
@property (nonatomic, weak) UIWindow *targetWindow;
@property (nonatomic, assign) BOOL isMenuVisible;
@property (nonatomic, assign) BOOL isFloatingButtonVisible;
@property (nonatomic, assign) NSInteger gestureInstallRetryCount;
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
        } completion:nil];
        
        self.isFloatingButtonVisible = YES;
        NSLog(@"[DK] ✅ 悬浮按钮已显示");
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
            BOOL isFilterToggle = (i == rowCount - 4);
            BOOL isClearData = (i == rowCount - 3);
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
                              [UIColor whiteColor];
            label.font = [UIFont systemFontOfSize:15];
            
            if (isAddAccount) {
                label.font = [UIFont boldSystemFontOfSize:15];
            }
            
            if (isVersionInfo) {
                label.font = [UIFont systemFontOfSize:13];
            }

            if (isCurrentAccount && !isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo) {
                label.text = [NSString stringWithFormat:@"✓ %@", item];
                label.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:1.0];
            }

            // 标记指定默认账号
            if (designatedDefault && [item isEqualToString:designatedDefault] &&
                !isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo) {
                label.text = [NSString stringWithFormat:@"⭐ %@", item];
                label.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1.0];
            }
            
            [rowView addSubview:label];
            
            if (!isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo) {
                NSInteger unread = [[DKPushNotificationBridge sharedInstance] unreadCountForAccount:item];
                if (unread > 0) {
                    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(kMenuWidth - 42, 12, 24, 24)];
                    badge.backgroundColor = [UIColor redColor];
                    badge.textColor = [UIColor whiteColor];
                    badge.text = unread > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)unread];
                    badge.font = [UIFont boldSystemFontOfSize:11];
                    badge.textAlignment = NSTextAlignmentCenter;
                    badge.layer.cornerRadius = 12;
                    badge.clipsToBounds = YES;
                    [rowView addSubview:badge];
                }
                
                // 非默认账号：添加 ⭐ 设为默认按钮
                if (!isDefaultAccount && !isAddAccount) {
                    UIButton *starBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                    starBtn.frame = CGRectMake(kMenuWidth - 52, 8, 32, 32);
                    [starBtn setTitle:@"⭐" forState:UIControlStateNormal];
                    starBtn.titleLabel.font = [UIFont systemFontOfSize:16];
                    starBtn.tag = i;
                    [starBtn addTarget:self action:@selector(_handleStarButtonTap:) forControlEvents:UIControlEventTouchUpInside];
                    [rowView addSubview:starBtn];
                }
            }
            
            rowView.tag = i;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                            initWithTarget:self
                                            action:@selector(_handleMenuItemTap:)];
            [rowView addGestureRecognizer:tap];
            
            if (!isAddAccount && !isHideOption && !isFilterToggle && !isClearData && !isVersionInfo) {
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
    // 0: add, 1: default, 2..N+1: accounts, N+2: filter, N+3: clear data, N+4: version, N+5: hide
    NSInteger defaultAccountOffset = 1; // 默认账号在菜单中的偏移
    NSInteger totalItems = 1 + defaultAccountOffset + accounts.count + 4;
    
    if (index == 0) {
        [self _promptAddAccount];
    } else if (index == 1) {
        // 切换到默认账号（原始 TRAE 登录）
        [[DKAccountManager sharedManager] switchToDefaultAccount];
        [self _showToast:@"已切换到默认账号"];
    } else if (index == totalItems - 1) {
        [self hideFloatingButtonAnimated:YES];
        [self _showToast:@"悬浮按钮已隐藏，三指长按可重新呼出"];
    } else if (index == totalItems - 2) {
        [self _showToast:[NSString stringWithFormat:@"当前版本 v%@", DKGetVersion() ?: @"unknown"]];
    } else if (index == totalItems - 3) {
        [self _promptClearMultiAccountData];
    } else if (index == totalItems - 4) {
        [self _toggleContentFilter];
    } else {
        NSInteger accountIndex = index - 2;
        if (accountIndex < accounts.count) {
            NSString *accountName = accounts[accountIndex];
            [[DKAccountManager sharedManager] switchToAccount:accountName];
            [self _showToast:[NSString stringWithFormat:@"已切换到: %@", accountName]];
        }
    }
}

- (void)_handleMenuItemLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    
    NSInteger index = gesture.view.tag;
    // 0: add, 1: default (can't delete), 2..N+1: accounts
    if (index <= 1) return; // 添加账号和默认账号不能删除
    
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    NSString *accountName = accounts[index - 2];
    
    // 弹出删除确认
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:accountName
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"删除账号"
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

- (void)_handleStarButtonTap:(UIButton *)sender {
    NSInteger index = sender.tag;
    [self hideAccountMenu];
    
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    NSInteger accountIndex = index - 2;
    if (accountIndex >= 0 && accountIndex < accounts.count) {
        NSString *accountName = accounts[accountIndex];
        [[DKAccountManager sharedManager] promptSetDesignatedDefaultForAccount:accountName];
    }
}

#pragma mark - 敏感词过滤开关

- (void)_toggleContentFilter {
    DKContentFilterBypass *bypass = [DKContentFilterBypass sharedInstance];
    bypass.enabled = !bypass.enabled;
    
    NSString *status = bypass.enabled ? @"已开启" : @"已关闭";
    [self _showToast:[NSString stringWithFormat:@"敏感词过滤绕过 %@", status]];
    
    NSLog(@"[DK] 敏感词过滤绕过: %@", bypass.enabled ? @"ON" : @"OFF");
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
