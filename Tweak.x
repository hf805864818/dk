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
#import "fishhook/fishhook.h"

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
extern NSDictionary* DKRemapKeychainAttributes(NSDictionary *attributes);
extern NSDictionary* DKUnmapKeychainResult(NSDictionary *result);
extern BOOL DKKeychainResultMatchesCurrentAccount(NSDictionary *result);

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
// POSIX 文件 I/O Hook 前向声明（fishhook）
// TRAE 使用 WCDB/MMKV 等 C++ 存储引擎，底层直接调用
// open()/fopen()/stat()/access()/openat()，ObjC 层 %hook 无法拦截。
// 必须用 fishhook 重定向这些 C 函数，否则子账号会读取默认账号的数据库文件。
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
    return [[DKDataIsolation sharedInstance] userDefaultsFileForSuiteName:nil];
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

    NSString *currentAccount = [manager currentAccountName];
    return [currentAccount isEqualToString:[manager defaultAccountName]];
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
        BOOL isNonDefaultAccount = ![currentAccount isEqualToString:defaultAccount];

        NSLog(@"[DK] BundleID=%@, 当前账号=%@, 非默认=%@, accountsRoot=%@",
              bundleID, currentAccount, isNonDefaultAccount ? @"YES" : @"NO",
              [[DKAccountManager sharedManager] accountsRootPath]);

        if (isNonDefaultAccount) {
            // 子账号启动：清空原始 NSUserDefaults 域，确保 App 看不到默认账号的登录态。
            // 注意：这里只清空，不再把 savedDefaultDomain 写回原始域。
            // 之前写回默认账号数据会导致子账号与默认账号状态混杂，
            // 切回默认时 TRAE 可能检测到不一致而清除登录态。
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSDictionary *savedDefaultDomain = [defaults persistentDomainForName:bundleID];

            if (savedDefaultDomain) {
                // 清空原始域 — 内存 + 磁盘 plist 全部清除
                [defaults removePersistentDomainForName:bundleID];
                [defaults synchronize];
                NSLog(@"[DK] 子账号启动：已清空原始 NSUserDefaults（%lu 个键），App 将显示登录页",
                      (unsigned long)savedDefaultDomain.count);
            } else {
                NSLog(@"[DK] 子账号启动：原始 NSUserDefaults 域为空，无需清空");
            }
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
            // POSIX 文件 I/O（5 个）— WCDB/MMKV 底层依赖
            {"fopen",   hooked_fopen,   (void **)&original_fopen},
            {"open",    hooked_open,    (void **)&original_open},
            {"stat",    hooked_stat,    (void **)&original_stat},
            {"access",  hooked_access,  (void **)&original_access},
            {"openat",  hooked_openat,  (void **)&original_openat},
        };
        rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding));
        NSLog(@"[DK] fishhook C 函数 Hook 已安装（18 个：Keychain 4 + CFPreferences 9 + POSIX 5）");

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
                [[DKFileManagerHook sharedInstance] install];
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
// POSIX 文件 I/O Hook 实现（fishhook）
// WCDB/MMKV 等 C++ 存储引擎直接调用这些 C 函数，
// ObjC 层的 NSFileManager/NSData 等 %hook 无法拦截。
// 所有实现都加了 _dkStartupGuard 保护，启动恢复期间透传。
// ============================================================

FILE* hooked_fopen(const char *path, const char *mode) {
    if (_dkStartupGuard) return original_fopen(path, mode);
    if (_dk_fopen_hook_guard) return original_fopen(path, mode);
    _dk_fopen_hook_guard = YES;

    FILE *result = NULL;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        result = original_fopen(remapped ? [remapped UTF8String] : path, mode);
    } else {
        result = original_fopen(path, mode);
    }
    _dk_fopen_hook_guard = NO;
    return result;
}

int hooked_open(const char *path, int flags, mode_t mode) {
    if (_dkStartupGuard) return original_open(path, flags, mode);
    if (_dk_open_hook_guard) return original_open(path, flags, mode);
    _dk_open_hook_guard = YES;

    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        result = original_open(remapped ? [remapped UTF8String] : path, flags, mode);
    } else {
        result = original_open(path, flags, mode);
    }
    _dk_open_hook_guard = NO;
    return result;
}

int hooked_stat(const char *path, struct stat *buf) {
    if (_dkStartupGuard) return original_stat(path, buf);
    if (_dk_stat_hook_guard) return original_stat(path, buf);
    _dk_stat_hook_guard = YES;

    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        result = original_stat(remapped ? [remapped UTF8String] : path, buf);
    } else {
        result = original_stat(path, buf);
    }
    _dk_stat_hook_guard = NO;
    return result;
}

int hooked_access(const char *path, int mode) {
    if (_dkStartupGuard) return original_access(path, mode);
    if (_dk_access_hook_guard) return original_access(path, mode);
    _dk_access_hook_guard = YES;

    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        result = original_access(remapped ? [remapped UTF8String] : path, mode);
    } else {
        result = original_access(path, mode);
    }
    _dk_access_hook_guard = NO;
    return result;
}

int hooked_openat(int fd, const char *path, int flags, mode_t mode) {
    if (_dkStartupGuard) return original_openat(fd, path, flags, mode);
    if (_dk_openat_hook_guard) return original_openat(fd, path, flags, mode);
    _dk_openat_hook_guard = YES;

    int result = -1;
    if (path) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSString *remapped = DKRemapFilePath(nsPath);
        result = original_openat(fd, remapped ? [remapped UTF8String] : path, flags, mode);
    } else {
        result = original_openat(fd, path, flags, mode);
    }
    _dk_openat_hook_guard = NO;
    return result;
}

// ============================================================
// Keychain - 钥匙串隔离（C 函数 Hook）
// 通过给 service/account 添加前缀实现每个账号的独立 Keychain
// 使用 fishhook rebind_symbols 重定向符号指针（不修改 __TEXT 代码页）
// ============================================================

static OSStatus hooked_SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    if (_dkStartupGuard) return original_SecItemAdd(query, result);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    return original_SecItemAdd((__bridge CFDictionaryRef)mappedQuery, result);
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (_dkStartupGuard) return original_SecItemCopyMatching(query, result);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
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
    if (_dkStartupGuard) return original_SecItemUpdate(query, attributesToUpdate);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    NSDictionary *mappedQuery = DKRemapKeychainQuery(nsQuery);
    NSDictionary *nsAttributes = (__bridge NSDictionary *)attributesToUpdate;
    NSDictionary *mappedAttributes = DKRemapKeychainAttributes(nsAttributes);
    return original_SecItemUpdate((__bridge CFDictionaryRef)mappedQuery,
                                  (__bridge CFDictionaryRef)mappedAttributes);
}

static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    if (_dkStartupGuard) return original_SecItemDelete(query);
    NSDictionary *nsQuery = (__bridge NSDictionary *)query;
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        // 非默认账号：检查删除操作是否有可能误删其他账号的 Keychain 项。
        // 如果查询没有指定 service/account/label，TTAccountSDK
        // 可能在进行"清空所有 Keychain 数据"操作，必须拦截。
        id service = nsQuery[(__bridge id)kSecAttrService];
        id account = nsQuery[(__bridge id)kSecAttrAccount];
        id label  = nsQuery[(__bridge id)kSecAttrLabel];

        if (!service && !account && !label) {
            // 宽泛删除：只允许删除带有当前账号前缀的项。
            // 给查询加上前缀条件，避免误删默认账号或其他子账号的数据。
            NSMutableDictionary *safeQuery = [nsQuery mutableCopy];
            NSString *prefix = [[DKDataIsolation sharedInstance] keychainServicePrefix];
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
                    // 只删除带有当前账号前缀的项
                    if ([itemService hasPrefix:prefix] || [itemAccount hasPrefix:prefix]) {
                        NSMutableDictionary *delQuery = [NSMutableDictionary dictionary];
                        delQuery[(__bridge id)kSecClass] = nsQuery[(__bridge id)kSecClass];
                        if (itemService) delQuery[(__bridge id)kSecAttrService] = itemService;
                        if (itemAccount) delQuery[(__bridge id)kSecAttrAccount] = itemAccount;
                        original_SecItemDelete((__bridge CFDictionaryRef)delQuery);
                    }
                }
            }
            // 返回成功，原始调用者以为删除了所有项
            return errSecSuccess;
        }
    }

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
// CFPreferences C 函数 Hook 实现
// TTAccountSDK 是 C/C++ 重 SDK，可能通过 CFPreferences
// 直接读写 UserDefaults plist 文件，绕过 NSUserDefaults Hook。
// 这里对非默认账号做独立 plist 隔离，默认账号走原始逻辑。
// ============================================================

static void hooked_CFPreferencesSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID) {
    if (_dkStartupGuard) {
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
    if (_dkStartupGuard) return original_CFPreferencesCopyAppValue(key, applicationID);
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
    if (_dkStartupGuard) return original_CFPreferencesAppSynchronize(applicationID);
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
    if (_dkStartupGuard) {
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
    if (_dkStartupGuard) return original_CFPreferencesCopyValue(key, applicationID, userName, hostName);
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
    if (_dkStartupGuard) return original_CFPreferencesSynchronize(applicationID, userName, hostName);
    NSMutableDictionary *dict = DKCFPreferencesLoad();
    if (dict) {
        // 非默认账号：plist 已在写入时同步，直接返回 true
        return true;
    }
    return original_CFPreferencesSynchronize(applicationID, userName, hostName);
}

static CFArrayRef hooked_CFPreferencesCopyKeyList(CFStringRef applicationID,
                                                   CFStringRef userName, CFStringRef hostName) {
    if (_dkStartupGuard) return original_CFPreferencesCopyKeyList(applicationID, userName, hostName);
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
    if (_dkStartupGuard) {
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
    if (_dkStartupGuard) return original_CFPreferencesCopyMultiple(keysToFetch, applicationID, userName, hostName);
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
