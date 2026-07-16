#import <Foundation/Foundation.h>

// ============================================================
// DKAccountManager - 账号管理核心
// 负责账号的创建、删除、切换、列表管理
// ============================================================

@interface DKAccountManager : NSObject

+ (instancetype)sharedManager;

/// 当前活跃账号名称
@property (nonatomic, copy, readonly) NSString *currentAccountName;

/// 所有已添加账号的名称列表
@property (nonatomic, copy, readonly) NSArray<NSString *> *allAccountNames;

/// 默认账号名称（应用原始数据）
@property (nonatomic, copy, readonly) NSString *defaultAccountName;

/// 账号数据根目录
@property (nonatomic, copy, readonly) NSString *accountsRootPath;

/// 切换账号时是否通知代理
@property (nonatomic, assign) BOOL isSwitching;

/// 添加新账号
- (BOOL)addAccountWithName:(NSString *)name;

/// 删除账号
- (BOOL)deleteAccountWithName:(NSString *)name;

/// 清理所有多开账号数据，保留默认账号原始数据
- (BOOL)clearAllMultiAccountData;

/// 切换到指定账号
- (BOOL)switchToAccount:(NSString *)name;

/// 切换到默认账号（原始数据）
- (BOOL)switchToDefaultAccount;

/// 刷新账号列表
- (void)refreshAccountList;

/// 获取账号数据目录路径
- (NSString *)dataPathForAccount:(NSString *)accountName;

/// 获取当前活跃账号的数据目录路径
- (NSString *)currentDataPath;

/// 保存当前账号状态
- (void)saveCurrentState;

/// 恢复指定账号状态
- (void)restoreStateForAccount:(NSString *)accountName;

/// 获取账号元数据（如创建时间等）
- (NSDictionary *)metadataForAccount:(NSString *)accountName;

@end
