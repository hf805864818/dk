#import "DKPushNotificationBridge.h"
#import "DKAccountManager.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

// ============================================================
// 存储键
// ============================================================
static NSString *const kDKDeviceTokenKey = @"DK_DeviceToken";
static NSString *const kDKNotificationCountsKey = @"DK_NotificationCounts";
static NSString *const kDKBadgeCountsKey = @"DK_BadgeCounts";
static NSString *const kDKNotificationCategoryID = @"DK_ACCOUNT_MSG";

@implementation DKPushNotificationBridge {
    NSString *_deviceTokenString;
    NSMutableDictionary<NSString *, NSNumber *> *_unreadCounts;
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_pendingNotifications;
    NSMutableDictionary<NSString *, NSNumber *> *_badgeCounts;
    NSString *_activeAccount;
}

+ (instancetype)sharedInstance {
    static DKPushNotificationBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKPushNotificationBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _unreadCounts = [NSMutableDictionary dictionary];
        _pendingNotifications = [NSMutableDictionary dictionary];
        _badgeCounts = [NSMutableDictionary dictionary];
        
        // 恢复已保存的 deviceToken
        _deviceTokenString = [[NSUserDefaults standardUserDefaults] stringForKey:kDKDeviceTokenKey];
    }
    return self;
}

#pragma mark - Setup

- (void)setup {
    NSLog(@"[DK] 推送通知桥接已初始化");
    [self registerNotificationCategories];
    [self _loadUnreadCounts];
    [self _loadBadgeCounts];
}

- (void)registerNotificationCategories {
    if (@available(iOS 10.0, *)) {
        UNNotificationAction *viewAction = [UNNotificationAction actionWithIdentifier:@"DK_VIEW"
                                                                                title:@"查看"
                                                                              options:UNNotificationActionOptionForeground];
        
        UNNotificationAction *switchAction = [UNNotificationAction actionWithIdentifier:@"DK_SWITCH"
                                                                                  title:@"切换到此账号"
                                                                                options:UNNotificationActionOptionForeground];
        
        UNNotificationAction *dismissAction = [UNNotificationAction actionWithIdentifier:@"DK_DISMISS"
                                                                                   title:@"忽略"
                                                                                 options:UNNotificationActionOptionDestructive];
        
        UNNotificationCategory *category = [UNNotificationCategory categoryWithIdentifier:kDKNotificationCategoryID
                                                                                  actions:@[viewAction, switchAction, dismissAction]
                                                                        intentIdentifiers:@[]
                                                                                  options:UNNotificationCategoryOptionCustomDismissAction];
        
        [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:[NSSet setWithObject:category]];
    }
}

#pragma mark - DeviceToken 管理

- (void)registerDeviceToken:(NSData *)deviceToken {
    if (!deviceToken) return;
    
    // 转换为标准十六进制字符串
    NSMutableString *tokenString = [NSMutableString string];
    const unsigned char *bytes = deviceToken.bytes;
    for (NSInteger i = 0; i < deviceToken.length; i++) {
        [tokenString appendFormat:@"%02x", bytes[i]];
    }
    
    _deviceTokenString = [tokenString copy];
    
    // 持久化存储
    [[NSUserDefaults standardUserDefaults] setObject:_deviceTokenString forKey:kDKDeviceTokenKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSLog(@"[DK] DeviceToken 已注册: %@", _deviceTokenString);
}

- (NSString *)deviceTokenString {
    return _deviceTokenString;
}

#pragma mark - 远程推送处理

- (void)handleRemoteNotification:(NSDictionary *)userInfo
                 completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    
    NSLog(@"[DK] 收到远程推送: %@", userInfo);
    
    // 解析推送中的账号标识
    // 目标应用可能在 payload 中包含 account_id / user_id / uid 等字段
    NSString *accountId = [self _extractAccountIdFromUserInfo:userInfo];
    
    if (accountId) {
        DKAccountManager *manager = [DKAccountManager sharedManager];
        NSString *currentAccount = [manager currentAccountName];
        
        if (![accountId isEqualToString:currentAccount] &&
            ![accountId isEqualToString:[manager defaultAccountName]]) {
            // 推送属于其他账号，生成 local notification
            NSString *title = userInfo[@"aps"][@"alert"][@"title"] ?: @"新消息";
            NSString *body = userInfo[@"aps"][@"alert"][@"body"] ?: @"";
            
            [self postLocalNotificationForAccount:accountId
                                            title:title
                                             body:body
                                         userInfo:userInfo];
            
            // 增加未读计数
            [self _incrementUnreadCountForAccount:accountId];
        }
    }
    
    if (completionHandler) {
        completionHandler(UIBackgroundFetchResultNewData);
    }
}

#pragma mark - iOS 10+ UNUserNotificationCenter

- (void)handleUserNotificationCenterWillPresent:(UNNotification *)notification
                          withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    
    NSDictionary *userInfo = notification.request.content.userInfo;
    NSString *accountId = [self _extractAccountIdFromUserInfo:userInfo];
    
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if (accountId && ![accountId isEqualToString:currentAccount] &&
        ![accountId isEqualToString:[manager defaultAccountName]]) {
        // 后台账号的通知 — 即使在应用前台也显示横幅
        if (completionHandler) {
            completionHandler(UNNotificationPresentationOptionBadge |
                              UNNotificationPresentationOptionSound |
                              UNNotificationPresentationOptionBanner |
                              UNNotificationPresentationOptionList);
        }
    } else {
        // 当前账号的通知 — 正常处理
        if (completionHandler) {
            completionHandler(UNNotificationPresentationOptionBadge |
                              UNNotificationPresentationOptionSound |
                              UNNotificationPresentationOptionBanner);
        }
    }
}

- (void)handleUserNotificationCenterDidReceive:(UNNotificationResponse *)response
                          withCompletionHandler:(void (^)(void))completionHandler {
    
    // 处理通知点击
    if ([response.actionIdentifier isEqualToString:@"DK_SWITCH"]) {
        // 用户点击了"切换到此账号"
        NSDictionary *userInfo = response.notification.request.content.userInfo;
        NSString *accountId = [self _extractAccountIdFromUserInfo:userInfo];
        
        if (accountId) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[DKAccountManager sharedManager] switchToAccount:accountId];
            });
        }
    }
    
    if (completionHandler) {
        completionHandler();
    }
}

#pragma mark - 本地通知

- (void)postLocalNotificationForAccount:(NSString *)accountName
                                  title:(NSString *)title
                                   body:(NSString *)body
                               userInfo:(NSDictionary *)userInfo {
    
    if (@available(iOS 10.0, *)) {
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = [NSString stringWithFormat:@"[%@] %@", accountName, title];
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        content.badge = @([self _totalUnreadCount]);
        content.categoryIdentifier = kDKNotificationCategoryID;
        
        // 将账号信息附加到 userInfo 中
        NSMutableDictionary *mergedUserInfo = [userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
        mergedUserInfo[@"DK_AccountName"] = accountName;
        content.userInfo = mergedUserInfo;
        
        // 立即触发
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:
                                          [NSString stringWithFormat:@"DK_%@_%ld", accountName, (long)[[NSDate date] timeIntervalSince1970]]
                                                                              content:content
                                                                              trigger:nil];
        
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                                withCompletionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"[DK] 本地通知发送失败: %@", error);
            } else {
                NSLog(@"[DK] 已为账号 %@ 发送本地通知", accountName);
            }
        }];
    }
}

#pragma mark - 未读计数

- (NSInteger)unreadCountForAccount:(NSString *)accountName {
    return [_unreadCounts[accountName] integerValue];
}

- (void)clearNotificationsForAccount:(NSString *)accountName {
    _unreadCounts[accountName] = @(0);
    [self _saveUnreadCounts];
    [self clearBadgeForAccount:accountName];
    
    // 更新应用角标
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].applicationIconBadgeNumber = [self _totalUnreadCount];
    });
}

- (void)_incrementUnreadCountForAccount:(NSString *)accountName {
    NSInteger count = [_unreadCounts[accountName] integerValue] + 1;
    _unreadCounts[accountName] = @(count);
    [self _saveUnreadCounts];
    
    // 更新应用角标
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].applicationIconBadgeNumber = [self _totalUnreadCount];
    });
}

- (NSInteger)_totalUnreadCount {
    NSInteger total = 0;
    for (NSNumber *count in _unreadCounts.allValues) {
        total += [count integerValue];
    }
    return total;
}

- (void)_loadUnreadCounts {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDKNotificationCountsKey];
    if (saved) {
        _unreadCounts = [saved mutableCopy];
    }
}

- (void)_saveUnreadCounts {
    [[NSUserDefaults standardUserDefaults] setObject:[_unreadCounts copy] forKey:kDKNotificationCountsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 徽章数追踪（per-account）

/// 当应用徽章数更新时，hook 调用此方法将徽章数归属到当前活跃账号
- (void)setBadgeCount:(NSInteger)count forAccount:(NSString *)accountName {
    if (!accountName) return;
    _badgeCounts[accountName] = @(count);
    [self _saveBadgeCounts];
    NSLog(@"[DK] 🔔 账号 %@ 徽章数: %ld", accountName, (long)count);
}

/// 获取某账号记录的徽章数
- (NSInteger)badgeCountForAccount:(NSString *)accountName {
    if (!accountName) return 0;
    return [_badgeCounts[accountName] integerValue];
}

/// 所有账号徽章总数（用于悬浮按钮角标）
- (NSInteger)totalBadgeCount {
    NSInteger total = 0;
    for (NSNumber *count in _badgeCounts.allValues) {
        total += [count integerValue];
    }
    return total;
}

/// 设置当前活跃账号
- (void)setActiveAccount:(NSString *)accountName {
    _activeAccount = accountName;
}

/// 清除某账号的徽章数（切换账号后标记已读）
- (void)clearBadgeForAccount:(NSString *)accountName {
    _badgeCounts[accountName] = @(0);
    [self _saveBadgeCounts];
}

- (void)_loadBadgeCounts {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDKBadgeCountsKey];
    if (saved) {
        _badgeCounts = [saved mutableCopy];
    }
}

- (void)_saveBadgeCounts {
    [[NSUserDefaults standardUserDefaults] setObject:[_badgeCounts copy] forKey:kDKBadgeCountsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Private

- (NSString *)_extractAccountIdFromUserInfo:(NSDictionary *)userInfo {
    // 尝试从多种可能的键中提取账号标识
    // 不同应用使用不同的字段名，这里列举常见的
    NSArray *possibleKeys = @[
        @"account_id", @"accountId", @"account",
        @"user_id", @"userId", @"uid",
        @"sender_id", @"senderId",
        @"DK_AccountName",  // 我们自己的标记
    ];
    
    for (NSString *key in possibleKeys) {
        id value = userInfo[key];
        if (value && [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return value;
        }
    }
    
    // 也检查 aps.alert 中的自定义字段
    NSDictionary *aps = userInfo[@"aps"];
    if ([aps isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in possibleKeys) {
            id value = aps[key];
            if (value && [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return value;
            }
        }
    }
    
    return nil;
}

@end