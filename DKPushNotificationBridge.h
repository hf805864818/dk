#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

// ============================================================
// DKPushNotificationBridge - 推送通知桥接
//
// 核心原理:
// iOS 每个应用只有一个 deviceToken，所有账号共享同一个推送通道。
// 当推送到达时，通过解析通知 payload 中的账号标识，将通知
// 转发为本地通知，并标注来源账号，使得后台账号也能收到消息提醒。
//
// 工作流程:
// 1. Hook UIApplication 的推送注册回调，记录 deviceToken
// 2. Hook UNUserNotificationCenter 的推送接收回调
// 3. 解析推送 payload 中的 account_id / user_id 字段
// 4. 为不同账号生成独立的本地通知（带账号标签）
// 5. 维护每个账号的未读通知计数
// ============================================================

@interface DKPushNotificationBridge : NSObject

+ (instancetype)sharedInstance;

/// 初始化推送桥接
- (void)setup;

/// 记录当前应用的 deviceToken
- (void)registerDeviceToken:(NSData *)deviceToken;

/// 获取当前 deviceToken 字符串
- (NSString *)deviceTokenString;

/// 处理收到的远程推送
- (void)handleRemoteNotification:(NSDictionary *)userInfo
                 completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler;

/// 处理收到的推送（iOS 10+ UNUserNotificationCenter）
- (void)handleUserNotificationCenterWillPresent:(UNNotification *)notification
                          withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler;

/// 处理推送点击（iOS 10+）
- (void)handleUserNotificationCenterDidReceive:(UNNotificationResponse *)response
                          withCompletionHandler:(void (^)(void))completionHandler;

/// 为指定账号生成本地通知
- (void)postLocalNotificationForAccount:(NSString *)accountName
                                  title:(NSString *)title
                                   body:(NSString *)body
                               userInfo:(NSDictionary *)userInfo;

/// 获取某账号的未读通知数
- (NSInteger)unreadCountForAccount:(NSString *)accountName;

/// 清除某账号的通知
- (void)clearNotificationsForAccount:(NSString *)accountName;

/// 为所有账号注册推送类别
- (void)registerNotificationCategories;

@end