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
// ============================================================

static NSMutableDictionary<NSString *, NSUserDefaults *> *_accountDefaultsCache = nil;

NSUserDefaults* DKGetAccountUserDefaults(NSString *suiteName) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _accountDefaultsCache = [NSMutableDictionary dictionary];
    });
    
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        // 默认账号使用原始行为
        if (suiteName) {
            return [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        }
        return [NSUserDefaults standardUserDefaults];
    }
    
    // 为每个账号创建独立的 UserDefaults
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", currentAccount, suiteName ?: @"standard"];
    NSUserDefaults *cached = _accountDefaultsCache[cacheKey];
    if (cached) return cached;
    
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
    return cached;
}

// 同步账号的 UserDefaults 到文件
void DKSyncAccountUserDefaults(void) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) return;
    
    // 同步标准 UserDefaults
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 同步自定义 suite
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