#import <Foundation/Foundation.h>

// ============================================================
// DKLogManager - 手机端日志查看器
//
// 问题：用户没有电脑，无法用 Xcode 查看 NSLog 控制台输出。
// 解决方案：Hook NSLogv 捕获所有日志，存入环形缓冲区，
// 插件菜单中提供「查看日志」入口，直接在手机上查看。
// ============================================================

@interface DKLogManager : NSObject

+ (instancetype)sharedInstance;

/// 启动日志捕获（Hook NSLogv）
- (void)startCapture;

/// 停止日志捕获
- (void)stopCapture;

/// 获取最近 N 条日志
- (NSArray<NSString *> *)recentLogs:(NSUInteger)count;

/// 获取所有日志
- (NSArray<NSString *> *)allLogs;

/// 清空日志
- (void)clearLogs;

/// 日志条数
- (NSUInteger)logCount;

/// 过滤包含关键词的日志
- (NSArray<NSString *> *)logsContaining:(NSString *)keyword;

/// 导出全部日志为单个 txt 文件
- (NSString *)exportLogsToFile;

/// 导出全部日志为 zip 压缩包（包含日志文件 + 导出信息）
- (NSString *)exportLogsToZip;

@end