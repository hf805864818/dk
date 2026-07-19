#import "DKLogManager.h"
#import "fishhook/fishhook.h"
#import <objc/runtime.h>

// 最大日志条数
static const NSUInteger kMaxLogEntries = 2000;

// ============================================================
// NSLogv 原始函数指针
// ============================================================
static void (*original_NSLogv)(NSString *format, va_list args);

// ============================================================
// 环形缓冲区
// ============================================================
@interface DKLogManager () {
    NSMutableArray<NSString *> *_logBuffer;
    dispatch_queue_t _logQueue;
    BOOL _isCapturing;
}
@end

@implementation DKLogManager

+ (instancetype)sharedInstance {
    static DKLogManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKLogManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logBuffer = [NSMutableArray arrayWithCapacity:kMaxLogEntries];
        _logQueue = dispatch_queue_create("com.dk.logmanager", DISPATCH_QUEUE_SERIAL);
        _isCapturing = NO;
    }
    return self;
}

#pragma mark - 启动/停止捕获

- (void)startCapture {
    if (_isCapturing) return;
    
    __weak typeof(self) weakSelf = self;
    
    struct rebinding rebindings[] = {
        {"NSLogv", (void *)hooked_NSLogv, (void **)&original_NSLogv},
    };
    
    int result = rebind_symbols(rebindings, 1);
    if (result == 0) {
        _isCapturing = YES;
        [self addLog:@"[DK] 📋 日志捕获已启动"];
        NSLog(@"[DK] ✅ DKLogManager 日志捕获已启动");
    } else {
        NSLog(@"[DK] ❌ DKLogManager 日志捕获失败: rebind_symbols 返回 %d", result);
    }
}

- (void)stopCapture {
    if (!_isCapturing) return;
    
    // fishhook 的 rebind 是永久的，无法真正"停止"
    // 但我们可以标记为停止，不再添加到缓冲区
    _isCapturing = NO;
    NSLog(@"[DK] 📋 日志捕获已停止");
}

#pragma mark - 日志管理

- (void)addLog:(NSString *)log {
    if (!_isCapturing || !log) return;
    
    dispatch_async(_logQueue, ^{
        // 添加时间戳
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *entry = [NSString stringWithFormat:@"%@ %@", timestamp, log];
        
        [_logBuffer addObject:entry];
        
        // 环形缓冲区：超过最大条数时移除旧条目
        while (_logBuffer.count > kMaxLogEntries) {
            [_logBuffer removeObjectAtIndex:0];
        }
    });
}

- (NSArray<NSString *> *)recentLogs:(NSUInteger)count {
    __block NSArray *result = nil;
    dispatch_sync(_logQueue, ^{
        NSUInteger start = count >= _logBuffer.count ? 0 : _logBuffer.count - count;
        result = [_logBuffer subarrayWithRange:NSMakeRange(start, _logBuffer.count - start)];
    });
    return result;
}

- (NSArray<NSString *> *)allLogs {
    __block NSArray *result = nil;
    dispatch_sync(_logQueue, ^{
        result = [_logBuffer copy];
    });
    return result;
}

- (void)clearLogs {
    dispatch_async(_logQueue, ^{
        [_logBuffer removeAllObjects];
    });
    NSLog(@"[DK] 📋 日志已清空");
}

- (NSUInteger)logCount {
    __block NSUInteger count = 0;
    dispatch_sync(_logQueue, ^{
        count = _logBuffer.count;
    });
    return count;
}

- (NSArray<NSString *> *)logsContaining:(NSString *)keyword {
    __block NSArray *result = nil;
    dispatch_sync(_logQueue, ^{
        if (!keyword || keyword.length == 0) {
            result = [_logBuffer copy];
        } else {
            NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSString *entry, NSDictionary *bindings) {
                return [entry rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound;
            }];
            result = [_logBuffer filteredArrayUsingPredicate:predicate];
        }
    });
    return result;
}

- (NSString *)exportLogsToFile {
    NSArray *logs = [self allLogs];
    NSString *content = [logs componentsJoinedByString:@"\n"];
    
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"dk_logs_%.0f.txt", [[NSDate date] timeIntervalSince1970]]];
    [content writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return tmpPath;
}

@end

// ============================================================
// Hook 函数实现
// ============================================================
void hooked_NSLogv(NSString *format, va_list args) {
    // 先捕获日志（在调用原始 NSLogv 之前）
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    if (message) {
        [[DKLogManager sharedInstance] addLog:message];
    }
    
    // 调用原始 NSLogv（保持控制台输出）
    if (original_NSLogv) {
        original_NSLogv(format, args);
    }
}