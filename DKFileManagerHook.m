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

NSString* DKRemapFilePath(NSString *path) {
    if (DKIsStartupGuardActive()) return path;
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if (manager.isSwitching) return path;
    if ([[manager currentAccountName] isEqualToString:[manager defaultAccountName]]) return path;
    NSString *designatedDefault = [manager designatedDefaultAccountName];
    if (designatedDefault && [[manager currentAccountName] isEqualToString:designatedDefault]) return path;
    return DKMapPath(path);
}

NSURL* DKRemapFileURL(NSURL *url) {
    if (!url) return nil;
    NSString *path = [url path];
    NSString *mappedPath = DKRemapFilePath(path);
    if ([mappedPath isEqualToString:path]) return url;
    return [NSURL fileURLWithPath:mappedPath];
}