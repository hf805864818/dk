#import "DKTaskCleaner.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 日志宏 - 直接用 NSLog，DKLogManager 会自动捕获
// ============================================================
#define DKTaskLog(fmt, ...) \
    NSLog(@"[DKTaskCleaner] " fmt, ##__VA_ARGS__)

@interface DKTaskCleaner ()
@property (nonatomic, assign) BOOL isSupported;
@property (nonatomic, assign) BOOL hasDetected;
@property (nonatomic, strong) id storeInstance;
@property (nonatomic, strong) Class storeClass;
@property (nonatomic, strong) NSString *getAllConversationsSelectorName;
@property (nonatomic, strong) NSString *deleteConversationSelectorName;
@property (nonatomic, strong) NSString *conversationIdKeyPath;
@property (nonatomic, strong) NSString *conversationModeKeyPath;
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
        _isSupported = NO;
        _hasDetected = NO;
        _storeInstance = nil;
        _storeClass = nil;
    }
    return self;
}

#pragma mark - Public Methods

- (BOOL)isTaskCleanerSupported {
    if (!_hasDetected) {
        [self _detect];
    }
    return _isSupported;
}

- (NSInteger)taskCountForMode:(DKTaskMode)mode {
    if (!_hasDetected) {
        [self _detect];
    }
    if (!_isSupported) return 0;
    return [self _fetchConversationsForMode:mode].count;
}

- (void)clearTasksForMode:(DKTaskMode)mode
               completion:(void (^)(BOOL, NSInteger, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!self->_isSupported) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, 0, @"功能不支持");
            });
            return;
        }
        
        NSArray *conversations = [self _fetchConversationsForMode:mode];
        NSInteger totalCount = conversations.count;
        NSInteger deletedCount = 0;
        
        DKTaskLog(@"开始清理任务，模式=%ld，总数=%ld", (long)mode, (long)totalCount);
        
        for (id conv in conversations) {
            @try {
                NSString *convId = nil;
                if (self.conversationIdKeyPath) {
                    id val = [conv valueForKeyPath:self.conversationIdKeyPath];
                    if ([val isKindOfClass:[NSString class]]) {
                        convId = val;
                    }
                }
                if (!convId) {
                    convId = [conv valueForKey:@"identifier"];
                }
                if (!convId) {
                    convId = [conv valueForKey:@"conversationId"];
                }
                if (!convId) {
                    convId = [conv valueForKey:@"ID"];
                }
                
                if (convId) {
                    [self _deleteConversationWithId:convId];
                    deletedCount++;
                }
            } @catch (NSException *e) {
                DKTaskLog(@"删除会话失败: %@", e);
            }
        }
        
        DKTaskLog(@"清理完成，成功删除 %ld / %ld 个任务", (long)deletedCount, (long)totalCount);
        
        // 发送刷新通知
        [self _postUpdateNotification];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(deletedCount > 0, deletedCount, nil);
        });
    });
}

- (void)dumpRuntimeInfo {
    if (!_hasDetected) {
        [self _detect];
    }
}

#pragma mark - Private Detection

- (void)_detect {
    if (_hasDetected) return;
    _hasDetected = YES;
    
    DKTaskLog(@"开始探测会话存储类...");
    
    // 候选类名（按优先级排列）
    NSArray *candidateNames = @[
        // 从崩溃日志中发现的类
        @"AFConversationStore",
        // SLIM 相关
        @"SLIMConversationRepository",
        @"_TtC7SLIMKit26SLIMConversationRepository",
        @"$s7SLIMKit26SLIMConversationRepositoryC",
        @"SLIMKit.SLIMConversationRepository",
        @"SLConversationRepository",
        @"SLTaskSessionManager",
        @"_TtC7SLIMKit20SLTaskSessionManager",
        // 其他可能
        @"ConversationStore",
        @"ConversationManager",
        @"TaskStore",
        @"TaskManager",
    ];
    
    Class foundClass = nil;
    id foundInstance = nil;
    
    for (NSString *name in candidateNames) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        
        DKTaskLog(@"  找到候选类: %@", name);
        
        // 检查是否有会话相关方法
        if (![self _classHasConversationMethods:cls]) {
            DKTaskLog(@"    跳过：没有会话相关方法");
            continue;
        }
        
        // 尝试获取单例
        id instance = [self _getSingletonOfClass:cls];
        if (instance) {
            foundClass = cls;
            foundInstance = instance;
            DKTaskLog(@"    成功获取实例");
            break;
        }
    }
    
    // 如果预设候选都没找到，枚举所有类
    if (!foundClass) {
        DKTaskLog(@"  预设候选未找到，开始全类枚举搜索...");
        foundClass = [self _enumerateClassesForConversationStoreWithInstance:&foundInstance];
    }
    
    if (foundClass && foundInstance) {
        _storeClass = foundClass;
        _storeInstance = foundInstance;
        
        // 探测方法名
        [self _detectMethods];
        
        _isSupported = (_getAllConversationsSelectorName != nil);
        
        DKTaskLog(@"探测完成: 类=%@, 支持=%d", NSStringFromClass(foundClass), _isSupported);
    } else {
        DKTaskLog(@"探测失败: 未找到合适的会话存储类");
        _isSupported = NO;
    }
}

- (BOOL)_classHasConversationMethods:(Class)cls {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    BOOL hasConversation = NO;
    
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        NSString *lower = name.lowercaseString;
        
        if ([lower containsString:@"conversation"]) {
            hasConversation = YES;
            break;
        }
    }
    
    free(methods);
    return hasConversation;
}

- (id)_getSingletonOfClass:(Class)cls {
    SEL selectors[] = {
        @selector(sharedStore),
        @selector(sharedManager),
        @selector(sharedInstance),
        @selector(shared),
        @selector(defaultStore),
        @selector(defaultManager),
        @selector(defaultRepository),
    };
    
    for (int i = 0; i < sizeof(selectors)/sizeof(SEL); i++) {
        SEL sel = selectors[i];
        if ([cls respondsToSelector:sel]) {
            @try {
                IMP imp = [cls methodForSelector:sel];
                id (*func)(id, SEL) = (void *)imp;
                id result = func(cls, sel);
                if (result) {
                    DKTaskLog(@"    通过 %@ 获取到实例", NSStringFromSelector(sel));
                    return result;
                }
            } @catch (NSException *e) {
                DKTaskLog(@"    调用 %@ 异常: %@", NSStringFromSelector(sel), e);
            }
        }
    }
    
    return nil;
}

- (Class)_enumerateClassesForConversationStoreWithInstance:(id *)outInstance {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return nil;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    
    Class bestClass = nil;
    id bestInstance = nil;
    NSInteger bestScore = -1;
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        NSString *lower = name.lowercaseString;
        
        // 跳过系统类和非存储/管理类
        if (!([lower containsString:@"conversation"] ||
              [lower containsString:@"chat"] ||
              [lower containsString:@"message"])) {
            continue;
        }
        if (!([lower containsString:@"store"] ||
              [lower containsString:@"manager"] ||
              [lower containsString:@"repository"] ||
              [lower containsString:@"helper"] ||
              [lower containsString:@"service"])) {
            continue;
        }
        
        // 计算分数
        NSInteger score = 0;
        if ([lower containsString:@"conversation"]) score += 10;
        if ([lower containsString:@"store"]) score += 5;
        if ([lower containsString:@"manager"]) score += 3;
        if ([lower containsString:@"af"]) score += 3;  // AF前缀
        if ([lower containsString:@"slim"]) score += 2;
        
        // 检查是否有会话相关方法
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSInteger methodScore = 0;
        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *mName = NSStringFromSelector(sel).lowercaseString;
            if ([mName containsString:@"conversation"]) methodScore++;
            if ([mName containsString:@"fetch"] || [mName containsString:@"get"]) methodScore++;
            if ([mName containsString:@"delete"] || [mName containsString:@"remove"]) methodScore++;
            if ([mName containsString:@"all"]) methodScore++;
        }
        free(methods);
        
        score += methodScore;
        
        if (score > bestScore) {
            // 尝试获取单例
            id instance = [self _getSingletonOfClass:cls];
            if (instance) {
                bestScore = score;
                bestClass = cls;
                bestInstance = instance;
                DKTaskLog(@"    找到更好的候选: %@ (分数=%ld)", name, (long)score);
            }
        }
    }
    
    free(classes);
    
    if (bestClass && bestInstance) {
        if (outInstance != NULL) {
            *outInstance = bestInstance;
        }
        return bestClass;
    }
    return nil;
}

- (void)_detectMethods {
    if (!_storeClass) return;
    
    DKTaskLog(@"  探测方法名...");
    
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(_storeClass, &methodCount);
    
    NSMutableArray *getterCandidates = [NSMutableArray array];
    NSMutableArray *deleterCandidates = [NSMutableArray array];
    
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        NSString *lower = name.lowercaseString;
        
        // 获取所有会话的方法
        if (([lower containsString:@"allconversation"] ||
             [lower containsString:@"conversationlist"] ||
             [lower containsString:@"fetchconversation"] ||
             [lower containsString:@"getconversation"]) &&
            ([lower containsString:@"all"] ||
             [lower containsString:@"list"])) {
            [getterCandidates addObject:name];
        }
        
        // 删除会话的方法
        if (([lower containsString:@"deleteconversation"] ||
             [lower containsString:@"removeconversation"]) &&
            ![lower containsString:@"all"]) {
            [deleterCandidates addObject:name];
        }
    }
    
    free(methods);
    
    DKTaskLog(@"    获取方法候选: %@", getterCandidates);
    DKTaskLog(@"    删除方法候选: %@", deleterCandidates);
    
    // 选择最合适的获取方法
    if (getterCandidates.count > 0) {
        _getAllConversationsSelectorName = getterCandidates.firstObject;
        DKTaskLog(@"    选中获取方法: %@", _getAllConversationsSelectorName);
    }
    
    // 选择最合适的删除方法
    if (deleterCandidates.count > 0) {
        _deleteConversationSelectorName = deleterCandidates.firstObject;
        DKTaskLog(@"    选中删除方法: %@", _deleteConversationSelectorName);
    }
    
    // 探测会话模型属性
    [self _detectConversationModelProperties];
}

- (void)_detectConversationModelProperties {
    NSArray *convs = [self _fetchAllConversations];
    if (convs.count == 0) {
        DKTaskLog(@"    没有会话数据，无法探测模型属性");
        return;
    }
    
    id firstConv = convs.firstObject;
    Class convClass = [firstConv class];
    DKTaskLog(@"    会话模型类: %@", NSStringFromClass(convClass));
    
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(convClass, &propCount);
    
    NSMutableArray *propNames = [NSMutableArray array];
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        NSString *propName = [NSString stringWithUTF8String:name];
        [propNames addObject:propName];
        
        NSString *lower = propName.lowercaseString;
        // 找 ID 属性
        if ([lower isEqualToString:@"identifier"] ||
            [lower isEqualToString:@"conversationid"] ||
            [lower isEqualToString:@"id"] ||
            [lower isEqualToString:@"uid"]) {
            _conversationIdKeyPath = propName;
        }
        // 找 mode 属性
        if ([lower isEqualToString:@"mode"] ||
            [lower isEqualToString:@"type"] ||
            [lower containsString:@"mode"] ||
            [lower containsString:@"type"]) {
            _conversationModeKeyPath = propName;
        }
    }
    
    free(props);
    
    DKTaskLog(@"    会话属性: %@", propNames);
    DKTaskLog(@"    ID属性: %@", _conversationIdKeyPath);
    DKTaskLog(@"    Mode属性: %@", _conversationModeKeyPath);
}

#pragma mark - Private Data Operations

- (NSArray *)_fetchAllConversations {
    if (!_storeInstance || !_getAllConversationsSelectorName) {
        return @[];
    }
    
    SEL selector = NSSelectorFromString(_getAllConversationsSelectorName);
    if (![_storeInstance respondsToSelector:selector]) {
        return @[];
    }
    
    @try {
        IMP imp = [_storeInstance methodForSelector:selector];
        NSArray* (*func)(id, SEL) = (void *)imp;
        NSArray *result = func(_storeInstance, selector);
        return result ?: @[];
    } @catch (NSException *e) {
        DKTaskLog(@"获取会话列表异常: %@", e);
        return @[];
    }
}

- (NSArray *)_fetchConversationsForMode:(DKTaskMode)mode {
    NSArray *allConvs = [self _fetchAllConversations];
    if (mode == DKTaskModeAll) {
        return allConvs;
    }
    
    NSMutableArray *filtered = [NSMutableArray array];
    NSString *targetMode = (mode == DKTaskModeWork) ? @"work" : @"code";
    
    for (id conv in allConvs) {
        @try {
            NSString *modeValue = nil;
            if (_conversationModeKeyPath) {
                id val = [conv valueForKeyPath:_conversationModeKeyPath];
                if ([val isKindOfClass:[NSString class]]) {
                    modeValue = (NSString *)val;
                } else if ([val isKindOfClass:[NSNumber class]]) {
                    modeValue = [(NSNumber *)val stringValue];
                }
            }
            
            // 如果没找到mode属性，假设所有会话都是work模式（保守处理）
            if (!_conversationModeKeyPath) {
                if (mode == DKTaskModeWork) {
                    [filtered addObject:conv];
                }
                continue;
            }
            
            if (modeValue && [modeValue.lowercaseString containsString:targetMode]) {
                [filtered addObject:conv];
            }
        } @catch (NSException *e) {
            // 忽略单个会话的错误
        }
    }
    
    return filtered;
}

- (void)_deleteConversationWithId:(NSString *)convId {
    if (!_storeInstance || !_deleteConversationSelectorName || !convId) {
        return;
    }
    
    SEL selector = NSSelectorFromString(_deleteConversationSelectorName);
    if (![_storeInstance respondsToSelector:selector]) {
        return;
    }
    
    @try {
        NSMethodSignature *sig = [_storeInstance methodSignatureForSelector:selector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        invocation.target = _storeInstance;
        invocation.selector = selector;
        
        // 第一个参数设为 convId
        [invocation setArgument:&convId atIndex:2];
        
        [invocation invoke];
    } @catch (NSException *e) {
        DKTaskLog(@"调用删除方法异常: %@", e);
    }
}

- (void)_postUpdateNotification {
    // 尝试已知的通知名
    NSArray *notifNames = @[
        @"kUpdateConversationListNotification",
        @"SLConversationListDidUpdateNotification",
        @"AFConversationListDidChangeNotification",
        @"ConversationListDidUpdateNotification",
    ];
    
    for (NSString *name in notifNames) {
        @try {
            [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
        } @catch (NSException *e) {
            // 忽略
        }
    }
}

@end
