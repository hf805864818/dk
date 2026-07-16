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

#import "DKAccountManager.h"
#import "DKAccountUI.h"
#import "DKDataIsolation.h"
#import "DKFileManagerHook.h"
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
// 路径映射工具函数声明
// ============================================================
extern NSString* DKRemapFilePath(NSString *path);
extern NSURL* DKRemapFileURL(NSURL *url);
extern void DKSyncAccountUserDefaults(void);
extern id DKReadAccountUserDefault(NSString *key);
extern void DKWriteAccountUserDefault(NSString *key, id value);
extern NSDictionary* DKReadAccountUserDefaultsDictionary(void);
extern NSDictionary* DKRemapKeychainQuery(NSDictionary *query);
extern NSDictionary* DKUnmapKeychainResult(NSDictionary *result);

// ============================================================
// 获取当前应用的 Bundle ID
// ============================================================
static NSString* DKGetCurrentBundleID(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
}

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
// Hook 1: NSFileManager - 文件路径重定向
// 拦截所有文件操作，将路径映射到当前账号数据目录
// ============================================================

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, isDirectory);
}

- (BOOL)isReadableFileAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

- (BOOL)isWritableFileAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

- (BOOL)isExecutableFileAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

- (BOOL)isDeletableFileAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)contents attributes:(NSDictionary *)attributes {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, contents, attributes);
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, createIntermediates, attributes, error);
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, error);
}

- (NSArray *)subpathsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, error);
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, error);
}

- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    NSString *mappedSrc = DKRemapFilePath(srcPath);
    NSString *mappedDst = DKRemapFilePath(dstPath);
    return %orig(mappedSrc, mappedDst, error);
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    NSString *mappedSrc = DKRemapFilePath(srcPath);
    NSString *mappedDst = DKRemapFilePath(dstPath);
    return %orig(mappedSrc, mappedDst, error);
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, error);
}

- (BOOL)linkItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    NSString *mappedSrc = DKRemapFilePath(srcPath);
    NSString *mappedDst = DKRemapFilePath(dstPath);
    return %orig(mappedSrc, mappedDst, error);
}

- (NSData *)contentsAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

- (BOOL)setAttributes:(NSDictionary *)attributes ofItemAtPath:(NSString *)path error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(attributes, mappedPath, error);
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError **)error {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath, error);
}

- (NSDirectoryEnumerator *)enumeratorAtPath:(NSString *)path {
    NSString *mappedPath = DKRemapFilePath(path);
    return %orig(mappedPath);
}

%end

// ============================================================
// Hook 1.5: NSData / NSDictionary / NSArray / NSString / NSPropertyListSerialization
// 文件读写重定向 — 这些是 iOS 应用最常用的文件读写 API
// NSFileManager Hook 只拦截了部分操作，这些类方法也必须 Hook
// ============================================================

%hook NSData

+ (instancetype)dataWithContentsOfFile:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (instancetype)initWithContentsOfFile:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically {
    return %orig(DKRemapFilePath(path), atomically);
}

- (BOOL)writeToFile:(NSString *)path options:(NSDataWritingOptions)writeOptionsMask error:(NSError **)errorPtr {
    return %orig(DKRemapFilePath(path), writeOptionsMask, errorPtr);
}

// NSURL 方法
+ (instancetype)dataWithContentsOfURL:(NSURL *)url {
    return %orig(DKRemapFileURL(url));
}

- (instancetype)initWithContentsOfURL:(NSURL *)url {
    return %orig(DKRemapFileURL(url));
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically {
    return %orig(DKRemapFileURL(url), atomically);
}

- (BOOL)writeToURL:(NSURL *)url options:(NSDataWritingOptions)writeOptionsMask error:(NSError **)errorPtr {
    return %orig(DKRemapFileURL(url), writeOptionsMask, errorPtr);
}

%end

%hook NSDictionary

+ (NSDictionary *)dictionaryWithContentsOfFile:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically {
    return %orig(DKRemapFilePath(path), atomically);
}

// NSURL 方法
+ (NSDictionary *)dictionaryWithContentsOfURL:(NSURL *)url {
    return %orig(DKRemapFileURL(url));
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically {
    return %orig(DKRemapFileURL(url), atomically);
}

%end

%hook NSArray

+ (NSArray *)arrayWithContentsOfFile:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically {
    return %orig(DKRemapFilePath(path), atomically);
}

// NSURL 方法
+ (NSArray *)arrayWithContentsOfURL:(NSURL *)url {
    return %orig(DKRemapFileURL(url));
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically {
    return %orig(DKRemapFileURL(url), atomically);
}

%end

%hook NSString

+ (instancetype)stringWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError **)error {
    return %orig(DKRemapFilePath(path), enc, error);
}

- (instancetype)initWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError **)error {
    return %orig(DKRemapFilePath(path), enc, error);
}

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically encoding:(NSStringEncoding)enc error:(NSError **)error {
    return %orig(DKRemapFilePath(path), atomically, enc, error);
}

// NSURL 方法
+ (instancetype)stringWithContentsOfURL:(NSURL *)url encoding:(NSStringEncoding)enc error:(NSError **)error {
    return %orig(DKRemapFileURL(url), enc, error);
}

- (instancetype)initWithContentsOfURL:(NSURL *)url encoding:(NSStringEncoding)enc error:(NSError **)error {
    return %orig(DKRemapFileURL(url), enc, error);
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically encoding:(NSStringEncoding)enc error:(NSError **)error {
    return %orig(DKRemapFileURL(url), atomically, enc, error);
}

%end

%hook NSPropertyListSerialization

+ (id)propertyListWithData:(NSData *)data options:(NSPropertyListReadOptions)opt format:(NSPropertyListFormat *)format error:(NSError **)error {
    return %orig(data, opt, format, error);
}

+ (NSData *)dataWithPropertyList:(id)plist format:(NSPropertyListFormat)format options:(NSPropertyListWriteOptions)opt error:(NSError **)error {
    return %orig(plist, format, opt, error);
}

%end

// ============================================================
// Hook 1.6: NSFileHandle — 底层文件读写
// 拦截 NSFileHandle 的文件操作（Flutter 可能使用此 API）
// ============================================================

%hook NSFileHandle

// 已弃用但可能仍在使用
+ (instancetype)fileHandleForReadingAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

+ (instancetype)fileHandleForWritingAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

+ (instancetype)fileHandleForUpdatingAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

// 现代 API
+ (instancetype)fileHandleForReadingFromURL:(NSURL *)url error:(NSError **)error {
    return %orig(DKRemapFileURL(url), error);
}

+ (instancetype)fileHandleForWritingToURL:(NSURL *)url error:(NSError **)error {
    return %orig(DKRemapFileURL(url), error);
}

+ (instancetype)fileHandleForUpdatingURL:(NSURL *)url error:(NSError **)error {
    return %orig(DKRemapFileURL(url), error);
}

%end

// ============================================================
// Hook 1.7: NSKeyedUnarchiver / NSKeyedArchiver — 序列化持久化
// 拦截归档/解归档的文件操作
// ============================================================

%hook NSKeyedUnarchiver

+ (id)unarchiveObjectWithFile:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

%end

%hook NSKeyedArchiver

+ (BOOL)archiveRootObject:(id)rootObject toFile:(NSString *)path {
    return %orig(rootObject, DKRemapFilePath(path));
}

%end

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

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (manager.isSwitching) return %orig;
    
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return %orig;
    }
    
    // 仅从账号独立的 plist 读取（不 fallback 到 %orig，实现真正隔离）
    return DKReadAccountUserDefault(defaultName);
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
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
    
    // 仅写入账号独立的 plist（不写入原始 NSUserDefaults，实现真正隔离）
    DKWriteAccountUserDefault(defaultName, value);
}

- (void)removeObjectForKey:(NSString *)defaultName {
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
    
    // 仅从账号独立的 plist 移除
    DKWriteAccountUserDefault(defaultName, nil);
}

- (BOOL)synchronize {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    // 切换中：直接调用原始实现（写入原始 NSUserDefaults）
    if (manager.isSwitching) return %orig;
    
    NSString *currentAccount = [manager currentAccountName];
    // 默认账号：直接调用原始实现
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return %orig;
    }
    
    // 非默认账号：只同步账号独立 plist，不调用 %orig
    // 原始 NSUserDefaults 的缓存从未被修改（所有写操作被重定向到账号 plist），
    // 调用 %orig 可能触发系统内部机制意外覆盖原始数据
    DKSyncAccountUserDefaults();
    return YES;
}

- (NSDictionary *)dictionaryRepresentation {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
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
    [[DKNetworkSessionManager sharedManager] restoreSessionForAccount:currentAccount];
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

%end

// ============================================================
// Hook 5: NSURLSessionConfiguration - 网络配置隔离
// 每个账号使用独立的 URLSession 配置
// ============================================================

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    
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
// POSIX Hook 函数前向声明（必须在 %ctor 之前，否则 Logos 报错）
// ============================================================
static BOOL _dk_fopen_hook_guard = NO;
FILE* (*original_fopen)(const char *path, const char *mode);
FILE* hooked_fopen(const char *path, const char *mode);

static BOOL _dk_open_hook_guard = NO;
int (*original_open)(const char *path, int flags, mode_t mode);
int hooked_open(const char *path, int flags, mode_t mode);

static BOOL _dk_stat_hook_guard = NO;
int (*original_stat)(const char *path, struct stat *buf);
int hooked_stat(const char *path, struct stat *buf);

static BOOL _dk_access_hook_guard = NO;
int (*original_access)(const char *path, int mode);
int hooked_access(const char *path, int mode);

static BOOL _dk_openat_hook_guard = NO;
int (*original_openat)(int fd, const char *path, int flags, mode_t mode);
int hooked_openat(int fd, const char *path, int flags, mode_t mode);

// ============================================================
// 构造函数 - 插件加载时调用
// ============================================================
%ctor {
    %init;
    
    @autoreleasepool {
        NSString *bundleID = DKGetCurrentBundleID();
        
        NSLog(@"========================================");
        NSLog(@"[DK] DK Multi-Account Tweak v%@ 已加载", DK_VERSION);
        NSLog(@"[DK] 构建时间: %@", DK_BUILD_TIME);
        NSLog(@"[DK] 当前应用: %@", bundleID);
        NSLog(@"[DK] 功能: 多账号切换 + 登录态保持 + 推送通知桥接");
        NSLog(@"========================================");
        
        // 初始化各模块
        [[DKAccountManager sharedManager] refreshAccountList];
        [[DKDataIsolation sharedInstance] setup];
        [[DKFileManagerHook sharedInstance] install];
        [[DKUserDefaultsHook sharedInstance] install];
        [[DKKeychainHook sharedInstance] install];
        [[DKNetworkSessionManager sharedManager] setup];
        [[DKPushNotificationBridge sharedInstance] setup];
        [[DKContentFilterBypass sharedInstance] setup];
        [[DKAccountUI sharedInstance] setup];
        
        // 启动会话定期刷新
        [[DKNetworkSessionManager sharedManager] scheduleSessionRefresh];
        
        NSLog(@"[DK] ✅ 所有模块初始化完成，等待手势安装...");
        
        // 安装 Keychain C 函数 Hook
        MSHookFunction((void *)SecItemAdd, (void *)hooked_SecItemAdd, (void **)&original_SecItemAdd);
        MSHookFunction((void *)SecItemCopyMatching, (void *)hooked_SecItemCopyMatching, (void **)&original_SecItemCopyMatching);
        MSHookFunction((void *)SecItemUpdate, (void *)hooked_SecItemUpdate, (void **)&original_SecItemUpdate);
        MSHookFunction((void *)SecItemDelete, (void *)hooked_SecItemDelete, (void **)&original_SecItemDelete);
        NSLog(@"[DK] Keychain Hook 已安装");
        
        // 安装 POSIX 文件 I/O Hook（捕获 Flutter dart:io 的底层调用）
        MSHookFunction((void *)fopen, (void *)hooked_fopen, (void **)&original_fopen);
        NSLog(@"[DK] POSIX fopen Hook 已安装");
        MSHookFunction((void *)open, (void *)hooked_open, (void **)&original_open);
        NSLog(@"[DK] POSIX open Hook 已安装");
        MSHookFunction((void *)stat, (void *)hooked_stat, (void **)&original_stat);
        NSLog(@"[DK] POSIX stat Hook 已安装");
        MSHookFunction((void *)access, (void *)hooked_access, (void **)&original_access);
        NSLog(@"[DK] POSIX access Hook 已安装");
        MSHookFunction((void *)openat, (void *)hooked_openat, (void **)&original_openat);
        NSLog(@"[DK] POSIX openat Hook 已安装");
        
        // 延迟启动 UI 层敏感词过滤绕过（等应用完全启动后）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[DK] 敏感词过滤绕过 UI 层 Hook 已就绪");
        });
        
        NSLog(@"[DK] 所有模块初始化完成");
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
// Keychain - 钥匙串隔离（C 函数 Hook）
// 通过给 service/account 添加前缀实现每个账号的独立 Keychain
// 使用 MSHookFunction 直接 Hook C 函数
// ============================================================

static OSStatus hooked_SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    return original_SecItemAdd((__bridge CFDictionaryRef)mappedQuery, result);
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    OSStatus status = original_SecItemCopyMatching((__bridge CFDictionaryRef)mappedQuery, result);
    
    if (status == errSecSuccess && result && *result) {
        if (CFGetTypeID(*result) == CFDictionaryGetTypeID()) {
            NSDictionary *unmapped = DKUnmapKeychainResult((__bridge NSDictionary *)(*result));
            if (*result) CFRelease(*result);
            *result = (__bridge_retained CFTypeRef)unmapped;
        } else if (CFGetTypeID(*result) == CFArrayGetTypeID()) {
            NSArray *items = (__bridge NSArray *)(*result);
            NSMutableArray *unmappedItems = [NSMutableArray array];
            for (id item in items) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    [unmappedItems addObject:DKUnmapKeychainResult(item)];
                } else {
                    [unmappedItems addObject:item];
                }
            }
            if (*result) CFRelease(*result);
            *result = (__bridge_retained CFTypeRef)unmappedItems;
        }
    }
    
    return status;
}

static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    return original_SecItemUpdate((__bridge CFDictionaryRef)mappedQuery, attributesToUpdate);
}

static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    return original_SecItemDelete((__bridge CFDictionaryRef)mappedQuery);
}

// ============================================================
// Hook 9: SSE/流式响应拦截 (注释)
// TRAE 的 SSE 流式响应已通过 Hook 7 的 NSURLSession completionHandler
// 包装覆盖。对于流式 API，数据在 completion 中统一处理。
// 如需更精细的逐块拦截，可在运行时通过 MSHookMessageEx 动态绑定。
// ============================================================

// ============================================================
// POSIX fopen Hook — 捕获 Flutter dart:io 的底层文件 I/O
// Flutter 的 File 类使用 C 标准库的 fopen/fread/fwrite 进行文件操作，
// 这些底层调用不会被 Foundation 层的 %hook 拦截。
// 通过 MSHookFunction 直接修改 fopen 的机器码指令，实现路径重定向。
// ============================================================

FILE* hooked_fopen(const char *path, const char *mode) {
    // 递归保护：如果已经在 hooked_fopen 中，直接走原始实现
    if (_dk_fopen_hook_guard) {
        return original_fopen(path, mode);
    }
    
    _dk_fopen_hook_guard = YES;
    
    FILE *result = NULL;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        if (remapped && remapped != nsPath) {
            const char *newPath = [remapped UTF8String];
            result = original_fopen(newPath, mode);
        } else {
            result = original_fopen(path, mode);
        }
    } else {
        result = original_fopen(path, mode);
    }
    
    _dk_fopen_hook_guard = NO;
    return result;
}

// ============================================================
// POSIX open() Hook — 捕获 Flutter dart:io 的二进制文件 I/O
// Flutter 的 File.readAsBytes() / File.writeAsBytes() / RandomAccessFile
// 使用 open() 而非 fopen()。这是 dart:io 最核心的文件操作函数。
// ============================================================

int hooked_open(const char *path, int flags, mode_t mode) {
    // 递归保护
    if (_dk_open_hook_guard) {
        return original_open(path, flags, mode);
    }
    
    _dk_open_hook_guard = YES;
    
    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        if (remapped && remapped != nsPath) {
            const char *newPath = [remapped UTF8String];
            result = original_open(newPath, flags, mode);
        } else {
            result = original_open(path, flags, mode);
        }
    } else {
        result = original_open(path, flags, mode);
    }
    
    _dk_open_hook_guard = NO;
    return result;
}

// ============================================================
// POSIX stat() Hook — 捕获 Flutter dart:io 的文件存在性/元数据查询
// Flutter 的 File.exists() / File.stat() / Directory.exists()
// 使用 stat() 检查文件是否存在和获取元数据。
// ============================================================

int hooked_stat(const char *path, struct stat *buf) {
    // 递归保护
    if (_dk_stat_hook_guard) {
        return original_stat(path, buf);
    }
    
    _dk_stat_hook_guard = YES;
    
    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        if (remapped && remapped != nsPath) {
            const char *newPath = [remapped UTF8String];
            result = original_stat(newPath, buf);
        } else {
            result = original_stat(path, buf);
        }
    } else {
        result = original_stat(path, buf);
    }
    
    _dk_stat_hook_guard = NO;
    return result;
}

// ============================================================
// POSIX access() Hook — 捕获 Flutter dart:io 的文件可访问性检查
// Flutter 的某些文件操作使用 access() 检查文件是否存在。
// ============================================================

int hooked_access(const char *path, int mode) {
    // 递归保护
    if (_dk_access_hook_guard) {
        return original_access(path, mode);
    }
    
    _dk_access_hook_guard = YES;
    
    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        if (remapped && remapped != nsPath) {
            const char *newPath = [remapped UTF8String];
            result = original_access(newPath, mode);
        } else {
            result = original_access(path, mode);
        }
    } else {
        result = original_access(path, mode);
    }
    
    _dk_access_hook_guard = NO;
    return result;
}

// ============================================================
// POSIX openat() Hook — 捕获 Flutter dart:io 的现代文件 I/O
// Flutter 的 dart:io 在 iOS 上使用 openat() 而非 open() 系统调用。
// 这是最关键的 Hook，因为 NSUserDefaults 的 plist 文件读写
// 也可能通过 openat() 进行。没有这个 Hook，B 账号下 Flutter 引擎
// 会直接读写原始文件，导致 A 的登录数据被覆盖。
// ============================================================

int hooked_openat(int fd, const char *path, int flags, mode_t mode) {
    // 递归保护
    if (_dk_openat_hook_guard) {
        return original_openat(fd, path, flags, mode);
    }
    
    _dk_openat_hook_guard = YES;
    
    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        if (remapped && remapped != nsPath) {
            const char *newPath = [remapped UTF8String];
            result = original_openat(fd, newPath, flags, mode);
        } else {
            result = original_openat(fd, path, flags, mode);
        }
    } else {
        result = original_openat(fd, path, flags, mode);
    }
    
    _dk_openat_hook_guard = NO;
    return result;
}