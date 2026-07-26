// ============================================================
// DKWeChatAntiDetect.h — 微信 C 层越狱检测绕过
//
// 使用 MSHookFunction 拦截 sysctl + dyld_get_image_name，
// 过滤越狱进程名和越狱 dylib 路径。
// iOS 17+ 自动跳过 C 层 Hook，依赖 ObjC 层（DKWeChatJailBreakHook）覆盖。
//
// 仅在微信（com.tencent.xin）进程中激活，不影响 TRAE。
// ============================================================

#import <Foundation/Foundation.h>

@interface DKWeChatAntiDetect : NSObject

+ (instancetype)sharedInstance;

/// 安装 MSHookFunction C 函数拦截（sysctl + dyld + fork）
/// 仅在微信进程中调用
- (void)install;

@end