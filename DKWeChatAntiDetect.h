// ============================================================
// DKWeChatAntiDetect — 微信反越狱检测模块
// 仅在微信 (com.tencent.xin) 中激活
// ============================================================

#import <Foundation/Foundation.h>

@interface DKWeChatAntiDetect : NSObject

+ (instancetype)sharedInstance;

/// 安装反检测 Hook（仅对微信生效）
- (void)install;

/// 已安装标识
@property (nonatomic, readonly) BOOL isInstalled;

@end