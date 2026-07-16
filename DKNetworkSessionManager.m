#import "DKNetworkSessionManager.h"
#import "DKAccountManager.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

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
            if (![accountName isEqualToString:[manager defaultAccountName]]) {
                [self _restoreAuthHeaders:headers];
            } else {
                // 默认账号的 UserDefaults/Keychain 原始登录态由应用自己维护。
                // 这里不恢复 authHeaders，避免旧快照或不完整快照覆盖默认账号真实登录态。
                NSLog(@"[DK] 默认账号跳过 authHeaders 恢复，仅恢复 Cookie");
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
    BOOL hasHeaders = headers.count > 0;
    NSString *sessionPath = [self sessionPathForAccount:accountName];

    if (isDefaultAccount && !hasCookies && !hasHeaders &&
        [[NSFileManager defaultManager] fileExistsAtPath:sessionPath]) {
        NSLog(@"[DK] 默认账号当前未检测到有效会话，保留已有默认账号快照");
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
    // 从 NSUserDefaults 或 Keychain 中读取认证信息
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    
    for (NSString *key in DKAuthHeaderKeys()) {
        id value = [defaults objectForKey:key];
        if (value) {
            headers[key] = value;
        }
    }

    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    for (NSString *key in allDefaults) {
        if (DKIsSessionRelatedDefaultsKey(key)) {
            id value = allDefaults[key];
            if (value) {
                headers[key] = value;
            }
        }
    }
    
    return headers;
}

- (void)_restoreAuthHeaders:(NSDictionary *)headers {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [self _clearAuthHeaders];
    for (NSString *key in headers) {
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

@end
