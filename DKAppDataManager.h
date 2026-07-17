#import <Foundation/Foundation.h>

// ============================================================
// DKAppDataManager — 应用数据目录级快照管理
//
// 核心思想（借鉴 Crane 的容器级隔离）：
//   切换账号时，将当前账号的整个 Library/ 目录搬移到账号备份目录，
//   再将目标账号的 Library/ 目录搬移回应用沙盒。
//
//   只搬移 Library/（不搬移 Documents/），因为：
//   - Library/ 包含 MMKV、WCDB、NSUserDefaults plist、Cookie 等所有关键数据
//   - Documents/ 包含 DKAccounts/ 备份目录自身，搬移会形成递归
//
//   这比 API 级 Hook 更可靠，因为：
//   - MMKV 的 mmap() 映射的文件也会被正确搬移
//   - WCDB/SQLCipher 等 C++ 引擎的文件也会被正确搬移
//   - 不需要逐个 Hook 每个数据访问 API
//   - 搬移后的数据在应用原始路径下，应用无需任何修改即可正常使用
// ============================================================

@interface DKAppDataManager : NSObject

+ (instancetype)sharedManager;

/// 将当前应用沙盒的 Library/ 目录搬移到指定账号的备份目录
/// @param accountName 账号名称
/// @return 是否成功
- (BOOL)moveAppDataToAccount:(NSString *)accountName;

/// 将指定账号的备份目录搬移回应用沙盒
/// @param accountName 账号名称
/// @return 是否成功
- (BOOL)moveAccountDataToApp:(NSString *)accountName;

/// 检查账号是否有备份数据
- (BOOL)hasBackupForAccount:(NSString *)accountName;

/// 清理账号的备份数据
- (void)clearBackupForAccount:(NSString *)accountName;

/// 启动时调用：确保沙盒中的数据与当前账号匹配。
/// 如果不匹配，自动搬移旧数据到对应账号备份，并恢复当前账号数据。
/// @param currentAccount 当前活跃账号名
/// @param designatedDefault 指定默认账号名（可为 nil）
- (void)ensureDataOwnershipForAccount:(NSString *)currentAccount
                    designatedDefault:(NSString *)designatedDefault;

@end