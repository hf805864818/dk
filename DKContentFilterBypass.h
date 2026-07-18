#import <Foundation/Foundation.h>

// ============================================================
// DKContentFilterBypass - 敏感词过滤绕过
//
// 错误 983 分析（来自截图）:
//   "消息可能包含敏感词，请检查后重新发送。(983)"
//
// 触发机制:
//   1. 服务端返回 error_code=983 的 JSON 响应
//   2. 客户端 UI 层解析到 error 后显示粉色错误横幅
//   3. 原始 AI 生成内容被隐藏/丢弃
//
// 绕过策略（多层防护）:
//   Layer 1: Hook NSURLSession 响应，拦截 error 983 的 JSON
//            将 error_code 替换为 0，恢复原始内容
//   Layer 2: Hook SSE/流式响应解析，过滤敏感词标记
//   Layer 3: Hook 客户端本地敏感词预检，跳过输入检查
//   Layer 4: Hook UI 层错误展示，隐藏错误横幅
// ============================================================

@interface DKContentFilterBypass : NSObject

+ (instancetype)sharedInstance;

/// 初始化过滤绕过
- (void)setup;

/// 是否启用敏感词过滤绕过（默认 YES）
@property (nonatomic, assign) BOOL enabled;

/// 处理原始 JSON 响应数据，移除敏感词错误
/// 返回处理后的 JSON 字典
- (NSDictionary *)processResponseJSON:(NSDictionary *)originalJSON;

/// 处理数组类型的 JSON 响应
- (NSArray *)processResponseArray:(NSArray *)originalArray;

/// 处理原始响应数据（NSData 级别）
- (NSData *)processResponseData:(NSData *)originalData;

/// 检查文本是否触发了敏感词（用于调试）
- (BOOL)isTextFiltered:(NSString *)text;

/// 获取被拦截的统计信息
- (NSDictionary *)bypassStatistics;

@end

// ============================================================
// DKFilterProxyDelegate - NSURLSession 代理拦截器
//
// 问题：TRAE 使用 SSE (Server-Sent Events) 流式传输 AI 响应，
// 数据通过 NSURLSessionDataDelegate 的 didReceiveData: 回调逐块到达，
// 而非通过 completionHandler 一次性返回。
// 之前的 Hook 只拦截 completionHandler 路径，对 SSE 流完全无效。
//
// 解决方案：用一个代理对象包裹原始 delegate，
// 在 didReceiveData: 中拦截每个数据块，过滤敏感词错误后再转发。
// ============================================================
@interface DKFilterProxyDelegate : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate, NSURLSessionStreamDelegate>
@property (nonatomic, weak) id originalDelegate;
- (instancetype)initWithOriginalDelegate:(id)originalDelegate;
@end