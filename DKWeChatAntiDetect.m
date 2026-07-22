// ============================================================
// DKWeChatAntiDetect.m — 微信反越狱检测实现
//
// 微信检测越狱的主要手段：
//   1. 自研类 JailBreakHelper / IsJailBreak / JailBroken
//   2. 内核级 sysctlbyname 查询 (KERN_PROC, HW_MACHINE, etc.)
//   3. uname 系统信息查询
//   4. dyld 镜像列表遍历 (_dyld_image_count / _dyld_get_image_name)
//   5. 文件路径检测 (stat/access 对越狱路径)
//   6. NSProcessInfo 环境变量检测
//
// 策略：Hook 微信自身的检测类 + 系统级 API 拦截
// ============================================================

#import "DKWeChatAntiDetect.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "fishhook/fishhook.h"

// ============================================================
// 越狱相关的 sysctl name 前缀
// ============================================================
static BOOL isJailbreakSysctlName(const char *name) {
    if (!name) return NO;
    // 微信用这些 sysctl 查询来检测越狱环境
    // 我们对所有非标准查询做过滤
    static const char *blockedPrefixes[] = {
        "security.mac.",
        "kern.proc.",
        "kern.bootargs",
        "kern.procargs",
        "vm.cs_",
        "security.",
        "kern.exec",
        "kern.secure",
        NULL
    };
    for (int i = 0; blockedPrefixes[i] != NULL; i++) {
        if (strncmp(name, blockedPrefixes[i], strlen(blockedPrefixes[i])) == 0) {
            return YES;
        }
    }
    return NO;
}

// ============================================================
// 原始函数指针
// ============================================================
static int (*original_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_uname)(struct utsname *name);

// ============================================================
// 自定义 sysctlbyname
// ============================================================
static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // 对越狱检测相关的查询返回安全值
    if (name) {
        // 微信查询 kern.proc.pid 来获取进程信息 — 放行
        // 但 kern.procargs / kern.bootargs 等需要拦截
        if (isJailbreakSysctlName(name)) {
            // 返回 0 表示查询失败（进程不存在 / 属性不存在）
            if (oldp && oldlenp) {
                memset(oldp, 0, *oldlenp);
            }
            return 0;
        }
    }
    return original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ============================================================
// 自定义 uname — 隐藏越狱内核信息
// ============================================================
static int hooked_uname(struct utsname *name) {
    int ret = original_uname(name);
    if (ret == 0 && name) {
        // 微信可能检查 version/sysname 中的越狱特征
        // 这里我们不做修改，因为修改 uname 可能影响其他正常功能
        // 主要依赖 sysctl 拦截和微信类 Hook
    }
    return ret;
}

// ============================================================
// dyld 镜像遍历 Hook — 隐藏 dk.dylib
// ============================================================
static uint32_t (*original__dyld_image_count)(void);
static const char *(*original__dyld_get_image_name)(uint32_t index);

static uint32_t hooked__dyld_image_count(void) {
    return original__dyld_image_count();
}

static const char *hooked__dyld_get_image_name(uint32_t index) {
    const char *name = original__dyld_get_image_name(index);
    if (name && strstr(name, "dk.dylib")) {
        // 隐藏 dk.dylib — 返回一个无害的路径
        return "/usr/lib/libobjc.A.dylib";
    }
    return name;
}

// ============================================================
// 实现
// ============================================================
@implementation DKWeChatAntiDetect {
    BOOL _isInstalled;
}

+ (instancetype)sharedInstance {
    static DKWeChatAntiDetect *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isInstalled = NO;
    }
    return self;
}

- (BOOL)isInstalled {
    return _isInstalled;
}

- (void)install {
    if (_isInstalled) return;
    
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.tencent.xin"]) {
        NSLog(@"[DK] 反检测模块仅对微信生效，跳过 (当前: %@)", bundleID);
        return;
    }
    
    NSLog(@"[DK] 🔐 安装微信反越狱检测 Hook...");
    
    // ============================================
    // 1. Hook 微信自研越狱检测类
    // ============================================
    [self _hookWeChatJailbreakClasses];
    
    // ============================================
    // 2. fishhook sysctlbyname
    // ============================================
    struct rebinding rebindings[] = {
        {"sysctlbyname", hooked_sysctlbyname, (void **)&original_sysctlbyname},
        {"uname",        hooked_uname,        (void **)&original_uname},
        {"_dyld_image_count",     hooked__dyld_image_count,     (void **)&original__dyld_image_count},
        {"_dyld_get_image_name",  hooked__dyld_get_image_name,  (void **)&original__dyld_get_image_name},
    };
    rebind_symbols(rebindings, 4);
    NSLog(@"[DK] ✅ fishhook 反检测 C 函数已安装 (sysctlbyname/uname/dyld x2)");
    
    _isInstalled = YES;
    NSLog(@"[DK] 🔐 微信反越狱检测已激活");
}

#pragma mark - 微信自研类 Hook

- (void)_hookWeChatJailbreakClasses {
    // 所有已知越狱检测类的 Hook 在 _hookWeChatPluginDetection 中统一处理
    [self _hookWeChatPluginDetection];
    
    // ============================================
    // NSProcessInfo — 环境变量检测
    // ============================================
    [self _hookNSProcessInfo];
}

- (void)_hookWeChatPluginDetection {
    // 微信可能通过遍历已安装的 MobileSubstrate 插件来检测越狱
    // 常见的检测方法：HasInstallJailbreakPlugin:
    // 我们 hook 已知的检测类，不做全量类枚举（性能和安全考虑）
    
    // 尝试 hook 常见的检测方法名
    NSArray *candidateSelectors = @[
        @"HasInstallJailbreakPlugin:",
        @"hasInstallJailbreakPlugin:",
        @"isJailbreak",
        @"isJailBreak",
        @"jailbroken",
        @"jailBroken",
        @"checkJailbreak",
        @"checkIsJailbreak",
        @"deviceIsJailbroken",
        @"isDeviceJailbreak",
    ];
    
    // 已知可能包含越狱检测的微信类名
    NSArray *candidateClasses = @[
        @"JailBreakHelper",
        @"IsJailBreak",
        @"JailBroken",
        @"WCDeviceUtil",
        @"WCUtility",
        @"MMDeviceUtil",
        @"CUtility",
        @"DeviceInfo",
        @"SystemUtil",
        @"MMSystemUtil",
        @"WCSecurityUtil",
        @"SecurityUtil",
    ];
    
    for (NSString *className in candidateClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (!cls) continue;
        
        for (NSString *selName in candidateSelectors) {
            SEL sel = NSSelectorFromString(selName);
            [self _tryHookMethodReturningNO:cls selector:sel isClassMethod:YES];
            [self _tryHookMethodReturningNO:cls selector:sel isClassMethod:NO];
        }
    }
}

/// 尝试 hook 一个返回 BOOL 的方法，让其始终返回 NO
/// 使用 MSHookMessageEx 进行安全替换
- (void)_tryHookMethodReturningNO:(Class)cls selector:(SEL)sel isClassMethod:(BOOL)isClassMethod {
    Class targetClass = isClassMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(targetClass, sel);
    if (!method) return;
    
    // 获取返回类型
    char returnType[256];
    method_getReturnType(method, returnType, sizeof(returnType));
    
    // 只处理返回 BOOL/Bool 的方法
    if (strcmp(returnType, "B") != 0 && strcmp(returnType, "c") != 0) return;
    
    // 获取参数数量
    unsigned int argCount = method_getNumberOfArguments(method);
    
    // 使用 MSHookMessageEx 替换
    // 对于无参方法：直接替换为返回 NO
    // 对于有参方法：返回 NO 并忽略参数
    
    if (argCount == 2) {
        // 无参方法 (self, _cmd)
        IMP newIMP = imp_implementationWithBlock(^BOOL(id _self, SEL _cmd) {
            return NO;
        });
        method_setImplementation(method, newIMP);
    } else {
        // 有参方法 — 使用 MSHookMessageEx
        // 必须先获取原始实现
        IMP original = method_getImplementation(method);
        
        MSHookMessageEx(targetClass, sel, imp_implementationWithBlock(^BOOL(id _self, SEL _cmd, ...) {
            return NO;
        }), (IMP *)&original);
    }
}

- (void)_hookNSProcessInfo {
    // Hook NSProcessInfo.arguments 和 environment
    Class processInfoClass = objc_getClass("NSProcessInfo");
    if (!processInfoClass) return;
    
    // Hook -arguments — 过滤掉越狱环境变量
    {
        SEL sel = @selector(arguments);
        Method method = class_getInstanceMethod(processInfoClass, sel);
        if (method) {
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^NSArray *(id _self, SEL _cmd) {
                NSArray *args = ((NSArray *(*)(id, SEL))original)(_self, sel);
                NSMutableArray *filtered = [NSMutableArray array];
                for (NSString *arg in args) {
                    if (![arg containsString:@"MobileSubstrate"] &&
                        ![arg containsString:@"SubstrateLoader"] &&
                        ![arg containsString:@"DYLD_INSERT_LIBRARIES"] &&
                        ![arg containsString:@"jbroot"] &&
                        ![arg containsString:@"checkra1n"]) {
                        [filtered addObject:arg];
                    }
                }
                return [filtered copy];
            });
            method_setImplementation(method, replacement);
        }
    }
    
    // Hook -environment — 过滤越狱环境变量
    {
        SEL sel = @selector(environment);
        Method method = class_getInstanceMethod(processInfoClass, sel);
        if (method) {
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^NSDictionary *(id _self, SEL _cmd) {
                NSDictionary *env = ((NSDictionary *(*)(id, SEL))original)(_self, sel);
                NSMutableDictionary *filtered = [env mutableCopy];
                [filtered removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
                [filtered removeObjectForKey:@"DYLD_FORCE_FLAT_NAMESPACE"];
                [filtered removeObjectForKey:@"JB_ROOT"];
                [filtered removeObjectForKey:@"SUBSTRATE_INSERT_LIBRARIES"];
                return [filtered copy];
            });
            method_setImplementation(method, replacement);
        }
    }
    
    NSLog(@"[DK] ✅ NSProcessInfo 环境变量过滤已安装");
}

@end