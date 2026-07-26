// ============================================================
// DKWeChatJailBreakHook.m — 微信 ObjC 层越狱检测方法 Hook
//
// 策略：
// 拦截微信内部可能存在的越狱检测方法，返回 "未越狱"。
// 由于微信版本迭代频繁，类名和方法名可能变化，
// 使用 MSHookMessageEx 动态查找并 Hook。
//
// 仅在微信（com.tencent.xin）进程中激活，不影响 TRAE。
// ============================================================

#import "DKWeChatJailBreakHook.h"
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================
// 辅助：Safe Hook — 类不存在时静默跳过
// ============================================================
static BOOL DKSafeHook(NSString *className, NSString *selName, IMP newImp, IMP *origImp) {
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) {
        NSLog(@"[DK] 🔍 %@ 不存在，跳过 Hook", className);
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        method = class_getClassMethod(cls, sel);
    }
    if (!method) {
        NSLog(@"[DK] 🔍 %@.%@ 不存在，跳过 Hook", className, selName);
        return NO;
    }
    MSHookMessageEx(cls, sel, newImp, origImp);
    NSLog(@"[DK] ✅ 已 Hook %@.%@", className, selName);
    return YES;
}

// ============================================================
// Hook 1: 通用越狱检测方法 — isJailbroken / isJailBreak
// 微信可能在多个类中实现此方法（CUtility / WCUtility / SettingUtil 等）
// ============================================================

static BOOL (*original_isJailbroken)(id self, SEL _cmd);

static BOOL hooked_isJailbroken(id self, SEL _cmd) {
    NSLog(@"[DK] 🛡️ isJailbroken 被调用 → 返回 NO");
    return NO;
}

// ============================================================
// Hook 2: 文件检测返回 — 可能返回越狱文件路径
// ============================================================

static id (*original_checkJailbreak)(id self, SEL _cmd);

static id hooked_checkJailbreak(id self, SEL _cmd) {
    return nil;
}

// ============================================================
// Hook 4: Substrate / Substitrate 检测
// 微信可能检测是否有 Substrate 加载
// ============================================================

static BOOL (*original_hasTweakInjected)(id self, SEL _cmd);

static BOOL hooked_hasTweakInjected(id self, SEL _cmd) {
    return NO;
}

// ============================================================
// Hook 5: 调试器检测 — 微信可能检测是否被调试
// ============================================================

static BOOL (*original_isBeingDebugged)(id self, SEL _cmd);

static BOOL hooked_isBeingDebugged(id self, SEL _cmd) {
    return NO;
}

// ============================================================
// Hook 6: URL Scheme 检测 — 检测 cydia:// 等
// ============================================================

static BOOL (*original_canOpenURLForJailbreak)(id self, SEL _cmd, id url);

static BOOL hooked_canOpenURLForJailbreak(id self, SEL _cmd, id url) {
    NSString *urlStr = nil;
    if ([url isKindOfClass:[NSURL class]]) {
        urlStr = [(NSURL *)url absoluteString];
    } else if ([url isKindOfClass:[NSString class]]) {
        urlStr = (NSString *)url;
    }

    if ([urlStr containsString:@"cydia://"] ||
        [urlStr containsString:@"sileo://"] ||
        [urlStr containsString:@"zbra://"]) {
        NSLog(@"[DK] 🛡️ 越狱 URL Scheme 检测 → 返回 NO");
        return NO;
    }

    // 修复：original 为 NULL 时（未能 Hook 到原函数），返回 YES 而非 NO。
    // 返回 NO 会导致所有 URL Scheme 检测失败，其他插件依赖的合法 URL
    // 跳转（如第三方登录、支付回调）全部被拒绝。
    return original_canOpenURLForJailbreak ? original_canOpenURLForJailbreak(self, _cmd, url) : YES;
}

// ============================================================
// Hook 7: 动态库检测 — 检测是否加载了越狱 dylib
// ============================================================

static BOOL (*original_isJailbreakDylibLoaded)(id self, SEL _cmd);

static BOOL hooked_isJailbreakDylibLoaded(id self, SEL _cmd) {
    return NO;
}

// ============================================================
// Hook 8: 系统环境异常检测 — 微信新版可能使用的方法名
// 对应截图中的 "系统环境可能存在异常" 弹窗
// ============================================================

static BOOL (*original_isSystemEnvAbnormal)(id self, SEL _cmd);

static BOOL hooked_isSystemEnvAbnormal(id self, SEL _cmd) {
    return NO;
}

static id (*original_checkSystemEnvironment)(id self, SEL _cmd);

static id hooked_checkSystemEnvironment(id self, SEL _cmd) {
    return nil;
}

// ============================================================
// Hook 9: 越狱插件检测 — HasInstallJailbreakPlugin
// 微信检测设备上是否安装了任何越狱插件（不限 DK）
// ============================================================

static BOOL (*original_HasInstallJailbreakPlugin)(id self, SEL _cmd);

static BOOL hooked_HasInstallJailbreakPlugin(id self, SEL _cmd) {
    NSLog(@"[DK] 🛡️ HasInstallJailbreakPlugin 被调用 → 返回 NO");
    return NO;
}

// ============================================================
// Hook 10: 可疑越狱模块检测 — getJailbreakSuspiciousModules
// 微信新版主力检测手段，返回已加载的可疑越狱 dylib 列表
// ============================================================

static id (*original_getJailbreakSuspiciousModules)(id self, SEL _cmd);

static id hooked_getJailbreakSuspiciousModules(id self, SEL _cmd) {
    NSLog(@"[DK] 🛡️ getJailbreakSuspiciousModules 被调用 → 返回空数组");
    return @[];
}

// ============================================================
// Hook 11: 文件完整性检查绕过 — BypassFileCheckB:
// 微信可能校验自身 dylib/二进制文件是否被篡改
// ============================================================

static void (*original_BypassFileCheckB)(id self, SEL _cmd, id arg);

static void hooked_BypassFileCheckB(id self, SEL _cmd, id arg) {
    NSLog(@"[DK] 🛡️ BypassFileCheckB: 被调用 → 跳过文件检查");
    return;
}

// ============================================================
// Hook 12: 版本检查绕过 — CheckAllVersion
// 微信可能检测客户端版本号是否官方，暴露 DK 插件信息
// ============================================================

static id (*original_CheckAllVersion)(id self, SEL _cmd);

static id hooked_CheckAllVersion(id self, SEL _cmd) {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"8.0.50";
    NSLog(@"[DK] 🛡️ CheckAllVersion 被调用 → 返回 %@", version);
    return version;
}

// ============================================================
// Hook 13: 人脸/面容检测绕过 — _bypassWCFace
// 微信可能在人脸认证流程中触发额外的安全检测
// ============================================================

static BOOL (*original_bypassWCFace)(id self, SEL _cmd);

static BOOL hooked_bypassWCFace(id self, SEL _cmd) {
    NSLog(@"[DK] 🛡️ _bypassWCFace 被调用 → 返回 YES（跳过人脸检测）");
    return YES;
}

// ============================================================
// DKWeChatJailBreakHook 实现
// ============================================================
@implementation DKWeChatJailBreakHook

+ (instancetype)sharedInstance {
    static DKWeChatJailBreakHook *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)install {
    NSLog(@"[DK] 🔐 安装微信越狱检测绕过（ObjC 层 MSHookMessageEx）");

    // 按优先级从高到低尝试 Hook：
    //
    // 微信的类名可能因版本而异，常见命名模式：
    //   - CUtility / WCUtility / MMUtility
    //   - SettingUtil / WCSettingUtil
    //   - WCDeviceInfo / DeviceInfo
    //   - WCAccountLoginControlLogic（登录流程）
    //
    // 方法名常见模式：
    //   - isJailbroken / isJailBreak / isJailBroken
    //   - hasJailbreak / checkJailbreak
    //   - hasTweakInjected / isTweakInjected

    // === 通用越狱检测方法 ===
    NSArray *jailbreakCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"SettingUtil", @"WCSettingUtil",
        @"WCDeviceInfo", @"DeviceInfo",
        @"WCCrashBlockHandler", @"CrashBlockHandler",
        @"WCAntiCheat", @"AntiCheatLogic",
        @"WCSecurityManager", @"SecurityManager",
    ];

    NSArray *jailbreakCheckSelectors = @[
        @"isJailbroken", @"isJailBreak", @"isJailBroken",
        @"hasJailbreak", @"checkJailbreak",
        @"isDeviceJailbroken", @"deviceIsJailbroken",
    ];

    for (NSString *className in jailbreakCheckClasses) {
        for (NSString *selName in jailbreakCheckSelectors) {
            DKSafeHook(className, selName, (IMP)hooked_isJailbroken, (IMP *)&original_isJailbroken);
        }
    }

    // === 调试器检测 ===
    NSArray *debugCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
    ];
    NSArray *debugCheckSelectors = @[
        @"isBeingDebugged", @"isDebugged",
        @"isDebuggerAttached",
    ];
    for (NSString *className in debugCheckClasses) {
        for (NSString *selName in debugCheckSelectors) {
            DKSafeHook(className, selName, (IMP)hooked_isBeingDebugged, (IMP *)&original_isBeingDebugged);
        }
    }

    // === URL Scheme 检测 ===
    // ⚠️ 已移除 UIApplication canOpenURL: Hook。
    // 原因：微信人脸认证使用内部 URL Scheme 进行摄像头/活体检测通信，
    // MSHookMessageEx 对 canOpenURL: 的 Hook 与 Logos 的 UIApplication
    // %hook 块形成 Hook 链冲突，主线程触发 SIGBUS (KERN_PROTECTION_FAILURE)。
    // URL Scheme 级越狱检测已由 sysctl 进程过滤和 isJailbroken 方法 Hook 覆盖，
    // 移除此 Hook 不会降低防检测效果。
    // DKSafeHook(@"UIApplication", @"canOpenURL:", (IMP)hooked_canOpenURLForJailbreak, (IMP *)&original_canOpenURLForJailbreak);

    // === 动态库检测 ===
    NSArray *dylibCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
    ];
    NSArray *dylibCheckSelectors = @[
        @"isJailbreakDylibLoaded", @"hasJailbreakDylib",
        @"checkDylibInjection", @"isDylibInjected",
    ];
    for (NSString *className in dylibCheckClasses) {
        for (NSString *selName in dylibCheckSelectors) {
            DKSafeHook(className, selName, (IMP)hooked_isJailbreakDylibLoaded, (IMP *)&original_isJailbreakDylibLoaded);
        }
    }

    // === Tweak 注入检测（微信可能检测是否有 Substrate/Substitute 加载） ===
    NSArray *tweakCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
    ];
    NSArray *tweakCheckSelectors = @[
        @"hasTweakInjected", @"isTweakInjected",
    ];
    for (NSString *className in tweakCheckClasses) {
        for (NSString *selName in tweakCheckSelectors) {
            DKSafeHook(className, selName, (IMP)hooked_hasTweakInjected, (IMP *)&original_hasTweakInjected);
        }
    }

    // === 文件检测返回 ===
    DKSafeHook(@"CUtility", @"checkJailbreakFiles", (IMP)hooked_checkJailbreak, (IMP *)&original_checkJailbreak);
    DKSafeHook(@"WCUtility", @"checkJailbreakFiles", (IMP)hooked_checkJailbreak, (IMP *)&original_checkJailbreak);

    // === 系统环境异常检测（微信新版安全检测方法） ===
    NSArray *envCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
        @"WCSecurityLogic", @"MMSecurityCheck",
        @"WCAccountSafetyMgr", @"WCSafetyMgr",
        @"WCRiskManager", @"MMRiskManager",
        @"WCDeviceCheck", @"MMDeviceCheck",
    ];
    NSArray *envCheckSelectors = @[
        @"isSystemEnvironmentAbnormal", @"isSystemEnvAbnormal",
        @"checkSystemEnvironment", @"checkEnvironment",
        @"isDeviceCompromised", @"checkDeviceSecurity",
        @"hasSecurityRisk", @"checkSecurityRisk",
        @"isAbnormalEnvironment", @"checkAbnormalEnv",
        @"isRiskEnvironment", @"isEnvRisk",
    ];
    for (NSString *className in envCheckClasses) {
        for (NSString *selName in envCheckSelectors) {
            DKSafeHook(className, selName, (IMP)hooked_isSystemEnvAbnormal, (IMP *)&original_isSystemEnvAbnormal);
        }
    }

    // === checkSystemEnvironment 返回 nil 的变体 ===
    NSArray *envCheckClasses2 = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
        @"WCSecurityLogic", @"MMSecurityCheck",
    ];
    for (NSString *className in envCheckClasses2) {
        DKSafeHook(className, @"checkSystemEnvironment", (IMP)hooked_checkSystemEnvironment, (IMP *)&original_checkSystemEnvironment);
        DKSafeHook(className, @"checkEnvironment", (IMP)hooked_checkSystemEnvironment, (IMP *)&original_checkSystemEnvironment);
        DKSafeHook(className, @"getSecurityRiskInfo", (IMP)hooked_checkSystemEnvironment, (IMP *)&original_checkSystemEnvironment);
        DKSafeHook(className, @"getAbnormalEnvInfo", (IMP)hooked_checkSystemEnvironment, (IMP *)&original_checkSystemEnvironment);
    }

    // === 越狱插件检测（微信新版主力检测手段） ===
    NSArray *pluginCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
        @"WCSecurityLogic", @"MMSecurityCheck",
        @"WCDeviceInfo", @"DeviceInfo",
    ];
    for (NSString *className in pluginCheckClasses) {
        DKSafeHook(className, @"HasInstallJailbreakPlugin:",
                   (IMP)hooked_HasInstallJailbreakPlugin,
                   (IMP *)&original_HasInstallJailbreakPlugin);
    }

    // === 可疑越狱模块检测（返回空数组） ===
    NSArray *moduleCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
        @"WCSecurityLogic", @"MMSecurityCheck",
    ];
    NSArray *moduleCheckSelectors = @[
        @"getJailbreakSuspiciousModules",
        @"jailbreakSuspiciousModules",
        @"suspiciousModules",
        @"getSuspiciousModules",
    ];
    for (NSString *className in moduleCheckClasses) {
        for (NSString *selName in moduleCheckSelectors) {
            DKSafeHook(className, selName,
                       (IMP)hooked_getJailbreakSuspiciousModules,
                       (IMP *)&original_getJailbreakSuspiciousModules);
        }
    }

    // === 文件完整性检查绕过 ===
    NSArray *fileCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
        @"WCSecurityLogic", @"MMSecurityCheck",
        @"WCAccountSecurityMgr", @"WCAccountSafetyMgr",
    ];
    for (NSString *className in fileCheckClasses) {
        DKSafeHook(className, @"BypassFileCheckB:",
                   (IMP)hooked_BypassFileCheckB,
                   (IMP *)&original_BypassFileCheckB);
    }

    // === 版本检查绕过 ===
    NSArray *versionCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"MMContext", @"WCContext",
        @"SettingUtil", @"WCSettingUtil",
    ];
    NSArray *versionCheckSelectors = @[
        @"CheckAllVersion", @"checkAllVersion",
        @"getVersion", @"currentVersion",
    ];
    for (NSString *className in versionCheckClasses) {
        for (NSString *selName in versionCheckSelectors) {
            DKSafeHook(className, selName,
                       (IMP)hooked_CheckAllVersion,
                       (IMP *)&original_CheckAllVersion);
        }
    }

    // === 人脸/面容检测绕过 ===
    NSArray *faceCheckClasses = @[
        @"CUtility", @"WCUtility", @"MMUtility",
        @"WCSecurityManager", @"SecurityManager",
        @"WCSecurityLogic", @"MMSecurityCheck",
        @"WCFaceCheckMgr", @"WCFaceAuthMgr",
        @"WCAccountSafetyMgr",
    ];
    NSArray *faceCheckSelectors = @[
        @"_bypassWCFace", @"bypassWCFace",
        @"bypassFaceCheck", @"bypassFaceAuth",
        @"skipFaceCheck", @"skipFaceAuth",
    ];
    for (NSString *className in faceCheckClasses) {
        for (NSString *selName in faceCheckSelectors) {
            DKSafeHook(className, selName,
                       (IMP)hooked_bypassWCFace,
                       (IMP *)&original_bypassWCFace);
        }
    }

    NSLog(@"[DK] ✅ 微信越狱检测绕过已安装（ObjC 层，含 13 类 Hook：越狱检测 + 调试器 + 动态库 + Tweak + 文件 + 环境异常 + 插件检测 + 模块检测 + 文件完整性 + 版本检查 + 人脸绕过）");
}

@end