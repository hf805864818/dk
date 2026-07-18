// ============================================================
// DK Multi-Account Tweak - Main Entry Point
// 使用 Logos 语法进行 Method Swizzling / MSHook
//
// 注意：所有 %hook 块必须在 %ctor 之前！
// Logos internal generator 不会生成前向声明，
// 如果 %hook 在 %ctor 之后，_logos_method$_ungrouped$ 符号未定义。
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Security/Security.h>
#import <substrate.h>
#import <UserNotifications/UserNotifications.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdio.h>
#import "fishhook/fishhook.h"

#import "DKAccountManager.h"
#import "DKAccountUI.h"
#import "DKDataIsolation.h"
#import "DKAppDataManager.h"
#import "DKUserDefaultsHook.h"
#import "DKKeychainHook.h"
#import "DKNetworkSessionManager.h"
#import "DKPushNotificationBridge.h"
#import "DKContentFilterBypass.h"

// ============================================================
// 版本号编译宏（由 Makefile 注入）
// ============================================================
#ifndef DK_VERSION
#define DK_VERSION @"1.0.0"
#endif
#ifndef DK_BUILD_TIME
#define DK_BUILD_TIME @"unknown"
#endif

// ============================================================
// 获取当前应用的 Bundle ID
// ============================================================
static NSString* DKGetCurrentBundleID(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
}

// ============================================================
// Keychain Hook 函数声明（实现在 DKKeychainHook.m 中）
// ============================================================
extern NSDictionary* DKRemapKeychainQuery(NSDictionary *query);
extern NSDictionary* DKRemapKeychainAttributes(NSDictionary *attributes);
extern NSDictionary* DKUnmapKeychainResult(NSDictionary *result);
extern BOOL DKKeychainResultMatchesCurrentAccount(NSDictionary *result);

// ============================================================
// 公开版本号获取函数（可在任意模块中调用）
// ============================================================
NSString* DKGetVersion(void) {
    return DK_VERSION;
}

NSString* DKGetBuildTime(void) {
    return DK_BUILD_TIME;
}

// ============================================================
// Keychain C 函数 Hook 前向声明
// ============================================================
static OSStatus (*original_SecItemAdd)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*original_SecItemDelete)(CFDictionaryRef query);

static OSStatus hooked_SecItemAdd(CFDictionaryRef query, CFTypeRef *result);
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);
static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus hooked_SecItemDelete(CFDictionaryRef query);

// ============================================================
// CFPreferences C 函数 Hook 前向声明
// TTAccountSDK 可能通过 CFPreferencesSetAppValue 直接写入
// 原始 UserDefaults plist，绕过 NSUserDefaults Hook。
// ============================================================
static void (*original_CFPreferencesSetAppValue)(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID);
static CFPropertyListRef (*original_CFPreferencesCopyAppValue)(CFStringRef key, CFStringRef applicationID);
static Boolean (*original_CFPreferencesAppSynchronize)(CFStringRef applicationID);

static void hooked_CFPreferencesSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID);
static CFPropertyListRef hooked_CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID);
static Boolean hooked_CFPreferencesAppSynchronize(CFStringRef applicationID);

// CFPreferences 非 App 版本 Hook 前向声明
// TTAccountSDK 可能直接调用 CFPreferencesSetValue（5 参数）而非
// CFPreferencesSetAppValue（3 参数），绕过已 Hook 的 App 版本。
// 非 App 版本的 applicationID 是可选的，SDK 可能传 NULL 或 kCFPreferencesCurrentApplication。
static void (*original_CFPreferencesSetValue)(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static CFPropertyListRef (*original_CFPreferencesCopyValue)(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static Boolean (*original_CFPreferencesSynchronize)(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static CFArrayRef (*original_CFPreferencesCopyKeyList)(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static void (*original_CFPreferencesSetMultiple)(CFDictionaryRef keysToSet, CFArrayRef keysToRemove, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static CFDictionaryRef (*original_CFPreferencesCopyMultiple)(CFArrayRef keysToFetch, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);

static void hooked_CFPreferencesSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static CFPropertyListRef hooked_CFPreferencesCopyValue(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static Boolean hooked_CFPreferencesSynchronize(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static CFArrayRef hooked_CFPreferencesCopyKeyList(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static void hooked_CFPreferencesSetMultiple(CFDictionaryRef keysToSet, CFArrayRef keysToRemove, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static CFDictionaryRef hooked_CFPreferencesCopyMultiple(CFArrayRef keysToFetch, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);

// ============================================================
// POSIX 文件操作 C 函数 Hook 前向声明
// MMKV / WCDB / SQLCipher 等 C/C++ 库直接使用 open()/stat() 等
// POSIX API 读写文件，绕过所有 ObjC 层 Hook（NSFileManager 等）。
// 必须通过 fishhook 拦截这些底层调用，将路径重定向到隔离目录。
// ============================================================

// DKRemapFilePath 在 DKFileManagerHook.m 中定义
extern NSString* DKRemapFilePath(NSString *path);

static int (*original_open)(const char *path, int flags, ...);
static int (*original_openat)(int fd, const char *path, int flags, ...);
static int (*original_stat)(const char *path, struct stat *buf);
static int (*original_lstat)(const char *path, struct stat *buf);
static int (*original_access)(const char *path, int mode);
static FILE *(*original_fopen)(const char *path, const char *mode);
static int (*original_unlink)(const char *path);
static int (*original_unlinkat)(int fd, const char *path, int flag);
static int (*original_rename)(const char *old, const char *new);
static int (*original_mkdir)(const char *path, mode_t mode);
static int (*original_mkdirat)(int fd, const char *path, mode_t mode);

static int hooked_open(const char *path, int flags, ...);
static int hooked_openat(int fd, const char *path, int flags, ...);
static int hooked_stat(const char *path, struct stat *buf);
static int hooked_lstat(const char *path, struct stat *buf);
static int hooked_access(const char *path, int mode);
static FILE *hooked_fopen(const char *path, const char *mode);
static int hooked_unlink(const char *path);
static int hooked_unlinkat(int fd, const char *path, int flag);
static int hooked_rename(const char *old, const char *new);
static int hooked_mkdir(const char *path, mode_t mode);
static int hooked_mkdirat(int fd, const char *path, mode_t mode);

// CFPreferences 隔离用 plist 路径
// 与 NSUserDefaults Hook 共享同一个账号隔离 plist，
// 避免 TRAE 直接调用 CFPreferences API 时数据落入不同文件，
// 导致切换账号后登录态丢失。
static NSString* DKCFPreferencesPlistPath(void) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return nil;
    }
    NSString *designatedDefault = [manager designatedDefaultAccountName];
    if (designatedDefault && [currentAccount isEqualToString:designatedDefault]) {
        return nil;
    }

    // 使用自定义文件名 dk_<bundleID>.plist，绕过 cfprefsd
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSString *prefsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    NSString *filename = [NSString stringWithFormat:@"dk_%@.plist", bundleID];
    return [prefsDir stringByAppendingPathComponent:filename];
}

static NSMutableDictionary* DKCFPreferencesLoad(void) {
    NSString *path = DKCFPreferencesPlistPath();
    if (!path) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static void DKCFPreferencesSave(NSMutableDictionary *dict) {
    NSString *path = DKCFPreferencesPlistPath();
    if (!path) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [dict writeToFile:path atomically:YES];
}

// ============================================================
// Hook 2: NSUserDefaults - 配置隔离
// 每个账号使用独立的 UserDefaults 存储
// ============================================================

// ============================================================
// Hook 2: NSUserDefaults - 配置隔离（直接读写 plist，避免递归）
// 每个账号使用独立的 plist 文件存储配置
// 注意：直接读写 plist 文件，不使用 NSUserDefaults 实例方法，
// 避免触发 Hook 导致无限递归
//
// 重要：对非默认账号，不通过 %orig 回退到原始 NSUserDefaults，
// 实现真正的配置隔离。新账号创建时会自动复制原始默认值。
// ============================================================

// 启动保护：%ctor 期间 App 的 dispatch_once 初始化可能被 DK 的 setup 调用
// 间接触发，此时 DK 自身尚未完全就绪。强制所有 Hook 透传，避免返回 nil 导致 App 崩溃。
static BOOL _dkStartupGuard = YES;

BOOL DKIsStartupGuardActive(void) {
    return _dkStartupGuard;
}

static BOOL DKShouldUseOriginalDefaults(void) {
    if (_dkStartupGuard) return YES;
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (manager.isSwitching) return YES;

    // 默认账号和指定默认账号 → 使用原始 cfprefsd
    // 其他子账号 → 使用自定义 dk_<bundleID>.plist（绕过 cfprefsd 缓存）
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) return YES;
    NSString *designatedDefault = [manager designatedDefaultAccountName];
    if (designatedDefault && [currentAccount isEqualToString:designatedDefault]) return YES;
    return NO;
}

// CFPreferences 隔离守卫：与 DKShouldUseOriginalDefaults 逻辑一致，
// 确保在切换账号（isSwitching=YES）时 CFPreferences Hook 也透传到原始逻辑，
// 避免 saveCurrentState 中的 DK_Current_Account 写入被重定向到隔离 plist。
static BOOL DKShouldUseOriginalCFPreferences(void) {
    return DKShouldUseOriginalDefaults();
}

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        return %orig;
    }

    // 仅从账号独立的 plist 读取（不 fallback 到 %orig，实现真正隔离）
    return DKReadAccountUserDefault(defaultName);
}

- (NSString *)stringForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (NSArray *)arrayForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

- (NSDictionary *)dictionaryForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSData *)dataForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value isKindOfClass:[NSData class]] ? value : nil;
}

- (NSURL *)URLForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    if ([value isKindOfClass:[NSURL class]]) return value;
    if ([value isKindOfClass:[NSString class]]) return [NSURL URLWithString:value];
    return nil;
}

- (BOOL)boolForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (NSInteger)integerForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

- (float)floatForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : 0.0f;
}

- (double)doubleForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) return %orig;
    id value = DKReadAccountUserDefault(defaultName);
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }

    // 仅写入账号独立的 plist（不写入原始 NSUserDefaults，实现真正隔离）
    DKWriteAccountUserDefault(defaultName, value);
}

- (void)setBool:(BOOL)value forKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    DKWriteAccountUserDefault(defaultName, @(value));
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    DKWriteAccountUserDefault(defaultName, @(value));
}

- (void)setFloat:(float)value forKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    DKWriteAccountUserDefault(defaultName, @(value));
}

- (void)setDouble:(double)value forKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    DKWriteAccountUserDefault(defaultName, @(value));
}

- (void)setURL:(NSURL *)url forKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    DKWriteAccountUserDefault(defaultName, url.absoluteString);
}

- (void)removeObjectForKey:(NSString *)defaultName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }

    // 仅从账号独立的 plist 移除
    DKWriteAccountUserDefault(defaultName, nil);
}

- (BOOL)synchronize {
    if (DKShouldUseOriginalDefaults()) {
        return %orig;
    }

    // 非默认账号：只同步账号独立 plist，不调用 %orig
    // 原始 NSUserDefaults 的缓存从未被修改（所有写操作被重定向到账号 plist），
    // 调用 %orig 可能触发系统内部机制意外覆盖原始数据
    DKSyncAccountUserDefaults();
    return YES;
}

- (NSDictionary *)dictionaryRepresentation {
    if (DKShouldUseOriginalDefaults()) {
        return %orig;
    }

    // 仅返回账号独立的 plist 数据（不合并原始数据）
    NSDictionary *accountDict = DKReadAccountUserDefaultsDictionary();
    return accountDict ?: @{};
}

// 防止 app 在非默认账号下重置标准 UserDefaults
+ (void)resetStandardUserDefaults {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (manager.isSwitching) {
        %orig;
        return;
    }
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        %orig;
        return;
    }
    // 非默认账号下忽略 resetStandardUserDefaults，保护原始数据
    NSLog(@"[DK] 拦截 resetStandardUserDefaults（当前账号：%@）", currentAccount);
}

// 拦截域级别的读取操作。
// TTAccountSDK 可能通过 persistentDomainForName: 直接读取整个
// UserDefaults 域，此方法未被之前的 Hook 覆盖，导致子账号读到
// 原始 cfprefsd 的数据（而非隔离 plist）。
- (NSDictionary *)persistentDomainForName:(NSString *)domainName {
    if (DKShouldUseOriginalDefaults()) {
        return %orig;
    }
    // 非默认账号：从账号独立 plist 读取全部数据
    NSDictionary *accountDict = DKReadAccountUserDefaultsDictionary();
    return accountDict ?: @{};
}

// 拦截域级别的写入操作。
// setPersistentDomain:forName: 会批量写入整个域，若不拦截，
// 子账号的数据会被写入原始 cfprefsd，污染默认账号数据。
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)domainName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    // 非默认账号：将所有键值写入账号独立 plist
    for (NSString *key in domain) {
        DKWriteAccountUserDefault(key, domain[key]);
    }
}

// 拦截域级别的删除操作。
// removePersistentDomainForName: 会删除整个域。
// 若不拦截，子账号会删除原始 cfprefsd 的默认账号数据。
- (void)removePersistentDomainForName:(NSString *)domainName {
    if (DKShouldUseOriginalDefaults()) {
        %orig;
        return;
    }
    // 非默认账号：清空账号独立 plist
    DKClearAccountUserDefaults();
}

%end

// ============================================================
// Hook 3: NSHTTPCookieStorage - Cookie 隔离
// 每个账号维护独立的 Cookie 存储
// ============================================================

%hook NSHTTPCookieStorage

- (NSArray<NSHTTPCookie *> *)cookies {
    return %orig;
}

- (void)setCookie:(NSHTTPCookie *)cookie {
    %orig;
    // Cookie 变化时自动备份
    [[DKNetworkSessionManager sharedManager] saveCurrentSession];
}

- (void)deleteCookie:(NSHTTPCookie *)cookie {
    %orig;
    [[DKNetworkSessionManager sharedManager] saveCurrentSession];
}

%end

// ============================================================
// Hook 4: UIApplication - 生命周期 + 推送通知
// 确保在应用状态变化时保存/恢复会话
// 拦截推送注册回调，记录 deviceToken
// ============================================================

%hook UIApplication

- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;

    // 恢复当前账号的会话状态
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    DKNetworkSessionManager *sessionManager = [DKNetworkSessionManager sharedManager];
    BOOL shouldClearMissingDefaultSession =
        [currentAccount isEqualToString:[manager defaultAccountName]] &&
        ![sessionManager hasSessionSnapshotForAccount:[manager defaultAccountName]];
    [sessionManager restoreSessionForAccount:currentAccount
                       clearSessionIfMissing:shouldClearMissingDefaultSession];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // 进入后台前保存会话
    [[DKNetworkSessionManager sharedManager] saveCurrentSession];
    [[DKAccountManager sharedManager] saveCurrentState];

    %orig;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // 终止前保存所有状态
    [[DKNetworkSessionManager sharedManager] saveCurrentSession];
    [[DKAccountManager sharedManager] saveCurrentState];

    %orig;
}

// ============================================================
// 拦截推送注册回调
// ============================================================
- (void)application:(UIApplication *)application
didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    // 记录 deviceToken
    [[DKPushNotificationBridge sharedInstance] registerDeviceToken:deviceToken];

    // 调用原始方法
    %orig;
}

- (void)application:(UIApplication *)application
didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"[DK] 推送注册失败: %@", error);
    %orig;
}

// ============================================================
// 拦截远程推送接收（iOS 9 及以下旧 API）
// ============================================================
- (void)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {

    // 通过桥接模块处理推送
    [[DKPushNotificationBridge sharedInstance] handleRemoteNotification:userInfo
                                                       completionHandler:completionHandler];

    // 也调用原始方法
    %orig;
}

// ============================================================
// 摇晃检测 - 通过 sendEvent: 拦截运动事件
// 这是最可靠的摇晃检测方式：sendEvent: 接收所有分发的事件，
// 不依赖 responder chain 中某个对象实现了 motionEnded:。
// ============================================================
- (void)sendEvent:(UIEvent *)event {
    %orig;

    if (event.type == UIEventTypeMotion && event.subtype == UIEventSubtypeMotionShake) {
        static NSTimeInterval lastShakeTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        // 防抖：1 秒内只响应一次
        if (now - lastShakeTime > 1.0) {
            lastShakeTime = now;
            NSLog(@"[DK] 🔥 检测到摇晃！");
            [[DKAccountUI sharedInstance] triggerShowFloatingButton];
        }
    }
}

%end

// ============================================================
// Hook 5: NSURLSessionConfiguration - 网络配置隔离
// 每个账号使用独立的 URLSession 配置
// ============================================================

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;

    if (_dkStartupGuard) return config;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        NSString *sessionPath = [[DKNetworkSessionManager sharedManager] sessionPathForAccount:currentAccount];
        NSDictionary *sessionData = [NSDictionary dictionaryWithContentsOfFile:sessionPath];
        NSDictionary *headers = sessionData[@"authHeaders"];

        if (headers) {
            NSMutableDictionary *allHeaders = [config.HTTPAdditionalHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
            [allHeaders addEntriesFromDictionary:headers];
            config.HTTPAdditionalHeaders = allHeaders;
        }
    }

    return config;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;

    if (_dkStartupGuard) return config;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        NSString *sessionPath = [[DKNetworkSessionManager sharedManager] sessionPathForAccount:currentAccount];
        NSDictionary *sessionData = [NSDictionary dictionaryWithContentsOfFile:sessionPath];
        NSDictionary *headers = sessionData[@"authHeaders"];

        if (headers) {
            NSMutableDictionary *allHeaders = [config.HTTPAdditionalHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
            [allHeaders addEntriesFromDictionary:headers];
            config.HTTPAdditionalHeaders = allHeaders;
        }
    }

    return config;
}

%end

// ============================================================
// Hook 6: UNUserNotificationCenter (iOS 10+)
// 拦截推送通知展示和点击
// ============================================================

%hook UNUserNotificationCenter

// 前台收到推送
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {

    [[DKPushNotificationBridge sharedInstance] handleUserNotificationCenterWillPresent:notification
                                                                  withCompletionHandler:completionHandler];

    // 如果桥接没有处理，执行原始逻辑
    %orig;
}

// 点击推送通知
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {

    [[DKPushNotificationBridge sharedInstance] handleUserNotificationCenterDidReceive:response
                                                                withCompletionHandler:completionHandler];

    %orig;
}

%end

// ============================================================
// Hook 7: NSURLSession - 敏感词过滤绕过
// 拦截网络响应数据，在 JSON 解析前替换错误码 983
// 策略：包装 completionHandler，在原始回调前处理数据
// ============================================================

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = nil;

    if (completionHandler) {
        wrappedHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *processedData = [[DKContentFilterBypass sharedInstance] processResponseData:data];
            completionHandler(processedData, response, error);
        };
    }

    return %orig(request, wrappedHandler ?: completionHandler);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = nil;

    if (completionHandler) {
        wrappedHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *processedData = [[DKContentFilterBypass sharedInstance] processResponseData:data];
            completionHandler(processedData, response, error);
        };
    }

    return %orig(url, wrappedHandler ?: completionHandler);
}

%end

// ============================================================
// Hook 8: NSFileManager - 文件管理器路径重定向（关键！）
//
// TRAE 大量使用 NSFileManager 进行文件操作（copyItemAtPath:、
// createDirectoryAtPath:、fileExistsAtPath: 等），这些方法
// 之前完全未被 Hook。子账号时 TRAE 通过这些方法直接读写
// 沙盒路径，绕过所有隔离逻辑。
//
// 这是导致子账号和默认账号切换后都进入登录页的根本原因。
// ============================================================
%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    return %orig(DKRemapFilePath(path), isDirectory);
}

- (BOOL)createDirectoryAtPath:(NSString *)path
  withIntermediateDirectories:(BOOL)intermediates
                   attributes:(NSDictionary *)attributes
                        error:(NSError **)error {
    return %orig(DKRemapFilePath(path), intermediates, attributes, error);
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    return %orig(DKRemapFilePath(path), error);
}

- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    return %orig(DKRemapFilePath(srcPath), DKRemapFilePath(dstPath), error);
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    return %orig(DKRemapFilePath(srcPath), DKRemapFilePath(dstPath), error);
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    return %orig(DKRemapFilePath(path), error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attr {
    return %orig(DKRemapFilePath(path), data, attr);
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    return %orig(DKRemapFilePath(path), error);
}

- (BOOL)isReadableFileAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (BOOL)isWritableFileAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (BOOL)isDeletableFileAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

%end

// ============================================================
// 构造函数 - 插件加载时调用
//
// 关键设计：不在此处调用 %init，也不安装任何 Hook。
// %init 会调用 MSHookMessageEx 修改 NSDictionary/NSData/NSArray
// 等底层系统类的方法表。即使 Hook 透传，修改方法表本身也可能
// 扰乱 TRAE 主程序的 dispatch_once 初始化块，导致
// "attempt to insert nil object from objects[15]" 崩溃。
//
// 解决方案：延迟 2 秒到 App 完全启动后再安装所有 Hook。
// 此时 TRAE 的 dispatch_once 初始化已全部完成，Hook 不会
// 干扰任何关键启动流程。
//
// 子账号启动处理：
// 如果上次退出前已切换到子账号（B/C/D），%ctor 阶段立即调用
// refreshAccountList 确定当前账号。若为子账号，保存并清空
// 原始 NSUserDefaults 域，App 启动时看不到默认账号登录数据，
// 自然显示登录页。Hook 安装后再恢复原始域到默认账号存储。
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bundleID = DKGetCurrentBundleID();

        // ============================================================
        // 启动时清理上次 exit(0) 前可能残留的临时目录
        // DKAppDataManager 异步清理 Library.old/Library.tmp，
        // 如果 App 在清理前就被杀，残留目录会影响下次启动。
        // ============================================================
        for (NSString *suffix in @[@"Library.old", @"Library.tmp"]) {
            NSString *tmpPath = [NSHomeDirectory() stringByAppendingPathComponent:suffix];
            if ([[NSFileManager defaultManager] fileExistsAtPath:tmpPath]) {
                [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
                NSLog(@"[DK] 清理残留临时目录: %@", suffix);
            }
        }

        NSLog(@"========================================");
        NSLog(@"[DK] DK Multi-Account Tweak v%@ 已加载", DK_VERSION);
        NSLog(@"[DK] 构建时间: %@", DK_BUILD_TIME);
        NSLog(@"[DK] 当前应用: %@", bundleID);
        NSLog(@"========================================");

        // ============================================
        // 关键：立即确定当前账号，不能等到 Hook 安装后。
        // 如果上次退出前已切换到子账号（B/C/D），
        // 必须在 App 初始化前清空原始 NSUserDefaults，
        // 否则 App 会读取到默认账号的登录态并显示主页面。
        // ============================================
        [[DKAccountManager sharedManager] refreshAccountList];
        NSString *currentAccount = [[DKAccountManager sharedManager] currentAccountName];
        NSString *defaultAccount = [[DKAccountManager sharedManager] defaultAccountName];
        NSString *designatedDefault = [[DKAccountManager sharedManager] designatedDefaultAccountName];

        // ============================================
        // 启动时自动修复数据所有权：
        // 如果沙盒中 Library/ 的数据不属于当前账号（例如上次切换时
        // 目录搬移失败），自动将旧数据搬移到对应账号备份，
        // 并恢复当前账号数据。
        // 这解决了"添加B后进入软件还是默认账号信息"的问题。
        // ============================================
        [[DKAppDataManager sharedManager] ensureDataOwnershipForAccount:currentAccount
                                                      designatedDefault:designatedDefault];

        // 指定默认账号使用 NSHomeDirectory()，等同于原始默认账号，
        // 不需要清空 NSUserDefaults
        BOOL isNonDefaultAccount = ![currentAccount isEqualToString:defaultAccount] &&
            !(designatedDefault && [currentAccount isEqualToString:designatedDefault]);

        NSLog(@"[DK] BundleID=%@, 当前账号=%@, 指定默认=%@, 非默认=%@, accountsRoot=%@",
              bundleID, currentAccount, designatedDefault ?: @"无",
              isNonDefaultAccount ? @"YES" : @"NO",
              [[DKAccountManager sharedManager] accountsRootPath]);

        if (isNonDefaultAccount) {
            // 子账号启动：无条件清空原始 NSUserDefaults 域。
            //
            // 关键：ensureDataOwnershipForAccount 已经把 Library/ 搬走并创建了空目录，
            // persistentDomainForName: 在此刻返回 nil（空 plist 无数据），
            // 但 cfprefsd 守护进程可能仍缓存着旧进程的域数据。
            //
            // 必须无条件调用 removePersistentDomainForName: +
            // CFPreferencesAppSynchronize + synchronize 来强制 cfprefsd 清空缓存。
            // 不能依赖 "if (savedDefaultDomain)" — 那会跳过清理。
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

            // 1. 强制 cfprefsd 从磁盘同步（确保看到空 plist）
            CFPreferencesAppSynchronize((__bridge CFStringRef)bundleID);

            // 2. 无条件清空域（内存中的缓存 + 通知 cfprefsd 删除）
            [defaults removePersistentDomainForName:bundleID];

            // 3. 同步到磁盘
            [defaults synchronize];

            // 4. 再次强制 cfprefsd 同步（确保清空操作生效）
            CFPreferencesAppSynchronize((__bridge CFStringRef)bundleID);

            NSLog(@"[DK] 子账号启动：已无条件清空原始 NSUserDefaults 域");
        }

        NSLog(@"[DK] 立即安装模式：Hook 将在 App 初始化前全部安装完毕");

        // ============================================
        // 第一步：安装 Logos %hook（MSHookMessageEx）
        // 必须在 App 初始化前安装，否则 App 启动时会读取原始存储
        // 此时 _dkStartupGuard = YES，Hook 暂时透传
        // ============================================
        %init;
        NSLog(@"[DK] Logos Hook 已安装");

        // ============================================
        // 第二步：安装 C 函数 Hook（fishhook rebind_symbols）
        // 同样必须在 App 初始化前安装
        // ============================================
        static struct rebinding rebindings[] = {
            // Keychain（4 个）
            {"SecItemAdd",            hooked_SecItemAdd,            (void **)&original_SecItemAdd},
            {"SecItemCopyMatching",   hooked_SecItemCopyMatching,   (void **)&original_SecItemCopyMatching},
            {"SecItemUpdate",         hooked_SecItemUpdate,         (void **)&original_SecItemUpdate},
            {"SecItemDelete",         hooked_SecItemDelete,         (void **)&original_SecItemDelete},
            // CFPreferences（3 个 App 版本 + 6 个非 App 版本 = 9 个）
            {"CFPreferencesSetAppValue",    hooked_CFPreferencesSetAppValue,    (void **)&original_CFPreferencesSetAppValue},
            {"CFPreferencesCopyAppValue",   hooked_CFPreferencesCopyAppValue,   (void **)&original_CFPreferencesCopyAppValue},
            {"CFPreferencesAppSynchronize", hooked_CFPreferencesAppSynchronize, (void **)&original_CFPreferencesAppSynchronize},
            {"CFPreferencesSetValue",       hooked_CFPreferencesSetValue,       (void **)&original_CFPreferencesSetValue},
            {"CFPreferencesCopyValue",      hooked_CFPreferencesCopyValue,      (void **)&original_CFPreferencesCopyValue},
            {"CFPreferencesSynchronize",    hooked_CFPreferencesSynchronize,    (void **)&original_CFPreferencesSynchronize},
            {"CFPreferencesCopyKeyList",    hooked_CFPreferencesCopyKeyList,    (void **)&original_CFPreferencesCopyKeyList},
            {"CFPreferencesSetMultiple",    hooked_CFPreferencesSetMultiple,    (void **)&original_CFPreferencesSetMultiple},
            {"CFPreferencesCopyMultiple",   hooked_CFPreferencesCopyMultiple,   (void **)&original_CFPreferencesCopyMultiple},
            // POSIX 文件操作（11 个）— 拦截 MMKV/WCDB 等 C/C++ 库的直接文件 I/O
            {"open",    hooked_open,    (void **)&original_open},
            {"openat",  hooked_openat,  (void **)&original_openat},
            {"stat",    hooked_stat,    (void **)&original_stat},
            {"lstat",   hooked_lstat,   (void **)&original_lstat},
            {"access",  hooked_access,  (void **)&original_access},
            {"fopen",   hooked_fopen,   (void **)&original_fopen},
            {"unlink",  hooked_unlink,  (void **)&original_unlink},
            {"unlinkat",hooked_unlinkat,(void **)&original_unlinkat},
            {"rename",  hooked_rename,  (void **)&original_rename},
            {"mkdir",   hooked_mkdir,   (void **)&original_mkdir},
            {"mkdirat", hooked_mkdirat, (void **)&original_mkdirat},
        };
        rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding));
        NSLog(@"[DK] fishhook C 函数 Hook 已安装（24 个：Keychain 4 + CFPreferences 9 + POSIX 11）");

        // ============================================
        // 第三步：关闭启动保护
        // 子账号启动时不再把默认账号的 NSUserDefaults 写回原始域，
        // 避免状态污染。子账号的所有配置都写入隔离 plist。
        // ============================================
        _dkStartupGuard = NO;
        NSLog(@"[DK] 启动保护已关闭，账号隔离 Hook 已激活");

        // ============================================
        // 第四步：初始化各模块（dispatch_async 到主线程，确保 UI 操作安全）
        // ============================================
        dispatch_async(dispatch_get_main_queue(), ^{
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                [[DKDataIsolation sharedInstance] setup];
                [[DKUserDefaultsHook sharedInstance] install];
                [[DKKeychainHook sharedInstance] install];
                [[DKNetworkSessionManager sharedManager] setup];
                [[DKPushNotificationBridge sharedInstance] setup];
                [[DKContentFilterBypass sharedInstance] setup];
                [[DKAccountUI sharedInstance] setup];

                // 启动会话定期刷新
                [[DKNetworkSessionManager sharedManager] scheduleSessionRefresh];

                // 启动时不主动快照默认账号。
                // 会话快照在手动切换账号时（switchToAccount:）保存，
                // 以及在进入后台/终止时自动保存。启动时快照可能因
                // exit(0) 前 Cookie 未刷盘而覆盖正确的会话文件。
                DKAccountManager *manager = [DKAccountManager sharedManager];
                DKNetworkSessionManager *sessionManager = [DKNetworkSessionManager sharedManager];
                if (![[manager currentAccountName] isEqualToString:[manager defaultAccountName]] &&
                    ![sessionManager hasSessionSnapshotForAccount:[manager defaultAccountName]]) {
                    NSLog(@"[DK] 当前为子账号 %@，默认账号暂无快照；切回默认并登录后会自动保存",
                          [manager currentAccountName]);
                }

                NSLog(@"[DK] ✅ 所有模块初始化完成");
            });
        });
    }
}

// ============================================================
// %dtor - 插件卸载时调用（用于调试）
// ============================================================
%dtor {
    @autoreleasepool {
        [[DKAccountUI sharedInstance] cleanup];
        [[DKAccountManager sharedManager] saveCurrentState];
        [[DKNetworkSessionManager sharedManager] saveCurrentSession];
        NSLog(@"[DK] DK Multi-Account Tweak 已卸载");
    }
}

// ============================================================
// POSIX 文件操作 C 函数 Hook 实现
//
// MMKV 使用 open() + mmap() 直接读写文件，WCDB/SQLCipher 等
// C/C++ 库也直接使用 open()/stat()/access() 等 POSIX API。
// 这些调用完全绕过 ObjC 层的 NSFileManager/NSData Hook。
//
// 即使 DKAppDataManager 的 rename() 搬移 Library/ 失败，
// 这些 Hook 也能确保所有文件 I/O 被重定向到隔离目录，
// 子账号不会读到默认账号的 MMKV/WCDB 数据。
//
// 路径映射逻辑内置于 DKRemapFilePath()，与 NSFileManager Hook
// 共享同一套规则（DKIsStartupGuardActive + isSwitching + 默认账号检查）。
// ============================================================

/// 将 C 字符串路径通过 DKRemapFilePath 映射。
/// 返回的 const char * 来自 NSString 的 fileSystemRepresentation，
/// 其生命周期与 mappedPath 对象绑定（调用方栈帧内有效）。
/// 若路径为 NULL、非 UTF-8 或无需映射，返回原指针。
static const char *DKRemapCFilepath(const char *cPath, NSString * __strong *outHolder) {
    if (!cPath) return NULL;
    NSString *nsPath = [NSString stringWithUTF8String:cPath];
    if (!nsPath) return cPath;
    NSString *mapped = DKRemapFilePath(nsPath);
    if (mapped == nsPath || [mapped isEqualToString:nsPath]) return cPath;
    if (outHolder) *outHolder = mapped;
    return [mapped fileSystemRepresentation];
}

static int hooked_open(const char *path, int flags, ...) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode_t mode = va_arg(args, int);
        va_end(args);
        return original_open(mappedPath, flags, mode);
    }
    return original_open(mappedPath, flags);
}

static int hooked_openat(int fd, const char *path, int flags, ...) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode_t mode = va_arg(args, int);
        va_end(args);
        return original_openat(fd, mappedPath, flags, mode);
    }
    return original_openat(fd, mappedPath, flags);
}

static int hooked_stat(const char *path, struct stat *buf) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_stat(mappedPath, buf);
}

static int hooked_lstat(const char *path, struct stat *buf) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_lstat(mappedPath, buf);
}

static int hooked_access(const char *path, int mode) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_access(mappedPath, mode);
}

static FILE *hooked_fopen(const char *path, const char *mode) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_fopen(mappedPath, mode);
}

static int hooked_unlink(const char *path) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_unlink(mappedPath);
}

static int hooked_unlinkat(int fd, const char *path, int flag) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_unlinkat(fd, mappedPath, flag);
}

static int hooked_rename(const char *old, const char *new) {
    NSString *oldHolder = nil, *newHolder = nil;
    const char *mappedOld = DKRemapCFilepath(old, &oldHolder);
    const char *mappedNew = DKRemapCFilepath(new, &newHolder);
    return original_rename(mappedOld, mappedNew);
}

static int hooked_mkdir(const char *path, mode_t mode) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_mkdir(mappedPath, mode);
}

static int hooked_mkdirat(int fd, const char *path, mode_t mode) {
    NSString *holder = nil;
    const char *mappedPath = DKRemapCFilepath(path, &holder);
    return original_mkdirat(fd, mappedPath, mode);
}

// ============================================================
// Keychain - 钥匙串隔离（C 函数 Hook）
// 通过给 service/account 添加前缀实现每个账号的独立 Keychain
// 使用 fishhook rebind_symbols 重定向符号指针（不修改 __TEXT 代码页）
// ============================================================

static BOOL DKIsNonDefaultKeychainAccount(void) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return NO;
    }
    NSString *designatedDefault = [manager designatedDefaultAccountName];
    if (designatedDefault && [currentAccount isEqualToString:designatedDefault]) {
        return NO;
    }
    return YES;
}

static BOOL DKKeychainQueryHasScopedAttribute(NSDictionary *query) {
    if (query[(__bridge id)kSecAttrService]) return YES;
    if (query[(__bridge id)kSecAttrAccount]) return YES;
    if (query[(__bridge id)kSecAttrLabel]) return YES;
    if (query[(__bridge id)kSecAttrGeneric]) return YES;
    return NO;
}

static NSDictionary *DKKeychainQueryWithSyntheticScopeIfNeeded(NSDictionary *query) {
    if (!DKIsNonDefaultKeychainAccount()) return query;
    if (DKKeychainQueryHasScopedAttribute(query)) return query;

    // 某些 SDK 会使用“只按 kSecClass 查询”的宽 Keychain 读写。
    // 如果不加任何账号归属字段，子账号启动时会读到默认账号 A 的凭证。
    // 对无 service/account/label/generic 的新增项加一个合成 label，
    // 之后宽查询会通过过滤逻辑只返回当前账号自己的项。
    NSString *prefix = [[DKDataIsolation sharedInstance] keychainServicePrefix];
    if (prefix.length == 0) return query;

    NSMutableDictionary *scoped = [query mutableCopy];
    scoped[(__bridge id)kSecAttrLabel] = [prefix stringByAppendingString:@"__DK_WIDE_KEYCHAIN_ITEM__"];
    return scoped;
}

static id DKKeychainProjectedResultForOriginalQuery(NSDictionary *originalQuery, NSDictionary *matchedItem) {
    NSDictionary *unmapped = DKUnmapKeychainResult(matchedItem);
    BOOL wantsData = [originalQuery[(__bridge id)kSecReturnData] boolValue];
    BOOL wantsAttributes = [originalQuery[(__bridge id)kSecReturnAttributes] boolValue];

    if (wantsData && !wantsAttributes) {
        id data = matchedItem[(__bridge id)kSecValueData];
        return data ?: unmapped;
    }
    return unmapped;
}

static OSStatus hooked_SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    if (DKShouldUseOriginalCFPreferences()) return original_SecItemAdd(query, result);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *scopedQuery = DKKeychainQueryWithSyntheticScopeIfNeeded(nsQuery);
    NSDictionary *mappedQuery = DKRemapKeychainQuery(scopedQuery);
    return original_SecItemAdd((__bridge CFDictionaryRef)mappedQuery, result);
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (DKShouldUseOriginalCFPreferences()) return original_SecItemCopyMatching(query, result);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;

    // 非默认账号的宽查询必须特殊处理。
    // 原实现会直接把查询透传给系统；如果 SDK 只传 kSecClass 而不传
    // service/account/label/generic，系统会返回默认账号 A 的 Keychain 数据。
    // 更糟的是很多调用只要求 kSecReturnData，此时返回值是 NSData，
    // 没有属性可供 DKKeychainResultMatchesCurrentAccount 判断归属。
    if (DKIsNonDefaultKeychainAccount() && !DKKeychainQueryHasScopedAttribute(nsQuery)) {
        NSMutableDictionary *fetchQuery = [nsQuery mutableCopy];
        fetchQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
        fetchQuery[(__bridge id)kSecReturnAttributes] = @YES;
        fetchQuery[(__bridge id)kSecReturnData] = @YES;

        CFTypeRef fetchResult = NULL;
        OSStatus fetchStatus = original_SecItemCopyMatching((__bridge CFDictionaryRef)fetchQuery, &fetchResult);
        if (fetchStatus != errSecSuccess || !fetchResult) {
            if (fetchResult) CFRelease(fetchResult);
            return fetchStatus;
        }

        NSArray *items = nil;
        if (CFGetTypeID(fetchResult) == CFArrayGetTypeID()) {
            items = (__bridge NSArray *)fetchResult;
        } else if (CFGetTypeID(fetchResult) == CFDictionaryGetTypeID()) {
            items = @[(__bridge NSDictionary *)fetchResult];
        }

        NSMutableArray *matchedItems = [NSMutableArray array];
        for (NSDictionary *item in items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            if (DKKeychainResultMatchesCurrentAccount(item)) {
                [matchedItems addObject:DKKeychainProjectedResultForOriginalQuery(nsQuery, item)];
            }
        }
        CFRelease(fetchResult);

        if (matchedItems.count == 0) {
            if (result) *result = NULL;
            return errSecItemNotFound;
        }

        if (!result) {
            return errSecSuccess;
        }

        BOOL wantsAll = (nsQuery[(__bridge id)kSecMatchLimit] == (__bridge id)kSecMatchLimitAll);
        if (wantsAll) {
            *result = (__bridge_retained CFTypeRef)matchedItems;
        } else {
            *result = (__bridge_retained CFTypeRef)matchedItems.firstObject;
        }
        return errSecSuccess;
    }

    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    OSStatus status = original_SecItemCopyMatching((__bridge CFDictionaryRef)mappedQuery, result);

    if (status == errSecSuccess && result && *result) {
        if (CFGetTypeID(*result) == CFDictionaryGetTypeID()) {
            NSDictionary *item = (__bridge NSDictionary *)(*result);
            if (!DKKeychainResultMatchesCurrentAccount(item)) {
                if (*result) CFRelease(*result);
                *result = NULL;
                return errSecItemNotFound;
            }
            NSDictionary *unmapped = DKUnmapKeychainResult(item);
            if (*result) CFRelease(*result);
            *result = (__bridge_retained CFTypeRef)unmapped;
        } else if (CFGetTypeID(*result) == CFArrayGetTypeID()) {
            NSArray *items = (__bridge NSArray *)(*result);
            NSMutableArray *unmappedItems = [NSMutableArray array];
            for (id item in items) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    if (!DKKeychainResultMatchesCurrentAccount(item)) {
                        continue;
                    }
                    [unmappedItems addObject:DKUnmapKeychainResult(item)];
                } else {
                    [unmappedItems addObject:item];
                }
            }
            if (*result) CFRelease(*result);
            if (unmappedItems.count == 0) {
                *result = NULL;
                return errSecItemNotFound;
            }
            *result = (__bridge_retained CFTypeRef)unmappedItems;
        }
    }

    return status;
}

static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (DKShouldUseOriginalCFPreferences()) return original_SecItemUpdate(query, attributesToUpdate);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *scopedQuery = DKKeychainQueryWithSyntheticScopeIfNeeded(nsQuery);
    NSDictionary *mappedQuery = DKRemapKeychainQuery(scopedQuery);
    NSDictionary *nsAttributes = (__bridge NSDictionary *)attributesToUpdate;
    NSDictionary *mappedAttributes = DKRemapKeychainAttributes(nsAttributes);
    return original_SecItemUpdate((__bridge CFDictionaryRef)mappedQuery,
                                  (__bridge CFDictionaryRef)mappedAttributes);
}

static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    if (DKShouldUseOriginalCFPreferences()) return original_SecItemDelete(query);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    if (DKIsNonDefaultKeychainAccount()) {
        // 非默认账号：检查删除操作是否有可能误删其他账号的 Keychain 项。
        // 如果查询没有指定 service/account/label/generic，TTAccountSDK
        // 可能在进行"清空所有 Keychain 数据"操作，必须拦截。
        id service = nsQuery[(__bridge id)kSecAttrService];
        id account = nsQuery[(__bridge id)kSecAttrAccount];
        id label  = nsQuery[(__bridge id)kSecAttrLabel];
        id generic = nsQuery[(__bridge id)kSecAttrGeneric];

        if (!service && !account && !label && !generic) {
            // 宽泛删除：只允许删除带有当前账号前缀的项。
            // 给查询加上前缀条件，避免误删默认账号或其他子账号的数据。
            // 由于原始查询没有 service，我们无法直接过滤。
            // 安全策略：拒绝执行这种可能删除所有账号的宽泛操作。
            // 改为先遍历所有匹配项，只删除属于当前账号的。
            NSMutableDictionary *fetchQuery = [nsQuery mutableCopy];
            fetchQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
            fetchQuery[(__bridge id)kSecReturnAttributes] = @YES;

            CFTypeRef results = NULL;
            OSStatus fetchStatus = original_SecItemCopyMatching((__bridge CFDictionaryRef)fetchQuery, &results);
            if (fetchStatus == errSecSuccess && results) {
                NSArray *items = (__bridge_transfer NSArray *)results;
                for (NSDictionary *item in items) {
                    NSString *itemService = item[(__bridge id)kSecAttrService];
                    NSString *itemAccount = item[(__bridge id)kSecAttrAccount];
                    NSString *itemLabel = item[(__bridge id)kSecAttrLabel];
                    id itemGeneric = item[(__bridge id)kSecAttrGeneric];

                    // 只删除属于当前账号的项。这里不能只看 service/account，
                    // 因为宽 Keychain 新增项可能使用合成 label 标记归属。
                    if (DKKeychainResultMatchesCurrentAccount(item)) {
                        NSMutableDictionary *delQuery = [NSMutableDictionary dictionary];
                        delQuery[(__bridge id)kSecClass] = nsQuery[(__bridge id)kSecClass];
                        if (itemService) delQuery[(__bridge id)kSecAttrService] = itemService;
                        if (itemAccount) delQuery[(__bridge id)kSecAttrAccount] = itemAccount;
                        if (itemLabel) delQuery[(__bridge id)kSecAttrLabel] = itemLabel;
                        if (itemGeneric) delQuery[(__bridge id)kSecAttrGeneric] = itemGeneric;
                        original_SecItemDelete((__bridge CFDictionaryRef)delQuery);
                    }
                }
            }
            // 返回成功，原始调用者以为删除了所有项
            return errSecSuccess;
        }
    }

    NSDictionary *scopedQuery = DKKeychainQueryWithSyntheticScopeIfNeeded(nsQuery);
    NSDictionary *mappedQuery = DKRemapKeychainQuery(scopedQuery);
    return original_SecItemDelete((__bridge CFDictionaryRef)mappedQuery);
}

// ============================================================
// Hook 9: SSE/流式响应拦截 (注释)
// TRAE 的 SSE 流式响应已通过 Hook 7 的 NSURLSession completionHandler
// 包装覆盖。对于流式 API，数据在 completion 中统一处理。
// 如需更精细的逐块拦截，可在运行时通过 MSHookMessageEx 动态绑定。
// ============================================================

// ============================================================
// CFPreferences C 函数 Hook 实现
// TTAccountSDK 是 C/C++ 重 SDK，可能通过 CFPreferences
// 直接读写 UserDefaults plist 文件，绕过 NSUserDefaults Hook。
// 这里对非默认账号做独立 plist 隔离，默认账号走原始逻辑。
// ============================================================

static void hooked_CFPreferencesSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID) {
    if (DKShouldUseOriginalCFPreferences()) {
        original_CFPreferencesSetAppValue(key, value, applicationID);
        return;
    }
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：写入独立 plist
        NSString *nsKey = (__bridge NSString *)key;
        if (value) {
            dict[nsKey] = (__bridge id)value;
        } else {
            [dict removeObjectForKey:nsKey];
        }
        DKCFPreferencesSave(dict);
    } else {
        // 默认账号：走原始逻辑
        original_CFPreferencesSetAppValue(key, value, applicationID);
    }
}

static CFPropertyListRef hooked_CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID) {
    if (DKShouldUseOriginalCFPreferences()) {
        return original_CFPreferencesCopyAppValue(key, applicationID);
    }
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：从独立 plist 读取
        NSString *nsKey = (__bridge NSString *)key;
        id value = dict[nsKey];
        if (value) {
            CFRetain((__bridge CFTypeRef)value);
            return (__bridge CFPropertyListRef)value;
        }
        return NULL;
    }
    // 默认账号：走原始逻辑
    return original_CFPreferencesCopyAppValue(key, applicationID);
}

static Boolean hooked_CFPreferencesAppSynchronize(CFStringRef applicationID) {
    if (DKShouldUseOriginalCFPreferences()) return original_CFPreferencesAppSynchronize(applicationID);
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：plist 已在写入时同步，这里直接返回 true
        return true;
    }
    return original_CFPreferencesAppSynchronize(applicationID);
}

// ============================================================
// CFPreferences 非 App 版本 Hook 实现
// SetValue/CopyValue/Synchronize/CopyKeyList 是 CFPreferences 的底层 API，
// 允许调用方指定 userName 和 hostName。TTAccountSDK 可能直接调用这些
// 函数而非 App 版本（SetAppValue/CopyAppValue/AppSynchronize），
// 从而绕过已 Hook 的 3 个 App 版本。
//
// 这些 Hook 与 App 版本共享同一隔离 plist（DKCFPreferencesPlistPath），
// 确保所有 CFPreferences 写入都落在同一文件。
// ============================================================

static void hooked_CFPreferencesSetValue(CFStringRef key, CFPropertyListRef value,
                                          CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    if (DKShouldUseOriginalCFPreferences()) {
        original_CFPreferencesSetValue(key, value, applicationID, userName, hostName);
        return;
    }
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：写入独立 plist
        NSString *nsKey = (__bridge NSString *)key;
        if (value) {
            dict[nsKey] = (__bridge id)value;
        } else {
            [dict removeObjectForKey:nsKey];
        }
        DKCFPreferencesSave(dict);
    } else {
        // 默认账号：走原始逻辑
        original_CFPreferencesSetValue(key, value, applicationID, userName, hostName);
    }
}

static CFPropertyListRef hooked_CFPreferencesCopyValue(CFStringRef key,
                                                        CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    if (DKShouldUseOriginalCFPreferences()) return original_CFPreferencesCopyValue(key, applicationID, userName, hostName);
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：从独立 plist 读取
        NSString *nsKey = (__bridge NSString *)key;
        id value = dict[nsKey];
        if (value) {
            CFRetain((__bridge CFTypeRef)value);
            return (__bridge CFPropertyListRef)value;
        }
        return NULL;
    }
    // 默认账号：走原始逻辑
    return original_CFPreferencesCopyValue(key, applicationID, userName, hostName);
}

static Boolean hooked_CFPreferencesSynchronize(CFStringRef applicationID,
                                                CFStringRef userName, CFStringRef hostName) {
    if (DKShouldUseOriginalCFPreferences()) return original_CFPreferencesSynchronize(applicationID, userName, hostName);
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：plist 已在写入时同步，直接返回 true
        return true;
    }
    return original_CFPreferencesSynchronize(applicationID, userName, hostName);
}

static CFArrayRef hooked_CFPreferencesCopyKeyList(CFStringRef applicationID,
                                                   CFStringRef userName, CFStringRef hostName) {
    if (DKShouldUseOriginalCFPreferences()) return original_CFPreferencesCopyKeyList(applicationID, userName, hostName);
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：从独立 plist 读取所有 key
        NSArray *keys = [dict allKeys];
        CFArrayRef result = (__bridge CFArrayRef)keys;
        CFRetain(result);
        return result;
    }
    return original_CFPreferencesCopyKeyList(applicationID, userName, hostName);
}

static void hooked_CFPreferencesSetMultiple(CFDictionaryRef keysToSet, CFArrayRef keysToRemove,
                                             CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    if (DKShouldUseOriginalCFPreferences()) {
        original_CFPreferencesSetMultiple(keysToSet, keysToRemove, applicationID, userName, hostName);
        return;
    }
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：写入独立 plist
        if (keysToSet) {
            NSDictionary *nsDict = (__bridge NSDictionary *)keysToSet;
            [dict addEntriesFromDictionary:nsDict];
        }
        if (keysToRemove) {
            NSArray *nsKeys = (__bridge NSArray *)keysToRemove;
            for (NSString *key in nsKeys) {
                [dict removeObjectForKey:key];
            }
        }
        DKCFPreferencesSave(dict);
    } else {
        original_CFPreferencesSetMultiple(keysToSet, keysToRemove, applicationID, userName, hostName);
    }
}

static CFDictionaryRef hooked_CFPreferencesCopyMultiple(CFArrayRef keysToFetch,
                                                         CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    if (DKShouldUseOriginalCFPreferences()) return original_CFPreferencesCopyMultiple(keysToFetch, applicationID, userName, hostName);
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：从独立 plist 批量读取
        NSArray *nsKeys = (__bridge NSArray *)keysToFetch;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSString *key in nsKeys) {
            id value = dict[key];
            if (value) {
                result[key] = value;
            }
        }
        CFDictionaryRef cfResult = (__bridge CFDictionaryRef)result;
        CFRetain(cfResult);
        return cfResult;
    }
    return original_CFPreferencesCopyMultiple(keysToFetch, applicationID, userName, hostName);
}
