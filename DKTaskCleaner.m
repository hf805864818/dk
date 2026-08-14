#import "DKTaskCleaner.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "DKLogManager.h"

// ============================================================
// 内部方法名常量
// Swift 类在 Objective-C runtime 中的 mangled 名称
// ============================================================
static NSString *const kDKSLIMConversationRepositoryClass = @"_TtC7SLIMKit26SLIMConversationRepository";
static NSString *const kDKSLIMConversationTableClass      = @"_TtC7SLIMKit21SLIMConversationTable";
static NSString *const kDKUpdateConversationListNotification = @"kUpdateConversationListNotification";

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
    
    _repoClass = NSClassFromString(kDKSLIMConversationRepositoryClass);
    
    if (!_repoClass) {
        DKTaskLog(@"ERROR: SLIMConversationRepository class not found (%@)", kDKSLIMConversationRepositoryClass);
        _isSupported = NO;
        return NO;
    }
    
    DKTaskLog(@"Found SLIMConversationRepository class: %@", NSStringFromClass(_repoClass));
    
    // 尝试获取单例
    SEL sharedSelector = NSSelectorFromString(@"shared");
    SEL sharedManagerSelector = NSSelectorFromString(@"sharedManager");
    SEL sharedInstanceSelector = NSSelectorFromString(@"sharedInstance");
    SEL defaultSelector = NSSelectorFromString(@"defaultRepository");
    
    SEL singletonSelector = nil;
    if ([_repoClass respondsToSelector:sharedSelector]) {
        singletonSelector = sharedSelector;
    } else if ([_repoClass respondsToSelector:sharedManagerSelector]) {
        singletonSelector = sharedManagerSelector;
    } else if ([_repoClass respondsToSelector:sharedInstanceSelector]) {
        singletonSelector = sharedInstanceSelector;
    } else if ([_repoClass respondsToSelector:defaultSelector]) {
        singletonSelector = defaultSelector;
    }
    
    if (!singletonSelector) {
        DKTaskLog(@"ERROR: No singleton method found on SLIMConversationRepository");
        DKTaskLog(@"Class methods: %@", [self _methodListForClass:_repoClass]);
        _isSupported = NO;
        return NO;
    }
    
    DKTaskLog(@"Using singleton method: %@", NSStringFromSelector(singletonSelector));
    
    // 调用单例方法
    IMP imp = [_repoClass methodForSelector:singletonSelector];
    id (*func)(id, SEL) = (void *)imp;
    _repoInstance = func(_repoClass, singletonSelector);
    
    if (!_repoInstance) {
        DKTaskLog(@"ERROR: Failed to get SLIMConversationRepository singleton");
        _isSupported = NO;
        return NO;
    }
    
    DKTaskLog(@"Got SLIMConversationRepository instance: %@", _repoInstance);
    _isSupported = YES;
    return YES;
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
    
    // 检查 SLIMConversationRepository
    Class repoClass = NSClassFromString(kDKSLIMConversationRepositoryClass);
    if (repoClass) {
        DKTaskLog(@"[OK] SLIMConversationRepository class found: %@", NSStringFromClass(repoClass));
        DKTaskLog(@"  Methods: %@", [self _methodListForClass:repoClass]);
    } else {
        DKTaskLog(@"[FAIL] SLIMConversationRepository class NOT found");
    }
    
    // 检查 SLIMConversationTable
    Class tableClass = NSClassFromString(kDKSLIMConversationTableClass);
    if (tableClass) {
        DKTaskLog(@"[OK] SLIMConversationTable class found: %@", NSStringFromClass(tableClass));
        DKTaskLog(@"  Properties: %@", [self _methodListForClass:tableClass]);
    } else {
        DKTaskLog(@"[FAIL] SLIMConversationTable class NOT found");
    }
    
    // 检查 SLTaskSessionManager
    Class sessionMgrClass = NSClassFromString(@"_TtC7SLIMKit20SLTaskSessionManager");
    if (sessionMgrClass) {
        DKTaskLog(@"[OK] SLTaskSessionManager class found");
        DKTaskLog(@"  Methods: %@", [self _methodListForClass:sessionMgrClass]);
    } else {
        DKTaskLog(@"[FAIL] SLTaskSessionManager class NOT found");
    }
    
    // 尝试获取仓库实例并获取会话
    if ([self _ensureRepository]) {
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
