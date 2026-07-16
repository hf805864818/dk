#import "DKDataIsolation.h"
#import "DKAccountManager.h"

@implementation DKDataIsolation

+ (instancetype)sharedInstance {
    static DKDataIsolation *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKDataIsolation alloc] init];
    });
    return instance;
}

- (void)setup {
    // 数据隔离由各个 Hook 模块独立实现
    // 此方法在账号切换时调用，用于刷新隔离状态
    NSString *currentAccount = [[DKAccountManager sharedManager] currentAccountName];
    NSLog(@"[DK] 数据隔离已激活，当前账号: %@", currentAccount);
}

- (NSString *)mappedPathForOriginalPath:(NSString *)originalPath {
    if (!originalPath) return nil;
    
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    // 默认账号不映射
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return originalPath;
    }
    
    NSString *homePath = NSHomeDirectory();
    NSString *accountDataPath = [manager dataPathForAccount:currentAccount];
    
    // 如果路径在沙盒内，映射到账号数据目录
    if ([originalPath hasPrefix:homePath]) {
        NSString *relativePath = [originalPath substringFromIndex:homePath.length];
        
        // 排除 DK 自身的数据目录
        if ([relativePath hasPrefix:@"/Documents/DKAccounts"]) {
            return originalPath;
        }
        
        NSString *mappedPath = [accountDataPath stringByAppendingPathComponent:relativePath];
        
        // 确保父目录存在
        NSString *parentDir = [mappedPath stringByDeletingLastPathComponent];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:parentDir]) {
            [fm createDirectoryAtPath:parentDir
          withIntermediateDirectories:YES
                           attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                error:nil];
        }
        
        return mappedPath;
    }
    
    return originalPath;
}

- (NSString *)userDefaultsFileForSuiteName:(NSString *)suiteName {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return nil; // 使用默认路径
    }
    
    NSString *accountPath = [manager dataPathForAccount:currentAccount];
    return [accountPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Preferences/%@.plist", suiteName ?: @"dk_defaults"]];
}

- (NSString *)keychainAccessGroupForOriginalGroup:(NSString *)originalGroup {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return originalGroup;
    }
    
    // 为每个账号创建独立的 keychain access group
    return [NSString stringWithFormat:@"%@.dk.%@", originalGroup ?: @"com.dk", currentAccount];
}

- (NSString *)keychainServicePrefix {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return @"";
    }
    
    return [NSString stringWithFormat:@"DK_%@_", currentAccount];
}

@end