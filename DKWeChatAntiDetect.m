// ============================================================
// DKWeChatAntiDetect.m — 微信 C 层越狱检测绕过
//
// 策略：
//   1. 过滤进程列表中的越狱进程名（sysctl）
//   2. 过滤 dyld 镜像列表中的越狱 dylib 路径（dyld_get_image_name）
//
// ⚠️ 不 Hook stat/access/fopen/getenv：
// 在 rootless 越狱环境中，libsandy 已 Hook 这些函数用于
// 路径重映射（/var/jb/...）。如果我们再 Hook 同一批函数，
// 会与 libsandy 的路径解析冲突，导致 SIGABRT 闪退。
//
// 文件/路径级别的越狱检测由 ObjC 层 Hook 覆盖。
// ============================================================

#import "DKWeChatAntiDetect.h"
#import <substrate.h>
#import <sys/sysctl.h>
#import <string.h>
#import <dlfcn.h>

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
// dyld_get_image_name Hook — 过滤加载的越狱 dylib 路径
//
// 微信可能遍历 dyld 加载的所有镜像，检查是否包含
// substitute/libhooker/substrate 等越狱框架。
// 返回安全的系统库路径替代越狱 dylib 路径。
// ============================================================
static const char* (*original_dyld_get_image_name)(uint32_t image_index);

static const char* hooked_dyld_get_image_name(uint32_t image_index) {
    const char* name = original_dyld_get_image_name(image_index);
    if (name) {
        if (strstr(name, "substitute") ||
            strstr(name, "libhooker") ||
            strstr(name, "Substrate") ||
            strstr(name, "substrate") ||
            strstr(name, "dk.dylib")) {
            return "/usr/lib/system/libsystem_kernel.dylib";
        }
    }
    return name;
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
    NSLog(@"[DK] 🔐 安装微信越狱检测绕过（sysctl 进程过滤 + dyld 镜像过滤）");

    // iOS 17+ 启用 W^X 内存保护，MSHookFunction 修改代码页可能触发
    // KERN_PROTECTION_FAILURE。在此情况下跳过 C 层 Hook，
    // 越狱检测绕过由 ObjC 层 (DKWeChatJailBreakHook) 覆盖。
    if (@available(iOS 17.0, *)) {
        NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
        if (version.majorVersion >= 17) {
            NSLog(@"[DK] ⚠️ iOS %ld 检测到 W^X 保护，跳过 C 层 Hook，依赖 ObjC 层绕过",
                  (long)version.majorVersion);
            return;
        }
    }

    // 使用 MSHookFunction 替代 fishhook：
    // fishhook 的 rebind_symbols 是全局符号重绑定，会覆盖其他插件的 Hook 链，
    // 导致其他插件 Hook 失效。MSHookFunction 是 Cydia Substrate 的 Hook 机制，
    // 原生支持 Hook 链，多个插件 Hook 同一函数时各层都会被正确调用。
    MSHookFunction((void *)sysctl, (void *)hooked_sysctl, (void **)&original_sysctl);
    MSHookFunction((void *)dyld_get_image_name, (void *)hooked_dyld_get_image_name, (void **)&original_dyld_get_image_name);

    NSLog(@"[DK] ✅ 微信越狱检测绕过已安装（2 个 C 函数：sysctl + dyld_get_image_name，MSHookFunction）");
}

@end