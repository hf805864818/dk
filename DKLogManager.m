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
    
    // 构建导出内容：头部信息 + 全部日志
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *dateStr = [df stringFromDate:[NSDate date]];
    
    NSMutableString *content = [NSMutableString string];
    [content appendFormat:@"DK 多开插件 - 日志导出\n"];
    [content appendFormat:@"导出时间: %@\n", dateStr];
    [content appendFormat:@"日志总数: %lu 条\n", (unsigned long)logs.count];
    [content appendString:@"========================================================\n\n"];
    
    for (NSString *log in logs) {
        [content appendFormat:@"%@\n", log];
    }
    
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"dk_logs_%.0f.txt", [[NSDate date] timeIntervalSince1970]]];
    [content writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return tmpPath;
}

- (NSString *)exportLogsToZip {
    // 先生成 txt 文件
    NSString *txtPath = [self exportLogsToFile];
    if (!txtPath) return nil;
    
    NSString *txtName = [txtPath lastPathComponent];
    NSData *txtData = [NSData dataWithContentsOfFile:txtPath];
    if (!txtData) return nil;
    
    // 手动构建 zip 文件（store 模式，无压缩）
    NSMutableData *zipData = [NSMutableData data];
    
    // 使用系统时间作为 zip 内部时间戳
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                                     fromDate:now];
    uint16_t dosTime = (uint16_t)((comp.second / 2) | (comp.minute << 5) | (comp.hour << 11));
    uint16_t dosDate = (uint16_t)(comp.day | (comp.month << 5) | ((comp.year - 1980) << 9));
    
    uint32_t crc = (uint32_t)[self _crc32ForData:txtData];
    uint32_t fileSize = (uint32_t)txtData.length;
    const char *fileName = [txtName UTF8String];
    uint16_t fileNameLen = (uint16_t)strlen(fileName);
    
    // ---- Local File Header ----
    // signature (4): 0x04034b50
    // version needed (2): 20
    // flags (2): 0
    // compression (2): 0 (store)
    // mod time (2)
    // mod date (2)
    // crc32 (4)
    // compressed size (4)
    // uncompressed size (4)
    // filename length (2)
    // extra field length (2): 0
    uint32_t sig = 0x04034b50;
    [zipData appendBytes:&sig length:4];
    uint16_t ver = 20;
    [zipData appendBytes:&ver length:2];
    uint16_t flags = 0;
    [zipData appendBytes:&flags length:2];
    uint16_t method = 0;
    [zipData appendBytes:&method length:2];
    [zipData appendBytes:&dosTime length:2];
    [zipData appendBytes:&dosDate length:2];
    [zipData appendBytes:&crc length:4];
    [zipData appendBytes:&fileSize length:4];
    [zipData appendBytes:&fileSize length:4];
    [zipData appendBytes:&fileNameLen length:2];
    uint16_t extraLen = 0;
    [zipData appendBytes:&extraLen length:2];
    [zipData appendBytes:fileName length:fileNameLen];
    
    // ---- File Data ----
    [zipData appendData:txtData];
    
    // ---- Central Directory Entry ----
    // signature (4): 0x02014b50
    // version made by (2): 20
    // version needed (2): 20
    // flags (2): 0
    // compression (2): 0
    // mod time (2)
    // mod date (2)
    // crc32 (4)
    // compressed size (4)
    // uncompressed size (4)
    // filename length (2)
    // extra field length (2): 0
    // comment length (2): 0
    // disk # start (2): 0
    // internal attrs (2): 0
    // external attrs (4): 0
    // local header offset (4)
    uint32_t localHeaderOffset = 0;
    uint32_t cdSig = 0x02014b50;
    [zipData appendBytes:&cdSig length:4];
    uint16_t verMade = 20;
    [zipData appendBytes:&verMade length:2];
    [zipData appendBytes:&ver length:2];
    [zipData appendBytes:&flags length:2];
    [zipData appendBytes:&method length:2];
    [zipData appendBytes:&dosTime length:2];
    [zipData appendBytes:&dosDate length:2];
    [zipData appendBytes:&crc length:4];
    [zipData appendBytes:&fileSize length:4];
    [zipData appendBytes:&fileSize length:4];
    [zipData appendBytes:&fileNameLen length:2];
    [zipData appendBytes:&extraLen length:2];
    uint16_t commentLen = 0;
    [zipData appendBytes:&commentLen length:2];
    uint16_t diskStart = 0;
    [zipData appendBytes:&diskStart length:2];
    uint16_t internalAttrs = 0;
    [zipData appendBytes:&internalAttrs length:2];
    uint32_t externalAttrs = 0;
    [zipData appendBytes:&externalAttrs length:4];
    [zipData appendBytes:&localHeaderOffset length:4];
    [zipData appendBytes:fileName length:fileNameLen];
    
    // ---- End of Central Directory Record ----
    // signature (4): 0x06054b50
    // disk # (2): 0
    // disk with CD (2): 0
    // entries on this disk (2): 1
    // total entries (2): 1
    // CD size (4)
    // CD offset (4)
    // comment length (2): 0
    uint32_t cdSize = (uint32_t)(46 + fileNameLen);
    uint32_t cdOffset = (uint32_t)(30 + fileNameLen + fileSize);
    uint32_t eocdSig = 0x06054b50;
    [zipData appendBytes:&eocdSig length:4];
    uint16_t diskNum = 0;
    [zipData appendBytes:&diskNum length:2];
    [zipData appendBytes:&diskNum length:2];
    uint16_t entryCount = 1;
    [zipData appendBytes:&entryCount length:2];
    [zipData appendBytes:&entryCount length:2];
    [zipData appendBytes:&cdSize length:4];
    [zipData appendBytes:&cdOffset length:4];
    [zipData appendBytes:&commentLen length:2];
    
    // 写入 zip 文件
    NSString *zipName = [txtName stringByReplacingOccurrencesOfString:@".txt" withString:@".zip"];
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:zipName];
    [zipData writeToFile:zipPath atomically:YES];
    
    // 清理临时 txt 文件
    [[NSFileManager defaultManager] removeItemAtPath:txtPath error:nil];
    
    return zipPath;
}

#pragma mark - CRC32 计算

- (uint32_t)_crc32ForData:(NSData *)data {
    static uint32_t crcTable[256];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t crc = i;
            for (int j = 0; j < 8; j++) {
                crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320 : 0);
            }
            crcTable[i] = crc;
        }
    });
    
    uint32_t crc = 0xFFFFFFFF;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    for (NSUInteger i = 0; i < length; i++) {
        crc = (crc >> 8) ^ crcTable[(crc ^ bytes[i]) & 0xFF];
    }
    return crc ^ 0xFFFFFFFF;
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