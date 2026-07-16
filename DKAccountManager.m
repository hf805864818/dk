#import "DKAccountManager.h"
#import "DKDataIsolation.h"
#import "DKNetworkSessionManager.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>

// ============================================================
// 账号元数据存储键
// ============================================================
static NSString *const kDKAccountsKey = @"DK_Accounts_List";
static NSString *const kDKCurrentAccountKey = @"DK_Current_Account";
static NSString *const kDKDefaultAccountName = @"__DK_DEFAULT__";

// ============================================================
// 内部存储 — 使用 App Group 级别共享存储
// ============================================================
static NSString *_accountsRootPath = nil;

@implementation DKAccountManager {
    NSMutableArray<NSString *> *_accountNames;
    NSString *_currentAccountName;
    NSMutableDictionary<NSString *, NSDictionary *> *_metadataCache;
}

+ (instancetype)sharedManager {
    static DKAccountManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKAccountManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _accountNames = [NSMutableArray array];
        _metadataCache = [NSMutableDictionary dictionary];
        _currentAccountName = kDKDefaultAccountName;
        _isSwitching = NO;
    }
    return self;
}

#pragma mark - 路径管理

- (NSString *)accountsRootPath {
    if (!_accountsRootPath) {
        // 使用 /var/mobile/Documents/DKAccounts 作为账号数据根目录
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docPath = [paths firstObject];
        _accountsRootPath = [docPath stringByAppendingPathComponent:@"DKAccounts"];
        
        // 确保目录存在
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:_accountsRootPath]) {
            [fm createDirectoryAtPath:_accountsRootPath
           withIntermediateDirectories:YES
                            attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                 error:nil];
        }
    }
    return _accountsRootPath;
}

- (NSString *)dataPathForAccount:(NSString *)accountName {
    if ([accountName isEqualToString:kDKDefaultAccountName]) {
        // 默认账号使用原始沙盒路径
        return NSHomeDirectory();
    }
    return [self.accountsRootPath stringByAppendingPathComponent:accountName];
}

- (NSString *)currentDataPath {
    return [self dataPathForAccount:self.currentAccountName];
}

- (NSString *)defaultAccountName {
    return kDKDefaultAccountName;
}

#pragma mark - 账号管理

- (NSArray<NSString *> *)allAccountNames {
    return [_accountNames copy];
}

- (NSString *)currentAccountName {
    return _currentAccountName;
}

- (void)refreshAccountList {
    [_accountNames removeAllObjects];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:self.accountsRootPath error:nil];
    
    for (NSString *item in contents) {
        NSString *fullPath = [self.accountsRootPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
            // 检查是否有元数据文件
            NSString *metaPath = [fullPath stringByAppendingPathComponent:@".dk_metadata.plist"];
            if ([fm fileExistsAtPath:metaPath]) {
                [_accountNames addObject:item];
                NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
                if (meta) {
                    _metadataCache[item] = meta;
                }
            }
        }
    }
    
    // 重要：先临时设为默认账号，这样 NSUserDefaults Hook 的 objectForKey 走 %orig，
    // 读取原始 NSUserDefaults（而非某个账号的独立 plist），确保读到正确的保存状态
    _currentAccountName = kDKDefaultAccountName;
    
    // 读取上次活跃账号（从原始 NSUserDefaults 读取）
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kDKCurrentAccountKey];
    if (saved) {
        if ([saved isEqualToString:kDKDefaultAccountName]) {
            _currentAccountName = kDKDefaultAccountName;
        } else if ([_accountNames containsObject:saved]) {
            _currentAccountName = saved;
        } else {
            // 保存的账号已不存在，回退到第一个可用账号或默认
            _currentAccountName = _accountNames.count > 0 ? _accountNames.firstObject : kDKDefaultAccountName;
        }
    } else {
        _currentAccountName = _accountNames.count > 0 ? _accountNames.firstObject : kDKDefaultAccountName;
    }
}

- (BOOL)addAccountWithName:(NSString *)name {
    if (!name || name.length == 0) return NO;
    if ([name isEqualToString:kDKDefaultAccountName]) return NO;
    if ([_accountNames containsObject:name]) return NO;

    // 添加新账号前，如果当前还在默认账号，先强制保存默认账号会话快照。
    // 这样后续立即切到 B 账号并登录，也能确保默认账号有可恢复的基线。
    if ([_currentAccountName isEqualToString:kDKDefaultAccountName]) {
        [[DKNetworkSessionManager sharedManager] snapshotDefaultSessionIfActive];
    }
    
    // 创建账号数据目录结构
    NSString *accountPath = [self dataPathForAccount:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSError *error = nil;
    [fm createDirectoryAtPath:accountPath
  withIntermediateDirectories:YES
                   attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                        error:&error];
    if (error) {
        NSLog(@"[DK] 创建账号目录失败: %@", error);
        return NO;
    }
    
    // 创建子目录结构（模拟原始沙盒结构）
    NSArray *subDirs = @[@"Documents", @"Library", @"Library/Preferences",
                         @"Library/Caches", @"Library/Cookies",
                         @"tmp"];
    for (NSString *sub in subDirs) {
        NSString *subPath = [accountPath stringByAppendingPathComponent:sub];
        [fm createDirectoryAtPath:subPath
      withIntermediateDirectories:YES
                       attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                            error:nil];
    }
    
    // 注意：不复制原始 NSUserDefaults
    // 新账号的独立 plist 保持为空，登录态/配置全从零开始
    // 这样切换账号后 app 找不到登录态，自然显示登录页
    NSLog(@"[DK] 账号 %@ 的 NSUserDefaults 已留空（全新开始）", name);
    
    // 保存元数据
    NSDictionary *metadata = @{
        @"name": name,
        @"createdAt": [NSDate date],
        @"version": @1
    };
    NSString *metaPath = [accountPath stringByAppendingPathComponent:@".dk_metadata.plist"];
    [metadata writeToFile:metaPath atomically:YES];
    _metadataCache[name] = metadata;
    
    [_accountNames addObject:name];
    
    // 保存账号列表
    [self _saveAccountList];
    
    NSLog(@"[DK] 账号添加成功: %@", name);
    return YES;
}

- (BOOL)deleteAccountWithName:(NSString *)name {
    if (!name || [name isEqualToString:kDKDefaultAccountName]) return NO;
    if (![_accountNames containsObject:name]) return NO;
    
    NSString *accountPath = [self dataPathForAccount:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 如果当前正在使用此账号，先切换到默认
    if ([_currentAccountName isEqualToString:name]) {
        [self switchToDefaultAccount];
    }
    
    NSError *error = nil;
    [fm removeItemAtPath:accountPath error:&error];
    if (error) {
        NSLog(@"[DK] 删除账号目录失败: %@", error);
        return NO;
    }
    
    [_accountNames removeObject:name];
    [_metadataCache removeObjectForKey:name];
    [self _saveAccountList];
    
    NSLog(@"[DK] 账号已删除: %@", name);
    return YES;
}

- (BOOL)clearAllMultiAccountData {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *rootPath = self.accountsRootPath;
    NSArray<NSString *> *accountNamesToClear = [_accountNames copy];

    // 先把运行态重置为默认账号，避免清理后继续指向已删除的 B/C/D 账号目录。
    _currentAccountName = kDKDefaultAccountName;
    [_accountNames removeAllObjects];
    [_metadataCache removeAllObjects];

    // 插件内部状态必须写入原始 NSUserDefaults，不能被当前账号 Hook 到子账号 plist。
    BOOL previousSwitching = _isSwitching;
    _isSwitching = YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:kDKDefaultAccountName forKey:kDKCurrentAccountKey];
    [defaults removeObjectForKey:kDKAccountsKey];
    [defaults removeObjectForKey:@"DK_NotificationCounts"];
    [defaults synchronize];
    _isSwitching = previousSwitching;

    // 清理子账号 Keychain 项。只删除带 DK_账号名_ 前缀的项，保留默认账号原始 Keychain。
    [self _clearKeychainItemsForAccountNames:accountNamesToClear];

    NSError *removeError = nil;
    if ([fm fileExistsAtPath:rootPath]) {
        [fm removeItemAtPath:rootPath error:&removeError];
        if (removeError) {
            NSLog(@"[DK] 清理多开账号数据失败: %@", removeError);
            return NO;
        }
    }

    NSError *createError = nil;
    [fm createDirectoryAtPath:rootPath
  withIntermediateDirectories:YES
                   attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                        error:&createError];
    if (createError) {
        NSLog(@"[DK] 重建账号根目录失败: %@", createError);
        return NO;
    }

    NSLog(@"[DK] 已清理所有多开账号数据，默认账号原始数据已保留");
    return YES;
}

#pragma mark - 账号切换

- (BOOL)switchToAccount:(NSString *)name {
    if (!name) return NO;
    if ([_currentAccountName isEqualToString:name]) return NO;
    
    if (![name isEqualToString:kDKDefaultAccountName] &&
        ![_accountNames containsObject:name]) {
        return NO;
    }

    BOOL switchingFromDefaultToSubAccount =
        [_currentAccountName isEqualToString:kDKDefaultAccountName] &&
        ![name isEqualToString:kDKDefaultAccountName];

    BOOL switchingToDefaultWithoutSnapshot =
        [name isEqualToString:kDKDefaultAccountName] &&
        ![[DKNetworkSessionManager sharedManager] hasSessionSnapshotForAccount:kDKDefaultAccountName];

    if (switchingFromDefaultToSubAccount) {
        // 从默认账号切到 B/C 等账号前，再强制保存一次默认账号快照。
        // 这是最关键的保险点，避免默认账号没有快照导致切回时进入登录页。
        [[DKNetworkSessionManager sharedManager] snapshotDefaultSessionIfActive];
        // 同时备份默认账号的 Keychain 数据。
        // TTAccountSDK 在子账号登录时可能误删/覆盖默认账号 Keychain 项。
        [[DKNetworkSessionManager sharedManager] backupDefaultAccountKeychain];
    } else if (switchingToDefaultWithoutSnapshot) {
        // 升级插件时如果当前已在 B/C/D，默认账号无法被自动快照。
        // 用户主动切回默认账号时，不要继续沿用子账号登录态。
        NSLog(@"[DK] 默认账号暂无快照，切回默认账号时将清理当前子账号登录态");
    }
    
    // 1. 保存当前账号的网络会话状态
    // 注意：这里不能把 isSwitching 设为 YES。
    // isSwitching 会让 UserDefaults Hook 直接走原始存储，
    // 如果当前是 B 账号，会错误读取/写入默认账号的登录态。
    [[DKNetworkSessionManager sharedManager] saveCurrentSession];

    if (switchingFromDefaultToSubAccount) {
        // 延迟安装 Hook 后，App 重启最早期会直接读取原始 Keychain。
        // 如果不在退出前清空默认账号 Keychain，子账号启动仍会读到默认账号登录态。
        // 默认账号 Keychain 已在上面备份，切回默认账号时会恢复。
        [[DKNetworkSessionManager sharedManager] clearDefaultAccountKeychainForSubAccountStartup];
    }

    // 保存完旧账号后，暂停自动备份一段时间。
    // 账号变量马上会切到目标账号，但应用内存里仍可能显示旧账号页面；
    // 如果退出前 Cookie/生命周期回调触发 saveCurrentSession，
    // 就会把旧账号运行态误保存成目标账号快照。
    [[DKNetworkSessionManager sharedManager] suspendAutomaticSessionBackupForSeconds:10.0];
    
    // 2. 保存当前账号的 UserDefaults 同步
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 3. 切换账号
    NSString *oldAccount = _currentAccountName;
    _currentAccountName = name;
    
    // 4. 保存当前活跃账号
    // 只有插件自己的当前账号标记需要写入原始 NSUserDefaults，
    // 因此把 isSwitching 的作用范围缩小到 saveCurrentState 内部。
    [self saveCurrentState];
    
    // 5. 恢复目标账号的网络会话
    // 此时 isSwitching 必须为 NO，才能让非默认账号恢复到自己的隔离存储。
    if ([name isEqualToString:kDKDefaultAccountName]) {
        // 切回默认账号时，先恢复默认账号 Keychain 数据。
        // 子账号登录过程中 TTAccountSDK 可能误删了默认账号的 Keychain 项。
        [[DKNetworkSessionManager sharedManager] restoreDefaultAccountKeychain];
    }
    [[DKNetworkSessionManager sharedManager] restoreSessionForAccount:name
                                                clearSessionIfMissing:switchingToDefaultWithoutSnapshot];
    
    // 6. 通知数据隔离层刷新
    [[DKDataIsolation sharedInstance] setup];
    
    NSLog(@"[DK] 账号切换: %@ -> %@", oldAccount, name);
    
    // 7. 发送账号切换通知
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DKAccountDidChangeNotification"
                                                        object:nil
                                                      userInfo:@{@"oldAccount": oldAccount ?: @"",
                                                                 @"newAccount": name}];
    
    // 8. 提示用户重启应用使新账号生效
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        UIWindowScene *windowScene = (UIWindowScene *)scene;
                        if (windowScene.windows.count > 0) {
                            keyWindow = windowScene.windows.firstObject;
                        }
                    }
                }
            }
        }
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        
        UIViewController *rootVC = keyWindow.rootViewController;
        while (rootVC.presentedViewController) {
            rootVC = rootVC.presentedViewController;
        }
        
        if (rootVC) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"账号已切换"
                                                                           message:[NSString stringWithFormat:@"已切换到账号「%@」\n应用即将重启以使新账号生效", name]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                // 退出应用，让用户重新打开后以新账号运行
                exit(0);
            }]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
    
    return YES;
}

- (BOOL)switchToDefaultAccount {
    return [self switchToAccount:kDKDefaultAccountName];
}

#pragma mark - 状态保存与恢复

- (void)saveCurrentState {
    // 临时开启 isSwitching，确保插件内部状态写入原始 NSUserDefaults（不走账号隔离 Hook）
    BOOL previousSwitching = _isSwitching;
    _isSwitching = YES;
    [[NSUserDefaults standardUserDefaults] setObject:_currentAccountName
                                              forKey:kDKCurrentAccountKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    _isSwitching = previousSwitching;
}

- (void)restoreStateForAccount:(NSString *)accountName {
    if ([accountName isEqualToString:kDKDefaultAccountName]) {
        // 默认账号不需要特殊恢复
        return;
    }
    
    // 确保账号数据目录存在
    NSString *accountPath = [self dataPathForAccount:accountName];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:accountPath]) {
        NSLog(@"[DK] 警告: 账号 %@ 的数据目录不存在", accountName);
    }
}

- (NSDictionary *)metadataForAccount:(NSString *)accountName {
    return _metadataCache[accountName];
}

#pragma mark - Private

- (BOOL)_keychainItem:(NSDictionary *)item hasAnyPrefix:(NSArray<NSString *> *)prefixes {
    NSArray *keysToCheck = @[
        (__bridge id)kSecAttrService,
        (__bridge id)kSecAttrAccount,
        (__bridge id)kSecAttrLabel
    ];

    for (id key in keysToCheck) {
        id value = item[key];
        if ([value isKindOfClass:[NSString class]]) {
            for (NSString *prefix in prefixes) {
                if ([value hasPrefix:prefix]) {
                    return YES;
                }
            }
        }
    }

    id generic = item[(__bridge id)kSecAttrGeneric];
    if ([generic isKindOfClass:[NSData class]]) {
        NSString *genericString = [[NSString alloc] initWithData:generic encoding:NSUTF8StringEncoding];
        for (NSString *prefix in prefixes) {
            if ([genericString hasPrefix:prefix]) {
                return YES;
            }
        }
    } else if ([generic isKindOfClass:[NSString class]]) {
        for (NSString *prefix in prefixes) {
            if ([generic hasPrefix:prefix]) {
                return YES;
            }
        }
    }

    return NO;
}

- (void)_clearKeychainItemsForAccountNames:(NSArray<NSString *> *)accountNames {
    if (accountNames.count == 0) return;

    NSMutableArray<NSString *> *prefixes = [NSMutableArray array];
    for (NSString *accountName in accountNames) {
        if (accountName.length > 0 && ![accountName isEqualToString:kDKDefaultAccountName]) {
            [prefixes addObject:[NSString stringWithFormat:@"DK_%@_", accountName]];
        }
    }
    if (prefixes.count == 0) return;

    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];

    for (id secClass in classes) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
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
            if (![self _keychainItem:item hasAnyPrefix:prefixes]) continue;

            NSMutableDictionary *deleteQuery = [@{(__bridge id)kSecClass: secClass} mutableCopy];
            NSArray *identityKeys = @[
                (__bridge id)kSecAttrService,
                (__bridge id)kSecAttrAccount,
                (__bridge id)kSecAttrLabel,
                (__bridge id)kSecAttrGeneric,
                (__bridge id)kSecAttrAccessGroup
            ];

            for (id key in identityKeys) {
                id value = item[key];
                if (value) {
                    deleteQuery[key] = value;
                }
            }

            if (deleteQuery.count > 1) {
                SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
            }
        }

        CFRelease(result);
    }
}

- (void)_saveAccountList {
    NSString *listPath = [self.accountsRootPath stringByAppendingPathComponent:@".dk_accounts.plist"];
    [_accountNames writeToFile:listPath atomically:YES];
}

@end
