#import "DKUserDefaultsHook.h"
#import "DKAccountManager.h"
#import "DKDataIsolation.h"
#import <objc/runtime.h>

// ============================================================
// NSUserDefaults Hook
// 拦截 UserDefaults 读写，为每个账号维护独立的配置
// ============================================================

@implementation DKUserDefaultsHook

+ (instancetype)sharedInstance {
    static DKUserDefaultsHook *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKUserDefaultsHook alloc] init];
    });
    return instance;
}

- (void)install {
    NSLog(@"[DK] UserDefaults Hook 已安装");
}

- (void)uninstall {
    NSLog(@"[DK] UserDefaults Hook 已卸载");
}

@end

// ============================================================
// 为每个账号创建独立的 NSUserDefaults 实例
// （用于非 Hook 场景，如 DKAccountManager 内部使用）
// ============================================================

static NSMutableDictionary<NSString *, NSUserDefaults *> *_accountDefaultsCache = nil;

// ============================================================
// 递归保护 — 防止 DKGetAccountUserDefaults 内部创建 NSUserDefaults
// 时触发 Hook 导致无限递归
// ============================================================
static BOOL DKGetAccountUserDefaultsRecursionGuard = NO;

NSUserDefaults* DKGetAccountUserDefaults(NSString *suiteName) {
    if (DKGetAccountUserDefaultsRecursionGuard) {
        if (suiteName) {
            return [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        }
        return [NSUserDefaults standardUserDefaults];
    }
    
    DKGetAccountUserDefaultsRecursionGuard = YES;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _accountDefaultsCache = [NSMutableDictionary dictionary];
    });
    
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        DKGetAccountUserDefaultsRecursionGuard = NO;
        if (suiteName) {
            return [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        }
        return [NSUserDefaults standardUserDefaults];
    }
    
    // 为每个账号创建独立的 UserDefaults
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", currentAccount, suiteName ?: @"standard"];
    NSUserDefaults *cached = _accountDefaultsCache[cacheKey];
    if (cached) {
        DKGetAccountUserDefaultsRecursionGuard = NO;
        return cached;
    }
    
    // 使用自定义 plist 文件路径
    NSString *plistPath = [[DKDataIsolation sharedInstance] userDefaultsFileForSuiteName:suiteName];
    
    if (plistPath) {
        // 从文件加载字典
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        
        // 注册到标准 UserDefaults（通过临时路径）
        cached = [[NSUserDefaults alloc] initWithSuiteName:cacheKey];
        if (dict) {
            for (NSString *key in dict) {
                [cached setObject:dict[key] forKey:key];
            }
        }
    } else {
        cached = [[NSUserDefaults alloc] initWithSuiteName:suiteName ?: currentAccount];
    }
    
    _accountDefaultsCache[cacheKey] = cached;
    
    DKGetAccountUserDefaultsRecursionGuard = NO;
    return cached;
}

// ============================================================
// 直接读取账号独立 UserDefaults 的 plist 文件
// 用于 Hook 中，避免创建 NSUserDefaults 实例触发递归
// ============================================================

static NSString* _DKGetAccountPlistPath(void) {
    // 获取当前账号的 UserDefaults plist 路径
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return nil; // 默认账号不隔离
    }
    
    NSString *plistPath = [[DKDataIsolation sharedInstance] userDefaultsFileForSuiteName:nil];
    // 确保文件存在
    if (plistPath && ![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[plistPath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        [@{} writeToFile:plistPath atomically:YES];
    }
    return plistPath;
}

// 直接从账号独立的 plist 读取值（用于 Hook 中，避免递归）
id DKReadAccountUserDefault(NSString *key) {
    NSString *plistPath = _DKGetAccountPlistPath();
    if (!plistPath) return nil;
    
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    return dict[key];
}

// 直接写入账号独立的 plist（用于 Hook 中，避免递归）
void DKWriteAccountUserDefault(NSString *key, id value) {
    NSString *plistPath = _DKGetAccountPlistPath();
    if (!plistPath) return;
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] ?: [NSMutableDictionary dictionary];
    if (value) {
        dict[key] = value;
    } else {
        [dict removeObjectForKey:key];
    }
    [dict writeToFile:plistPath atomically:YES];
}

// 读取账号独立的 UserDefaults 全部字典（用于 Hook 中，避免递归）
NSDictionary* DKReadAccountUserDefaultsDictionary(void) {
    NSString *plistPath = _DKGetAccountPlistPath();
    if (!plistPath) return nil;
    
    return [NSDictionary dictionaryWithContentsOfFile:plistPath];
}

// 同步账号的 UserDefaults 到文件
void DKSyncAccountUserDefaults(void) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) return;
    
    // 注意：不要调用 [[NSUserDefaults standardUserDefaults] synchronize]，
    // 这会触发 %hook 的 synchronize 方法，导致无限递归
    
    // 将缓存中的 NSUserDefaults 数据写入 plist 文件
    for (NSString *cacheKey in _accountDefaultsCache) {
        NSUserDefaults *defaults = _accountDefaultsCache[cacheKey];
        NSDictionary *dict = [defaults dictionaryRepresentation];
        
        NSString *plistPath = [[DKDataIsolation sharedInstance] userDefaultsFileForSuiteName:
                                [cacheKey containsString:@"_"] ? [[cacheKey componentsSeparatedByString:@"_"] lastObject] : nil];
        if (plistPath) {
            [dict writeToFile:plistPath atomically:YES];
        }
    }
}

// 清空当前账号的 UserDefaults 独立 plist
void DKClearAccountUserDefaults(void) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) return;
    
    NSString *plistPath = _DKGetAccountPlistPath();
    if (plistPath) {
        [@{} writeToFile:plistPath atomically:YES];
        NSLog(@"[DK] 已清空账号 %@ 的 UserDefaults 独立 plist", currentAccount);
    }
}