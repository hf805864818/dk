#import <Foundation/Foundation.h>

// ============================================================
// DKNetworkSessionManager - 网络会话管理
// 负责保存和恢复每个账号的网络会话状态（Cookie/Token等）
// 确保切换账号后不需要重新登录
// ============================================================

@interface DKNetworkSessionManager : NSObject

+ (instancetype)sharedInstance;

/// 兼容旧调用方式
+ (instancetype)sharedManager;

/// 初始化网络会话管理
- (void)setup;

/// 保存当前账号的网络会话状态
- (void)saveCurrentSession;

/// 恢复指定账号的网络会话状态
- (void)restoreSessionForAccount:(NSString *)accountName;

/// 为指定账号备份网络会话数据
- (void)backupSessionForAccount:(NSString *)accountName;

/// 获取账号的会话数据路径
- (NSString *)sessionPathForAccount:(NSString *)accountName;

/// 定期刷新所有账号的会话（保持在线）
- (void)scheduleSessionRefresh;

@end