#import "DKTaskCleaner.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "DKLogManager.h"

// ============================================================
// 内部方法名常量
// Swift 类在 Objective-C runtime 中的名称
// 可能的格式：mangled name / 模块名.类名 / @objc 重命名
// ============================================================
static NSArray *DKRepositoryClassCandidates(void) {
    static NSArray *candidates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        candidates = @[
            // mangled name（旧格式）
            @"_TtC7SLIMKit26SLIMConversationRepository",
            // mangled name（新 Swift 5+ 格式，模块名长度 + 模块名 + 类名长度 + 类名）
            @"$s7SLIMKit26SLIMConversationRepositoryC",
            @"$s7SLIMKit26SLIMConversationRepositoryCMa",
            // 模块.类名 格式
            @"SLIMKit.SLIMConversationRepository",
            @"SLIMKit.SLConversationRepository",
            // 纯类名（如果被 @objc 导出）
            @"SLIMConversationRepository",
            @"SLConversationRepository",
            // 其他可能
            @"_TtC7SLIMKit21SLIMConversationTable",
            @"SLIMKit.SLIMConversationTable",
        ];
    });
    return candidates;
}

static NSArray *DKSessionManagerClassCandidates(void) {
    static NSArray *candidates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        candidates = @[
            @"_TtC7SLIMKit20SLTaskSessionManager",
            @"$s7SLIMKit20SLTaskSessionManagerC",
            @"SLIMKit.SLTaskSessionManager",
            @"SLTaskSessionManager",
        ];
    });
    return candidates;
}

// 日志宏
#define DKTaskLog(fmt, ...) \
    do { \
        NSString *msg = [NSString stringWithFormat:@"[DKTaskCleaner] " fmt, ##__VA_ARGS__]; \
        NSLog(@"%@", msg); \
        if ([[DKLogManager sharedInstance] respondsToSelector:@selector(logCount)]) { \
            /* 日志会被 NSLog Hook 自动捕获 */ \
        } \
    } while(0)

@interface DKTaskCleaner () {
    Class _repoClass;
    id _repoInstance;
    BOOL _checkedSupported;
    BOOL _isSupported;
}

/// 尝试获取 SLIMConversationRepository 单例
- (BOOL)_ensureRepository;

/// 尝试用指定类建立仓库
- (BOOL)_trySetupRepositoryClass:(Class)cls;

/// 获取所有会话
- (NSArray *)_fetchAllConversations;

/// 从会话对象中获取 mode 字段
- (NSString *)_modeFromConversation:(id)conversation;

/// 从会话对象中获取 ID
- (NSString *)_conversationId:(id)conversation;

/// 删除单个会话（通过业务层方法，会触发网络请求）
- (BOOL)_deleteConversationWithId:(NSString *)conversationId;

/// 发送会话列表更新通知
- (void)_postUpdateNotification;

/// 枚举类的所有方法（调试用）
- (NSArray<NSString *> *)_methodListForClass:(Class)cls;

@end

@implementation DKTaskCleaner

+ (instancetype)sharedCleaner {
    static DKTaskCleaner *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKTaskCleaner alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _repoClass = nil;
        _repoInstance = nil;
        _checkedSupported = NO;
        _isSupported = NO;
    }
    return self;
}

- (BOOL)isSupported {
    if (!_checkedSupported) {
        [self _ensureRepository];
        _checkedSupported = YES;
    }
    return _isSupported;
}

#pragma mark - 核心方法

- (BOOL)_ensureRepository {
    if (_repoInstance && _repoClass) {
        return YES;
    }
    
    // 第一步：尝试已知的候选类名
    for (NSString *className in DKRepositoryClassCandidates()) {
        Class cls = NSClassFromString(className);
        if (cls) {
            DKTaskLog(@"Found candidate class: %@ (via name %@)", NSStringFromClass(cls), className);
            if ([self _trySetupRepositoryClass:cls]) {
                return YES;
            }
        }
    }
    
    // 第二步：运行时枚举所有类，搜索包含 "Conversation" 和 "Repository/Store/Manager" 的类
    DKTaskLog(@"Candidate names not found, enumerating all classes...");
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            NSString *className = NSStringFromClass(cls);
            
            // 搜索包含 Conversation + Repository/Store/DB/Database 的类
            BOOL hasConversation = [className.lowercaseString containsString:@"conversation"];
            BOOL hasRepo = [className.lowercaseString containsString:@"repository"] ||
                           [className.lowercaseString containsString:@"store"] ||
                           [className.lowercaseString containsString:@"database"] ||
                           [className.lowercaseString containsString:@"dbmanager"] ||
                           [className.lowercaseString containsString:@"dao"];
            
            if (hasConversation && hasRepo) {
                DKTaskLog(@"Found conversation repository candidate: %@", className);
                if ([self _trySetupRepositoryClass:cls]) {
                    free(classes);
                    return YES;
                }
            }
        }
        
        // 如果没找到 Repository，试试找带 Task 和 Manager 的
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            NSString *className = NSStringFromClass(cls);
            
            BOOL hasTask = [className.lowercaseString containsString:@"task"];
            BOOL hasManager = [className.lowercaseString containsString:@"manager"] ||
                            [className.lowercaseString containsString:@"session"];
            
            if (hasTask && hasManager) {
                DKTaskLog(@"Found task manager candidate: %@", className);
            }
        }
        
        free(classes);
    }
    
    DKTaskLog(@"ERROR: Could not find any conversation repository class");
    _isSupported = NO;
    return NO;
}

- (BOOL)_trySetupRepositoryClass:(Class)cls {
    // 检查这个类是否有获取会话列表的能力
    NSArray *methods = [self _methodListForClass:cls];
    BOOL hasGetConversation = NO;
    BOOL hasDeleteConversation = NO;
    
    for (NSString *method in methods) {
        NSString *lower = method.lowercaseString;
        if ([lower containsString:@"conversation"] &&
            ([lower containsString:@"get"] ||
             [lower containsString:@"all"] ||
             [lower containsString:@"list"] ||
             [lower containsString:@"fetch"])) {
            hasGetConversation = YES;
        }
        if ([lower containsString:@"conversation"] &&
            ([lower containsString:@"delete"] ||
             [lower containsString:@"remove"] ||
             [lower containsString:@"clear"])) {
            hasDeleteConversation = YES;
        }
    }
    
    if (!hasGetConversation) {
        DKTaskLog(@"  Skip %@: no conversation getter found", NSStringFromClass(cls));
        return NO;
    }
    
    DKTaskLog(@"  Class %@ looks promising (hasGet=%d, hasDelete=%d)",
              NSStringFromClass(cls), hasGetConversation, hasDeleteConversation);
    
    // 尝试获取单例
    SEL sharedSelectors[] = {
        @selector(shared),
        @selector(sharedManager),
        @selector(sharedInstance),
        @selector(defaultRepository),
        @selector(defaultManager),
        @selector(defaultStore),
        @selector(sharedRepository),
    };
    
    for (int i = 0; i < sizeof(sharedSelectors)/sizeof(SEL); i++) {
        SEL sel = sharedSelectors[i];
        if ([cls respondsToSelector:sel]) {
            DKTaskLog(@"  Found singleton method: %@", NSStringFromSelector(sel));
            
            IMP imp = [cls methodForSelector:sel];
            id (*func)(id, SEL) = (void *)imp;
            id instance = func(cls, sel);
            
            if (instance) {
                _repoClass = cls;
                _repoInstance = instance;
                _isSupported = YES;
                DKTaskLog(@"  Successfully got instance: %@", instance);
                return YES;
            }
        }
    }
    
    // 尝试 alloc/init
    if ([cls instancesRespondToSelector:@selector(init)]) {
        @try {
            id instance = [[cls alloc] init];
            if (instance) {
                _repoClass = cls;
                _repoInstance = instance;
                _isSupported = YES;
                DKTaskLog(@"  Created instance via alloc/init: %@", instance);
                return YES;
            }
        } @catch (NSException *e) {
            DKTaskLog(@"  alloc/init failed: %@", e);
        }
    }
    
    return NO;
}

- (NSInteger)taskCountForMode:(DKTaskMode)mode {
    if (![self _ensureRepository]) {
        return 0;
    }
    
    NSArray *conversations = [self _fetchAllConversations];
    if (!conversations || conversations.count == 0) {
        return 0;
    }
    
    if (mode == DKTaskModeAll) {
        return conversations.count;
    }
    
    NSString *targetMode = (mode == DKTaskModeWork) ? @"work" : @"code";
    NSInteger count = 0;
    
    for (id conv in conversations) {
        NSString *convMode = [self _modeFromConversation:conv];
        if ([convMode.lowercaseString isEqualToString:targetMode.lowercaseString]) {
            count++;
        }
    }
    
    return count;
}

- (void)clearTasksForMode:(DKTaskMode)mode
               completion:(void (^)(BOOL success, NSInteger deletedCount, NSString *errorMessage))completion {
    
    void (^completeOnMain)(BOOL, NSInteger, NSString *) = ^(BOOL success, NSInteger count, NSString *error) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, count, error);
            });
        }
    };
    
    if (![self _ensureRepository]) {
        completeOnMain(NO, 0, @"任务管理模块未找到");
        return;
    }
    
    // 后台执行删除
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            NSArray *conversations = [self _fetchAllConversations];
            if (!conversations || conversations.count == 0) {
                completeOnMain(YES, 0, nil);
                return;
            }
            
            NSString *targetMode = nil;
            if (mode == DKTaskModeWork) {
                targetMode = @"work";
            } else if (mode == DKTaskModeCode) {
                targetMode = @"code";
            }
            
            NSMutableArray *toDelete = [NSMutableArray array];
            for (id conv in conversations) {
                if (mode == DKTaskModeAll) {
                    [toDelete addObject:conv];
                } else {
                    NSString *convMode = [self _modeFromConversation:conv];
                    if ([convMode.lowercaseString isEqualToString:targetMode.lowercaseString]) {
                        [toDelete addObject:conv];
                    }
                }
            }
            
            DKTaskLog(@"Found %lu conversations to delete (mode: %ld)",
                      (unsigned long)toDelete.count, (long)mode);
            
            NSInteger deletedCount = 0;
            for (id conv in toDelete) {
                NSString *convId = [self _conversationId:conv];
                if (convId.length > 0) {
                    if ([self _deleteConversationWithId:convId]) {
                        deletedCount++;
                    }
                }
            }
            
            // 刷新 UI
            [self _postUpdateNotification];
            
            DKTaskLog(@"Successfully deleted %lu tasks", (long)deletedCount);
            completeOnMain(YES, deletedCount, nil);
            
        } @catch (NSException *exception) {
            DKTaskLog(@"Exception while clearing tasks: %@", exception);
            completeOnMain(NO, 0, exception.description);
        }
    });
}

#pragma mark - 内部辅助方法

- (NSArray *)_fetchAllConversations {
    if (!_repoInstance) return nil;
    
    @try {
        // 尝试调用 getAllConversations 方法
        // Swift 方法签名可能是: getAllConversations(orderByUpdatedAt:limit:offset:)
        // 我们先尝试几种可能的 selector
        
        NSArray *selectorsToTry = @[
            // 完整方法名
            @"getAllConversationsWithOrderByUpdatedAt:limit:offset:",
            @"getAllConversationsOrderByUpdatedAt:limit:offset:",
            @"allConversationsWithOrderBy:limit:offset:",
            // 简化版
            @"getAllConversations",
            @"allConversations",
            @"fetchAllConversations",
            @"conversationList",
            // 带 namespace 参数的版本
            @"getAllConversationsWithNamespace:orderByUpdatedAt:limit:offset:",
        ];
        
        for (NSString *selName in selectorsToTry) {
            SEL selector = NSSelectorFromString(selName);
            if ([_repoInstance respondsToSelector:selector]) {
                DKTaskLog(@"Trying selector: %@", selName);
                
                // 对于无参数方法，直接调用
                NSMethodSignature *sig = [_repoInstance methodSignatureForSelector:selector];
                if (!sig) continue;
                
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                invocation.target = _repoInstance;
                invocation.selector = selector;
                
                // 设置默认参数
                NSInteger numberOfArgs = sig.numberOfArguments - 2; // 减去 self 和 _cmd
                if (numberOfArgs >= 1) {
                    BOOL orderBy = YES;
                    [invocation setArgument:&orderBy atIndex:2];
                }
                if (numberOfArgs >= 2) {
                    int limit = 1000; // 获取足够多的任务
                    [invocation setArgument:&limit atIndex:3];
                }
                if (numberOfArgs >= 3) {
                    int offset = 0;
                    [invocation setArgument:&offset atIndex:4];
                }
                
                [invocation invoke];
                
                __unsafe_unretained id result = nil;
                if (sig.methodReturnLength > 0) {
                    [invocation getReturnValue:&result];
                }
                
                if (result && [result isKindOfClass:[NSArray class]]) {
                    DKTaskLog(@"Got %lu conversations via selector: %@",
                              (unsigned long)[(NSArray *)result count], selName);
                    return result;
                }
            }
        }
        
        // 如果上面的方法都不行，枚举所有方法找包含 "Conversation" 的
        DKTaskLog(@"Trying to find conversation method by enumeration...");
        NSArray *methods = [self _methodListForClass:_repoClass];
        for (NSString *methodName in methods) {
            if ([methodName.lowercaseString containsString:@"conversation"] &&
                ([methodName.lowercaseString containsString:@"get"] ||
                 [methodName.lowercaseString containsString:@"all"] ||
                 [methodName.lowercaseString containsString:@"list"] ||
                 [methodName.lowercaseString containsString:@"fetch"])) {
                
                SEL selector = NSSelectorFromString(methodName);
                if ([_repoInstance respondsToSelector:selector]) {
                    @try {
                        IMP imp = [_repoInstance methodForSelector:selector];
                        id (*func)(id, SEL) = (void *)imp;
                        id result = func(_repoInstance, selector);
                        if (result && [result isKindOfClass:[NSArray class]]) {
                            DKTaskLog(@"Found working selector: %@, count=%lu",
                                      methodName, (unsigned long)[(NSArray *)result count]);
                            return result;
                        }
                    } @catch (NSException *e) {
                        // 忽略，继续试下一个
                    }
                }
            }
        }
        
        DKTaskLog(@"ERROR: Could not find a way to fetch conversations");
        return nil;
        
    } @catch (NSException *exception) {
        DKTaskLog(@"Exception fetching conversations: %@", exception);
        return nil;
    }
}

- (NSString *)_modeFromConversation:(id)conversation {
    if (!conversation) return nil;
    
    @try {
        // 尝试访问 mode 属性
        if ([conversation respondsToSelector:@selector(mode)]) {
            id mode = [conversation valueForKey:@"mode"];
            if ([mode isKindOfClass:[NSString class]]) {
                return mode;
            }
            if ([mode isKindOfClass:[NSNumber class]]) {
                return [mode stringValue];
            }
        }
        
        // 尝试直接 KVC
        id modeValue = [conversation valueForKey:@"mode"];
        if ([modeValue isKindOfClass:[NSString class]]) {
            return modeValue;
        }
        
        // 尝试 cliType
        id cliType = [conversation valueForKey:@"cliType"];
        if ([cliType isKindOfClass:[NSString class]]) {
            return cliType;
        }
        
        // 尝试 type
        id typeValue = [conversation valueForKey:@"type"];
        if ([typeValue isKindOfClass:[NSString class]]) {
            return typeValue;
        }
        
        DKTaskLog(@"WARN: Could not get mode from conversation: %@", conversation);
        return nil;
        
    } @catch (NSException *exception) {
        DKTaskLog(@"Exception getting mode: %@", exception);
        return nil;
    }
}

- (NSString *)_conversationId:(id)conversation {
    if (!conversation) return nil;
    
    @try {
        // 尝试 id 属性
        if ([conversation respondsToSelector:@selector(id)]) {
            id convId = [conversation valueForKey:@"id"];
            if ([convId isKindOfClass:[NSString class]]) {
                return convId;
            }
        }
        
        // KVC
        id convId = [conversation valueForKey:@"id"];
        if ([convId isKindOfClass:[NSString class]]) {
            return convId;
        }
        
        // conversationId
        id conversationId = [conversation valueForKey:@"conversationId"];
        if ([conversationId isKindOfClass:[NSString class]]) {
            return conversationId;
        }
        
        DKTaskLog(@"WARN: Could not get ID from conversation");
        return nil;
        
    } @catch (NSException *exception) {
        DKTaskLog(@"Exception getting conversation ID: %@", exception);
        return nil;
    }
}

- (BOOL)_deleteConversationWithId:(NSString *)conversationId {
    if (!conversationId || conversationId.length == 0) return NO;
    if (!_repoInstance) return NO;
    
    @try {
        // 尝试多种删除方法
        NSArray *deleteSelectors = @[
            @"deleteConversationWithId:completion:",
            @"deleteConversationById:completion:",
            @"deleteConversation:completion:",
            @"removeConversationWithId:completion:",
            @"removeConversationById:completion:",
            @"deleteConversationWithId:",
            @"deleteConversationById:",
            @"deleteConversation:",
        ];
        
        for (NSString *selName in deleteSelectors) {
            SEL selector = NSSelectorFromString(selName);
            if ([_repoInstance respondsToSelector:selector]) {
                DKTaskLog(@"Trying delete selector: %@", selName);
                
                NSMethodSignature *sig = [_repoInstance methodSignatureForSelector:selector];
                if (!sig) continue;
                
                NSInteger argCount = sig.numberOfArguments - 2;
                
                if (argCount == 1) {
                    // 只有一个参数（id），无 completion
                    IMP imp = [_repoInstance methodForSelector:selector];
                    void (*func)(id, SEL, NSString *) = (void *)imp;
                    func(_repoInstance, selector, conversationId);
                    return YES;
                    
                } else if (argCount >= 2) {
                    // 有 completion block
                    IMP imp = [_repoInstance methodForSelector:selector];
                    void (*func)(id, SEL, NSString *, void (^)(id)) = (void *)imp;
                    
                    __block BOOL done = NO;
                    __block BOOL success = NO;
                    
                    void (^completionBlock)(id) = ^(id result) {
                        done = YES;
                        success = YES;
                        DKTaskLog(@"Delete completed for %@", conversationId);
                    };
                    
                    func(_repoInstance, selector, conversationId, completionBlock);
                    
                    // 等一小段时间让异步操作开始
                    // 注意：删除可能是异步的，这里我们假设只要方法调用成功即可
                    return YES;
                }
            }
        }
        
        // 如果 repo 上找不到，试试 SLTaskSessionManager
        Class sessionManagerClass = NSClassFromString(@"_TtC7SLIMKit20SLTaskSessionManager");
        if (sessionManagerClass) {
            id sessionManager = nil;
            
            // 获取单例
            SEL sharedSel = NSSelectorFromString(@"shared");
            SEL sharedManagerSel = NSSelectorFromString(@"sharedManager");
            if ([sessionManagerClass respondsToSelector:sharedSel]) {
                IMP imp = [sessionManagerClass methodForSelector:sharedSel];
                id (*func)(id, SEL) = (void *)imp;
                sessionManager = func(sessionManagerClass, sharedSel);
            } else if ([sessionManagerClass respondsToSelector:sharedManagerSel]) {
                IMP imp = [sessionManagerClass methodForSelector:sharedManagerSel];
                id (*func)(id, SEL) = (void *)imp;
                sessionManager = func(sessionManagerClass, sharedManagerSel);
            }
            
            if (sessionManager) {
                for (NSString *selName in deleteSelectors) {
                    SEL selector = NSSelectorFromString(selName);
                    if ([sessionManager respondsToSelector:selector]) {
                        DKTaskLog(@"Found delete on SLTaskSessionManager: %@", selName);
                        NSMethodSignature *sig = [sessionManager methodSignatureForSelector:selector];
                        if (sig && sig.numberOfArguments - 2 >= 1) {
                            IMP imp = [sessionManager methodForSelector:selector];
                            void (*func)(id, SEL, NSString *) = (void *)imp;
                            func(sessionManager, selector, conversationId);
                            return YES;
                        }
                    }
                }
            }
        }
        
        DKTaskLog(@"ERROR: Could not find delete method for conversation: %@", conversationId);
        return NO;
        
    } @catch (NSException *exception) {
        DKTaskLog(@"Exception deleting conversation: %@", exception);
        return NO;
    }
}

- (void)_postUpdateNotification {
    @try {
        // 发送列表更新通知
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        
        // 尝试已知的通知名
        NSArray *notifNames = @[
            kDKUpdateConversationListNotification,
            @"kUpdateConversationListNotification",
            @"SLConversationListDidUpdateNotification",
            @"SLTaskListDidUpdateNotification",
            @"ConversationListDidChangeNotification",
            @"TaskListDidChangeNotification",
        ];
        
        for (NSString *name in notifNames) {
            [nc postNotificationName:name object:nil];
        }
        
        DKTaskLog(@"Posted update notifications");
        
    } @catch (NSException *exception) {
        DKTaskLog(@"Exception posting notification: %@", exception);
    }
}

#pragma mark - 调试方法

- (void)dumpRuntimeInfo {
    DKTaskLog(@"========== DKTaskCleaner Runtime Info ==========");
    
    // 枚举所有类，找出和 conversation/task 相关的
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        
        NSMutableArray *conversationClasses = [NSMutableArray array];
        NSMutableArray *taskClasses = [NSMutableArray array];
        NSMutableArray *slimClasses = [NSMutableArray array];
        
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            NSString *className = NSStringFromClass(cls);
            NSString *lower = className.lowercaseString;
            
            if ([lower containsString:@"conversation"]) {
                [conversationClasses addObject:className];
            }
            if ([lower containsString:@"task"] &&
                ([lower containsString:@"manager"] ||
                 [lower containsString:@"session"] ||
                 [lower containsString:@"store"] ||
                 [lower containsString:@"repository"] ||
                 [lower containsString:@"viewmodel"])) {
                [taskClasses addObject:className];
            }
            if ([lower containsString:@"slim"] &&
                ([lower containsString:@"db"] ||
                 [lower containsString:@"database"] ||
                 [lower containsString:@"store"] ||
                 [lower containsString:@"repo"])) {
                [slimClasses addObject:className];
            }
        }
        
        free(classes);
        
        DKTaskLog(@"--- Conversation-related classes (%lu) ---", (unsigned long)conversationClasses.count);
        for (NSString *name in conversationClasses) {
            DKTaskLog(@"  %@", name);
        }
        
        DKTaskLog(@"--- Task manager/repo classes (%lu) ---", (unsigned long)taskClasses.count);
        for (NSString *name in taskClasses) {
            DKTaskLog(@"  %@", name);
        }
        
        DKTaskLog(@"--- SLIM DB/Store classes (%lu) ---", (unsigned long)slimClasses.count);
        for (NSString *name in slimClasses) {
            DKTaskLog(@"  %@", name);
        }
    }
    
    // 尝试获取仓库实例并获取会话
    if ([self _ensureRepository]) {
        DKTaskLog(@"--- Repository found: %@ ---", NSStringFromClass(_repoClass));
        DKTaskLog(@"Instance: %@", _repoInstance);
        DKTaskLog(@"Methods: %@", [self _methodListForClass:_repoClass]);
        
        NSArray *convs = [self _fetchAllConversations];
        DKTaskLog(@"Conversations count: %lu", (unsigned long)convs.count);
        
        if (convs.count > 0) {
            id firstConv = convs.firstObject;
            DKTaskLog(@"First conversation class: %@", NSStringFromClass([firstConv class]));
            DKTaskLog(@"First conversation description: %@", firstConv);
            
            // 尝试获取所有属性
            unsigned int count;
            objc_property_t *props = class_copyPropertyList([firstConv class], &count);
            NSMutableArray *propNames = [NSMutableArray array];
            for (unsigned int i = 0; i < count; i++) {
                const char *name = property_getName(props[i]);
                [propNames addObject:[NSString stringWithUTF8String:name]];
            }
            free(props);
            DKTaskLog(@"First conversation properties: %@", propNames);
        }
    } else {
        DKTaskLog(@"--- Repository NOT found ---");
    }
    
    DKTaskLog(@"=================================================");
}

- (NSArray<NSString *> *)_methodListForClass:(Class)cls {
    if (!cls) return @[];
    
    NSMutableArray<NSString *> *methods = [NSMutableArray array];
    unsigned int count;
    Method *methodList = class_copyMethodList(cls, &count);
    
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methodList[i]);
        NSString *name = NSStringFromSelector(sel);
        [methods addObject:name];
    }
    
    free(methodList);
    
    // 也加类方法
    Method *classMethodList = class_copyMethodList(object_getClass(cls), &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(classMethodList[i]);
        NSString *name = [@"+" stringByAppendingString:NSStringFromSelector(sel)];
        [methods addObject:name];
    }
    free(classMethodList);
    
    [methods sortUsingSelector:@selector(compare:)];
    return methods;
}

@end
