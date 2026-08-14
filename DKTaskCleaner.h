#import <Foundation/Foundation.h>

// ============================================================
// DKTaskCleaner - Work/Code 任务清空器
//
// 功能：清空 TRAE 应用中 Work 模式和/或 Code 模式的所有任务
// 原理：通过 Objective-C runtime 动态调用 SLIMConversationRepository
//       的方法，实现任务的获取和删除。
//
// 注意：删除操作会通过 TRAE 自身的删除逻辑（含网络请求）执行，
//       因此删除后会同步到云端和其他设备。
// ============================================================

typedef NS_ENUM(NSInteger, DKTaskMode) {
    DKTaskModeWork = 0,   // Work 模式任务
    DKTaskModeCode = 1,   // Code 模式任务
    DKTaskModeAll  = 2    // 所有模式任务
};

@interface DKTaskCleaner : NSObject

/// 单例
+ (instancetype)sharedCleaner;

/// 是否支持任务清空功能（检测 SLIMConversationRepository 类是否存在）
@property (nonatomic, assign, readonly) BOOL isSupported;

/// 获取指定模式的任务数量
- (NSInteger)taskCountForMode:(DKTaskMode)mode;

/// 清空指定模式的所有任务
/// @param mode 任务模式（Work/Code/All）
/// @param completion 完成回调（主线程调用）
- (void)clearTasksForMode:(DKTaskMode)mode
               completion:(void (^)(BOOL success, NSInteger deletedCount, NSString *errorMessage))completion;

/// 运行时探测：输出所有候选类和方法信息到日志（调试用）
- (void)dumpRuntimeInfo;

@end
