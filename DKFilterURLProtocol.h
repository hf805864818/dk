//
//  DKFilterURLProtocol.h
//  DK 多开插件 — NSURLProtocol 敏感词过滤
//
//  NSURLProtocol 工作在 NSURLSession 之下，拦截所有网络请求。
//  不受 TRAE 内部 PointCastleHook 的 swizzle 干扰。
//

#import <Foundation/Foundation.h>

@interface DKFilterURLProtocol : NSURLProtocol

/// 注册此 Protocol 到 NSURLSession 系统（在 %ctor 中调用）
+ (void)registerProtocol;

/// 注销此 Protocol
+ (void)unregisterProtocol;

/// 是否已注册
+ (BOOL)isRegistered;

@end