// ============================================================
// DKWeChatAntiDetect.m — 微信 C 层越狱检测绕过
//
// 策略：仅过滤进程列表中的越狱进程名（sysctl）。
//
// ⚠️ 不 Hook stat/access/fopen/getenv：
// 在 rootless 越狱环境中，libsandy 已 Hook 这些函数用于
// 路径重映射（/var/jb/...）。如果我们再 Hook 同一批函数，
// 会与 libsandy 的路径解析冲突，导致 SIGABRT 闪退。
//
// 文件/路径级别的越狱检测由 ObjC 层 Hook 覆盖。
// ============================================================

#import "DKWeChatAntiDetect.h"
#import "fishhook/fishhook.h"
#import <sys/sysctl.h>
#import <string.h>

// ============================================================
// 越狱进程名黑名单
// ============================================================
static NSSet<NSString *> *jailbreakProcessNames(void) {
    static NSSet *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"Cydia", @"Sileo", @"Zebra", @"Installer",
            @"sshd", @"dropbear",
            @"frida-server", @"frida-helper",
            @"substituted", @"libhooker",
        ]];
    });
    return names;
}

// ============================================================
// 原始函数指针
// ============================================================
static int (*original_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

// ============================================================
// sysctl Hook — 过滤进程列表中的越狱进程名
// ============================================================
static int hooked_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    // 只拦截 KERN_PROC / KERN_PROC_ALL 查询（进程列表）
    if (ret == 0 && oldp && oldlenp && *oldlenp > 0 &&
        namelen >= 2 && name[0] == CTL_KERN &&
        (name[1] == KERN_PROC || name[1] == KERN_PROC_ALL)) {

        struct kinfo_proc *procs = (struct kinfo_proc *)oldp;
        size_t count = *oldlenp / sizeof(struct kinfo_proc);
        size_t writeIdx = 0;

        for (size_t i = 0; i < count; i++) {
            NSString *procName = [NSString stringWithUTF8String:procs[i].kp_proc.p_comm];
            if (![jailbreakProcessNames() containsObject:procName]) {
                if (writeIdx != i) {
                    procs[writeIdx] = procs[i];
                }
                writeIdx++;
            }
        }

        *oldlenp = writeIdx * sizeof(struct kinfo_proc);
    }

    return ret;
}

// ============================================================
// DKWeChatAntiDetect 实现
// ============================================================
@implementation DKWeChatAntiDetect

+ (instancetype)sharedInstance {
    static DKWeChatAntiDetect *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)install {
    NSLog(@"[DK] 🔐 安装微信越狱检测绕过（sysctl 进程过滤）");

    struct rebinding rebindings[] = {
        {"sysctl", hooked_sysctl, (void **)&original_sysctl},
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));

    NSLog(@"[DK] ✅ 微信越狱检测绕过已安装（1 个 C 函数：sysctl）");
}

@end