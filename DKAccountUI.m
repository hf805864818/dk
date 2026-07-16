#import "DKAccountUI.h"
#import "DKAccountManager.h"
#import "DKPushNotificationBridge.h"
#import "DKContentFilterBypass.h"
#import <objc/runtime.h>

// ============================================================
// UI 常量
// ============================================================
static const CGFloat kFloatingButtonSize = 56.0;
static const CGFloat kFloatingButtonMargin = 20.0;
static const CGFloat kMenuWidth = 220.0;
static const CGFloat kMenuRowHeight = 48.0;
static const CGFloat kMenuCornerRadius = 12.0;
static const CGFloat kMenuMaxVisibleRows = 6;

// 隐藏按钮的小指示条
static const CGFloat kHiddenIndicatorSize = 6.0;

// ============================================================
// 关联对象 Key
// ============================================================
static char kDKFloatingButtonKey;
static char kDKMenuViewKey;
static char kDKOverlayViewKey;
static char kDKGestureKey;
static char kDKHiddenIndicatorKey;

@interface DKAccountUI ()
@property (nonatomic, weak) UIWindow *targetWindow;
@property (nonatomic, assign) BOOL isMenuVisible;
@property (nonatomic, assign) BOOL isFloatingButtonVisible;
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
    }
    return self;
}

#pragma mark - Setup

- (void)setup {
    // 监听应用启动完成通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_applicationDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
    
    // 监听账号切换通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_accountDidChange:)
                                                 name:@"DKAccountDidChangeNotification"
                                               object:nil];
}

- (void)_applicationDidFinishLaunching:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _installGestureRecognizer];
    });
}

- (void)_accountDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshMenu];
        // 切换账号后清除该账号的通知计数
        NSString *newAccount = notification.userInfo[@"newAccount"];
        if (newAccount) {
            [[DKPushNotificationBridge sharedInstance] clearNotificationsForAccount:newAccount];
        }
    });
}

#pragma mark - 手势识别

- (void)_installGestureRecognizer {
    UIWindow *keyWindow = [self _keyWindow];
    if (!keyWindow) return;
    
    self.targetWindow = keyWindow;
    
    // 移除旧手势
    UILongPressGestureRecognizer *oldGesture = objc_getAssociatedObject(keyWindow, &kDKGestureKey);
    if (oldGesture) {
        [keyWindow removeGestureRecognizer:oldGesture];
    }
    
    // 三指长按手势
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
                                              initWithTarget:self
                                              action:@selector(_handleLongPress:)];
    gesture.numberOfTouchesRequired = 3;
    gesture.minimumPressDuration = 1.0;
    gesture.delegate = (id<UIGestureRecognizerDelegate>)self;
    
    [keyWindow addGestureRecognizer:gesture];
    objc_setAssociatedObject(keyWindow, &kDKGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    NSLog(@"[DK] 三指长按手势已安装");
}

- (void)_handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSLog(@"[DK] 三指长按触发");
        
        if (self.isMenuVisible) {
            [self hideAccountMenu];
        }
        
        // 三指长按始终显示悬浮按钮（即使之前被隐藏）
        [self showFloatingButton];
    }
}

#pragma mark - 隐藏指示条（悬浮按钮隐藏后的小标记）

- (void)_showHiddenIndicator {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        [self _hideHiddenIndicator];
        
        // 屏幕边缘显示一个小指示条，点击可重新显示悬浮按钮
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
        
        // 渐显
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
        if (!keyWindow) return;
        
        // 移除旧按钮
        [self hideFloatingButton];
        
        // 创建圆形悬浮按钮
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat screenWidth = keyWindow.bounds.size.width;
        CGFloat screenHeight = keyWindow.bounds.size.height;
        
        button.frame = CGRectMake(screenWidth - kFloatingButtonSize - kFloatingButtonMargin,
                                   screenHeight - kFloatingButtonSize - kFloatingButtonMargin - 100,
                                   kFloatingButtonSize,
                                   kFloatingButtonSize);
        button.layer.cornerRadius = kFloatingButtonSize / 2.0;
        button.clipsToBounds = YES;
        
        // 渐变背景
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = button.bounds;
        gradient.colors = @[(id)[UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0].CGColor,
                            (id)[UIColor colorWithRed:0.1 green:0.4 blue:0.9 alpha:1.0].CGColor];
        gradient.startPoint = CGPointMake(0, 0);
        gradient.endPoint = CGPointMake(1, 1);
        gradient.cornerRadius = kFloatingButtonSize / 2.0;
        [button.layer insertSublayer:gradient atIndex:0];
        
        // 阴影
        button.layer.shadowColor = [UIColor blackColor].CGColor;
        button.layer.shadowOffset = CGSizeMake(0, 4);
        button.layer.shadowRadius = 8;
        button.layer.shadowOpacity = 0.3;
        
        // 图标文字
        [button setTitle:@"DK" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        
        // 拖拽手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                        initWithTarget:self
                                        action:@selector(_handlePan:)];
        [button addGestureRecognizer:pan];
        
        // 点击事件
        [button addTarget:self
                   action:@selector(_handleButtonTap:)
         forControlEvents:UIControlEventTouchUpInside];
        
        // ============================================================
        // 双击隐藏功能
        // ============================================================
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
                                              initWithTarget:self
                                              action:@selector(_handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [button addGestureRecognizer:doubleTap];
        
        [keyWindow addSubview:button];
        objc_setAssociatedObject(keyWindow, &kDKFloatingButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // 隐藏指示条
        [self _hideHiddenIndicator];
        
        // 入场动画
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
        
        // 显示隐藏指示条，提示用户可以重新呼出
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
        
        // 检测是否拖到屏幕外（侧滑隐藏）
        // 如果拖到屏幕边缘超过一半，则隐藏
        if (finalCenter.x < -kFloatingButtonSize / 2.0 ||
            finalCenter.x > screenWidth + kFloatingButtonSize / 2.0) {
            [self hideFloatingButtonAnimated:YES];
            [self _showHiddenIndicator];
            return;
        }
        
        // 水平吸附
        if (finalCenter.x < screenWidth / 2.0) {
            finalCenter.x = margin + kFloatingButtonSize / 2.0;
        } else {
            finalCenter.x = screenWidth - margin - kFloatingButtonSize / 2.0;
        }
        
        // 垂直边界约束
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
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self _keyWindow];
        if (!keyWindow) return;
        
        [self hideAccountMenu]; // 先移除旧菜单
        
        // 刷新账号列表
        [[DKAccountManager sharedManager] refreshAccountList];
        
        NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
        NSString *currentAccount = [[DKAccountManager sharedManager] currentAccountName];
        
        // 菜单项: 添加账号 + 已添加账号列表 + 敏感词过滤开关 + 隐藏图标
        NSMutableArray *menuItems = [NSMutableArray arrayWithObject:@"➕ 添加账号"];
        [menuItems addObjectsFromArray:accounts];
        
        // 敏感词过滤开关（倒数第二项）
        BOOL filterEnabled = [DKContentFilterBypass sharedInstance].enabled;
        NSString *filterLabel = filterEnabled ? @"🔒 敏感词过滤: 开" : @"🔓 敏感词过滤: 关";
        [menuItems addObject:filterLabel];
        
        [menuItems addObject:@"👁 隐藏图标"];  // 最后一项
        
        NSInteger rowCount = menuItems.count;
        CGFloat menuHeight = MIN(rowCount * kMenuRowHeight, kMenuMaxVisibleRows * kMenuRowHeight);
        BOOL scrollable = rowCount > kMenuMaxVisibleRows;
        
        // 定位在悬浮按钮附近
        UIButton *floatBtn = objc_getAssociatedObject(keyWindow, &kDKFloatingButtonKey);
        CGFloat menuX = floatBtn ? floatBtn.frame.origin.x - kMenuWidth + kFloatingButtonSize : keyWindow.bounds.size.width - kMenuWidth - kFloatingButtonMargin;
        CGFloat menuY = floatBtn ? floatBtn.frame.origin.y - menuHeight - 10 : keyWindow.bounds.size.height / 2.0 - menuHeight / 2.0;
        
        // 确保菜单不超出屏幕
        menuX = MAX(10, MIN(menuX, keyWindow.bounds.size.width - kMenuWidth - 10));
        menuY = MAX(keyWindow.safeAreaInsets.top + 10, MIN(menuY, keyWindow.bounds.size.height - keyWindow.safeAreaInsets.bottom - menuHeight - 10));
        
        // 容器视图
        UIView *menuContainer = [[UIView alloc] initWithFrame:CGRectMake(menuX, menuY, kMenuWidth, menuHeight)];
        menuContainer.backgroundColor = [UIColor clearColor];
        menuContainer.layer.cornerRadius = kMenuCornerRadius;
        menuContainer.clipsToBounds = YES;
        
        // 毛玻璃效果
        if (@available(iOS 13.0, *)) {
            UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.frame = menuContainer.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [menuContainer addSubview:blurView];
        } else {
            menuContainer.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.95];
        }
        
        // 阴影
        menuContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        menuContainer.layer.shadowOffset = CGSizeMake(0, 8);
        menuContainer.layer.shadowRadius = 16;
        menuContainer.layer.shadowOpacity = 0.4;
        menuContainer.layer.masksToBounds = NO;
        
        // 滚动视图（如果项目太多）
        UIView *contentView = menuContainer;
        if (scrollable) {
            UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:menuContainer.bounds];
            scrollView.contentSize = CGSizeMake(kMenuWidth, rowCount * kMenuRowHeight);
            scrollView.showsVerticalScrollIndicator = YES;
            scrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
            [menuContainer addSubview:scrollView];
            contentView = scrollView;
        }
        
        // 创建菜单行
        for (NSInteger i = 0; i < rowCount; i++) {
            NSString *item = menuItems[i];
            BOOL isAddAccount = (i == 0);
            BOOL isFilterToggle = (i == rowCount - 2);  // 倒数第二项：敏感词过滤开关
            BOOL isHideOption = (i == rowCount - 1);     // 最后一项：隐藏图标
            BOOL isCurrentAccount = [item isEqualToString:currentAccount];
            
            UIView *rowView = [[UIView alloc] initWithFrame:CGRectMake(0, i * kMenuRowHeight, kMenuWidth, kMenuRowHeight)];
            
            // 分隔线
            if (i > 0) {
                UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(12, 0, kMenuWidth - 24, 0.5)];
                separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
                [rowView addSubview:separator];
            }
            
            // 标签
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, kMenuWidth - 50, kMenuRowHeight)];
            label.text = item;
            label.textColor = isAddAccount ? [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0] :
                              isHideOption ? [UIColor colorWithWhite:0.6 alpha:1.0] :
                              isFilterToggle ? [UIColor colorWithRed:1.0 green:0.75 blue:0.3 alpha:1.0] :
                              [UIColor whiteColor];
            label.font = [UIFont systemFontOfSize:15];
            
            if (isAddAccount) {
                label.font = [UIFont boldSystemFontOfSize:15];
            }
            
            if (isCurrentAccount && !isAddAccount && !isHideOption && !isFilterToggle) {
                label.text = [NSString stringWithFormat:@"✓ %@", item];
                label.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:1.0];
            }
            
            [rowView addSubview:label];
            
            // 未读通知计数徽章（非添加/隐藏/过滤行）
            if (!isAddAccount && !isHideOption && !isFilterToggle) {
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
            }
            
            // 点击手势
            rowView.tag = i;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                            initWithTarget:self
                                            action:@selector(_handleMenuItemTap:)];
            [rowView addGestureRecognizer:tap];
            
            // 长按删除（非添加账号项，非隐藏图标项，非过滤开关项）
            if (!isAddAccount && !isHideOption && !isFilterToggle) {
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
        
        // 入场动画
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
    });
}

- (void)hideAccountMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
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
    });
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideFloatingButton];
        [self hideAccountMenu];
        [self _hideHiddenIndicator];
    });
}

#pragma mark - 菜单项交互

- (void)_handleMenuItemTap:(UITapGestureRecognizer *)gesture {
    NSInteger index = gesture.view.tag;
    [self hideAccountMenu];
    
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    NSInteger totalItems = 1 + accounts.count + 2; // 添加 + 账号列表 + 过滤开关 + 隐藏
    
    if (index == 0) {
        // 添加账号
        [self _promptAddAccount];
    } else if (index == totalItems - 1) {
        // 隐藏图标
        [self hideFloatingButtonAnimated:YES];
        [self _showToast:@"悬浮按钮已隐藏，三指长按可重新呼出"];
    } else if (index == totalItems - 2) {
        // 切换敏感词过滤开关
        [self _toggleContentFilter];
    } else {
        // 切换账号
        NSInteger accountIndex = index - 1;
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
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    if (index - 1 < accounts.count) {
        NSString *accountName = accounts[index - 1];
        [self _promptDeleteAccount:accountName];
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
                    // 自动切换到新账号
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
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        return window;
                    }
                }
            }
        }
    }
    
    return [UIApplication sharedApplication].keyWindow;
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