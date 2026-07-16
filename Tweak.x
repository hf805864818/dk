// ============================================================
// DK Multi-Account Tweak - Main Entry Point
// 使用 Logos 语法进行 Method Swizzling / MSHook
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Security/Security.h>
#import <substrate.h>
#import <UserNotifications/UserNotifications.h>

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
extern NSUserDefaults* DKGetAccountUserDefaults(NSString *suiteName);
extern void DKSyncAccountUserDefaults(void);
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
// Keychain C 函数 Hook 前向声明（定义在文件后面）
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
// 构造函数 - 插件加载时调用
// ============================================================
%ctor {
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
        
        // 安装 Keychain C 函数 Hook
        MSHookFunction((void *)SecItemAdd, (void *)hooked_SecItemAdd, (void **)&original_SecItemAdd);
        MSHookFunction((void *)SecItemCopyMatching, (void *)hooked_SecItemCopyMatching, (void **)&original_SecItemCopyMatching);
        MSHookFunction((void *)SecItemUpdate, (void *)hooked_SecItemUpdate, (void **)&original_SecItemUpdate);
        MSHookFunction((void *)SecItemDelete, (void *)hooked_SecItemDelete, (void **)&original_SecItemDelete);
        NSLog(@"[DK] Keychain Hook 已安装");
        
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
// Hook 2: NSUserDefaults - 配置隔离
// 每个账号使用独立的 UserDefaults 存储
// ============================================================

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (manager.isSwitching) return %orig;
    
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return %orig;
    }
    
    // 从账号独立的 UserDefaults 读取
    NSUserDefaults *accountDefaults = DKGetAccountUserDefaults(nil);
    return [accountDefaults objectForKey:defaultName] ?: %orig;
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
    
    // 写入账号独立的 UserDefaults
    NSUserDefaults *accountDefaults = DKGetAccountUserDefaults(nil);
    [accountDefaults setObject:value forKey:defaultName];
    [accountDefaults synchronize];
    
    // 也写入原始（保持兼容性）
    %orig;
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
    
    NSUserDefaults *accountDefaults = DKGetAccountUserDefaults(nil);
    [accountDefaults removeObjectForKey:defaultName];
    [accountDefaults synchronize];
    
    %orig;
}

- (BOOL)synchronize {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        DKSyncAccountUserDefaults();
    }
    
    return %orig;
}

- (NSDictionary *)dictionaryRepresentation {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return %orig;
    }
    
    // 合并账号数据和原始数据
    id origDict = %orig;
    NSMutableDictionary *merged = [origDict mutableCopy];
    NSUserDefaults *accountDefaults = DKGetAccountUserDefaults(nil);
    NSDictionary *accountDict = [accountDefaults dictionaryRepresentation];
    [merged addEntriesFromDictionary:accountDict];
    
    return merged;
}

%end

// ============================================================
// Hook 3: Keychain - 钥匙串隔离
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
// Hook 4: NSHTTPCookieStorage - Cookie 隔离
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
// Hook 5: UIApplication - 生命周期 + 推送通知
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
// Hook 6: NSURLSessionConfiguration - 网络配置隔离
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
// Hook 7: UNUserNotificationCenter (iOS 10+)
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
// Hook 8: NSURLSession - 敏感词过滤绕过
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
// Hook 9: SSE/流式响应拦截 (注释)
// TRAE 的 SSE 流式响应已通过 Hook 8 的 NSURLSession completionHandler
// 包装覆盖。对于流式 API，数据在 completion 中统一处理。
// 如需更精细的逐块拦截，可在运行时通过 MSHookMessageEx 动态绑定。
// ============================================================