#import "DKFileManagerHook.h"
#import "DKAccountManager.h"
#import "DKDataIsolation.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// NSFileManager Hook
// 拦截文件路径操作，将沙盒路径重定向到当前账号数据目录
// ============================================================

@implementation DKFileManagerHook

+ (instancetype)sharedInstance {
    static DKFileManagerHook *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKFileManagerHook alloc] init];
    });
    return instance;
}

- (void)install {
    // Hook 通过 MSHookMessageEx 在 Tweak.x 中实现
    NSLog(@"[DK] FileManager Hook 已安装");
}

- (void)uninstall {
    NSLog(@"[DK] FileManager Hook 已卸载");
}

@end

// ============================================================
// 路径映射工具函数
// ============================================================

static NSString* DKMapPath(NSString *originalPath) {
    if (!originalPath) return nil;
    return [[DKDataIsolation sharedInstance] mappedPathForOriginalPath:originalPath];
}

// ============================================================
// Hook 实现 — 这些函数在 Tweak.x 中被 %hook 调用
// ============================================================

// 用于 %hook 的辅助函数：将 NSFileManager 方法调用路径映射

// 声明外部启动保护函数（定义在 Tweak.x 中）
extern BOOL DKIsStartupGuardActive(void);

// ============================================================
// 微信越狱路径检测绕过
// 微信通过 NSFileManager 直接检查越狱文件/目录是否存在。
// 当检测到越狱路径时，返回一个确定不存在的路径，
// 使 fileExistsAtPath: 等方法返回 NO。
// ============================================================
static BOOL DKIsJailbreakFilePath(NSString *path) {
    if (!path) return NO;
    static NSSet *jailbreakPaths = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        jailbreakPaths = [NSSet setWithArray:@[
            @"/Applications/Cydia.app",
            @"/Applications/Sileo.app",
            @"/Applications/Zebra.app",
            @"/var/jb",
            @"/var/lib/apt",
            @"/var/lib/dpkg",
            @"/var/cache/apt",
            @"/var/log/apt",
            @"/usr/lib/libsubstitute.dylib",
            @"/usr/lib/libsubstrate.dylib",
            @"/usr/lib/libhooker.dylib",
            @"/usr/lib/TweakInject",
            @"/usr/libexec/ssh-keysign",
            @"/usr/sbin/sshd",
            @"/usr/bin/sshd",
            @"/Library/MobileSubstrate",
            @"/Library/PreferenceBundles",
            @"/etc/apt",
            @"/bin/bash",
            @"/.installed_unc0ver",
            @"/.bootstrapped",
            @"/.procursus_strapped",
            @"/private/var/jb",
            @"/private/etc/apt",
            @"/private/var/lib/apt",
        ]];
    });
    // 精确匹配或前缀匹配（目录下的子文件也隐藏）
    for (NSString *jbPath in jailbreakPaths) {
        if ([path isEqualToString:jbPath]) return YES;
        if ([path hasPrefix:[jbPath stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static BOOL DKIsWeChatFileManager(void) {
    static BOOL checked = NO;
    static BOOL isWeChat = NO;
    if (!checked) {
        isWeChat = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.tencent.xin"];
        checked = YES;
    }
    return isWeChat;
}

NSString* DKRemapFilePath(NSString *path) {
    if (!path) return nil;

    // 微信：隐藏越狱文件路径，使 fileExistsAtPath: 返回 NO
    if (DKIsWeChatFileManager() && DKIsJailbreakFilePath(path)) {
        return @"/.nonexistent_jb_path_dk";
    }

    if (DKIsStartupGuardActive()) return path;
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (manager.isSwitching) return path;
    if ([[manager currentAccountName] isEqualToString:[manager defaultAccountName]]) return path;
    NSString *designatedDefault = [manager designatedDefaultAccountName];
    if (designatedDefault && [[manager currentAccountName] isEqualToString:designatedDefault]) return path;
    // DKAccounts/ 目录下的操作不重定向，始终操作真实沙盒
    // 否则 renameAccount/deleteAccount 等账号管理操作会被错误重定向到隔离目录
    // 使用 accountsRootPath 精确前缀匹配，而非 containsString 子串匹配
    NSString *accountsRoot = [[DKAccountManager sharedManager] accountsRootPath];
    if (accountsRoot && [path hasPrefix:accountsRoot]) return path;
    return DKMapPath(path);
}

NSURL* DKRemapFileURL(NSURL *url) {
    if (!url) return nil;
    NSString *path = [url path];
    NSString *mappedPath = DKRemapFilePath(path);
    if ([mappedPath isEqualToString:path]) return url;
    return [NSURL fileURLWithPath:mappedPath];
}