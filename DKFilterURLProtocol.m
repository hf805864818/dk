//
//  DKFilterURLProtocol.m
//  DK 多开插件
//

#import "DKFilterURLProtocol.h"
#import "DKContentFilterBypass.h"

/// 标记请求已被处理，避免递归
static NSString * const kDKFilterProtocolHandledKey = @"DKFilterProtocolHandled";

@interface DKFilterURLProtocol () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *internalTask;
@property (nonatomic, strong) NSMutableData *accumulatedData;
@end

@implementation DKFilterURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // 避免递归：已标记的请求直接放过
    if ([NSURLProtocol propertyForKey:kDKFilterProtocolHandledKey inRequest:request]) {
        return NO;
    }
    
    // 仅拦截 HTTP/HTTPS 请求
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return NO;
    }
    
    // 跳过 WebSocket 升级请求（Upgrade: websocket）
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *upgrade = headers[@"Upgrade"];
    if (upgrade && [upgrade.lowercaseString containsString:@"websocket"]) {
        return NO;
    }
    
    // 检查是否启用
    if (![DKContentFilterBypass sharedInstance].enabled) {
        return NO;
    }
    
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (void)registerProtocol {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSURLProtocol registerClass:[DKFilterURLProtocol class]];
        NSLog(@"[DK] 🔌 DKFilterURLProtocol 已注册（NSURLProtocol 层敏感词过滤）");
    });
}

+ (void)unregisterProtocol {
    [NSURLProtocol unregisterClass:[DKFilterURLProtocol class]];
    NSLog(@"[DK] 🔌 DKFilterURLProtocol 已注销");
}

+ (BOOL)isRegistered {
    return YES; // 简化实现
}

- (void)startLoading {
    // 创建新请求并标记，避免递归
    NSMutableURLRequest *newRequest = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kDKFilterProtocolHandledKey inRequest:newRequest];
    
    // 使用 ephemeralSessionConfiguration（不使用缓存，不存储 cookie）
    // 不修改 protocolClasses，保持系统默认行为
    // 我们通过 kDKFilterProtocolHandledKey 标记来避免递归
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:self
                                                     delegateQueue:nil];
    self.internalTask = [session dataTaskWithRequest:newRequest];
    self.accumulatedData = [NSMutableData data];
    [self.internalTask resume];
}

- (void)stopLoading {
    [self.internalTask cancel];
    self.internalTask = nil;
    self.accumulatedData = nil;
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    // 透传响应给原始 client
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (!data || data.length == 0) return;
    
    // 🔑 关键：在这里过滤敏感词错误
    NSData *filtered = [[DKContentFilterBypass sharedInstance] processResponseData:data];
    [self.client URLProtocol:self didLoadData:filtered];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
    // 清理
    [session finishTasksAndInvalidate];
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    // 重定向时，标记新请求
    NSMutableURLRequest *redirectRequest = [request mutableCopy];
    [NSURLProtocol removePropertyForKey:kDKFilterProtocolHandledKey inRequest:redirectRequest];
    [self.client URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:response];
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    // 不转发认证挑战给 client！
    // [self.client URLProtocol:didReceiveAuthenticationChallenge:] 内部会调用
    // performDefaultHandlingForAuthenticationChallenge: 到 __NSCFURLLocalSessionConnection，
    // 该私有类不存在此 selector，导致 SIGABRT。
    //
    // 正确做法：直接用 sender 尝试用系统凭证处理，失败则取消
    if ([challenge previousFailureCount] > 0) {
        // 已经失败过，直接取消，避免无限循环
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    } else {
        // 尝试使用挑战 sender 提供的默认凭证
        NSURLCredential *credential = nil;
        NSURLProtectionSpace *space = [challenge protectionSpace];
        
        if (space.authenticationMethod == NSURLAuthenticationMethodServerTrust) {
            // HTTPS 服务器信任：接受所有证书（开发/调试用）
            credential = [NSURLCredential credentialForTrust:space.serverTrust];
        } else {
            // 其他认证方式：尝试从 NSURLCredentialStorage 取凭证
            NSURLCredential *stored = [[NSURLCredentialStorage sharedCredentialStorage]
                                         defaultCredentialForProtectionSpace:space];
            credential = stored;
        }
        
        if (credential) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        } else {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        }
    }
}

@end