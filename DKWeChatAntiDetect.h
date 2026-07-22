// ============================================================
// DKWeChatAntiDetect.h — 微信 C 层越狱检测绕过
//
// 使用 fishhook 拦截 POSIX 函数，过滤越狱相关路径和进程。
// arm64e 兼容（fishhook 修改 GOT 数据段，不修改代码页）。
//
// 仅在微信（com.tencent.xin）进程中激活，不影响 TRAE。
// ============================================================

#import <Foundation/Foundation.h>

@interface DKWeChatAntiDetect : NSObject

+ (instancetype)sharedInstance;

/// 安装 fishhook C 函数拦截（stat/access/fopen/sysctl/getenv）
/// 仅在微信进程中调用
- (void)install;

@end