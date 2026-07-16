#import "DKAccountManager.h"
#import "DKDataIsolation.h"
#import "DKNetworkSessionManager.h"
#import <UIKit/UIKit.h>

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
    
    // 读取上次活跃账号
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kDKCurrentAccountKey];
    if (saved && [_accountNames containsObject:saved]) {
        _currentAccountName = saved;
    } else if (_accountNames.count > 0) {
        _currentAccountName = _accountNames.firstObject;
    } else {
        _currentAccountName = kDKDefaultAccountName;
    }
}

- (BOOL)addAccountWithName:(NSString *)name {
    if (!name || name.length == 0) return NO;
    if ([name isEqualToString:kDKDefaultAccountName]) return NO;
    if ([_accountNames containsObject:name]) return NO;
    
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

#pragma mark - 账号切换

- (BOOL)switchToAccount:(NSString *)name {
    if (!name) return NO;
    if ([_currentAccountName isEqualToString:name]) return NO;
    
    if (![name isEqualToString:kDKDefaultAccountName] &&
        ![_accountNames containsObject:name]) {
        return NO;
    }
    
    _isSwitching = YES;
    
    // 1. 保存当前账号的网络会话状态
    [[DKNetworkSessionManager sharedManager] saveCurrentSession];
    
    // 2. 保存当前账号的 UserDefaults 同步
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 3. 切换账号
    NSString *oldAccount = _currentAccountName;
    _currentAccountName = name;
    
    // 4. 保存当前活跃账号
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:kDKCurrentAccountKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 5. 恢复目标账号的网络会话
    [[DKNetworkSessionManager sharedManager] restoreSessionForAccount:name];
    
    // 6. 通知数据隔离层刷新
    [[DKDataIsolation sharedInstance] setup];
    
    _isSwitching = NO;
    
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
                                                                           message:[NSString stringWithFormat:@"已切换到账号「%@」\n请重启 TRAE 以使新账号生效", name]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
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
    // 保存当前活跃账号标记
    [[NSUserDefaults standardUserDefaults] setObject:_currentAccountName
                                              forKey:kDKCurrentAccountKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
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

- (void)_saveAccountList {
    NSString *listPath = [self.accountsRootPath stringByAppendingPathComponent:@".dk_accounts.plist"];
    [_accountNames writeToFile:listPath atomically:YES];
}

@end