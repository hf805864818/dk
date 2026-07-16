#import "DKContentFilterBypass.h"

// ============================================================
// TRAE 应用敏感词过滤相关特征
// 基于截图和 IPA 分析推断的响应数据结构
// ============================================================

// 服务端返回的 JSON 中可能出现的错误码
static NSArray<NSNumber *> *kFilteredErrorCodes = nil;

// 敏感词过滤相关的 JSON 字段名
static NSArray<NSString *> *kFilteredJSONKeys = nil;

// 统计计数器
static NSUInteger _bypassCount = 0;

@implementation DKContentFilterBypass {
    BOOL _enabled;
    NSMutableDictionary *_statistics;
}

+ (instancetype)sharedInstance {
    static DKContentFilterBypass *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKContentFilterBypass alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 从 UserDefaults 恢复开关状态（默认开启）
        NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"DK_ContentFilterBypass_Enabled"];
        _enabled = saved ? [saved boolValue] : YES;
        _bypassCount = 0;
        _statistics = [NSMutableDictionary dictionary];
        
        // 初始化需要拦截的错误码
        kFilteredErrorCodes = @[
            @983,   // 敏感词过滤
            @984,   // 可能相关的变体
            @1001,  // 常见的内容审核错误
            @1002,  // 常见的内容审核错误
        ];
        
        // 初始化需要处理的 JSON 字段名
        kFilteredJSONKeys = @[
            @"error_code",
            @"errorCode",
            @"code",
            @"err_code",
            @"errCode",
            @"status_code",
            @"statusCode",
            @"error",
            @"err",
        ];
    }
    return self;
}

#pragma mark - Setup

- (void)setup {
    NSLog(@"[DK] 敏感词过滤绕过模块已初始化");
    NSLog(@"[DK] 拦截错误码: %@", kFilteredErrorCodes);
}

#pragma mark - 响应处理

- (NSDictionary *)processResponseJSON:(NSDictionary *)originalJSON {
    if (!_enabled) return originalJSON;
    if (!originalJSON || ![originalJSON isKindOfClass:[NSDictionary class]]) return originalJSON;
    
    BOOL modified = NO;
    NSMutableDictionary *result = [originalJSON mutableCopy];
    
    // ============================================================
    // 策略 1: 拦截顶层错误码
    // ============================================================
    for (NSString *key in kFilteredJSONKeys) {
        id errorValue = result[key];
        if (errorValue) {
            NSInteger errorCode = 0;
            if ([errorValue isKindOfClass:[NSNumber class]]) {
                errorCode = [errorValue integerValue];
            } else if ([errorValue isKindOfClass:[NSString class]]) {
                errorCode = [errorValue integerValue];
            }
            
            if ([kFilteredErrorCodes containsObject:@(errorCode)]) {
                result[key] = @0;  // 替换为成功
                modified = YES;
                _bypassCount++;
                
                NSLog(@"[DK] 🔓 拦截敏感词错误: %@ -> %ld → 替换为 0", key, (long)errorCode);
            }
        }
    }
    
    // ============================================================
    // 策略 2: 检查嵌套的 error 对象
    // ============================================================
    NSDictionary *errorObj = result[@"error"];
    if ([errorObj isKindOfClass:[NSDictionary class]]) {
        NSNumber *code = errorObj[@"code"];
        if (code && [kFilteredErrorCodes containsObject:code]) {
            [result removeObjectForKey:@"error"];
            [result removeObjectForKey:@"error_message"];
            [result removeObjectForKey:@"error_msg"];
            [result removeObjectForKey:@"message"];
            modified = YES;
            _bypassCount++;
            
            NSLog(@"[DK] 🔓 拦截嵌套 error 对象: code=%@", code);
        }
    }
    
    // ============================================================
    // 策略 3: 检查 data.error_code 嵌套
    // ============================================================
    id dataObj = result[@"data"];
    if ([dataObj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *data = [dataObj mutableCopy];
        for (NSString *key in kFilteredJSONKeys) {
            id errorValue = data[key];
            if (errorValue) {
                NSInteger errorCode = 0;
                if ([errorValue isKindOfClass:[NSNumber class]]) {
                    errorCode = [errorValue integerValue];
                } else if ([errorValue isKindOfClass:[NSString class]]) {
                    errorCode = [errorValue integerValue];
                }
                
                if ([kFilteredErrorCodes containsObject:@(errorCode)]) {
                    data[key] = @0;
                    modified = YES;
                    _bypassCount++;
                    NSLog(@"[DK] 🔓 拦截嵌套 data.%@ %ld", key, (long)errorCode);
                }
            }
        }
        if (modified) {
            result[@"data"] = data;
        }
    }
    
    // ============================================================
    // 策略 4: 检查 SSE 流式响应中的过滤标记
    // ============================================================
    NSString *eventType = result[@"event"];
    if ([eventType isEqualToString:@"error"] || [eventType isEqualToString:@"filtered"]) {
        result[@"event"] = @"message";
        result[@"error_code"] = @0;
        NSLog(@"[DK] 🔓 拦截 SSE 错误事件: %@", eventType);
        modified = YES;
        _bypassCount++;
    }
    
    // 检查 content_filter 标记
    id filterResult = result[@"content_filter"];
    if (filterResult) {
        [result removeObjectForKey:@"content_filter"];
        [result removeObjectForKey:@"filter_reason"];
        [result removeObjectForKey:@"sensitive_words"];
        modified = YES;
        _bypassCount++;
        NSLog(@"[DK] 🔓 移除 content_filter 标记");
    }
    
    // ============================================================
    // 策略 5: 检查消息列表中的敏感词标记
    // ============================================================
    NSArray *messages = result[@"messages"];
    if ([messages isKindOfClass:[NSArray class]]) {
        NSMutableArray *cleanMessages = [NSMutableArray array];
        for (id msg in messages) {
            if ([msg isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *cleanMsg = [msg mutableCopy];
                [cleanMsg removeObjectForKey:@"filtered"];
                [cleanMsg removeObjectForKey:@"sensitive"];
                [cleanMsg removeObjectForKey:@"blocked"];
                [cleanMsg removeObjectForKey:@"error_code"];
                [cleanMessages addObject:cleanMsg];
            } else {
                [cleanMessages addObject:msg];
            }
        }
        result[@"messages"] = cleanMessages;
    }
    
    if (modified) {
        _statistics[@"total_bypass"] = @(_bypassCount);
        _statistics[@"last_bypass_time"] = [NSDate date];
    }
    
    return modified ? [result copy] : originalJSON;
}

- (NSData *)processResponseData:(NSData *)originalData {
    if (!_enabled) return originalData;
    if (!originalData || originalData.length == 0) return originalData;
    
    // 尝试解析 JSON
    NSError *jsonError = nil;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:originalData
                                                 options:NSJSONReadingMutableContainers
                                                   error:&jsonError];
    
    if (jsonError || !jsonObj) {
        // 不是 JSON 数据，尝试文本匹配
        NSString *text = [[NSString alloc] initWithData:originalData encoding:NSUTF8StringEncoding];
        if (text) {
            // 检查是否包含敏感词错误特征
            if ([text containsString:@"error_code\":983"] ||
                [text containsString:@"error_code\": 983"] ||
                [text containsString:@"\"code\":983"] ||
                [text containsString:@"\"code\": 983"] ||
                [text containsString:@"敏感词"]) {
                
                // 替换错误码
                text = [text stringByReplacingOccurrencesOfString:@"\"error_code\":983"
                                                       withString:@"\"error_code\":0"];
                text = [text stringByReplacingOccurrencesOfString:@"\"error_code\": 983"
                                                       withString:@"\"error_code\": 0"];
                text = [text stringByReplacingOccurrencesOfString:@"\"code\":983"
                                                       withString:@"\"code\":0"];
                text = [text stringByReplacingOccurrencesOfString:@"\"code\": 983"
                                                       withString:@"\"code\": 0"];
                
                text = [text stringByReplacingOccurrencesOfString:@"\"error_code\":984"
                                                       withString:@"\"error_code\":0"];
                text = [text stringByReplacingOccurrencesOfString:@"\"code\":984"
                                                       withString:@"\"code\":0"];
                
                _bypassCount++;
                _statistics[@"total_bypass"] = @(_bypassCount);
                
                NSLog(@"[DK] 🔓 文本级拦截敏感词错误码");
                return [text dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
        return originalData;
    }
    
    // JSON 处理
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *processed = [self processResponseJSON:jsonObj];
        if (processed != jsonObj) {
            NSData *newData = [NSJSONSerialization dataWithJSONObject:processed
                                                              options:0
                                                                error:nil];
            if (newData) return newData;
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)jsonObj;
        NSMutableArray *processedArray = [NSMutableArray array];
        BOOL modified = NO;
        
        for (id item in array) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                NSDictionary *processed = [self processResponseJSON:item];
                [processedArray addObject:processed];
                if (processed != item) modified = YES;
            } else {
                [processedArray addObject:item];
            }
        }
        
        if (modified) {
            NSData *newData = [NSJSONSerialization dataWithJSONObject:processedArray
                                                              options:0
                                                                error:nil];
            if (newData) return newData;
        }
    }
    
    return originalData;
}

#pragma mark - 文本检测

- (BOOL)isTextFiltered:(NSString *)text {
    if (!text || text.length == 0) return NO;
    
    // 检查常见敏感词（仅用于调试，不会实际发送）
    // 这里只做简单的模式匹配
    NSArray *debugPatterns = @[
        @"error_code\":983",
        @"error_code\": 983",
        @"敏感词",
        @"content_filter",
    ];
    
    for (NSString *pattern in debugPatterns) {
        if ([text containsString:pattern]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark - 统计

- (NSDictionary *)bypassStatistics {
    return [_statistics copy];
}

#pragma mark - Properties

- (BOOL)enabled {
    return _enabled;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    // 持久化开关状态
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"DK_ContentFilterBypass_Enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[DK] 敏感词过滤绕过: %@", enabled ? @"已启用" : @"已禁用");
}

@end