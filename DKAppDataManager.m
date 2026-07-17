#import "DKAppDataManager.h"
#import "DKAccountManager.h"
#import <unistd.h>

// ============================================================
// DKAppDataManager 实现
//
// 使用 rename() 做原子级目录搬移，原因：
//   1. rename() 是原子操作，只改目录项，不复制数据
//   2. 即使文件正在被 mmap，rename() 也不影响已有映射
//      （内核通过 inode 跟踪文件，rename 不改 inode）
//   3. 搬移完成后 exit(0)，应用重启后文件在新位置
//
// 只搬移 Library/（不搬移 Documents/），因为：
//   - Library/ 包含 MMKV/WCDB/Preferences/Cookies 等所有关键数据
//   - Documents/ 包含 DKAccounts/ 备份目录自身，搬移会形成递归
//
// 与 Crane 的对比：
//   Crane 在 containermanagerd 守护进程中搬移容器目录，
//   我们直接在应用进程内搬移 Library/。
//   效果相同——都是让应用在原始路径下访问目标账号的数据。
// ============================================================

@implementation DKAppDataManager

+ (instancetype)sharedManager {
    static DKAppDataManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DKAppDataManager alloc] init];
    });
    return instance;
}

#pragma mark - 路径工具

- (NSString *)appHomePath {
    return NSHomeDirectory();
}

- (NSString *)backupRootPathForAccount:(NSString *)accountName {
    DKAccountManager *manager = [DKAccountManager sharedManager];
    if ([accountName isEqualToString:[manager defaultAccountName]]) {
        // 默认账号的备份放在 DKAccounts 根目录下
        return [manager.accountsRootPath stringByAppendingPathComponent:@".default_backup"];
    }
    // 如果此账号被指定为默认，也使用 .default_backup
    // （其数据通过 rename 搬移，与原始默认账号共享同一备份位置）
    if (manager.designatedDefaultAccountName &&
        [accountName isEqualToString:manager.designatedDefaultAccountName]) {
        return [manager.accountsRootPath stringByAppendingPathComponent:@".default_backup"];
    }
    return [[manager dataPathForAccount:accountName] stringByAppendingPathComponent:@"AppData"];
}

#pragma mark - 核心搬移逻辑

/// 安全搬移目录：将 srcDir 搬移到 dstDir
///
/// 核心策略：使用 rename() 原子交换，避免删除活跃目录（活跃目录中的文件可能被 mmap 占用，
/// removeItemAtPath 会失败）。rename() 只改目录项/inode 指针，不碰文件数据，
/// 即使文件正在被 mmap 也能成功。
///
/// 流程：
///   1. 如果 dstDir 不存在 → 直接 rename(srcDir → dstDir)
///   2. 如果 dstDir 存在 → rename(dstDir → dstDir.tmp)，rename(srcDir → dstDir)，删除 dstDir.tmp
///   3. 如果 srcDir 不存在 → 创建空 dstDir
///   4. 如果 rename 失败 → 逐个子目录搬移兜底
- (BOOL)_moveDirectory:(NSString *)srcDir toDirectory:(NSString *)dstDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    // 确保目标目录的父目录存在
    NSString *dstParent = [dstDir stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dstParent]) {
        [fm createDirectoryAtPath:dstParent
      withIntermediateDirectories:YES
                       attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                            error:&error];
        if (error) {
            NSLog(@"[DK] 创建备份父目录失败: %@ → %@", dstParent, error);
            return NO;
        }
    }

    // 如果源目录不存在，创建空的目标目录
    if (![fm fileExistsAtPath:srcDir]) {
        [fm createDirectoryAtPath:dstDir
      withIntermediateDirectories:YES
                       attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                            error:&error];
        if (error) {
            NSLog(@"[DK] 创建空目录失败: %@ → %@", dstDir, error);
            return NO;
        }
        NSLog(@"[DK] 源目录不存在，已创建空目标: %@", dstDir);
        return YES;
    }

    const char *srcPath = [srcDir fileSystemRepresentation];
    const char *dstPath = [dstDir fileSystemRepresentation];

    BOOL dstExists = [fm fileExistsAtPath:dstDir];

    if (!dstExists) {
        // 目标不存在：直接 rename 即可
        if (rename(srcPath, dstPath) == 0) {
            NSLog(@"[DK] rename 直接成功: %@ → %@", srcDir, dstDir);
            return YES;
        }
        NSLog(@"[DK] rename 直接失败 (errno=%d), 尝试 moveItemAtPath: %@ → %@",
              errno, srcDir, dstDir);
    } else {
        // 目标已存在：用 rename 做原子交换
        // 1. rename(dstDir → dstDir.tmp)  — 把旧目标挪开
        // 2. rename(srcDir → dstDir)     — 把新数据放进来
        // 3. 删除 dstDir.tmp              — 清理
        NSString *tmpDir = [dstDir stringByAppendingString:@".tmp"];
        const char *tmpPath = [tmpDir fileSystemRepresentation];

        // 先清理可能残留的 tmp 目录
        if ([fm fileExistsAtPath:tmpDir]) {
            [fm removeItemAtPath:tmpDir error:nil];
        }

        if (rename(dstPath, tmpPath) == 0) {
            NSLog(@"[DK] 已把旧目标挪到 .tmp: %@", dstDir);
            if (rename(srcPath, dstPath) == 0) {
                NSLog(@"[DK] rename 交换成功: %@ → %@", srcDir, dstDir);
                // 异步清理 tmp 目录（删除可能慢，先返回成功）
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];
                    NSLog(@"[DK] .tmp 目录已清理: %@", tmpDir);
                });
                return YES;
            } else {
                // 恢复：把旧目标挪回来
                NSLog(@"[DK] rename 第二步失败 (errno=%d), 回退", errno);
                rename(tmpPath, dstPath);
            }
        } else {
            NSLog(@"[DK] rename 第一步失败 (errno=%d): 无法把旧目标挪开", errno);
        }
    }

    // 兜底：逐个子目录搬移
    NSLog(@"[DK] rename 方案失败, 尝试逐个子目录搬移: %@ → %@", srcDir, dstDir);
    return [self _moveSubdirectories:srcDir toDirectory:dstDir];
}

/// 逐个子目录搬移（兜底方案）
- (BOOL)_moveSubdirectories:(NSString *)srcDir toDirectory:(NSString *)dstDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    [fm createDirectoryAtPath:dstDir
  withIntermediateDirectories:YES
                   attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                        error:nil];

    NSArray *contents = [fm contentsOfDirectoryAtPath:srcDir error:&error];
    if (error) {
        NSLog(@"[DK] 列出源目录内容失败: %@", error);
        return NO;
    }

    BOOL allSuccess = YES;
    for (NSString *item in contents) {
        // 跳过 DKAccounts 自身（在 Documents/ 下的子目录中可能出现）
        if ([item isEqualToString:@"DKAccounts"]) {
            NSLog(@"[DK]   ⏭ 跳过 DKAccounts 自身");
            continue;
        }

        NSString *srcItem = [srcDir stringByAppendingPathComponent:item];
        NSString *dstItem = [dstDir stringByAppendingPathComponent:item];

        // 先尝试 rename（最快）
        if (rename([srcItem fileSystemRepresentation], [dstItem fileSystemRepresentation]) == 0) {
            NSLog(@"[DK]   ✅ %@ (rename)", item);
            continue;
        }

        // 再尝试 moveItemAtPath
        if ([fm moveItemAtPath:srcItem toPath:dstItem error:&error]) {
            NSLog(@"[DK]   ✅ %@ (move)", item);
            continue;
        }

        // 最后尝试 copy + delete
        if ([fm copyItemAtPath:srcItem toPath:dstItem error:&error]) {
            [fm removeItemAtPath:srcItem error:nil];
            NSLog(@"[DK]   ✅ %@ (copy+delete)", item);
            continue;
        }

        NSLog(@"[DK]   ❌ %@: %@", item, error);
        allSuccess = NO;
    }

    // 清理源目录（如果为空）
    NSArray *remaining = [fm contentsOfDirectoryAtPath:srcDir error:nil];
    if (remaining.count == 0) {
        [fm removeItemAtPath:srcDir error:nil];
    } else {
        NSLog(@"[DK] 源目录仍有 %lu 项未搬移: %@", (unsigned long)remaining.count, remaining);
    }

    return allSuccess;
}

#pragma mark - 公开接口

- (BOOL)moveAppDataToAccount:(NSString *)accountName {
    NSString *appHome = [self appHomePath];
    NSString *backupRoot = [self backupRootPathForAccount:accountName];

    NSLog(@"[DK] ========================================");
    NSLog(@"[DK] 搬移应用数据 → 账号: %@", accountName);
    NSLog(@"[DK] 源: %@", appHome);
    NSLog(@"[DK] 目标: %@", backupRoot);

    NSString *srcLibrary = [appHome stringByAppendingPathComponent:@"Library"];
    NSString *dstLibrary = [backupRoot stringByAppendingPathComponent:@"Library"];

    if (![self _moveDirectory:srcLibrary toDirectory:dstLibrary]) {
        NSLog(@"[DK] ❌ Library/ 搬移失败，放弃本次切换");
        return NO;
    }
    NSLog(@"[DK] ✅ Library/ 搬移成功");

    // 搬移成功后才重建空目录结构
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *subdir in @[@"Library", @"Documents", @"tmp"]) {
        NSString *path = [appHome stringByAppendingPathComponent:subdir];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        }
    }

    // 确保 Library 子目录也存在
    for (NSString *subdir in @[@"Library/Preferences", @"Library/Caches",
                                @"Library/Cookies", @"Library/Application Support"]) {
        NSString *path = [appHome stringByAppendingPathComponent:subdir];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        }
    }

    NSLog(@"[DK] 应用数据搬移完成");
    return YES;
}

- (BOOL)moveAccountDataToApp:(NSString *)accountName {
    NSString *appHome = [self appHomePath];
    NSString *backupRoot = [self backupRootPathForAccount:accountName];

    NSLog(@"[DK] ========================================");
    NSLog(@"[DK] 搬移账号数据 → 应用: %@", accountName);
    NSLog(@"[DK] 源: %@", backupRoot);
    NSLog(@"[DK] 目标: %@", appHome);

    NSString *srcLibrary = [backupRoot stringByAppendingPathComponent:@"Library"];
    NSString *dstLibrary = [appHome stringByAppendingPathComponent:@"Library"];

    // 如果备份不存在（新账号），创建空目录结构即可
    if (![[NSFileManager defaultManager] fileExistsAtPath:srcLibrary]) {
        NSLog(@"[DK] 账号 %@ 无备份数据（新账号），创建空目录", accountName);
        // 用 rename 把旧 Library 挪开，再创建新的空 Library
        NSString *oldLibrary = [appHome stringByAppendingPathComponent:@"Library.old"];
        const char *oldPath = [oldLibrary fileSystemRepresentation];
        const char *dstPath = [dstLibrary fileSystemRepresentation];

        // 清理可能残留的 .old 目录
        if ([[NSFileManager defaultManager] fileExistsAtPath:oldLibrary]) {
            [[NSFileManager defaultManager] removeItemAtPath:oldLibrary error:nil];
        }

        // 把旧 Library 挪到 .old（不删除，用 rename 避免文件被占用的问题）
        if ([[NSFileManager defaultManager] fileExistsAtPath:dstLibrary]) {
            rename(dstPath, oldPath);
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dstLibrary
      withIntermediateDirectories:YES
                       attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                            error:nil];
        for (NSString *subdir in @[@"Library/Preferences", @"Library/Caches",
                                    @"Library/Cookies", @"Library/Application Support"]) {
            [fm createDirectoryAtPath:[appHome stringByAppendingPathComponent:subdir]
          withIntermediateDirectories:YES
                           attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                error:nil];
        }
        // 异步清理 .old
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [[NSFileManager defaultManager] removeItemAtPath:oldLibrary error:nil];
        });
        NSLog(@"[DK] 新账号空目录已创建");
        return YES;
    }

    if (![self _moveDirectory:srcLibrary toDirectory:dstLibrary]) {
        NSLog(@"[DK] ❌ Library/ 搬移失败");
        return NO;
    }
    NSLog(@"[DK] ✅ Library/ 搬移成功");

    // 清理备份根目录（已搬移，目录为空）
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:backupRoot]) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:backupRoot error:nil];
        if (contents.count == 0) {
            [fm removeItemAtPath:backupRoot error:nil];
        }
    }

    NSLog(@"[DK] 账号数据搬移完成");
    return YES;
}

- (BOOL)hasBackupForAccount:(NSString *)accountName {
    NSString *backupRoot = [self backupRootPathForAccount:accountName];
    NSString *libraryPath = [backupRoot stringByAppendingPathComponent:@"Library"];
    return [[NSFileManager defaultManager] fileExistsAtPath:libraryPath];
}

- (void)clearBackupForAccount:(NSString *)accountName {
    NSString *backupRoot = [self backupRootPathForAccount:accountName];
    [[NSFileManager defaultManager] removeItemAtPath:backupRoot error:nil];
    NSLog(@"[DK] 已清理账号 %@ 的备份数据", accountName);
}

@end