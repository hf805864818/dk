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
    if (service && [service isKindOfClass:[NSString class]] && ![service hasPrefix:prefix]) {
        mappedQuery[(__bridge id)kSecAttrService] = [prefix stringByAppendingString:service];
    }
    
    // 给 kSecAttrAccount 添加前缀
    id account = query[(__bridge id)kSecAttrAccount];
    if (account && [account isKindOfClass:[NSString class]] && ![account hasPrefix:prefix]) {
        mappedQuery[(__bridge id)kSecAttrAccount] = [prefix stringByAppendingString:account];
    }
    
    // 不修改 kSecAttrAccessGroup。
    // access group 必须匹配应用 entitlement，随意加账号前缀会导致 SecItemAdd/Update 失败，
    // 进而出现 B/C 账号登录态无法持久化的问题。
    
    // 给 kSecAttrLabel 添加前缀（某些 app 使用 label 而非 service）
    id label = query[(__bridge id)kSecAttrLabel];
    if (label && [label isKindOfClass:[NSString class]] && ![label hasPrefix:prefix]) {
        mappedQuery[(__bridge id)kSecAttrLabel] = [prefix stringByAppendingString:label];
    }
    
    // 给 kSecAttrGeneric 添加前缀（某些 app 使用 generic 属性）
    id generic = query[(__bridge id)kSecAttrGeneric];
    if (generic) {
        // kSecAttrGeneric 是 CFDataRef，但这里我们只处理 NSString 和 NSData
        if ([generic isKindOfClass:[NSString class]] && ![generic hasPrefix:prefix]) {
            mappedQuery[(__bridge id)kSecAttrGeneric] = [prefix stringByAppendingString:generic];
        } else if ([generic isKindOfClass:[NSData class]]) {
            NSString *dataStr = [[NSString alloc] initWithData:generic encoding:NSUTF8StringEncoding];
            if (dataStr && ![dataStr hasPrefix:prefix]) {
                NSString *prefixed = [prefix stringByAppendingString:dataStr];
                mappedQuery[(__bridge id)kSecAttrGeneric] = [prefixed dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
    }
    
    return [mappedQuery copy];
}

NSDictionary* DKRemapKeychainAttributes(NSDictionary *attributes) {
    if (!attributes) return attributes;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];
    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        return attributes;
    }

    NSString *prefix = [[DKDataIsolation sharedInstance] keychainServicePrefix];
    if (prefix.length == 0) return attributes;

    NSMutableDictionary *mappedAttributes = [attributes mutableCopy];

    id service = attributes[(__bridge id)kSecAttrService];
    if (service && [service isKindOfClass:[NSString class]] && ![service hasPrefix:prefix]) {
        mappedAttributes[(__bridge id)kSecAttrService] = [prefix stringByAppendingString:service];
    }

    id account = attributes[(__bridge id)kSecAttrAccount];
    if (account && [account isKindOfClass:[NSString class]] && ![account hasPrefix:prefix]) {
        mappedAttributes[(__bridge id)kSecAttrAccount] = [prefix stringByAppendingString:account];
    }

    id label = attributes[(__bridge id)kSecAttrLabel];
    if (label && [label isKindOfClass:[NSString class]] && ![label hasPrefix:prefix]) {
        mappedAttributes[(__bridge id)kSecAttrLabel] = [prefix stringByAppendingString:label];
    }

    id generic = attributes[(__bridge id)kSecAttrGeneric];
    if ([generic isKindOfClass:[NSString class]] && ![generic hasPrefix:prefix]) {
        mappedAttributes[(__bridge id)kSecAttrGeneric] = [prefix stringByAppendingString:generic];
    } else if ([generic isKindOfClass:[NSData class]]) {
        NSString *dataStr = [[NSString alloc] initWithData:generic encoding:NSUTF8StringEncoding];
        if (dataStr && ![dataStr hasPrefix:prefix]) {
            NSString *prefixed = [prefix stringByAppendingString:dataStr];
            mappedAttributes[(__bridge id)kSecAttrGeneric] = [prefixed dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    return [mappedAttributes copy];
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

BOOL DKKeychainResultMatchesCurrentAccount(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) return YES;

    DKAccountManager *manager = [DKAccountManager sharedManager];
    NSString *currentAccount = [manager currentAccountName];

    NSArray *keysToCheck = @[
        (__bridge id)kSecAttrService,
        (__bridge id)kSecAttrAccount,
        (__bridge id)kSecAttrLabel
    ];

    NSMutableArray<NSString *> *stringValues = [NSMutableArray array];
    for (id key in keysToCheck) {
        id value = result[key];
        if ([value isKindOfClass:[NSString class]]) {
            [stringValues addObject:value];
        }
    }

    id generic = result[(__bridge id)kSecAttrGeneric];
    if ([generic isKindOfClass:[NSString class]]) {
        [stringValues addObject:generic];
    } else if ([generic isKindOfClass:[NSData class]]) {
        NSString *genericString = [[NSString alloc] initWithData:generic encoding:NSUTF8StringEncoding];
        if (genericString.length > 0) {
            [stringValues addObject:genericString];
        }
    }

    if ([currentAccount isEqualToString:[manager defaultAccountName]]) {
        for (NSString *value in stringValues) {
            if ([value hasPrefix:@"DK_"]) {
                return NO;
            }
        }
        return YES;
    }

    NSString *prefix = [[DKDataIsolation sharedInstance] keychainServicePrefix];
    if (prefix.length == 0) return YES;

    // 如果返回的是纯数据而没有属性，无法判断归属，保持兼容放行。
    if (stringValues.count == 0) return YES;

    for (NSString *value in stringValues) {
        if ([value hasPrefix:prefix]) {
            return YES;
        }
    }

    return NO;
}
