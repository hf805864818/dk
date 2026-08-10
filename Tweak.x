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
#import <CommonCrypto/CommonDigest.h>
#import <WebKit/WebKit.h>
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
#import "DKLogManager.h"
#import "DKWeChatAntiDetect.h"
#import "DKWeChatJailBreakHook.h"

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
// 应用识别辅助函数
// 用于区分 TRAE / 微信 / MonkeyCode，控制各应用专属功能
// ============================================================
static NSString* const DK_BUNDLE_TRAE       = @"com.stone.solo.cn";
static NSString* const DK_BUNDLE_WECHAT    = @"com.tencent.xin";
static NSString* const DK_BUNDLE_MONKEYCODE = @"com.chaitin.baizhi.monkeycode";

static BOOL DKIsMonkeyCode(void) {
    static BOOL checked = NO;
    static BOOL isMC = NO;
    if (!checked) {
        isMC = [DKGetCurrentBundleID() isEqualToString:DK_BUNDLE_MONKEYCODE];
        checked = YES;
    }
    return isMC;
}

static BOOL DKIsTRAE(void) {
    static BOOL checked = NO;
    static BOOL isTRAE = NO;
    if (!checked) {
        isTRAE = [DKGetCurrentBundleID() isEqualToString:DK_BUNDLE_TRAE];
        checked = YES;
    }
    return isTRAE;
}

/// 内容过滤绕过（DKContentFilterBypass）和 NSURLSession 代理注入
/// 仅适用于 TRAE。MonkeyCode 是标准的 React Native 应用，
/// 其 API 响应结构与 TRAE 不同，内容过滤会破坏登录等关键 API 的响应。
static BOOL DKShouldApplyContentFilter(void) {
    return DKIsTRAE();
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
extern NSURL* DKRemapFileURL(NSURL *url);

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
static ssize_t (*original_write)(int fd, const void *buf, size_t count);
static ssize_t (*original_read)(int fd, void *buf, size_t count);
static void *(*original_mmap)(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
static int (*original_msync)(void *addr, size_t len, int flags);
static int (*original_munmap)(void *addr, size_t len);
static int (*original_ftruncate)(int fd, off_t length);

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
static ssize_t hooked_write(int fd, const void *buf, size_t count);
static ssize_t hooked_read(int fd, void *buf, size_t count);
static void *hooked_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
static int hooked_msync(void *addr, size_t len, int flags);
static int hooked_munmap(void *addr, size_t len);
static int hooked_ftruncate(int fd, off_t length);

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

// ============================================================
// %group TRAE — 所有多账号隔离 Hook
// 微信进程也会通过 %init(TRAE) 安装这些 Hook，
// 但运行时所有 Hook 通过 DKShouldUseOriginalDefaults 守卫函数
// 透传到 %orig，不影响微信行为。
// ============================================================
%group TRAE

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
// Hook 12.5: NSJSONSerialization — 全局 JSON 拦截（零信任架构 v2）
//
// 根因：TRAE 使用 WebSocket 传输 SSE 流式数据，数据经过：
//   1. WebSocket 帧 → 2. 文本行拆分 → 3. NSJSONSerialization 解析
// NSURLProtocol 只拦截 HTTP，WebSocket 帧直接绕过。
// NSURLSession delegate 被 PointCastle swizzle 覆盖。
//
// v2 增强：
//   - 同时 Hook 解析（读取）和序列化（写入）两个方向
//   - 递归处理嵌套字典/数组，覆盖更深层的错误码
//   - 增加对 NSArray 类型响应的支持
//   - 增加对请求体 JSON 的敏感词检测绕过（发送前）
// ============================================================
%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig(data, opt, error);
    if (!result || error == NULL || *error != nil) return result;
    if (!DKShouldApplyContentFilter()) return result;
    if (![DKContentFilterBypass sharedInstance].enabled) return result;
    
    // 处理字典类型
    if ([result isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)result;
        NSDictionary *filtered = [[DKContentFilterBypass sharedInstance] processResponseJSON:dict];
        return filtered ?: result;
    }
    
    // 处理数组类型
    if ([result isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)result;
        NSArray *filtered = [[DKContentFilterBypass sharedInstance] processResponseArray:arr];
        return filtered ?: result;
    }
    
    return result;
}

+ (id)JSONObjectWithStream:(NSInputStream *)stream options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig(stream, opt, error);
    if (!result || error == NULL || *error != nil) return result;
    if (!DKShouldApplyContentFilter()) return result;
    if (![DKContentFilterBypass sharedInstance].enabled) return result;
    
    if ([result isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)result;
        NSDictionary *filtered = [[DKContentFilterBypass sharedInstance] processResponseJSON:dict];
        return filtered ?: result;
    }
    
    if ([result isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)result;
        NSArray *filtered = [[DKContentFilterBypass sharedInstance] processResponseArray:arr];
        return filtered ?: result;
    }
    
    return result;
}

%end

// ============================================================
// Hook 12: UIActivityViewController - 修复文件导出崩溃 v2
//
// 问题：TRAE 将文件保存到 Documents/，被 Hook 重定向到隔离目录。
// 后续通过 UIActivityViewController 分享时，系统分享框架
// (SHSheetActivityItemsManager/NSItemProvider) 用原始路径加载文件，
// 这些系统 API 绕过 Hook → 文件不存在 → nil → 白色弹窗闪退。
//
// v2 改进：
//   - 支持 NSItemProvider 类型的 activity items
//   - 支持 UIActivityItemSource 类型
//   - 增加文件存在性双重检查（原始路径 + 隔离路径）
//   - 确保复制后的文件有正确的访问权限
//   - 添加详细日志便于调试
// ============================================================
%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    // 获取当前账号的隔离路径前缀
    DKAccountManager *accountMgr = [DKAccountManager sharedManager];
    NSString *currentAccount = [accountMgr currentAccountName];
    NSString *defaultAccount = [accountMgr defaultAccountName];
    NSString *designatedDefault = [accountMgr designatedDefaultAccountName];
    
    BOOL isIsolated = ![currentAccount isEqualToString:defaultAccount] &&
                      (!designatedDefault || ![currentAccount isEqualToString:designatedDefault]);
    
    NSArray *fixedItems = activityItems;
    if (isIsolated) {
        NSString *accountDataPath = [accountMgr dataPathForAccount:currentAccount];
        NSString *homePath = NSHomeDirectory();
        NSMutableArray *mutableItems = [activityItems mutableCopy];
        BOOL needsFix = NO;
        
        for (NSUInteger i = 0; i < mutableItems.count; i++) {
            id item = mutableItems[i];
            NSURL *fileURL = nil;
            
            // 类型1: NSURL 文件 URL
            if ([item isKindOfClass:[NSURL class]]) {
                fileURL = (NSURL *)item;
            }
            // 类型2: NSString 路径
            else if ([item isKindOfClass:[NSString class]]) {
                fileURL = [NSURL fileURLWithPath:(NSString *)item];
            }
            // 类型3: NSItemProvider
            else if ([item isKindOfClass:NSClassFromString(@"NSItemProvider")]) {
                // NSItemProvider 可能包含文件，尝试提取
                NSURL *providerURL = nil;
                @try {
                    if ([item respondsToSelector:NSSelectorFromString(@"fileURL")]) {
                        providerURL = [item valueForKey:@"fileURL"];
                    }
                    if (!providerURL && [item respondsToSelector:NSSelectorFromString(@"registeredTypeIdentifiers")]) {
                        // 有注册的类型标识符，可能是文件
                        NSArray *types = [item valueForKey:@"registeredTypeIdentifiers"];
                        if (types.count > 0) {
                            NSLog(@"[DK] 📋 NSItemProvider types: %@", types);
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[DK] ⚠️ 读取 NSItemProvider 失败: %@", e);
                }
                
                if (providerURL && [providerURL isFileURL]) {
                    fileURL = providerURL;
                }
            }
            
            if (!fileURL || ![fileURL isFileURL]) continue;
            
            NSString *filePath = [fileURL path];
            NSFileManager *fm = [NSFileManager defaultManager];
            
            // 检查文件是否在原始路径存在
            BOOL fileExistsAtOriginal = [fm fileExistsAtPath:filePath];
            
            // 计算隔离目录中的对应路径
            NSString *isolatedPath = nil;
            if ([filePath hasPrefix:homePath]) {
                NSString *relativePath = [filePath substringFromIndex:homePath.length];
                // 跳过已经在隔离目录、tmp、Caches 中的文件
                if ([relativePath hasPrefix:@"/Documents/DKAccounts"]) {
                    // 文件已经在隔离目录中，需要复制到 tmp
                    isolatedPath = filePath;
                } else if ([relativePath hasPrefix:@"/tmp/"] || [relativePath isEqualToString:@"/tmp"]) {
                    continue; // tmp 中的文件不需要处理
                } else if ([relativePath hasPrefix:@"/Library/Caches/"] || [relativePath isEqualToString:@"/Library/Caches"]) {
                    continue; // Caches 中的文件不需要处理
                } else {
                    isolatedPath = [accountDataPath stringByAppendingPathComponent:relativePath];
                }
            } else if ([filePath hasPrefix:accountDataPath]) {
                // 文件已经在隔离目录中
                isolatedPath = filePath;
            }
            
            if (!isolatedPath) continue;
            
            BOOL fileExistsAtIsolated = [fm fileExistsAtPath:isolatedPath];
            
            // 如果原始路径不存在但隔离路径存在，需要复制到 tmp
            // 如果原始路径存在但可能是重定向后的（即文件实际在隔离目录），也复制到 tmp 确保安全
            if (fileExistsAtIsolated || fileExistsAtOriginal) {
                NSString *sourcePath = fileExistsAtIsolated ? isolatedPath : filePath;
                
                // 生成唯一的 tmp 路径（使用时间戳避免重名冲突）
                NSString *timestamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970] * 1000];
                NSString *tmpFileName = [NSString stringWithFormat:@"dk_share_%@_%@", timestamp, [filePath lastPathComponent]];
                NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpFileName];
                
                // 移除旧文件
                [fm removeItemAtPath:tmpPath error:nil];
                
                NSError *copyError = nil;
                if ([fm copyItemAtPath:sourcePath toPath:tmpPath error:&copyError]) {
                    // 确保文件有正确的访问权限
                    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)}
                                                     ofItemAtPath:tmpPath
                                                            error:nil];
                    
                    NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];
                    
                    // 根据原始 item 类型替换
                    if ([item isKindOfClass:[NSURL class]]) {
                        mutableItems[i] = tmpURL;
                    } else if ([item isKindOfClass:[NSString class]]) {
                        mutableItems[i] = tmpPath;
                    } else if ([item isKindOfClass:NSClassFromString(@"NSItemProvider")]) {
                        // 对于 NSItemProvider，直接用 NSURL 替换更可靠
                        mutableItems[i] = tmpURL;
                        NSLog(@"[DK] 🔄 NSItemProvider → NSURL: %@", tmpPath);
                    }
                    
                    needsFix = YES;
                    NSLog(@"[DK] 🔄 导出文件映射: %@ → %@", sourcePath, tmpPath);
                } else {
                    NSLog(@"[DK] ❌ 文件复制失败: %@ → %@, error: %@", sourcePath, tmpPath, copyError);
                }
            } else {
                NSLog(@"[DK] ⚠️ 文件在两个路径都不存在: original=%@, isolated=%@", filePath, isolatedPath);
            }
        }
        
        if (needsFix) {
            fixedItems = [mutableItems copy];
            NSLog(@"[DK] ✅ UIActivityViewController items 已修复，共 %lu 个项目", (unsigned long)fixedItems.count);
        }
    }
    
    return %orig(fixedItems, applicationActivities);
}

%end

// ============================================================
// Hook 9: NSFileHandle - 文件描述符级路径重定向
//
// 文件上传失败的根因：TRAE 使用 NSFileHandle 读写文件，
// 但 NSFileHandle 的创建方法（fileHandleForReadingAtPath: 等）
// 直接调用 open() 获取 fd，不走 NSFileManager。
// 子账号时，文件可能被写入到隔离目录，但 NSFileHandle
// 未 Hook → 从原始沙盒路径读取 → 文件不存在 → 上传失败。
// ============================================================
%hook NSFileHandle

+ (id)fileHandleForReadingAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

+ (id)fileHandleForWritingAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

+ (id)fileHandleForUpdatingAtPath:(NSString *)path {
    return %orig(DKRemapFilePath(path));
}

%end

// ============================================================
// Hook 10: NSData - 文件读写路径重定向
//
// NSData 的 writeToFile / initWithContentsOfFile 等方法
// 内部使用 open() / write() / read() 系统调用，
// 但 NSData 可能缓存路径字符串，后续操作绕过 open() Hook。
// 显式 Hook 确保路径一致性。
// ============================================================
%hook NSData

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically {
    return %orig(DKRemapFilePath(path), atomically);
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically {
    return %orig(DKRemapFileURL(url), atomically);
}

- (BOOL)writeToFile:(NSString *)path options:(NSDataWritingOptions)options error:(NSError **)error {
    return %orig(DKRemapFilePath(path), options, error);
}

- (BOOL)writeToURL:(NSURL *)url options:(NSDataWritingOptions)options error:(NSError **)error {
    return %orig(DKRemapFileURL(url), options, error);
}

%end

// 不能 %hook NSData 的类方法和 init 方法（Logos 限制），
// 改用 MSHookMessageEx 在 %ctor 中手动安装

static id (*original_NSData_dataWithContentsOfFile)(Class, SEL, NSString *);
static id (*original_NSData_initWithContentsOfFile)(id, SEL, NSString *);

static id hooked_NSData_dataWithContentsOfFile(Class cls, SEL sel, NSString *path) {
    return original_NSData_dataWithContentsOfFile(cls, sel, DKRemapFilePath(path));
}

static id hooked_NSData_initWithContentsOfFile(id self, SEL sel, NSString *path) {
    return original_NSData_initWithContentsOfFile(self, sel, DKRemapFilePath(path));
}

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

    // MonkeyCode 子账号：隔离 APNs deviceToken
    // APNs token 对同一设备同一 app 是固定的，无法通过文件系统隔离。
    // 子账号将 token 与账号名哈希异或，生成不同 token，
    // 避免服务器通过 APNs token 识别为同一设备。
    NSData *tokenToUse = deviceToken;

    if (!DKIsStartupGuardActive() && DKIsMonkeyCode()) {
        DKAccountManager *manager = [DKAccountManager sharedManager];
        NSString *currentAccount = [manager currentAccountName];

        BOOL isDefault = [currentAccount isEqualToString:[manager defaultAccountName]];
        NSString *designatedDefault = [manager designatedDefaultAccountName];
        BOOL isDesignatedDefault = designatedDefault &&
            [currentAccount isEqualToString:designatedDefault];

        if (!isDefault && !isDesignatedDefault) {
            NSString *seed = [NSString stringWithFormat:@"DK_APNs_%@", currentAccount];
            const char *seedStr = [seed UTF8String];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(seedStr, (CC_LONG)strlen(seedStr), digest);

            const unsigned char *originalBytes = deviceToken.bytes;
            unsigned char derived[deviceToken.length];
            for (NSUInteger i = 0; i < deviceToken.length; i++) {
                derived[i] = originalBytes[i] ^ digest[i % CC_SHA256_DIGEST_LENGTH];
            }
            tokenToUse = [NSData dataWithBytes:derived length:deviceToken.length];

            static BOOL loggedAPNs = NO;
            if (!loggedAPNs) {
                NSLog(@"[DK] APNs deviceToken 已隔离: 账号「%@」", currentAccount);
                loggedAPNs = YES;
            }
        }
    }

    // 调用原始方法（传入可能修改过的 token）
    %orig(application, tokenToUse);
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
// Hook 4.5: UIApplication - setApplicationIconBadgeNumber
// 捕获每个账号的徽章数，实现多账号通知角标
// ============================================================
%hook UIApplication

- (void)setApplicationIconBadgeNumber:(NSInteger)applicationIconBadgeNumber {
    %orig;
    
    // 将徽章数归属到当前活跃账号
    DKAccountManager *mgr = [DKAccountManager sharedManager];
    NSString *currentName = [mgr currentAccountName];
    if (currentName) {
        [[DKPushNotificationBridge sharedInstance] setBadgeCount:applicationIconBadgeNumber
                                                      forAccount:currentName];
        // 刷新悬浮按钮角标
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DKAccountUI sharedInstance] refreshFloatingBadge];
        });
    }
}

%end

// ============================================================
// Hook 5: NSURLSessionConfiguration - 网络配置隔离
// 每个账号使用独立的 URLSession 配置
//
// ⚠️ 重要修复（MonkeyCode 登录失败根因）：
// authHeaders 中包含 __DK_ISOLATION_PLIST__ / __DK_FULL_DOMAIN__
// 等内部 DK 元数据键（值为 NSDictionary，非 NSString）。
// 直接注入 HTTPAdditionalHeaders 会导致 NSURLSession 构造请求时
// 出现非法 HTTP 头，服务器返回错误（"登录失败，请重试"）。
//
// 修复策略：
//   1. 过滤所有 __DK_ 前缀的内部键，不注入为 HTTP 头
//   2. 仅注入值为 NSString/NSData 的合法 HTTP 头
//   3. MonkeyCode（React Native）完全跳过头部注入：
//      RN 在 JS 层通过 fetch headers 管理 auth token，
//      不依赖 NSURLSessionConfiguration.HTTPAdditionalHeaders
// ============================================================

/// 从 authHeaders 中过滤出合法的 HTTP 头
/// 移除 __DK_ 前缀的内部元数据键和非字符串值
static NSDictionary* DKFilterAuthHeadersForHTTP(NSDictionary *headers) {
    if (!headers || headers.count == 0) return nil;

    NSMutableDictionary *filtered = [NSMutableDictionary dictionary];
    for (NSString *key in headers) {
        // 跳过内部 DK 元数据键
        if ([key hasPrefix:@"__DK_"]) continue;

        id value = headers[key];
        // HTTPAdditionalHeaders 只接受 NSString 或 NSData 值
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSData class]]) {
            filtered[key] = value;
        }
    }
    return filtered.count > 0 ? [filtered copy] : nil;
}

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;

    if (_dkStartupGuard) return config;

    // MonkeyCode（React Native）：完全跳过头部注入
    // RN 在 JS 层管理 auth token，HTTPAdditionalHeaders 注入会干扰 API 请求
    if (DKIsMonkeyCode()) return config;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        NSString *sessionPath = [[DKNetworkSessionManager sharedManager] sessionPathForAccount:currentAccount];
        NSDictionary *sessionData = [NSDictionary dictionaryWithContentsOfFile:sessionPath];
        NSDictionary *headers = sessionData[@"authHeaders"];

        // 过滤内部 DK 键，仅注入合法 HTTP 头
        NSDictionary *validHeaders = DKFilterAuthHeadersForHTTP(headers);
        if (validHeaders) {
            NSMutableDictionary *allHeaders = [config.HTTPAdditionalHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
            [allHeaders addEntriesFromDictionary:validHeaders];
            config.HTTPAdditionalHeaders = allHeaders;
        }
    }

    return config;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;

    if (_dkStartupGuard) return config;

    // MonkeyCode（React Native）：完全跳过头部注入
    if (DKIsMonkeyCode()) return config;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        NSString *sessionPath = [[DKNetworkSessionManager sharedManager] sessionPathForAccount:currentAccount];
        NSDictionary *sessionData = [NSDictionary dictionaryWithContentsOfFile:sessionPath];
        NSDictionary *headers = sessionData[@"authHeaders"];

        NSDictionary *validHeaders = DKFilterAuthHeadersForHTTP(headers);
        if (validHeaders) {
            NSMutableDictionary *allHeaders = [config.HTTPAdditionalHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
            [allHeaders addEntriesFromDictionary:validHeaders];
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
// Hook 7: NSURLSession - 敏感词过滤绕过（双层防护）
//
// Layer 1 (completionHandler): 拦截 dataTaskWithRequest:completionHandler:
//   和 dataTaskWithURL:completionHandler: — 处理非流式 HTTP 请求
// Layer 2 (delegate 代理): 拦截 NSURLSession 初始化，注入代理对象 —
//   处理 SSE 流式响应，TRAE 的 AI 对话通过此路径传输
// ============================================================

%hook NSURLSession

// Layer 1: completionHandler 路径（保留原有逻辑）
// ⚠️ 微信模式下跳过敏感词过滤：DKContentFilterBypass 未在微信中初始化，
// 且人脸认证等关键网络请求不应被包装处理。
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {

    // 微信模式：直接透传，不包装 completionHandler
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        return %orig;
    }

    // MonkeyCode：不包装 completionHandler，避免内容过滤破坏 API 响应
    if (!DKShouldApplyContentFilter()) {
        return %orig;
    }

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

    // 微信模式：直接透传
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        return %orig;
    }

    // MonkeyCode：不包装 completionHandler
    if (!DKShouldApplyContentFilter()) {
        return %orig;
    }

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = nil;

    if (completionHandler) {
        wrappedHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *processedData = [[DKContentFilterBypass sharedInstance] processResponseData:data];
            completionHandler(processedData, response, error);
        };
    }

    return %orig(url, wrappedHandler ?: completionHandler);
}

// Layer 3: uploadTask 路径 — 文件上传路径重定向
// uploadTaskWithRequest:fromFile: 的 fromFile 参数内部 open() 读取文件，
// 显式重映射 URL 确保路径与 NSFileHandle/NSData 一致。
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL {
    return %orig(request, DKRemapFileURL(fileURL));
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    // 微信模式：直接透传，但保留文件路径重映射
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        return %orig(request, DKRemapFileURL(fileURL), completionHandler);
    }
    // MonkeyCode：保留文件路径重映射，但不包装 completionHandler
    if (!DKShouldApplyContentFilter()) {
        return %orig(request, DKRemapFileURL(fileURL), completionHandler);
    }
    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = nil;
    if (completionHandler) {
        wrappedHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *processedData = [[DKContentFilterBypass sharedInstance] processResponseData:data];
            completionHandler(processedData, response, error);
        };
    }
    return %orig(request, DKRemapFileURL(fileURL), wrappedHandler ?: completionHandler);
}

// Layer 4: uploadTask fromData 路径 — 内存数据上传
// TRAE 很可能将文件先读入 NSData 再通过 fromData: 上传，
// 而非直接从文件路径上传。此路径不涉及文件路径，无需重映射，
// 但需要拦截 completionHandler 做敏感词过滤。
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    return %orig(request, bodyData);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    // 微信模式：直接透传
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        return %orig(request, bodyData, completionHandler);
    }
    // MonkeyCode：不包装 completionHandler
    if (!DKShouldApplyContentFilter()) {
        return %orig(request, bodyData, completionHandler);
    }
    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = nil;
    if (completionHandler) {
        wrappedHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *processedData = [[DKContentFilterBypass sharedInstance] processResponseData:data];
            completionHandler(processedData, response, error);
        };
    }
    return %orig(request, bodyData, wrappedHandler ?: completionHandler);
}

%end

// Layer 2: 代理注入 — 拦截所有 delegate-based NSURLSession（SSE 流式响应）
// 使用 MSHookMessageEx 直接 hook 类方法，因为 %hook 无法 hook 类方法簇

static id (*original_sessionWithConfig_delegate_queue)(Class, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);
static id (*original_sessionWithConfig)(Class, SEL, NSURLSessionConfiguration *);

static id hooked_sessionWithConfig_delegate_queue(Class cls, SEL sel, NSURLSessionConfiguration *config, id delegate, NSOperationQueue *queue) {
    // 如果有 delegate，用代理包裹
    if (delegate) {
        DKFilterProxyDelegate *proxy = [[DKFilterProxyDelegate alloc] initWithOriginalDelegate:delegate];
        return original_sessionWithConfig_delegate_queue(cls, sel, config, proxy, queue);
    }
    return original_sessionWithConfig_delegate_queue(cls, sel, config, delegate, queue);
}

static id hooked_sessionWithConfig(Class cls, SEL sel, NSURLSessionConfiguration *config) {
    return original_sessionWithConfig(cls, sel, config);
}

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
// Hook 13: UIDevice - identifierForVendor 设备标识隔离
//
// MonkeyCode（白泽/长亭）使用 identifierForVendor (IDFV) 生成
// 设备指纹，用于登录验证码发送、captcha token 获取等流程。
// IDFV 是系统级标识符，同一设备上同 vendor 的所有 App 共享
// 同一值，DK 的文件/Keychain Hook 无法隔离。
//
// 若不 Hook，子账号登录时服务器检测到与默认账号相同的设备指纹，
// 会判定为同一设备重复注册，拒绝登录（"登录失败，请重试"）。
//
// 策略：
//   - 默认账号 / 指定默认账号：返回原始 IDFV（不影响原功能）
//   - 子账号：返回基于账号名 + 原始 IDFV 生成的确定性 UUID
//     （同一子账号每次启动都得到相同的 UUID，不同子账号各不相同）
// ============================================================
%hook UIDevice

- (NSUUID *)identifierForVendor {
    NSUUID *original = %orig;

    if (DKIsStartupGuardActive()) return original;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    // 默认账号不修改
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return original;
    }
    // 指定默认账号也不修改
    NSString *designatedDefault = [manager designatedDefaultAccountName];
    if (designatedDefault && [currentAccount isEqualToString:designatedDefault]) {
        return original;
    }

    // 子账号：基于账号名 + 原始 IDFV 生成确定性 UUID
    // 使用 SHA-256 保证不同账号名生成不同的 UUID
    NSString *seed = [NSString stringWithFormat:@"DK_IDFV_%@_%@",
                      currentAccount, [original UUIDString]];
    const char *seedStr = [seed UTF8String];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(seedStr, (CC_LONG)strlen(seedStr), digest);

    // NSUUID 需要 16 字节 (128 bit)
    // RFC 4122 version 4: 设置第 7 字节高 4 位为 0100，第 9 字节高 2 位为 10
    digest[6] = (digest[6] & 0x0F) | 0x40;
    digest[8] = (digest[8] & 0x3F) | 0x80;

    NSUUID *derivedUUID = [[NSUUID alloc] initWithUUIDBytes:digest];

    static BOOL loggedOnce = NO;
    if (!loggedOnce) {
        NSLog(@"[DK] identifierForVendor 已隔离: 账号「%@」UUID %@ → %@",
              currentAccount, [original UUIDString], [derivedUUID UUIDString]);
        loggedOnce = YES;
    }

    return derivedUUID;
}

%end

// ============================================================
// Hook 14: WKWebView Cookie / DataStore 隔离
//
// MonkeyCode 登录流程使用 RNCWebView (WKWebView) 加载 Baizhi OAuth 页面。
// WKWebView 有独立的 cookie 存储 (WKHTTPCookieStore)，与
// NSHTTPCookieStorage 完全隔离。DK 的 Cookie Hook 无法覆盖。
//
// 若不隔离，子账号启动时 WKWebView 仍保留默认账号的 cookie，
// 服务器检测到已有会话（来自默认账号）而拒绝登录。
//
// 策略：
//   - 默认账号 / 指定默认账号：不干预，使用原始 dataStore
//   - 子账号：清除 defaultDataStore 的所有 cookie 和网站数据
//     确保 WebView 在干净的 cookie 环境中加载登录页
// ============================================================
%hook WKWebsiteDataStore

+ (WKWebsiteDataStore *)defaultDataStore {
    WKWebsiteDataStore *store = %orig;

    // 仅子账号执行清理
    static dispatch_once_t onceToken;
    static BOOL shouldClear = NO;
    static BOOL cleared = NO;

    dispatch_once(&onceToken, ^{
        // 仅 MonkeyCode 子账号需要清除 WKWebView cookie
        // TRAE 和微信不使用 WKWebView 登录，无需干预
        if (!DKIsMonkeyCode()) {
            shouldClear = NO;
            return;
        }

        if (DKIsStartupGuardActive()) {
            shouldClear = NO;
            return;
        }

        DKAccountManager *manager = [DKAccountManager sharedManager];
        NSString *currentAccount = [manager currentAccountName];

        // 默认账号和指定默认账号不清理
        if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
            shouldClear = NO;
            return;
        }
        NSString *designatedDefault = [manager designatedDefaultAccountName];
        if (designatedDefault && [currentAccount isEqualToString:designatedDefault]) {
            shouldClear = NO;
            return;
        }

        shouldClear = YES;
    });

    if (shouldClear && !cleared) {
        cleared = YES;
        // 清除所有 cookie 和网站数据
        NSSet *websiteDataTypes = [WKWebsiteDataStore allWebsiteDataTypes];
        NSDate *dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
        [store removeDataOfTypes:websiteDataTypes
                  modifiedSince:dateFrom
                 completionHandler:^{
            NSLog(@"[DK] WKWebView cookie 和网站数据已清除（账号隔离）");
        }];
        NSLog(@"[DK] WKWebsiteDataStore 已标记清理（子账号 WebView 隔离）");
        // ⚠️ 注意：清理是异步的。通过在 %ctor 第 3.5 步提前触发
        // defaultDataStore 调用，确保清理在应用 UI 加载前就开始，
        // 远早于用户点击登录触发 OAuth 流程。
        // cleared 标志确保只清理一次，不会在 OAuth 设置 cookie 后再次清理。
    }

    return store;
}

%end

// ============================================================
// Hook 15: WKHTTPCookieStore - Cookie 写入拦截
//
// 防止 WebView 在子账号环境下写入的 cookie 被默认账号的
// WebView 读取。通过在 setCookie: 时记录但不阻止，
// 在子账号启动时清除所有 WebView cookie 来实现隔离。
// ============================================================
%hook WKHTTPCookieStore

- (void)setCookie:(NSHTTPCookie *)cookie completionHandler:(void (^)(void))completionHandler {
    // 直接透传，cookie 隔离通过 Hook 启动时清除来实现
    // 不在此处做额外处理，避免 WebView 功能异常
    %orig(cookie, completionHandler);
}

%end

%end // %group TRAE

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
        BOOL isWeChat = [bundleID isEqualToString:@"com.tencent.xin"];

        // ============================================================
        // 微信专属：越狱检测绕过 + 防检测
        // 必须在所有其他 Hook 之前安装，防止微信检测到越狱后主动退出。
        // 但与之前不同：不再 return！微信也需要完整的多账号功能。
        // ============================================================
        if (isWeChat) {
            NSLog(@"[DK] 🔐 检测到微信，安装越狱检测绕过...");
            [[DKWeChatAntiDetect sharedInstance] install];
            [[DKWeChatJailBreakHook sharedInstance] install];
        }

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
        NSLog(@"[DK] 当前应用: %@%@", bundleID,
              isWeChat ? @" (微信)" : (DKIsMonkeyCode() ? @" (MonkeyCode)" : @" (TRAE)"));
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
        %init(TRAE);
        NSLog(@"[DK] Logos Hook 已安装（%@ 多账号隔离）",
              isWeChat ? @"微信" : (DKIsMonkeyCode() ? @"MonkeyCode" : @"TRAE"));

        // ============================================
        // 第二步：安装 C 函数 Hook（fishhook rebind_symbols）
        //
        // TRAE：安装全部 30 个 Hook（Keychain + CFPreferences + POSIX + mmap）
        // 微信：仅安装 Keychain + CFPreferences（13 个），跳过 POSIX + mmap
        //
        // 原因：在 rootless 越狱环境中，libsandy 已 Hook open/stat/access/
        // fopen 等函数用于路径重映射。微信中再 Hook 同一批函数会导致
        // 与 libsandy 的 Hook 链冲突，可能引发 SIGABRT 闪退。
        //
        // 微信的文件隔离依赖 DKAppDataManager 的目录级搬移（rename）
        // 而非 POSIX 文件级 Hook，同样能保证多账号数据隔离。
        // ============================================
        if (!isWeChat) {
            // TRAE：完整 Hook 集
            static struct rebinding rebindings[] = {
                // Keychain（4 个）
                {"SecItemAdd",            hooked_SecItemAdd,            (void **)&original_SecItemAdd},
                {"SecItemCopyMatching",   hooked_SecItemCopyMatching,   (void **)&original_SecItemCopyMatching},
                {"SecItemUpdate",         hooked_SecItemUpdate,         (void **)&original_SecItemUpdate},
                {"SecItemDelete",         hooked_SecItemDelete,         (void **)&original_SecItemDelete},
                // CFPreferences（9 个）
                {"CFPreferencesSetAppValue",    hooked_CFPreferencesSetAppValue,    (void **)&original_CFPreferencesSetAppValue},
                {"CFPreferencesCopyAppValue",   hooked_CFPreferencesCopyAppValue,   (void **)&original_CFPreferencesCopyAppValue},
                {"CFPreferencesAppSynchronize", hooked_CFPreferencesAppSynchronize, (void **)&original_CFPreferencesAppSynchronize},
                {"CFPreferencesSetValue",       hooked_CFPreferencesSetValue,       (void **)&original_CFPreferencesSetValue},
                {"CFPreferencesCopyValue",      hooked_CFPreferencesCopyValue,      (void **)&original_CFPreferencesCopyValue},
                {"CFPreferencesSynchronize",    hooked_CFPreferencesSynchronize,    (void **)&original_CFPreferencesSynchronize},
                {"CFPreferencesCopyKeyList",    hooked_CFPreferencesCopyKeyList,    (void **)&original_CFPreferencesCopyKeyList},
                {"CFPreferencesSetMultiple",    hooked_CFPreferencesSetMultiple,    (void **)&original_CFPreferencesSetMultiple},
                {"CFPreferencesCopyMultiple",   hooked_CFPreferencesCopyMultiple,   (void **)&original_CFPreferencesCopyMultiple},
                // POSIX 文件操作（13 个）
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
                {"write",   hooked_write,   (void **)&original_write},
                {"read",    hooked_read,    (void **)&original_read},
                // mmap 系列（4 个）
                {"mmap",    hooked_mmap,    (void **)&original_mmap},
                {"msync",   hooked_msync,   (void **)&original_msync},
                {"munmap",  hooked_munmap,  (void **)&original_munmap},
                {"ftruncate", hooked_ftruncate, (void **)&original_ftruncate},
            };
            rebind_symbols(rebindings, 30);
            NSLog(@"[DK] fishhook C 函数 Hook 已安装（30 个：Keychain 4 + CFPreferences 9 + POSIX 13 + mmap 4）");
        } else {
            // 微信：仅 Keychain + CFPreferences，跳过 POSIX 和 mmap
            static struct rebinding wechat_rebindings[] = {
                {"SecItemAdd",            hooked_SecItemAdd,            (void **)&original_SecItemAdd},
                {"SecItemCopyMatching",   hooked_SecItemCopyMatching,   (void **)&original_SecItemCopyMatching},
                {"SecItemUpdate",         hooked_SecItemUpdate,         (void **)&original_SecItemUpdate},
                {"SecItemDelete",         hooked_SecItemDelete,         (void **)&original_SecItemDelete},
                {"CFPreferencesSetAppValue",    hooked_CFPreferencesSetAppValue,    (void **)&original_CFPreferencesSetAppValue},
                {"CFPreferencesCopyAppValue",   hooked_CFPreferencesCopyAppValue,   (void **)&original_CFPreferencesCopyAppValue},
                {"CFPreferencesAppSynchronize", hooked_CFPreferencesAppSynchronize, (void **)&original_CFPreferencesAppSynchronize},
                {"CFPreferencesSetValue",       hooked_CFPreferencesSetValue,       (void **)&original_CFPreferencesSetValue},
                {"CFPreferencesCopyValue",      hooked_CFPreferencesCopyValue,      (void **)&original_CFPreferencesCopyValue},
                {"CFPreferencesSynchronize",    hooked_CFPreferencesSynchronize,    (void **)&original_CFPreferencesSynchronize},
                {"CFPreferencesCopyKeyList",    hooked_CFPreferencesCopyKeyList,    (void **)&original_CFPreferencesCopyKeyList},
                {"CFPreferencesSetMultiple",    hooked_CFPreferencesSetMultiple,    (void **)&original_CFPreferencesSetMultiple},
                {"CFPreferencesCopyMultiple",   hooked_CFPreferencesCopyMultiple,   (void **)&original_CFPreferencesCopyMultiple},
            };
            rebind_symbols(wechat_rebindings, 13);
            NSLog(@"[DK] fishhook C 函数 Hook 已安装（13 个：Keychain 4 + CFPreferences 9，跳过 POSIX/mmap）");
        }

        // ============================================
        // 第 2.5 步：Hook NSURLSession 类方法 — 代理注入（仅 TRAE）
        // 微信不需要 SSE 流式过滤和敏感词处理。
        // MonkeyCode 也不需要：代理注入会包装所有 delegate-based
        // NSURLSession，干扰 React Native fetch/WebSocket 的响应处理。
        // ============================================
        if (!isWeChat && DKShouldApplyContentFilter()) {
            Class sessionClass = objc_getClass("NSURLSession");
            if (sessionClass) {
                MSHookMessageEx(object_getClass(sessionClass),
                                @selector(sessionWithConfiguration:delegate:delegateQueue:),
                                (IMP)hooked_sessionWithConfig_delegate_queue,
                                (IMP *)&original_sessionWithConfig_delegate_queue);
                MSHookMessageEx(object_getClass(sessionClass),
                                @selector(sessionWithConfiguration:),
                                (IMP)hooked_sessionWithConfig,
                                (IMP *)&original_sessionWithConfig);
                NSLog(@"[DK] NSURLSession delegate 代理注入已安装（SSE 流式过滤）");
            }
        }

        // ============================================
        // 第 2.6 步：Hook NSData 类方法（Logos 无法 %hook 类方法）
        // dataWithContentsOfFile: 和 initWithContentsOfFile:
        // 是文件上传/读取流程中常用的 API，未 Hook 会导致
        // 子账号读取文件时路径不一致。
        // ============================================
        {
            Class nsdataClass = objc_getClass("NSData");
            if (nsdataClass) {
                // Hook 类方法 +dataWithContentsOfFile:
                MSHookMessageEx(object_getClass(nsdataClass),
                                @selector(dataWithContentsOfFile:),
                                (IMP)hooked_NSData_dataWithContentsOfFile,
                                (IMP *)&original_NSData_dataWithContentsOfFile);
                // Hook 实例方法 -initWithContentsOfFile:
                MSHookMessageEx(nsdataClass,
                                @selector(initWithContentsOfFile:),
                                (IMP)hooked_NSData_initWithContentsOfFile,
                                (IMP *)&original_NSData_initWithContentsOfFile);
                NSLog(@"[DK] NSData 文件读写方法已安装（MSHookMessageEx）");
            }
        }

        // ============================================
        // 第三步：关闭启动保护
        // 子账号启动时不再把默认账号的 NSUserDefaults 写回原始域，
        // 避免状态污染。子账号的所有配置都写入隔离 plist。
        // ============================================
        _dkStartupGuard = NO;
        NSLog(@"[DK] 启动保护已关闭，账号隔离 Hook 已激活");

        // ============================================
        // 第 3.5 步：提前触发 WKWebView 数据清理（MonkeyCode 子账号）
        //
        // ⚠️ 关键修复：之前将清理放在第四步的 dispatch_async 中，
        // 并且内部又嵌套了一层 dispatch_async，导致清理被三重延迟。
        // 实际运行时，清理可能在用户已点击登录、OAuth 流程已设置
        // WKWebView cookie 之后才执行，把 OAuth cookie 清掉，
        // 导致「登录完成」后立即「登录失败」。
        //
        // 修复：在 %ctor 中直接调用 defaultDataStore，触发
        // WKWebsiteDataStore Hook 的 dispatch_once 清理逻辑。
        // 清理是异步的，但在 %ctor 中触发可以确保它在应用
        // UI 加载之前就开始执行，远早于用户点击登录。
        // ============================================
        if (DKIsMonkeyCode() && isNonDefaultAccount) {
            @try {
                // 触发 WKWebsiteDataStore Hook 的 dispatch_once 清理
                [WKWebsiteDataStore defaultDataStore];
                NSLog(@"[DK] MonkeyCode 子账号 WKWebView 清理已提前触发");
            } @catch (NSException *e) {
                NSLog(@"[DK] ⚠️ 提前触发 WKWebView 清理失败: %@", e);
            }
        }

        // ============================================
        // 第四步：初始化各模块（dispatch_async 到主线程，确保 UI 操作安全）
        // ============================================
        dispatch_async(dispatch_get_main_queue(), ^{
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                // === 通用模块（TRAE + 微信） ===
                [[DKDataIsolation sharedInstance] setup];
                [[DKUserDefaultsHook sharedInstance] install];
                [[DKKeychainHook sharedInstance] install];
                [[DKNetworkSessionManager sharedManager] setup];
                [[DKPushNotificationBridge sharedInstance] setup];
                [[DKLogManager sharedInstance] startCapture];
                [[DKAccountUI sharedInstance] setup];  // 悬浮按钮：微信中也会出现

                if (!isWeChat && DKIsTRAE()) {
                    // === TRAE 专属模块 ===
                    // 内容过滤绕过和会话刷新仅适用于 TRAE。
                    // MonkeyCode 的 API 响应结构与 TRAE 不同，
                    // 内容过滤会破坏登录等关键 API 的响应（将错误码替换为 0）。
                    // 会话刷新使用 TRAE 专属心跳 URL (api.trae.ai/heartbeat)，
                    // 对 MonkeyCode 无意义且可能触发不必要的网络请求。
                    [[DKContentFilterBypass sharedInstance] setup];
                    [[DKNetworkSessionManager sharedManager] scheduleSessionRefresh];

                    // 启动时不主动快照默认账号。
                    DKAccountManager *manager = [DKAccountManager sharedManager];
                    DKNetworkSessionManager *sessionManager = [DKNetworkSessionManager sharedManager];
                    if (![[manager currentAccountName] isEqualToString:[manager defaultAccountName]] &&
                        ![sessionManager hasSessionSnapshotForAccount:[manager defaultAccountName]]) {
                        NSLog(@"[DK] 当前为子账号 %@，默认账号暂无快照；切回默认并登录后会自动保存",
                              [manager currentAccountName]);
                    }
                }

                // === MonkeyCode: WKWebView cookie 清理已移至 %ctor 第 3.5 步 ===
                // 之前在此处通过双重 dispatch_async 清理 WKWebView 数据，
                // 但三重延迟导致清理可能在 OAuth 登录流程设置 cookie 之后
                // 才执行，把 OAuth cookie 清掉，导致登录失败。
                // 现在改为在 %ctor 中提前触发 WKWebsiteDataStore Hook
                // 的 dispatch_once 清理逻辑，确保清理在应用 UI 加载前开始。
                //
                // WKWebsiteDataStore.defaultDataStore Hook（Hook 14）仍然保留，
                // 作为安全网：如果 defaultDataStore 在 %ctor 之后才被首次调用，
                // Hook 会自动触发清理。

                NSLog(@"[DK] ✅ 所有模块初始化完成 (%@)", isWeChat ? @"微信" : (DKIsMonkeyCode() ? @"MonkeyCode" : @"TRAE"));

                // ============================================
                // 崩溃恢复：子账号无有效会话时自动显示悬浮按钮
                //
                // 场景：切到子账号 → 人脸认证闪退 → 重启后子账号
                // 无任何登录数据，用户被困在登录页无法切回默认账号。
                //
                // 检测：子账号的 NSUserDefaults 隔离 plist 为空
                // （新账号从未成功登录过），自动显示悬浮按钮。
                // ============================================
                if (isNonDefaultAccount) {
                    NSDictionary *accountDefaults = DKReadAccountUserDefaultsDictionary();
                    BOOL hasSessionData = accountDefaults && accountDefaults.count > 0;
                    if (!hasSessionData) {
                        NSLog(@"[DK] ⚠️ 子账号「%@」无有效会话数据（NSUserDefaults plist 为空），"
                              "自动显示悬浮按钮以便切回默认账号", currentAccount);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [[DKAccountUI sharedInstance] showFloatingButton];
                        });
                    }
                }
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

// write() 和 read() 是文件内容读写的核心系统调用。
// 虽然 open() 已 Hook，但 fd 可能通过 dup()/fcntl(F_DUPFD)
// 或其他方式获取，这些 fd 可能指向原始路径。
// 显式 Hook 确保读写操作与路径重定向一致。
// 注意：write()/read() 操作的是已打开的 fd，不需要路径映射，
// 仅透传即可。保留此 Hook 是为了未来可能的 fd 级重定向。
static ssize_t hooked_write(int fd, const void *buf, size_t count) {
    return original_write(fd, buf, count);
}

static ssize_t hooked_read(int fd, void *buf, size_t count) {
    return original_read(fd, buf, count);
}

// ============================================================
// mmap / msync / munmap / ftruncate — MMKV 内存映射 Hook
//
// MMKV（微信/TRAE 使用的 KV 存储库）核心流程：
//   open() → ftruncate() → mmap() → 直接写内存 → msync() 刷盘
//
// open() 已被 Hook 重定向到隔离目录，fd 已指向正确文件。
// ftruncate/mmap/msync/munmap 操作 fd 而非路径，因此直接透传即可。
// 保留这些 Hook 是为了：
//   1. 保护 fd 不被意外关闭/替换（未来可扩展）
//   2. 调试日志输出，方便排查 MMKV 数据隔离问题
//   3. 如果未来需要 fd 级重定向，无需改动调用方
// ============================================================

static void *hooked_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    // fd 已由 hooked_open 重定向到隔离目录，直接透传
    return original_mmap(addr, len, prot, flags, fd, offset);
}

static int hooked_msync(void *addr, size_t len, int flags) {
    // MMKV 用 msync 将内存映射脏页刷回磁盘
    // 由于 addr 来自 isolated 文件的 mmap，数据自动写入隔离目录
    return original_msync(addr, len, flags);
}

static int hooked_munmap(void *addr, size_t len) {
    return original_munmap(addr, len);
}

static int hooked_ftruncate(int fd, off_t length) {
    // MMKV 用 ftruncate 设置文件大小后再 mmap
    // fd 已由 hooked_open 重定向，直接透传
    return original_ftruncate(fd, length);
}

// ============================================================
// Keychain - 钥匙串隔离（C 函数 Hook）
// 通过给 service/account 添加前缀实现每个账号的独立 Keychain
// 使用 fishhook rebind_symbols 重定向符号指针（不修改 __TEXT 代码页）
// ============================================================

/// 判断 Keychain 查询是否应该跳过 Hook。
/// 只对 kSecClassGenericPassword / kSecClassInternetPassword 做前缀隔离，
/// Certificate、Key、Identity 等类型直接透传。
/// 原因：人脸认证 SDK 使用 kSecClassKey / kSecClassIdentity 存储
/// 生物识别凭证，前缀修改会破坏其内部二进制数据格式，导致
/// 主线程 SIGBUS (KERN_PROTECTION_FAILURE) 闪退。
static BOOL DKShouldSkipKeychainHook(CFDictionaryRef query) {
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    id secClass = nsQuery[(__bridge id)kSecClass];
    if (!secClass) return NO; // 未指定 class，不跳过

    if ([(__bridge id)kSecClassGenericPassword isEqual:secClass]) return NO;
    if ([(__bridge id)kSecClassInternetPassword isEqual:secClass]) return NO;

    // Certificate / Key / Identity → 跳过 Hook，直接透传
    return YES;
}

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
    if (DKShouldSkipKeychainHook(query)) return original_SecItemAdd(query, result);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *scopedQuery = DKKeychainQueryWithSyntheticScopeIfNeeded(nsQuery);
    NSDictionary *mappedQuery = DKRemapKeychainQuery(scopedQuery);
    return original_SecItemAdd((__bridge CFDictionaryRef)mappedQuery, result);
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (DKShouldUseOriginalCFPreferences()) return original_SecItemCopyMatching(query, result);
    if (DKShouldSkipKeychainHook(query)) return original_SecItemCopyMatching(query, result);
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
    if (DKShouldSkipKeychainHook(query)) return original_SecItemUpdate(query, attributesToUpdate);
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
    if (DKShouldSkipKeychainHook(query)) return original_SecItemDelete(query);
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
