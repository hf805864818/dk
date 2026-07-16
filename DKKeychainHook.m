#import "DKKeychainHook.h"
#import "DKAccountManager.h"
#import "DKDataIsolation.h"
#import <Security/Security.h>
#import <objc/runtime.h>

// ============================================================
// Keychain Hook
// 为每个账号维护独立的 Keychain 命名空间
// 通过给 service/account 添加前缀实现隔离
// ============================================================

@implementation DKKeychainHook

+ (instancetype)sharedInstance {
    static DKKeychainHook *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKKeychainHook alloc] init];
    });
    return instance;
}

- (void)install {
    NSLog(@"[DK] Keychain Hook 已安装");
}

- (void)uninstall {
    NSLog(@"[DK] Keychain Hook 已卸载");
}

@end

// ============================================================
// Keychain 查询参数映射
// ============================================================

NSDictionary* DKRemapKeychainQuery(NSDictionary *query) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return query;
    }
    
    NSString *prefix = [[DKDataIsolation sharedInstance] keychainServicePrefix];
    if (prefix.length == 0) return query;
    
    NSMutableDictionary *mappedQuery = [query mutableCopy];
    
    // 给 kSecAttrService 添加前缀
    id service = query[(__bridge id)kSecAttrService];
    if (service && [service isKindOfClass:[NSString class]]) {
        mappedQuery[(__bridge id)kSecAttrService] = [prefix stringByAppendingString:service];
    }
    
    // 给 kSecAttrAccount 添加前缀
    id account = query[(__bridge id)kSecAttrAccount];
    if (account && [account isKindOfClass:[NSString class]]) {
        mappedQuery[(__bridge id)kSecAttrAccount] = [prefix stringByAppendingString:account];
    }
    
    // 给 kSecAttrAccessGroup 添加前缀
    id accessGroup = query[(__bridge id)kSecAttrAccessGroup];
    if (accessGroup && [accessGroup isKindOfClass:[NSString class]]) {
        mappedQuery[(__bridge id)kSecAttrAccessGroup] = [[DKDataIsolation sharedInstance]
                                                          keychainAccessGroupForOriginalGroup:accessGroup];
    }
    
    // 给 kSecAttrLabel 添加前缀（某些 app 使用 label 而非 service）
    id label = query[(__bridge id)kSecAttrLabel];
    if (label && [label isKindOfClass:[NSString class]]) {
        mappedQuery[(__bridge id)kSecAttrLabel] = [prefix stringByAppendingString:label];
    }
    
    // 给 kSecAttrGeneric 添加前缀（某些 app 使用 generic 属性）
    id generic = query[(__bridge id)kSecAttrGeneric];
    if (generic) {
        // kSecAttrGeneric 是 CFDataRef，但这里我们只处理 NSString 和 NSData
        if ([generic isKindOfClass:[NSString class]]) {
            mappedQuery[(__bridge id)kSecAttrGeneric] = [prefix stringByAppendingString:generic];
        } else if ([generic isKindOfClass:[NSData class]]) {
            NSString *dataStr = [[NSString alloc] initWithData:generic encoding:NSUTF8StringEncoding];
            if (dataStr) {
                NSString *prefixed = [prefix stringByAppendingString:dataStr];
                mappedQuery[(__bridge id)kSecAttrGeneric] = [prefixed dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
    }
    
    return [mappedQuery copy];
}

// 反向映射：去除前缀
NSDictionary* DKUnmapKeychainResult(NSDictionary *result) {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return result;
    }
    
    NSString *prefix = [[DKDataIsolation sharedInstance] keychainServicePrefix];
    if (prefix.length == 0) return result;
    
    NSMutableDictionary *unmappedResult = [result mutableCopy];
    
    id service = result[(__bridge id)kSecAttrService];
    if (service && [service isKindOfClass:[NSString class]] && [service hasPrefix:prefix]) {
        unmappedResult[(__bridge id)kSecAttrService] = [service substringFromIndex:prefix.length];
    }
    
    id account = result[(__bridge id)kSecAttrAccount];
    if (account && [account isKindOfClass:[NSString class]] && [account hasPrefix:prefix]) {
        unmappedResult[(__bridge id)kSecAttrAccount] = [account substringFromIndex:prefix.length];
    }
    
    return [unmappedResult copy];
}