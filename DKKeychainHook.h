#import <Foundation/Foundation.h>

// ============================================================
// DKKeychainHook - Keychain Hook
// 拦截 Keychain 读写，实现每个账号独立的钥匙串存储
// ============================================================

@interface DKKeychainHook : NSObject

+ (instancetype)sharedInstance;

/// 安装 Hook
- (void)install;

/// 卸载 Hook
- (void)uninstall;

@end