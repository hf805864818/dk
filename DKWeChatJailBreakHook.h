// ============================================================
// DKWeChatJailBreakHook.h — 微信 ObjC 层越狱检测方法 Hook
//
// 使用 MSHookMessageEx 拦截微信内部的越狱检测方法。
// 仅在微信（com.tencent.xin）进程中激活，不影响 TRAE。
// ============================================================

#import <Foundation/Foundation.h>

@interface DKWeChatJailBreakHook : NSObject

+ (instancetype)sharedInstance;

/// 安装 MSHookMessageEx 拦截微信越狱检测方法
/// 仅在微信进程中调用
- (void)install;

@end