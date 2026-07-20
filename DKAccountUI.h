#import <UIKit/UIKit.h>

// ============================================================
// DKAccountUI - 悬浮按钮和账号菜单 UI
// 三指长按触发，圆形图标 + 竖排菜单标签栏
// 双击悬浮按钮隐藏 / 三指长按重新呼出
// ============================================================

@interface DKAccountUI : NSObject

+ (instancetype)sharedInstance;

/// 初始化 UI（在 Tweak 加载时调用）
- (void)setup;

/// 显示悬浮按钮
- (void)showFloatingButton;

/// 隐藏悬浮按钮（双击隐藏）
- (void)hideFloatingButton;

/// 切换悬浮按钮显示/隐藏状态
- (void)toggleFloatingButton;

/// 摇晃触发显示悬浮按钮（由 sendEvent: Hook 调用）
- (void)triggerShowFloatingButton;

/// 悬浮按钮是否可见
@property (nonatomic, assign, readonly) BOOL isFloatingButtonVisible;

/// 显示账号菜单
- (void)showAccountMenu;

/// 隐藏账号菜单
- (void)hideAccountMenu;

/// 刷新账号菜单
- (void)refreshMenu;

/// 刷新悬浮按钮角标（总未读通知数）
- (void)refreshFloatingBadge;

/// 完全清理 UI
- (void)cleanup;

@end