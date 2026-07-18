#import <Foundation/Foundation.h>

@interface DKUserDefaultsHook : NSObject

+ (instancetype)sharedInstance;
- (void)install;
- (void)uninstall;

@end

// ============================================================
// 以下 C 函数用于在 Tweak.x 的 %hook 中直接读写 plist 文件
// 避免创建 NSUserDefaults 实例触发 Hook 导致无限递归
// ============================================================

// 获取账号独立的 NSUserDefaults 实例（用于非 Hook 场景）
NSUserDefaults* DKGetAccountUserDefaults(NSString *suiteName);

// 直接从账号独立的 plist 读取值（用于 Hook 中，避免递归）
id DKReadAccountUserDefault(NSString *key);

// 直接写入账号独立的 plist（用于 Hook 中，避免递归）
void DKWriteAccountUserDefault(NSString *key, id value);

// 读取账号独立的 UserDefaults 全部字典（用于 Hook 中，避免递归）
NSDictionary* DKReadAccountUserDefaultsDictionary(void);

// 同步账号的 UserDefaults 到文件
void DKSyncAccountUserDefaults(void);

// 写入完整的账号独立 UserDefaults 字典（用于恢复会话）
void DKWriteAccountUserDefaultsDictionary(NSDictionary *dict);

// 清空当前账号的 UserDefaults 独立 plist（用于 removePersistentDomainForName: Hook）
void DKClearAccountUserDefaults(void);