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
        
        // 初始化需要拦截的错误码（基于 TRAE 错误码体系分析）
        kFilteredErrorCodes = @[
            @983,   // 敏感词过滤（主要错误码）
            @984,   // 敏感词过滤变体
            @1001,  // 常见内容审核错误
            @1002,  // 常见内容审核错误
            @403,   // 内容安全策略阻止
            @2001,  // 企业版内容过滤
            @2002,  // 企业版内容过滤
            @2003,  // 企业版内容过滤
            @3001,  // 风险请求拦截
            @3002,  // 防火墙拦截
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
            @"result_code",
            @"resultCode",
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
    
    // 检查 SSE 流式响应中的 content_filter_warning 字段
    id filterWarning = result[@"content_filter_warning"];
    if (filterWarning) {
        [result removeObjectForKey:@"content_filter_warning"];
        [result removeObjectForKey:@"contentFilterWarning"];
        [result removeObjectForKey:@"isTruncated"];
        modified = YES;
        _bypassCount++;
        NSLog(@"[DK] 🔓 移除 content_filter_warning 标记");
    }
    
    // ============================================================
    // 策略 4.5: 检查 choices[].finish_reason — OpenAI 兼容 SSE 格式
    // TRAE 使用 OpenAI 兼容的 SSE 流式响应格式：
    // {"choices":[{"delta":{...},"finish_reason":"content_filter"}]}
    // 当 finish_reason 为 content_filter/sensitive/moderation 时，
    // 表示 AI 回复被内容审核拦截，需要替换为 stop 或 null。
    // ============================================================
    NSArray *choices = result[@"choices"];
    if ([choices isKindOfClass:[NSArray class]]) {
        BOOL choiceModified = NO;
        NSMutableArray *mutableChoices = [choices mutableCopy];
        for (NSUInteger i = 0; i < mutableChoices.count; i++) {
            NSDictionary *choice = mutableChoices[i];
            if (![choice isKindOfClass:[NSDictionary class]]) continue;
            
            NSString *finishReason = choice[@"finish_reason"];
            if ([finishReason isKindOfClass:[NSString class]]) {
                NSString *lower = [finishReason lowercaseString];
                if ([lower isEqualToString:@"content_filter"] ||
                    [lower isEqualToString:@"sensitive"] ||
                    [lower isEqualToString:@"moderation"] ||
                    [lower isEqualToString:@"blocked"]) {
                    NSMutableDictionary *mutableChoice = [choice mutableCopy];
                    mutableChoice[@"finish_reason"] = @"stop";
                    mutableChoice[@"content_filter"] = @NO;
                    [mutableChoice removeObjectForKey:@"content_filter_results"];
                    mutableChoices[i] = mutableChoice;
                    choiceModified = YES;
                    _bypassCount++;
                    NSLog(@"[DK] 🔓 拦截 choices[%lu].finish_reason: %@", (unsigned long)i, finishReason);
                }
            }
            
            // 检查 choices[].content_filter_results
            if (choice[@"content_filter_results"]) {
                NSMutableDictionary *mutableChoice = [choice mutableCopy];
                [mutableChoice removeObjectForKey:@"content_filter_results"];
                mutableChoices[i] = mutableChoice;
                choiceModified = YES;
                _bypassCount++;
                NSLog(@"[DK] 🔓 移除 choices[%lu].content_filter_results", (unsigned long)i);
            }
        }
        if (choiceModified) {
            result[@"choices"] = mutableChoices;
            modified = YES;
        }
    }
    
    // 检查 error_message 字段中的敏感词提示
    NSString *errorMessage = result[@"error_message"];
    if (errorMessage && [errorMessage containsString:@"敏感词"]) {
        [result removeObjectForKey:@"error_message"];
        [result removeObjectForKey:@"errorMessage"];
        [result removeObjectForKey:@"error_code"];
        [result removeObjectForKey:@"errorCode"];
        result[@"error_code"] = @0;
        modified = YES;
        _bypassCount++;
        NSLog(@"[DK] 🔓 移除敏感词 error_message: %@", errorMessage);
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
    
    // ============================================================
    // 策略 6: 深度递归扫描（终极兜底）
    //
    // 以上策略都是基于已知结构的定点检查，
    // 但 TRAE 可能有未知的嵌套结构（如 data.data.error_code）。
    // 此策略递归遍历整个 JSON 树，在任何层级
    // 发现错误码 983 都立即替换为 0。
    //
    // 注意：为了性能，只在前面的策略都没命中时才执行深度扫描。
    // ============================================================
    if (!modified) {
        id deepResult = [self deepScanAndFix:result];
        if (deepResult != result) {
            modified = YES;
            result = deepResult;
        }
    }
    
    if (modified) {
        _statistics[@"total_bypass"] = @(_bypassCount);
        _statistics[@"last_bypass_time"] = [NSDate date];
    }
    
    return modified ? [result copy] : originalJSON;
}

#pragma mark - 深度递归扫描

- (id)deepScanAndFix:(id)obj {
    if (!obj) return obj;
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return [self deepScanDictionary:obj];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        return [self deepScanArray:obj];
    }
    
    return obj;
}

- (NSDictionary *)deepScanDictionary:(NSDictionary *)dict {
    BOOL modified = NO;
    NSMutableDictionary *result = [dict mutableCopy];
    
    for (NSString *key in dict.allKeys) {
        id value = dict[key];
        
        // 检查当前 key 是否是错误码字段
        BOOL isErrorKey = NO;
        for (NSString *filteredKey in kFilteredJSONKeys) {
            if ([key caseInsensitiveCompare:filteredKey] == NSOrderedSame) {
                isErrorKey = YES;
                break;
            }
        }
        
        if (isErrorKey) {
            NSInteger errorCode = 0;
            if ([value isKindOfClass:[NSNumber class]]) {
                errorCode = [value integerValue];
            } else if ([value isKindOfClass:[NSString class]]) {
                errorCode = [value integerValue];
            }
            
            if ([kFilteredErrorCodes containsObject:@(errorCode)]) {
                result[key] = @0;
                modified = YES;
                _bypassCount++;
                NSLog(@"[DK] 🔓 深度扫描拦截: %@=%ld → 0", key, (long)errorCode);
            }
        }
        
        // 递归处理值
        id newValue = [self deepScanAndFix:value];
        if (newValue != value) {
            result[key] = newValue;
            modified = YES;
        }
    }
    
    // 检查 error_message 中的敏感词提示
    NSString *errorMessage = result[@"error_message"];
    if (!errorMessage) errorMessage = result[@"errorMessage"];
    if (!errorMessage) errorMessage = result[@"message"];
    if (!errorMessage) errorMessage = result[@"msg"];
    
    if (errorMessage && [errorMessage isKindOfClass:[NSString class]]) {
        if ([errorMessage containsString:@"敏感词"] ||
            [errorMessage containsString:@"content_filter"] ||
            [errorMessage containsString:@"983"]) {
            // 移除错误消息并将 error_code 设为 0
            [result removeObjectForKey:@"error_message"];
            [result removeObjectForKey:@"errorMessage"];
            [result removeObjectForKey:@"message"];
            [result removeObjectForKey:@"msg"];
            result[@"error_code"] = @0;
            result[@"code"] = @0;
            modified = YES;
            _bypassCount++;
            NSLog(@"[DK] 🔓 深度扫描拦截敏感词消息: %@", errorMessage);
        }
    }
    
    // 检查 finish_reason
    NSString *finishReason = result[@"finish_reason"];
    if (finishReason && [finishReason isKindOfClass:[NSString class]]) {
        NSString *lower = [finishReason lowercaseString];
        if ([lower isEqualToString:@"content_filter"] ||
            [lower isEqualToString:@"sensitive"] ||
            [lower isEqualToString:@"moderation"] ||
            [lower isEqualToString:@"blocked"]) {
            result[@"finish_reason"] = @"stop";
            modified = YES;
            _bypassCount++;
            NSLog(@"[DK] 🔓 深度扫描拦截 finish_reason: %@", finishReason);
        }
    }
    
    // 检查 content_filter 相关字段
    if (result[@"content_filter"] || result[@"contentFilter"]) {
        [result removeObjectForKey:@"content_filter"];
        [result removeObjectForKey:@"contentFilter"];
        [result removeObjectForKey:@"filter_reason"];
        [result removeObjectForKey:@"filterReason"];
        [result removeObjectForKey:@"sensitive_words"];
        [result removeObjectForKey:@"sensitiveWords"];
        modified = YES;
        _bypassCount++;
        NSLog(@"[DK] 🔓 深度扫描移除 content_filter 标记");
    }
    
    return modified ? [result copy] : dict;
}

- (NSArray *)deepScanArray:(NSArray *)arr {
    BOOL modified = NO;
    NSMutableArray *result = [arr mutableCopy];
    
    for (NSUInteger i = 0; i < result.count; i++) {
        id item = result[i];
        id newItem = [self deepScanAndFix:item];
        if (newItem != item) {
            result[i] = newItem;
            modified = YES;
        }
    }
    
    return modified ? [result copy] : arr;
}

- (NSArray *)processResponseArray:(NSArray *)originalArray {
    if (!_enabled) return originalArray;
    if (!originalArray || ![originalArray isKindOfClass:[NSArray class]]) return originalArray;
    
    BOOL modified = NO;
    NSMutableArray *result = [originalArray mutableCopy];
    
    for (NSUInteger i = 0; i < result.count; i++) {
        id item = result[i];
        if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *filtered = [self processResponseJSON:item];
            if (filtered != item) {
                result[i] = filtered;
                modified = YES;
            }
        } else if ([item isKindOfClass:[NSArray class]]) {
            NSArray *filtered = [self processResponseArray:item];
            if (filtered != item) {
                result[i] = filtered;
                modified = YES;
            }
        }
    }
    
    return modified ? [result copy] : originalArray;
}

- (NSData *)processResponseData:(NSData *)originalData {
    if (!_enabled) return originalData;
    if (!originalData || originalData.length == 0) return originalData;
    
    // ============================================================
    // 策略 0: SSE 流式数据过滤（最重要的路径）
    // TRAE 的 AI 对话通过 SSE (text/event-stream) 传输，
    // 格式为: "data: {...}\n\n"。敏感词错误码 983 嵌入在
    // data: 行的 JSON 载荷中，而非顶层 HTTP 响应。
    // 之前未处理此格式，导致敏感词过滤对 SSE 流完全无效。
    // ============================================================
    NSString *text = [[NSString alloc] initWithData:originalData encoding:NSUTF8StringEncoding];
    if (text) {
        BOOL modified = NO;
        
        // 检测 SSE 格式: "data: {...}" 或 "data:{...}"
        // 对每个 data: 行单独解析和过滤
        NSArray *chunks = [text componentsSeparatedByString:@"\n"];
        NSMutableArray *filteredChunks = [NSMutableArray arrayWithCapacity:chunks.count];
        
        for (NSString *chunk in chunks) {
            NSString *trimmed = [chunk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *processed = chunk;
            
            if ([trimmed hasPrefix:@"data:"] || [trimmed hasPrefix:@"data: "]) {
                // 提取 JSON 部分
                NSString *jsonStr = [trimmed substringFromIndex:[trimmed hasPrefix:@"data: "] ? 6 : 5];
                NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
                if (jsonData) {
                    NSError *jsonError = nil;
                    id jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                 options:NSJSONReadingMutableContainers
                                                                   error:&jsonError];
                    if (!jsonError && [jsonObj isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *filtered = [self processResponseJSON:jsonObj];
                        if (filtered != jsonObj) {
                            // 重新序列化
                            NSData *newData = [NSJSONSerialization dataWithJSONObject:filtered options:0 error:nil];
                            if (newData) {
                                NSString *newJson = [[NSString alloc] initWithData:newData encoding:NSUTF8StringEncoding];
                                processed = [NSString stringWithFormat:@"data: %@", newJson];
                                modified = YES;
                            }
                        }
                    }
                }
            }
            
            [filteredChunks addObject:processed];
        }
        
        if (modified) {
            text = [filteredChunks componentsJoinedByString:@"\n"];
            _bypassCount++;
            _statistics[@"total_bypass"] = @(_bypassCount);
            _statistics[@"last_bypass_time"] = [NSDate date];
            NSLog(@"[DK] 🔓 SSE 流式数据过滤: 已拦截敏感词标记");
            return [text dataUsingEncoding:NSUTF8StringEncoding];
        }
        
        // 检查是否包含敏感词错误特征（非 JSON 格式的文本级匹配）
        BOOL textModified = NO;
        NSMutableString *mText = [text mutableCopy];
        
        // 扩展的文本匹配模式（覆盖所有已知错误码变体）
        NSArray *textPatterns = @[
            // 错误码 983 的所有常见变体
            @[@"\"error_code\":983", @"\"error_code\":0"],
            @[@"\"error_code\": 983", @"\"error_code\": 0"],
            @[@"\"error_code\":984", @"\"error_code\":0"],
            @[@"\"error_code\": 984", @"\"error_code\": 0"],
            @[@"\"code\":983", @"\"code\":0"],
            @[@"\"code\": 983", @"\"code\": 0"],
            @[@"\"code\":984", @"\"code\":0"],
            @[@"\"code\": 984", @"\"code\": 0"],
            @[@"\"errCode\":983", @"\"errCode\":0"],
            @[@"\"err_code\":983", @"\"err_code\":0"],
            @[@"\"errorCode\":983", @"\"errorCode\":0"],
            // 新增错误码
            @[@"\"error_code\":1001", @"\"error_code\":0"],
            @[@"\"error_code\": 1001", @"\"error_code\": 0"],
            @[@"\"error_code\":1002", @"\"error_code\":0"],
            @[@"\"error_code\":403", @"\"error_code\":0"],
            @[@"\"error_code\":2001", @"\"error_code\":0"],
            @[@"\"error_code\":2002", @"\"error_code\":0"],
            // SSE 事件类型
            @[@"\"event\":\"error\"", @"\"event\":\"message\""],
            // 内容过滤标记
            @[@"\"sensitive\":true", @"\"sensitive\":false"],
            @[@"\"content_filter\":true", @"\"content_filter\":false"],
            // OpenAI 兼容 SSE 格式：finish_reason 过滤
            @[@"\"finish_reason\":\"content_filter\"", @"\"finish_reason\":\"stop\""],
            @[@"\"finish_reason\":\"sensitive\"", @"\"finish_reason\":\"stop\""],
            @[@"\"finish_reason\":\"moderation\"", @"\"finish_reason\":\"stop\""],
            @[@"\"finish_reason\":\"blocked\"", @"\"finish_reason\":\"stop\""],
            // 嵌套的 content_filter_results
            @[@"\"content_filter_results\"", @"\"_dk_filtered\""],
            // 敏感词错误提示文本
            @[@"敏感词", @""],
            @[@"sensitive_content", @"ok"],
            @[@"content_filter_warning", @"_dk_ok"],
        ];
        
        for (NSArray *pattern in textPatterns) {
            NSString *from = pattern[0];
            NSString *to = pattern[1];
            if ([mText containsString:from]) {
                mText = [[mText stringByReplacingOccurrencesOfString:from withString:to] mutableCopy];
                textModified = YES;
                NSLog(@"[DK] 🔓 文本级替换: %@ → %@", from, to);
            }
        }
        
        // 策略 B: 检查是否包含敏感词错误提示文本
        if ([text containsString:@"敏感词"] ||
            [text containsString:@"sensitive_content"] ||
            [text containsString:@"content_filter"] ||
            [text containsString:@"sensitive"]) {
            // 如果整个响应都是敏感词错误（没有实际内容），返回空成功
            // 注意：不做全量替换，只在确认是纯错误响应时处理
            if ([text containsString:@"error_code"] || [text containsString:@"errorCode"]) {
                // 这是纯错误 JSON，替换为成功
                mText = [[text stringByReplacingOccurrencesOfString:@"\"result\":\"error\""
                                                         withString:@"\"result\":\"success\""] mutableCopy];
                textModified = YES;
                NSLog(@"[DK] 🔓 检测到纯错误响应，替换为成功");
            }
        }
        
        if (textModified) {
            _bypassCount++;
            _statistics[@"total_bypass"] = @(_bypassCount);
            _statistics[@"last_bypass_time"] = [NSDate date];
            NSLog(@"[DK] 🔓 文本级拦截敏感词错误码");
            return [mText dataUsingEncoding:NSUTF8StringEncoding];
        }
        
        // 如果以上都没匹配到，返回原始数据
        return originalData;
    }
    
    // 非文本数据，尝试 JSON 解析
    NSError *jsonError = nil;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:originalData
                                                 options:NSJSONReadingMutableContainers
                                                   error:&jsonError];
    
    if (jsonError || !jsonObj) {
        // 非 JSON 数据且非 UTF8 文本，无法处理
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

// ============================================================
// DKFilterProxyDelegate - NSURLSession 代理拦截器
// ============================================================

@implementation DKFilterProxyDelegate {
    // 累积收到的 SSE 数据（用于跨 chunk 重组 JSON）
    NSMutableData *_accumulatedData;
}

- (instancetype)initWithOriginalDelegate:(id)originalDelegate {
    self = [super init];
    if (self) {
        _originalDelegate = originalDelegate;
    }
    return self;
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (!data || data.length == 0) {
        if ([_originalDelegate respondsToSelector:_cmd]) {
            [_originalDelegate URLSession:session dataTask:dataTask didReceiveData:data];
        }
        return;
    }
    
    // 处理数据：过滤敏感词错误
    NSData *filtered = [[DKContentFilterBypass sharedInstance] processResponseData:data];
    
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session dataTask:dataTask didReceiveData:filtered];
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
    } else {
        completionHandler(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session dataTask:dataTask didBecomeDownloadTask:downloadTask];
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 didBecomeStreamTask:(NSURLSessionStreamTask *)streamTask {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session dataTask:dataTask didBecomeStreamTask:streamTask];
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse * _Nullable))completionHandler {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
    } else {
        completionHandler(proposedResponse);
    }
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session task:task didCompleteWithError:error];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session task:task willPerformHTTPRedirection:response newRequest:request completionHandler:completionHandler];
    } else {
        completionHandler(request);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream * _Nullable))completionHandler {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session task:task needNewBodyStream:completionHandler];
    } else {
        completionHandler(nil);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session task:task didSendBodyData:bytesSent totalBytesSent:totalBytesSent totalBytesExpectedToSend:totalBytesExpectedToSend];
    }
}

- (void)URLSession:(NSURLSession *)session
      taskIsWaitingForConnectivity:(NSURLSessionTask *)task {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session taskIsWaitingForConnectivity:task];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session task:task didFinishCollectingMetrics:metrics];
    }
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session downloadTask:downloadTask didWriteData:bytesWritten totalBytesWritten:totalBytesWritten totalBytesExpectedToWrite:totalBytesExpectedToWrite];
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
    if ([_originalDelegate respondsToSelector:_cmd]) {
        [_originalDelegate URLSession:session downloadTask:downloadTask didResumeAtOffset:fileOffset expectedTotalBytes:expectedTotalBytes];
    }
}

#pragma mark - Forwarding to catch any methods we didn't explicitly implement

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [_originalDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return _originalDelegate;
}

@end