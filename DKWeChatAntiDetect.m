// ============================================================
// DKWeChatAntiDetect.m — 微信 C 层越狱检测绕过
//
// 策略：鱼目混珠
// - 文件检测：返回"文件不存在"（stat/access/fopen）
// - 进程检测：过滤 sysctl 返回的越狱相关进程名
// - 环境变量：隐藏 DYLD_INSERT_LIBRARIES
//
// 使用 fishhook 的 rebind_symbols 修改 GOT，
// arm64e 完全兼容。
// ============================================================

#import "DKWeChatAntiDetect.h"
#import "fishhook/fishhook.h"
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

// ============================================================
// 越狱检测路径黑名单
// ============================================================
static NSSet<NSString *> *jailbreakPaths(void) {
    static NSSet *paths = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = [NSSet setWithArray:@[
            @"/Applications/Cydia.app",
            @"/Applications/Sileo.app",
            @"/Applications/Zebra.app",
            @"/Applications/Installer.app",
            @"/Library/MobileSubstrate",
            @"/Library/MobileSubstrate/DynamicLibraries",
            @"/usr/lib/libsubstrate.dylib",
            @"/usr/lib/libsubstitute.dylib",
            @"/usr/lib/libhooker.dylib",
            @"/usr/lib/TweakInject",
            @"/usr/bin/ssh",
            @"/usr/bin/sshd",
            @"/usr/sbin/sshd",
            @"/etc/apt",
            @"/etc/ssh/sshd_config",
            @"/private/var/lib/apt",
            @"/private/var/lib/cydia",
            @"/private/var/stash",
            @"/private/var/tmp/cydia.log",
            @"/private/etc/apt",
            @"/bin/bash",
            @"/bin/sh",
            @"/.bootstrapped",
            @"/.installed_unc0ver",
            @"/.installed_odyssey",
            @"/.installed_taurine",
            @"/.installed_dopamine",
            @"/.installed_xina",
            @"/electra",
            @"/.cydia_no_stash",
            @"/jb",
            @"/var/jb",
            @"/var/mobile/Library/Preferences/ABPattern",
            @"/var/containers/Bundle/Application",
        ]];
    });
    return paths;
}

// 判断路径是否越狱相关
static BOOL DKIsJailbreakPath(const char *path) {
    if (!path) return NO;
    NSString *pathStr = [NSString stringWithUTF8String:path];
    if (!pathStr) return NO;

    // 精确匹配
    if ([jailbreakPaths() containsObject:pathStr]) return YES;

    // 前缀匹配（子路径）
    for (NSString *jbPath in jailbreakPaths()) {
        if ([pathStr hasPrefix:jbPath]) return YES;
    }

    // 额外检测：dyld_shared_cache 包含越狱路径
    if ([pathStr containsString:@"Cydia"] ||
        [pathStr containsString:@"Sileo"] ||
        [pathStr containsString:@"MobileSubstrate"] ||
        [pathStr containsString:@"substitute"] ||
        [pathStr containsString:@"libhooker"] ||
        [pathStr containsString:@"TweakInject"] ||
        [pathStr containsString:@"frida"] ||
        [pathStr containsString:@"Dobby"] ||
        [pathStr containsString:@"fishhook"]) {
        return YES;
    }

    return NO;
}

// ============================================================
// 原始函数指针
// ============================================================
static int (*original_stat)(const char *path, struct stat *buf);
static int (*original_lstat)(const char *path, struct stat *buf);
static int (*original_access)(const char *path, int mode);
static FILE* (*original_fopen)(const char *path, const char *mode);
static int (*original_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static char* (*original_getenv)(const char *name);

// ============================================================
// 拦截实现
// ============================================================

static int hooked_stat(const char *path, struct stat *buf) {
    if (DKIsJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return original_stat(path, buf);
}

static int hooked_lstat(const char *path, struct stat *buf) {
    if (DKIsJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return original_lstat(path, buf);
}

static int hooked_access(const char *path, int mode) {
    if (DKIsJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return original_access(path, mode);
}

static FILE* hooked_fopen(const char *path, const char *mode) {
    if (DKIsJailbreakPath(path)) {
        errno = ENOENT;
        return NULL;
    }
    return original_fopen(path, mode);
}

// ============================================================
// sysctl 拦截 — 过滤进程列表中的越狱进程名
// ============================================================
static NSSet<NSString *> *jailbreakProcessNames(void) {
    static NSSet *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"Cydia", @"Sileo", @"Zebra", @"Installer",
            @"sshd", @"dropbear",
            @"frida-server", @"frida-helper",
            @"Dobby", @"substituted", @"libhooker",
        ]];
    });
    return names;
}

static int hooked_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    // 只拦截 KERN_PROC / KERN_PROC_ALL 查询（进程列表）
    // name[0] == CTL_KERN (1), name[1] == KERN_PROC (14) 或 KERN_PROC_ALL (7)
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
// getenv 拦截 — 隐藏 DYLD_INSERT_LIBRARIES
// ============================================================
static char* hooked_getenv(const char *name) {
    if (name && strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) {
        return NULL;
    }
    return original_getenv(name);
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
    NSLog(@"[DK] 🔐 安装微信越狱检测绕过（C 层 fishhook）");

    struct rebinding rebindings[] = {
        {"stat",   hooked_stat,   (void **)&original_stat},
        {"lstat",  hooked_lstat,  (void **)&original_lstat},
        {"access", hooked_access, (void **)&original_access},
        {"fopen",  hooked_fopen,  (void **)&original_fopen},
        {"sysctl", hooked_sysctl, (void **)&original_sysctl},
        {"getenv", hooked_getenv, (void **)&original_getenv},
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));

    NSLog(@"[DK] ✅ 微信越狱检测绕过已安装（6 个 C 函数）");
}

@end