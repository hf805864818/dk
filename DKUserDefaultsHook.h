#import <Foundation/Foundation.h>

// ============================================================
// DKUserDefaultsHook - NSUserDefaults Hook
// 拦截 UserDefaults 读写，实现每个账号独立的配置存储
// ============================================================

@interface DKUserDefaultsHook : NSObject

+ (instancetype)sharedInstance;

/// 安装 Hook
- (void)install;

/// 卸载 Hook
- (void)uninstall;

@end