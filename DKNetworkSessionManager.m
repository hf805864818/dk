#import "DKNetworkSessionManager.h"
#import "DKAccountManager.h"
#import "DKUserDefaultsHook.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <unistd.h>

// ============================================================
// Keychain 备份校验和工具
// ============================================================
static NSString* DKSHA256ForData(NSData *data) {
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}

// ============================================================
// DKNetworkSessionManager
// 管理每个账号的网络会话状态（Cookie、Token 等）
// 确保切换账号后无需重新登录
// ============================================================

static BOOL DKSessionRestoreInProgress = NO;
static NSDate *DKSessionBackupSuspendedUntil = nil;

static NSArray<NSString *>* DKAuthHeaderKeys(void) {
    return @[@"auth_token", @"access_token", @"refresh_token",
             @"session_id", @"Authorization", @"Bearer",
             @"x-auth-token", @"token",
             @"uid", @"user_id", @"userId", @"account_id", @"accountId",
             @"user", @"account", @"profile", @"jwt", @"credential"];
}

static BOOL DKIsSessionRelatedDefaultsKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return NO;
    }

    NSString *lowerKey = [key lowercaseString];
    NSArray<NSString *> *keywords = @[
        @"token", @"auth", @"session", @"login", @"jwt", @"bearer",
        @"credential", @"uid", @"userid", @"user_id",
        @"accountid", @"account_id", @"profile"
    ];

    for (NSString *keyword in keywords) {
        if ([lowerKey containsString:keyword]) {
            return YES;
        }
    }

    return NO;
}

@implementation DKNetworkSessionManager

+ (instancetype)sharedInstance {
    static DKNetworkSessionManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKNetworkSessionManager alloc] init];
    });
    return instance;
}

+ (instancetype)sharedManager {
    return [self sharedInstance];
}

- (void)setup {
    // 监听应用进入后台，保存会话
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_applicationDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    // 监听应用即将终止
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_applicationWillTerminate)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];

    NSLog(@"[DK] 网络会话管理器已初始化");
}

- (void)saveCurrentSession {
    // 恢复会话时会批量删除/写入 Cookie，NSHTTPCookieStorage Hook 会触发本方法。
    // 此时不能备份，否则会把切换前账号的 Cookie 覆盖到目标账号快照里。
    if (DKSessionRestoreInProgress) {
        return;
    }

    if (DKSessionBackupSuspendedUntil &&
        [[NSDate date] compare:DKSessionBackupSuspendedUntil] == NSOrderedAscending) {
        NSLog(@"[DK] 自动会话备份已暂停，跳过本次保存");
        return;
    }

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    // 默认账号也必须保存。
    // NSHTTPCookieStorage 是进程级共享存储，B 账号登录后可能覆盖当前 Cookie；
    // 如果默认账号不备份，切回默认账号时就容易掉到登录页。
    [self backupSessionForAccount:currentAccount];
}

- (void)suspendAutomaticSessionBackupForSeconds:(NSTimeInterval)seconds {
    NSTimeInterval duration = MAX(seconds, 0);
    DKSessionBackupSuspendedUntil = [NSDate dateWithTimeIntervalSinceNow:duration];
    NSLog(@"[DK] 自动会话备份暂停 %.1f 秒", duration);
}

- (BOOL)snapshotDefaultSessionIfActive {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
        NSLog(@"[DK] 当前不是默认账号，跳过默认账号快照");
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] synchronize];
    [self backupSessionForAccount:[manager defaultAccountName]];
    NSLog(@"[DK] 默认账号会话快照已保存");
    return YES;
}

- (BOOL)hasSessionSnapshotForAccount:(NSString *)accountName {
    NSString *sessionPath = [self sessionPathForAccount:accountName];
    return [[NSFileManager defaultManager] fileExistsAtPath:sessionPath];
}

- (void)restoreSessionForAccount:(NSString *)accountName {
    [self restoreSessionForAccount:accountName clearSessionIfMissing:NO];
}

- (void)restoreSessionForAccount:(NSString *)accountName clearSessionIfMissing:(BOOL)clearSessionIfMissing {
    NSString *sessionPath = [self sessionPathForAccount:accountName];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:sessionPath]) {
        NSLog(@"[DK] 账号 %@ 没有已保存的会话数据", accountName);
        // 新增的非默认账号没有会话时，清空当前 Cookie，避免沿用上一个账号。
        // 如果升级插件时当前在 B/C/D，默认账号可能没有快照；
        // 用户主动切回默认账号时也要清空子账号 Cookie，进入干净的默认账号环境。
        DKAccountManager *manager = [DKAccountManager sharedManager];
        if (clearSessionIfMissing ||
            ![accountName isEqualToString:[manager defaultAccountName]]) {
            DKSessionRestoreInProgress = YES;
            @try {
                [self _clearCurrentSessionStateForAccount:accountName];
            } @finally {
                DKSessionRestoreInProgress = NO;
            }
        }
        return;
    }

    // 读取会话数据
    NSDictionary *sessionData = [NSDictionary dictionaryWithContentsOfFile:sessionPath];
    if (!sessionData) return;

    DKSessionRestoreInProgress = YES;

    @try {
        // 恢复前先清理旧登录态，避免不同账号互相污染。
        // 默认账号不清除原始 UserDefaults 认证键：
        // 默认账号快照可能未捕获 TRAE 实际使用的认证键名，
        // 预先清除会导致原始登录态被误删且无法恢复。
        [self _clearCurrentSessionStateForAccount:accountName];

        // 恢复 Cookie
        NSArray *cookiesData = sessionData[@"cookies"];
        if (cookiesData) {
            [self _restoreCookiesFromData:cookiesData];
        }

        // 恢复 HTTP 头部 Token
        NSDictionary *headers = sessionData[@"authHeaders"];
        if (headers) {
            DKAccountManager *manager = [DKAccountManager sharedManager];
            BOOL isDefault = [accountName isEqualToString:[manager defaultAccountName]];
            // 默认账号：如果有完整域快照（__DK_FULL_DOMAIN__），则恢复。
            // 完整域快照是可靠的：它记录了切换前默认账号的完整 UserDefaults 状态。
            // 如果没有完整域快照，跳过恢复，避免旧白名单快照覆盖默认账号登录态。
            if (!isDefault || headers[@"__DK_FULL_DOMAIN__"]) {
                [self _restoreAuthHeaders:headers];
            } else {
                NSLog(@"[DK] 默认账号无完整域快照，跳过 authHeaders 恢复，仅恢复 Cookie");
            }
        }

        // 恢复 NSURLSession 配置
        NSData *sessionConfigData = sessionData[@"sessionConfig"];
        if (sessionConfigData) {
            [self _restoreSessionConfig:sessionConfigData];
        }
    } @finally {
        DKSessionRestoreInProgress = NO;
    }

    NSLog(@"[DK] 账号 %@ 的网络会话已恢复", accountName);
}

- (void)backupSessionForAccount:(NSString *)accountName {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSMutableDictionary *sessionData = [NSMutableDictionary dictionary];

    // 备份 Cookie
    NSArray *cookies = [self _captureCookies];
    if (cookies) {
        sessionData[@"cookies"] = cookies;
    }

    // 备份 HTTP 头部
    NSDictionary *headers = [self _captureAuthHeaders];
    if (headers) {
        sessionData[@"authHeaders"] = headers;
    }

    // 备份 NSURLSession 配置
    NSData *configData = [self _captureSessionConfig];
    if (configData) {
        sessionData[@"sessionConfig"] = configData;
    }

    BOOL isDefaultAccount = [accountName isEqualToString:[manager defaultAccountName]];
    BOOL hasCookies = cookies.count > 0;
    BOOL hasFullDomain = [headers[@"__DK_FULL_DOMAIN__"] isKindOfClass:[NSDictionary class]] &&
                         [headers[@"__DK_FULL_DOMAIN__"] count] > 0;
    NSString *sessionPath = [self sessionPathForAccount:accountName];

    // 默认账号：只有当捕获到完整域快照时才允许覆盖旧快照。
    // 防止 NSUserDefaults 被意外清空时用空数据覆盖有效备份。
    if (isDefaultAccount && !hasCookies && !hasFullDomain &&
        [[NSFileManager defaultManager] fileExistsAtPath:sessionPath]) {
        NSLog(@"[DK] 默认账号当前未检测到有效完整域快照，保留已有默认账号快照");
        return;
    }

    // 保存时间戳
    sessionData[@"backupTime"] = [NSDate date];
    sessionData[@"accountName"] = accountName;

    // 写入文件
    // 确保目录存在
    NSString *sessionDir = [sessionPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:sessionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    [sessionData writeToFile:sessionPath atomically:YES];
    // 强制刷盘，避免 exit(0) 前数据丢失
    sync();
    NSLog(@"[DK] 账号 %@ 的网络会话已备份", accountName);
}

- (NSString *)sessionPathForAccount:(NSString *)accountName {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if ([accountName isEqualToString:[manager defaultAccountName]]) {
        // 默认账号的会话快照放在 DK 自己的数据根目录，避免污染应用原始 Cookie 目录。
        return [manager.accountsRootPath stringByAppendingPathComponent:@".dk_default_session.plist"];
    }

    NSString *accountPath = [manager dataPathForAccount:accountName];
    return [accountPath stringByAppendingPathComponent:@"Library/Cookies/.dk_session.plist"];
}

- (void)scheduleSessionRefresh {
    // 每 30 分钟刷新一次所有账号的会话
    [NSTimer scheduledTimerWithTimeInterval:1800
                                    repeats:YES
                                      block:^(NSTimer *timer) {
        [self _refreshAllSessions];
    }];

    NSLog(@"[DK] 会话定期刷新已启动（每30分钟）");
}

#pragma mark - Private

- (void)_applicationDidEnterBackground {
    [self saveCurrentSession];
    // 后台刷新所有会话
    [self _refreshAllSessions];
}

- (void)_applicationWillTerminate {
    [self saveCurrentSession];
}

- (void)_refreshAllSessions {
    NSArray *accounts = [[DKAccountManager sharedManager] allAccountNames];
    for (NSString *accountName in accounts) {
        // 尝试刷新会话（发送心跳请求）
        [self _sendHeartbeatForAccount:accountName];
    }
}

- (void)_sendHeartbeatForAccount:(NSString *)accountName {
    // 发送轻量心跳请求保持 Token 活跃
    // 具体实现取决于目标应用的后端 API
    // 这里提供框架，实际 API 端点需要根据 TRAE 后端调整
    //
    // 心跳 URL (api.trae.ai/heartbeat) 是 TRAE 专属端点。
    // 非 TRAE 应用（如 MonkeyCode）跳过心跳，避免向无关 API 发送请求。
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.stone.solo.cn"]) {
        return;
    }

    NSString *sessionPath = [self sessionPathForAccount:accountName];
    NSDictionary *sessionData = [NSDictionary dictionaryWithContentsOfFile:sessionPath];
    if (!sessionData) return;

    NSDictionary *headers = sessionData[@"authHeaders"];
    if (!headers) return;

    // 发送心跳请求
    NSURL *url = [NSURL URLWithString:@"https://api.trae.ai/heartbeat"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 10;

    for (NSString *key in headers) {
        [request setValue:headers[key] forHTTPHeaderField:key];
    }

    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[DK] 账号 %@ 心跳失败: %@", accountName, error.localizedDescription);
        } else {
            NSLog(@"[DK] 账号 %@ 心跳成功", accountName);
        }
    }] resume];
}

#pragma mark - Cookie 管理

- (void)_clearAllCookies {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [[storage cookies] copy];
    for (NSHTTPCookie *cookie in cookies) {
        [storage deleteCookie:cookie];
    }
}

- (NSArray *)_captureCookies {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [storage cookies];

    NSMutableArray *cookieDataList = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        NSDictionary *props = [cookie properties];
        if (props) {
            [cookieDataList addObject:props];
        }
    }

    return cookieDataList;
}

- (void)_restoreCookiesFromData:(NSArray *)cookieDataList {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];

    for (NSDictionary *props in cookieDataList) {
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie) {
            [storage setCookie:cookie];
        }
    }
}

#pragma mark - Auth Header 管理

- (NSDictionary *)_captureAuthHeaders {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        // 默认账号：保存完整 NSUserDefaults 域快照。
        // TTAccountSDK 使用 com.toutiao.account.userdefault.* 等键名，
        // 固定白名单无法覆盖，必须全量备份。
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSDictionary *fullDomain = [defaults persistentDomainForName:bundleID];
        if (fullDomain) {
            headers[@"__DK_FULL_DOMAIN__"] = fullDomain;
            NSLog(@"[DK] 默认账号完整 UserDefaults 域已捕获 %lu 键", (unsigned long)fullDomain.count);
        }
    } else {
        // 子账号：直接从隔离 plist 读取全部数据。
        // [NSUserDefaults dictionaryRepresentation] 没有被 Hook，
        // 子账号时它返回的是沙盒（空）的字典，而非隔离 plist 的数据。
        // 必须用 DKReadAccountUserDefaultsDictionary 直接读取隔离 plist 文件。
        NSDictionary *isolationDict = DKReadAccountUserDefaultsDictionary();
        if (isolationDict && isolationDict.count > 0) {
            headers[@"__DK_ISOLATION_PLIST__"] = isolationDict;
            NSLog(@"[DK] 子账号隔离 plist 已捕获 %lu 键", (unsigned long)isolationDict.count);
        }
    }

    for (NSString *key in DKAuthHeaderKeys()) {
        id value = [defaults objectForKey:key];
        if (value) {
            headers[key] = value;
        }
    }

    // 子账号的 dictionaryRepresentation 返回的是沙盒（空），
    // 所以 session-related keys 扫描对子账号无效。跳过这步，
    // 子账号的完整数据已通过 __DK_ISOLATION_PLIST__ 捕获。
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        NSDictionary *allDefaults = [defaults dictionaryRepresentation];
        for (NSString *key in allDefaults) {
            if (DKIsSessionRelatedDefaultsKey(key)) {
                id value = allDefaults[key];
                if (value) {
                    headers[key] = value;
                }
            }
        }
    }

    return headers;
}

- (void)_restoreAuthHeaders:(NSDictionary *)headers {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // 检查是否有完整域快照（默认账号专用）
    NSDictionary *fullDomain = headers[@"__DK_FULL_DOMAIN__"];
    if (fullDomain) {
        DKAccountManager *manager = [DKAccountManager sharedManager];
        NSString *currentAccount = [manager currentAccountName];
        if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
            // 默认账号：恢复完整 NSUserDefaults 域。
            // 先清除当前域，再全量写入快照。
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            [defaults removePersistentDomainForName:bundleID];
            [defaults setPersistentDomain:fullDomain forName:bundleID];
            [defaults synchronize];
            NSLog(@"[DK] 默认账号完整 UserDefaults 域已恢复 %lu 键", (unsigned long)fullDomain.count);
            return;
        }
    }

    // 检查是否有隔离 plist 快照（子账号专用）
    NSDictionary *isolationDict = headers[@"__DK_ISOLATION_PLIST__"];
    if (isolationDict) {
        DKAccountManager *manager = [DKAccountManager sharedManager];
        NSString *currentAccount = [manager currentAccountName];
        if (![currentAccount isEqualToString:[manager defaultAccountName]]) {
            // 子账号：直接写入隔离 plist 文件，恢复全部 NSUserDefaults 数据
            DKWriteAccountUserDefaultsDictionary(isolationDict);
            NSLog(@"[DK] 子账号隔离 plist 已恢复 %lu 键", (unsigned long)isolationDict.count);
            return;
        }
    }

    [self _clearAuthHeaders];
    for (NSString *key in headers) {
        if ([key isEqualToString:@"__DK_FULL_DOMAIN__"]) continue;
        if ([key isEqualToString:@"__DK_ISOLATION_PLIST__"]) continue;
        [defaults setObject:headers[key] forKey:key];
    }
    [defaults synchronize];
}

- (void)_clearAuthHeaders {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in DKAuthHeaderKeys()) {
        [defaults removeObjectForKey:key];
    }

    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    for (NSString *key in allDefaults) {
        if (DKIsSessionRelatedDefaultsKey(key)) {
            [defaults removeObjectForKey:key];
        }
    }

    [defaults synchronize];
}

- (void)_clearCurrentSessionStateForAccount:(NSString *)accountName {
    [self _clearAllCookies];

    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (![accountName isEqualToString:[manager defaultAccountName]]) {
        // 非默认账号：清除认证键，避免子账号残留污染。
        [self _clearAuthHeaders];
    }
    // 默认账号：只清 Cookie，保留原始 UserDefaults 认证数据。
    // 默认账号快照可能未完整捕获应用实际使用的认证键，
    // 若预先清除会导致原始登录态丢失且无法恢复。
}

#pragma mark - URLSession 配置管理

- (NSData *)_captureSessionConfig {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableDictionary *configDict = [NSMutableDictionary dictionary];

    if (config.HTTPAdditionalHeaders) {
        configDict[@"HTTPAdditionalHeaders"] = config.HTTPAdditionalHeaders;
    }
    if (config.HTTPCookieStorage) {
        configDict[@"hasCookieStorage"] = @YES;
    }
    configDict[@"timeoutIntervalForRequest"] = @(config.timeoutIntervalForRequest);
    configDict[@"timeoutIntervalForResource"] = @(config.timeoutIntervalForResource);

    return [NSKeyedArchiver archivedDataWithRootObject:configDict requiringSecureCoding:NO error:nil];
}

- (void)_restoreSessionConfig:(NSData *)configData {
    NSDictionary *configDict = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class]
                                                                  fromData:configData
                                                                     error:nil];
    if (!configDict) return;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];

    NSDictionary *headers = configDict[@"HTTPAdditionalHeaders"];
    if (headers) {
        config.HTTPAdditionalHeaders = headers;
    }
    if ([configDict[@"timeoutIntervalForRequest"] doubleValue] > 0) {
        config.timeoutIntervalForRequest = [configDict[@"timeoutIntervalForRequest"] doubleValue];
    }
    if ([configDict[@"timeoutIntervalForResource"] doubleValue] > 0) {
        config.timeoutIntervalForResource = [configDict[@"timeoutIntervalForResource"] doubleValue];
    }
}

// ============================================================
// 默认账号 Keychain 备份/恢复
// 切换前保存默认账号所有 Keychain 项（无 DK_ 前缀），
// 切回默认账号时恢复。防止 TTAccountSDK 在子账号登录
// 时误删或覆盖默认账号的 Keychain 数据。
// ============================================================

- (void)backupDefaultAccountKeychain {
    NSLog(@"[DK] 备份默认账号 Keychain 数据...");

    // 覆盖所有 Keychain 类，不只是 GenericPassword。
    // TTAccountSDK 可能使用 InternetPassword 或 Key 类存储凭证。
    NSArray *keychainClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
    ];

    NSMutableArray *allItems = [NSMutableArray array];

    for (id secClass in keychainClasses) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecReturnData: @YES,
        };

        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

        if (status == errSecSuccess && result) {
            NSArray *items = (__bridge_transfer NSArray *)result;
            for (NSDictionary *item in items) {
                NSString *service = item[(__bridge id)kSecAttrService];
                NSString *account = item[(__bridge id)kSecAttrAccount];
                // 跳过已有 DK_ 前缀的子账号 Keychain 项
                if ([service hasPrefix:@"DK_"] || [account hasPrefix:@"DK_"]) {
                    continue;
                }
                // 标记 Keychain 类别，恢复时需要
                NSMutableDictionary *taggedItem = [item mutableCopy];
                taggedItem[@"__DK_KeychainClass__"] = secClass;
                [allItems addObject:taggedItem];
            }
        }
    }

    if (allItems.count == 0) {
        NSLog(@"[DK] 默认账号无有效 Keychain 项");
        return;
    }

    // 保存到默认账号快照目录
    NSString *snapshotPath = [self sessionPathForAccount:@"__default_keychain__"];
    NSString *dir = [snapshotPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSData *archivedData = [NSKeyedArchiver archivedDataWithRootObject:allItems
                                                 requiringSecureCoding:NO
                                                                 error:nil];
    if (!archivedData) {
        NSLog(@"[DK] ❌ 默认账号 Keychain 归档失败，备份中止");
        return;
    }

    // 计算校验和，写入相邻文件
    NSString *checksum = DKSHA256ForData(archivedData);
    NSString *checksumPath = [snapshotPath stringByAppendingString:@".sha256"];
    [checksum writeToFile:checksumPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [archivedData writeToFile:snapshotPath atomically:YES];

    // 验证写入
    NSData *verifyData = [NSData dataWithContentsOfFile:snapshotPath];
    NSString *verifyChecksum = DKSHA256ForData(verifyData);
    if ([verifyChecksum isEqualToString:checksum]) {
        NSLog(@"[DK] ✅ 默认账号 Keychain 已备份 %lu 项（校验和: %@）", (unsigned long)allItems.count, checksum);
    } else {
        NSLog(@"[DK] ❌ 默认账号 Keychain 备份校验失败！写入数据与预期不一致");
    }
}

- (void)clearDefaultAccountKeychainForSubAccountStartup {
    NSLog(@"[DK] 清空默认账号 Keychain，避免子账号启动时读取默认登录态...");

    NSArray *keychainClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
    ];

    NSInteger deleted = 0;

    for (id secClass in keychainClasses) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
        };

        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess || !result) {
            if (result) CFRelease(result);
            continue;
        }

        NSArray *items = nil;
        if (CFGetTypeID(result) == CFArrayGetTypeID()) {
            items = (__bridge NSArray *)result;
        } else if (CFGetTypeID(result) == CFDictionaryGetTypeID()) {
            items = @[(__bridge NSDictionary *)result];
        }

        for (NSDictionary *item in items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;

            NSString *service = item[(__bridge id)kSecAttrService];
            NSString *account = item[(__bridge id)kSecAttrAccount];
            NSString *label = item[(__bridge id)kSecAttrLabel];
            id generic = item[(__bridge id)kSecAttrGeneric];

            // 只清理原始默认账号项，保留所有 DK_ 子账号项。
            BOOL isSubAccountItem = NO;
            NSArray *stringFields = @[service ?: @"", account ?: @"", label ?: @""];
            for (NSString *field in stringFields) {
                if ([field isKindOfClass:[NSString class]] && [field hasPrefix:@"DK_"]) {
                    isSubAccountItem = YES;
                    break;
                }
            }
            if (!isSubAccountItem && [generic isKindOfClass:[NSData class]]) {
                NSString *genericString = [[NSString alloc] initWithData:generic encoding:NSUTF8StringEncoding];
                if ([genericString hasPrefix:@"DK_"]) {
                    isSubAccountItem = YES;
                }
            } else if (!isSubAccountItem && [generic isKindOfClass:[NSString class]]) {
                if ([(NSString *)generic hasPrefix:@"DK_"]) {
                    isSubAccountItem = YES;
                }
            }
            if (isSubAccountItem) continue;

            NSMutableDictionary *deleteQuery = [NSMutableDictionary dictionary];
            deleteQuery[(__bridge id)kSecClass] = secClass;
            if (service) deleteQuery[(__bridge id)kSecAttrService] = service;
            if (account) deleteQuery[(__bridge id)kSecAttrAccount] = account;
            if (label) deleteQuery[(__bridge id)kSecAttrLabel] = label;
            if (generic) deleteQuery[(__bridge id)kSecAttrGeneric] = generic;
            if (item[(__bridge id)kSecAttrAccessGroup]) {
                deleteQuery[(__bridge id)kSecAttrAccessGroup] = item[(__bridge id)kSecAttrAccessGroup];
            }

            if (deleteQuery.count > 1) {
                OSStatus deleteStatus = SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
                if (deleteStatus == errSecSuccess) {
                    deleted++;
                }
            }
        }

        CFRelease(result);
    }

    NSLog(@"[DK] 默认账号 Keychain 已临时清理 %ld 项", (long)deleted);
}

- (void)restoreDefaultAccountKeychain {
    NSLog(@"[DK] 恢复默认账号 Keychain 数据...");

    NSString *snapshotPath = [self sessionPathForAccount:@"__default_keychain__"];
    NSData *archivedData = [NSData dataWithContentsOfFile:snapshotPath];

    if (!archivedData) {
        NSLog(@"[DK] ⚠️ 默认账号 Keychain 备份不存在，跳过恢复");
        return;
    }

    // 校验备份文件完整性
    NSString *checksumPath = [snapshotPath stringByAppendingString:@".sha256"];
    NSString *savedChecksum = [NSString stringWithContentsOfFile:checksumPath
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
    NSString *actualChecksum = DKSHA256ForData(archivedData);

    if (savedChecksum && ![savedChecksum isEqualToString:actualChecksum]) {
        NSLog(@"[DK] ❌ 默认账号 Keychain 备份校验失败！备份文件可能已损坏");
        NSLog(@"[DK] 预期校验和: %@", savedChecksum);
        NSLog(@"[DK] 实际校验和: %@", actualChecksum);
        NSLog(@"[DK] 跳过恢复，保护默认账号原始 Keychain 数据");
        return;
    }

    if (savedChecksum) {
        NSLog(@"[DK] ✅ 备份文件校验通过（%lu 字节）", (unsigned long)archivedData.length);
    } else {
        NSLog(@"[DK] ⚠️ 未找到校验和文件，跳过完整性验证（旧版本备份）");
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:
                             [NSArray class],
                             [NSDictionary class],
                             [NSMutableDictionary class],
                             [NSString class],
                             [NSData class],
                             [NSNumber class],
                             nil];
    NSArray *items = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
                                                         fromData:archivedData
                                                            error:&error];
    if (!items || error) {
        NSLog(@"[DK] 默认账号 Keychain 备份解档失败: %@", error);
        return;
    }

    NSInteger restored = 0;
    for (NSDictionary *item in items) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSString *account = item[(__bridge id)kSecAttrAccount];
        NSData *data = item[(__bridge id)kSecValueData];
        // 使用备份时标记的 Keychain 类别
        id secClass = item[@"__DK_KeychainClass__"];
        if (!secClass) {
            secClass = (__bridge id)kSecClassGenericPassword;
        }

        if (!service && !account) continue;

        // 先删除旧项
        NSMutableDictionary *delQuery = [NSMutableDictionary dictionary];
        delQuery[(__bridge id)kSecClass] = secClass;
        if (service) delQuery[(__bridge id)kSecAttrService] = service;
        if (account) delQuery[(__bridge id)kSecAttrAccount] = account;
        SecItemDelete((__bridge CFDictionaryRef)delQuery);

        // 写入新项
        NSMutableDictionary *addQuery = [NSMutableDictionary dictionary];
        addQuery[(__bridge id)kSecClass] = secClass;
        if (service) addQuery[(__bridge id)kSecAttrService] = service;
        if (account) addQuery[(__bridge id)kSecAttrAccount] = account;
        if (data) {
            addQuery[(__bridge id)kSecValueData] = data;
        }
        if (item[(__bridge id)kSecAttrLabel]) {
            addQuery[(__bridge id)kSecAttrLabel] = item[(__bridge id)kSecAttrLabel];
        }
        if (item[(__bridge id)kSecAttrGeneric]) {
            addQuery[(__bridge id)kSecAttrGeneric] = item[(__bridge id)kSecAttrGeneric];
        }
        if (item[(__bridge id)kSecAttrServer]) {
            addQuery[(__bridge id)kSecAttrServer] = item[(__bridge id)kSecAttrServer];
        }
        if (item[(__bridge id)kSecAttrProtocol]) {
            addQuery[(__bridge id)kSecAttrProtocol] = item[(__bridge id)kSecAttrProtocol];
        }
        if (item[(__bridge id)kSecAttrAccessGroup]) {
            addQuery[(__bridge id)kSecAttrAccessGroup] = item[(__bridge id)kSecAttrAccessGroup];
        }
        if (item[(__bridge id)kSecAttrAccessible]) {
            addQuery[(__bridge id)kSecAttrAccessible] = item[(__bridge id)kSecAttrAccessible];
        }

        OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
        if (addStatus == errSecSuccess) {
            restored++;
        } else {
            NSLog(@"[DK] Keychain 恢复失败 service=%@ class=%@ status=%d", service, secClass, (int)addStatus);
        }
    }
    NSLog(@"[DK] 默认账号 Keychain 已恢复 %ld 项", (long)restored);
}

@end
