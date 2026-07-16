#import <Foundation/Foundation.h>

// ============================================================
// DKFileManagerHook - NSFileManager Hook
// 拦截文件操作，将路径重定向到当前账号的数据目录
// ============================================================

@interface DKFileManagerHook : NSObject

+ (instancetype)sharedInstance;

/// 安装 Hook
- (void)install;

/// 卸载 Hook（用于调试）
- (void)uninstall;

@end