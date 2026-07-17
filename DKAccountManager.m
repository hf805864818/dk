#import "DKAccountManager.h"
#import "DKDataIsolation.h"
#import "DKNetworkSessionManager.h"
#import "DKAppDataManager.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <unistd.h>

// ============================================================
// 账号元数据存储键
// ============================================================
static NSString *const kDKAccountsKey = @"DK_Accounts_List";
static NSString *const kDKCurrentAccountKey = @"DK_Current_Account";
static NSString *const kDKDefaultAccountName = @"__DK_DEFAULT__";
static NSString *const kDKCurrentAccountFile = @".dk_current_account";
static NSString *const kDKDesignatedDefaultFile = @".dk_designated_default";

// ============================================================
// 内部存储 — 使用 App Group 级别共享存储
// ============================================================
static NSString *_accountsRootPath = nil;

@implementation DKAccountManager {
    NSMutableArray<NSString *> *_accountNames;
    NSString *_currentAccountName;
    NSString *_designatedDefaultAccountName;
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
        _designatedDefaultAccountName = nil;
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

- (NSString *)_currentAccountFilePath {
    return [self.accountsRootPath stringByAppendingPathComponent:kDKCurrentAccountFile];
}

- (NSString *)_designatedDefaultFilePath {
    return [self.accountsRootPath stringByAppendingPathComponent:kDKDesignatedDefaultFile];
}

- (NSString *)_loadDesignatedDefault {
    NSString *path = [self _designatedDefaultFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }
    NSString *name = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) return nil;
    return name;
}

- (void)_saveDesignatedDefault:(NSString *)accountName {
    NSString *path = [self _designatedDefaultFilePath];
    if (accountName) {
        [accountName writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

- (void)_saveCurrentAccountToFile:(NSString *)accountName {
    NSString *path = [self _currentAccountFilePath];
    // 直接写入文件系统，不依赖 NSUserDefaults/cfprefsd，避免 exit(0) 前同步延迟丢失
    NSLog(@"[DK] 写入当前账号文件: %@ -> %@", accountName, path);
    NSError *error = nil;
    BOOL ok = [accountName writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:&error];
    if (!ok || error) {
        NSLog(@"[DK] ❌ 当前账号文件写入失败: %@ (path=%@)", error, path);
    } else {
        // 验证写入内容
        NSString *verify = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[DK] ✅ 当前账号文件写入成功，验证读取: %@", verify);
    }
}

- (NSString *)_currentAccountFromFile {
    NSString *path = [self _currentAccountFilePath];
    NSLog(@"[DK] 读取当前账号文件: %@", path);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"[DK] 当前账号文件不存在: %@", path);
        return nil;
    }
    NSError *error = nil;
    NSString *saved = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (error) {
        NSLog(@"[DK] 当前账号文件读取失败: %@", error);
    }
    NSLog(@"[DK] 当前账号文件内容: %@", saved);
    return saved;
}

- (NSString *)dataPathForAccount:(NSString *)accountName {
    if ([accountName isEqualToString:kDKDefaultAccountName]) {
        // 默认账号使用原始沙盒路径
        return NSHomeDirectory();
    }
    // 如果此账号被指定为默认，也使用原始沙盒路径
    if (_designatedDefaultAccountName &&
        [accountName isEqualToString:_designatedDefaultAccountName]) {
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
    NSString *rootPath = self.accountsRootPath;
    NSLog(@"[DK] refreshAccountList: 根目录=%@", rootPath);

    NSArray *contents = [fm contentsOfDirectoryAtPath:rootPath error:nil];
    NSLog(@"[DK] refreshAccountList: 目录内容=%lu 项", (unsigned long)contents.count);

    for (NSString *item in contents) {
        NSString *fullPath = [rootPath stringByAppendingPathComponent:item];
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
                NSLog(@"[DK] refreshAccountList: 发现账号 %@", item);
            }
        }
    }

    // 重要：先临时设为默认账号，这样 NSUserDefaults Hook 的 objectForKey 走 %orig，
    // 读取原始 NSUserDefaults（而非某个账号的独立 plist），确保读到正确的保存状态
    _currentAccountName = kDKDefaultAccountName;

    // 加载指定默认账号（如果有）
    _designatedDefaultAccountName = [self _loadDesignatedDefault];
    if (_designatedDefaultAccountName) {
        NSLog(@"[DK] refreshAccountList: 指定默认账号=%@", _designatedDefaultAccountName);
    }

    // 优先读取独立文件中的当前账号标记。
    // exit(0) 前 cfprefsd 可能尚未把 NSUserDefaults 写入磁盘，导致状态丢失。
    NSString *saved = [self _currentAccountFromFile];
    if (!saved) {
        // 兼容旧版本：回退到 NSUserDefaults
        NSLog(@"[DK] refreshAccountList: 文件未读到，回退到 NSUserDefaults");
        saved = [[NSUserDefaults standardUserDefaults] stringForKey:kDKCurrentAccountKey];
        NSLog(@"[DK] refreshAccountList: NSUserDefaults 值=%@", saved);
    }

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
    NSLog(@"[DK] refreshAccountList: 最终当前账号=%@", _currentAccountName);
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

    // 保存旧账号状态后，暂停自动备份一段时间。
    // 如果用户不点"确定"而是切到后台，此时内存中的 _currentAccountName
    // 仍然是旧账号，Cookie/生命周期回调会正确保存到旧账号快照。
    [[DKNetworkSessionManager sharedManager] suspendAutomaticSessionBackupForSeconds:10.0];

    // 2. 保存当前账号的 UserDefaults 同步
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSString *oldAccount = _currentAccountName;

    NSLog(@"[DK] 准备切换账号: %@ -> %@（等待用户确认）", oldAccount, name);

    // 3. 提示用户重启应用使新账号生效
    // 关键：_currentAccountName 的切换推迟到弹窗"确定"按钮的 handler 中，
    // 在用户点击"确定"之前，内存状态保持不变（旧账号），
    // 如果用户切到后台，Cookie 备份会正确保存到旧账号快照。
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
                // ============================================================
                // 在 exit(0) 之前完成所有状态切换（此时用户已确认，不会回退）
                // ============================================================

                // 切换 _currentAccountName
                _currentAccountName = name;

                // 保存当前活跃账号标记到磁盘
                [self saveCurrentState];

                // 恢复目标账号的网络会话
                // isSwitching 此时为 NO，非默认账号恢复到自己的隔离存储。
                if ([name isEqualToString:kDKDefaultAccountName]) {
                    [[DKNetworkSessionManager sharedManager] restoreDefaultAccountKeychain];
                }
                [[DKNetworkSessionManager sharedManager] restoreSessionForAccount:name
                                                            clearSessionIfMissing:switchingToDefaultWithoutSnapshot];

                // 通知数据隔离层刷新
                [[DKDataIsolation sharedInstance] setup];

                // ============================================================
                // 目录级数据搬移（借鉴 Crane 容器级隔离思路）
                // 将当前 App 沙盒的 Library/ 和 Documents/ 搬移到旧账号备份，
                // 再将目标账号的备份搬移回 App 沙盒。
                // 这能捕获 MMKV、WCDB 等绕过 API Hook 的 C++ 存储引擎数据。
                // ============================================================
                if (![oldAccount isEqualToString:name]) {
                    // 1. 将当前 App 数据搬移到旧账号备份
                    [[DKAppDataManager sharedManager] moveAppDataToAccount:oldAccount];
                    // 2. 将目标账号数据搬移回 App 沙盒
                    [[DKAppDataManager sharedManager] moveAccountDataToApp:name];
                }

                // 发送账号切换通知
                [[NSNotificationCenter defaultCenter] postNotificationName:@"DKAccountDidChangeNotification"
                                                                    object:nil
                                                                  userInfo:@{@"oldAccount": oldAccount ?: @"",
                                                                             @"newAccount": name}];

                NSLog(@"[DK] 账号切换完成: %@ -> %@，即将退出应用", oldAccount, name);

                // 在退出前同步 NSUserDefaults
                [[NSUserDefaults standardUserDefaults] synchronize];

                // 延迟退出让 RunLoop 有机会处理异步操作（Cookie 持久化等），
                // 延迟结束后再次 sync() 刷新所有文件系统缓冲区再退出
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    // 退出前再次强制刷新所有数据到磁盘。
                    // sync() 放在这里（而非 dispatch_after 之前），确保
                    // 0.5s 延迟期间的任何异步写入也被刷盘。
                    sync();
                    // 退出应用，让用户重新打开后以新账号运行
                    exit(0);
                });
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

    // 独立文件写入也必须在 isSwitching=YES 期间完成。
    // 否则 _currentAccountName 可能已是子账号名，文件 Hook 会
    // 把 .dk_current_account 重定向到子账号隔离目录，下次启动读不到。
    [self _saveCurrentAccountToFile:_currentAccountName];

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

- (void)promptSetDesignatedDefault {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *currentAccount = _currentAccountName;
        NSString *defaultAccount = kDKDefaultAccountName;

        // 如果当前就是默认账号，无需操作
        if ([currentAccount isEqualToString:defaultAccount] &&
            !_designatedDefaultAccountName) {
            [self _showToast:@"当前已是默认账号"];
            return;
        }

        NSString *title = @"设为默认账号";
        NSString *message = [NSString stringWithFormat:
            @"将当前账号「%@」设为默认账号？\n\n"
            @"设定后，该账号数据将直接使用应用原始沙盒路径。\n"
            @"更新插件后无需重新登录此账号。\n\n"
            @"原默认账号数据会保留在备份中，可随时切换回去。",
            currentAccount];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

        [alert addAction:[UIAlertAction actionWithTitle:@"设为默认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // 保存指定默认账号标记
            [self _saveDesignatedDefault:currentAccount];
            _designatedDefaultAccountName = currentAccount;

            // 保存当前状态
            [self saveCurrentState];

            NSLog(@"[DK] 账号「%@」已设为指定默认账号，即将退出", currentAccount);

            // 同步然后退出
            [[NSUserDefaults standardUserDefaults] synchronize];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                sync();
                exit(0);
            });
        }]];

        UIViewController *rootVC = [self _rootViewController];
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (void)_showToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        UIWindowScene *windowScene = (UIWindowScene *)scene;
                        keyWindow = windowScene.windows.firstObject;
                    }
                }
            }
        }
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }

        UILabel *toast = [[UILabel alloc] init];
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont systemFontOfSize:14];
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;

        CGSize size = [message sizeWithAttributes:@{NSFontAttributeName: toast.font}];
        CGFloat toastWidth = MIN(size.width + 32, keyWindow.bounds.size.width - 40);
        toast.frame = CGRectMake((keyWindow.bounds.size.width - toastWidth) / 2.0,
                                  keyWindow.bounds.size.height - 100,
                                  toastWidth, size.height + 20);

        [keyWindow addSubview:toast];
        toast.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{
            toast.alpha = 1.0;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:1.5 options:0 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        }];
    });
}

- (UIViewController *)_rootViewController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    keyWindow = windowScene.windows.firstObject;
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
    return rootVC;
}

- (void)_saveAccountList {
    NSString *listPath = [self.accountsRootPath stringByAppendingPathComponent:@".dk_accounts.plist"];
    [_accountNames writeToFile:listPath atomically:YES];
}

@end
