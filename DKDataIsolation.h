#import <Foundation/Foundation.h>

// ============================================================
// DKDataIsolation - 数据隔离核心
// 通过 Hook 系统 API 实现每个账号的数据完全隔离
// ============================================================

@interface DKDataIsolation : NSObject

+ (instancetype)sharedInstance;

/// 初始化数据隔离 Hook
- (void)setup;

/// 获取当前账号的沙盒路径映射
- (NSString *)mappedPathForOriginalPath:(NSString *)originalPath;

/// 获取当前账号的 UserDefaults 文件名
- (NSString *)userDefaultsFileForSuiteName:(NSString *)suiteName;

/// 获取当前账号的 Keychain 访问组
- (NSString *)keychainAccessGroupForOriginalGroup:(NSString *)originalGroup;

/// 获取当前账号的 Keychain 服务名前缀
- (NSString *)keychainServicePrefix;

@end