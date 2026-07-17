#import "DKAppDataManager.h"
#import "DKAccountManager.h"
#import <unistd.h>

// ============================================================
// DKAppDataManager 实现
//
// 使用 rename() 做子目录级搬移，原因：
//   1. 整目录 rename() 在 iOS 上可能因沙盒限制失败
//   2. 子目录 rename() 只改目录项，不碰文件数据，即使文件正在被 mmap 也能成功
//   3. 搬移完成后 exit(0)，应用重启后文件在新位置
//
// 数据所有权标记：
//   在 Library/ 根目录写入 .dk_library_owner 文件，标记当前沙盒中
//   数据属于哪个账号。启动时检测到不匹配则自动恢复。
//
// 只搬移 Library/（不搬移 Documents/），因为：
//   - Library/ 包含 MMKV/WCDB/Preferences/Cookies 等所有关键数据
//   - Documents/ 包含 DKAccounts/ 备份目录自身，搬移会形成递归
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

/// 安全搬移目录：将 srcDir 的内容搬移到 dstDir
///
/// 核心策略：不使用整目录 rename()（iOS 上 Library/ 可能因包含 mmap 文件而失败），
/// 而是逐个子目录搬移。rename() 只改目录项/inode 指针，不碰文件数据，
/// 即使文件正在被 mmap 也能成功。
///
/// 流程：
///   1. 逐个子目录 rename(srcDir/item → dstDir/item)
///   2. 失败的子目录用 moveItemAtPath 兜底
///   3. 仍失败的子目录用 copyItemAtPath + removeItemAtPath 兜底
///   4. 始终返回 YES（部分失败不阻塞整体流程）
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

    // 直接逐个子目录搬移，跳过整目录 rename
    // iOS 上整目录 rename 因沙盒限制大概率失败
    return [self _moveSubdirectories:srcDir toDirectory:dstDir];
}

/// 逐个子目录搬移
/// 始终返回 YES —— 个别子目录搬移失败不阻塞整体流程。
/// 失败的子目录会被记录日志但不会导致账号切换失败。
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
        // 即使列出失败也返回 YES，不阻塞整体流程
        return YES;
    }

    for (NSString *item in contents) {
        // 跳过 DKAccounts 自身（在 Documents/ 下的子目录中可能出现）
        if ([item isEqualToString:@"DKAccounts"]) {
            NSLog(@"[DK]   ⏭ 跳过 DKAccounts 自身");
            continue;
        }

        NSString *srcItem = [srcDir stringByAppendingPathComponent:item];
        NSString *dstItem = [dstDir stringByAppendingPathComponent:item];

        // 如果目标子目录已存在，先移到 .tmp 再重试
        if ([fm fileExistsAtPath:dstItem]) {
            NSString *tmpItem = [dstItem stringByAppendingString:@".tmp"];
            [fm removeItemAtPath:tmpItem error:nil];
            rename([dstItem fileSystemRepresentation], [tmpItem fileSystemRepresentation]);
            // 异步清理 tmp
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                [[NSFileManager defaultManager] removeItemAtPath:tmpItem error:nil];
            });
        }

        // 先尝试 rename（最快，只改目录项）
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

        // 三层都失败，记录日志但不阻塞
        NSLog(@"[DK]   ⚠️ %@ 搬移失败（跳过）: %@", item, error);
    }

    // 清理源目录（如果为空）
    NSArray *remaining = [fm contentsOfDirectoryAtPath:srcDir error:nil];
    if (remaining.count == 0) {
        [fm removeItemAtPath:srcDir error:nil];
    } else {
        NSLog(@"[DK] 源目录仍有 %lu 项未搬移: %@", (unsigned long)remaining.count, remaining);
    }

    // 始终返回 YES，不因个别失败阻塞
    return YES;
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

        // 把旧 Library 的内容搬移到临时目录（不删除，用 rename 避免文件被占用的问题）
        // 使用 _moveSubdirectories 而非单次 rename，更可靠
        if ([[NSFileManager defaultManager] fileExistsAtPath:dstLibrary]) {
            NSString *oldLibrary = [appHome stringByAppendingPathComponent:@"Library.old"];
            // 清理可能残留的 .old 目录
            if ([[NSFileManager defaultManager] fileExistsAtPath:oldLibrary]) {
                // 先尝试 rename 到 .old.1，如果也失败则不管
                NSString *olderLibrary = [appHome stringByAppendingPathComponent:@"Library.old.1"];
                [[NSFileManager defaultManager] removeItemAtPath:olderLibrary error:nil];
                rename([oldLibrary fileSystemRepresentation], [olderLibrary fileSystemRepresentation]);
            }
            // 把旧 Library 的子目录逐一搬移到 .old
            [self _moveSubdirectories:dstLibrary toDirectory:oldLibrary];
            // 清理残留的 Library 目录（如果为空）
            [[NSFileManager defaultManager] removeItemAtPath:dstLibrary error:nil];
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
            NSString *oldLib = [appHome stringByAppendingPathComponent:@"Library.old"];
            [[NSFileManager defaultManager] removeItemAtPath:oldLib error:nil];
            NSString *olderLib = [appHome stringByAppendingPathComponent:@"Library.old.1"];
            [[NSFileManager defaultManager] removeItemAtPath:olderLib error:nil];
        });
        NSLog(@"[DK] 新账号空目录已创建");
        [self _writeLibraryOwner:accountName];
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
    [self _writeLibraryOwner:accountName];
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

static NSString *const kDKLibraryOwnerFile = @".dk_library_owner";

#pragma mark - 递归删除工具

/// 递归删除目录内容（不删除目录本身）。
/// 先删除文件，再递归进入子目录。单文件/空目录的 removeItemAtPath 在 %ctor 阶段必定成功。
/// 这与 rename() 不同：rename() 在 iOS 上可能因沙箱限制失败，
/// 但 removeItemAtPath 针对单个文件/空目录总是可行的。
- (void)_recursiveDeleteContentsOfDirectory:(NSString *)dirPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (!contents) return;

    for (NSString *item in contents) {
        // 跳过所有权标记文件（后续会重新写入）
        if ([item isEqualToString:kDKLibraryOwnerFile]) continue;

        NSString *itemPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        [fm fileExistsAtPath:itemPath isDirectory:&isDir];

        if (isDir) {
            [self _recursiveDeleteContentsOfDirectory:itemPath];
            [fm removeItemAtPath:itemPath error:nil];
        } else {
            [fm removeItemAtPath:itemPath error:nil];
        }
    }
}

#pragma mark - 数据所有权标记

- (void)_writeLibraryOwner:(NSString *)accountName {
    NSString *ownerPath = [[self appHomePath] stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/%@", kDKLibraryOwnerFile]];
    [accountName writeToFile:ownerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[DK] 写入 Library 所有权标记: %@", accountName);
}

- (NSString *)_readLibraryOwner {
    NSString *ownerPath = [[self appHomePath] stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/%@", kDKLibraryOwnerFile]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:ownerPath]) {
        return nil;
    }
    NSString *name = [NSString stringWithContentsOfFile:ownerPath encoding:NSUTF8StringEncoding error:nil];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)ensureDataOwnershipForAccount:(NSString *)currentAccount
                    designatedDefault:(NSString *)designatedDefault {
    NSString *defaultAccount = [[DKAccountManager sharedManager] defaultAccountName];

    // 指定默认账号 → 等同于默认账号，写入标记即可
    if (designatedDefault && [currentAccount isEqualToString:designatedDefault]) {
        [self _writeLibraryOwner:currentAccount];
        return;
    }

    NSString *owner = [self _readLibraryOwner];
    NSLog(@"[DK] 启动时数据所有权检查: 当前账号=%@, Library所有者=%@, 指定默认=%@",
          currentAccount, owner ?: @"无", designatedDefault ?: @"无");

    // 如果所有权标记匹配，一切正常
    if (owner && [owner isEqualToString:currentAccount]) {
        NSLog(@"[DK] 数据所有权匹配，无需恢复");
        return;
    }

    // 默认账号且无所有权标记 → 正常启动，无需交换
    if ([currentAccount isEqualToString:defaultAccount] && !owner) {
        return;
    }

    // ============================================================
    // 所有权不匹配：在 %ctor 中执行数据交换。
    // 此时 App 尚未初始化，MMKV/WCDB 等库未打开任何文件。
    //
    // 策略：
    //   1. 先尝试 rename() 整个 Library/（最快，只改 inode 指针）
    //   2. rename() 失败时，用递归删除清空 Library/ 内容
    //      （不依赖 _moveSubdirectories，因为 rename 子目录也可能失败，
    //        且 removeItemAtPath 对非空目录静默失败）
    //   3. 创建空目录结构或恢复目标账号数据
    // ============================================================
    NSString *sandboxLib = [[self appHomePath] stringByAppendingPathComponent:@"Library"];
    NSString *oldOwner = owner ?: defaultAccount;
    NSFileManager *fm = [NSFileManager defaultManager];

    // Step 1: 备份当前 Library/ 到旧所有者
    NSString *oldBackup = [self backupRootPathForAccount:oldOwner];
    NSString *oldBackupLib = [oldBackup stringByAppendingPathComponent:@"Library"];

    [fm createDirectoryAtPath:oldBackup
  withIntermediateDirectories:YES
                   attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                        error:nil];

    // 如果旧备份已存在，挪开
    if ([fm fileExistsAtPath:oldBackupLib]) {
        NSString *tmpLib = [oldBackupLib stringByAppendingString:@".tmp"];
        [fm removeItemAtPath:tmpLib error:nil];
        rename([oldBackupLib fileSystemRepresentation], [tmpLib fileSystemRepresentation]);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [[NSFileManager defaultManager] removeItemAtPath:tmpLib error:nil];
        });
    }

    const char *srcPath = [sandboxLib fileSystemRepresentation];
    const char *dstPath = [oldBackupLib fileSystemRepresentation];

    BOOL renameSucceeded = (rename(srcPath, dstPath) == 0);

    if (renameSucceeded) {
        NSLog(@"[DK] ✅ rename Library/ → 「%@」备份", oldOwner);
    } else {
        // ============================================================
        // rename() 失败：改用递归删除 + 重建策略。
        //
        // 为什么不用 _moveSubdirectories？
        //   _moveSubdirectories 内部也用 rename() 逐个子目录搬移，
        //   如果整目录 rename 失败，子目录 rename 大概率也失败。
        //   且失败后 removeItemAtPath 对非空目录静默失败，
        //   导致旧数据残留。
        //
        // 递归删除为什么可靠？
        //   %ctor 阶段 App 未初始化，所有文件空闲。
        //   先递归删除子目录内容 → 空目录 → removeItemAtPath 成功。
        //   文件 removeItemAtPath 在无 fd 占用时必定成功。
        // ============================================================
        NSLog(@"[DK] ⚠️ rename Library/ 失败 (errno=%d), 改用递归删除策略", errno);

        // 先尝试把能搬的子目录搬走（保底备份）
        [self _moveSubdirectories:sandboxLib toDirectory:oldBackupLib];

        // 递归删除 Library/ 中残留的所有内容
        [self _recursiveDeleteContentsOfDirectory:sandboxLib];
        NSLog(@"[DK] 递归删除 Library/ 内容完成");
    }

    // Step 2: 恢复目标账号数据或创建空目录
    NSString *targetBackup = [self backupRootPathForAccount:currentAccount];
    NSString *targetBackupLib = [targetBackup stringByAppendingPathComponent:@"Library"];

    if ([fm fileExistsAtPath:targetBackupLib]) {
        // 有备份：rename 到沙盒
        if (rename([targetBackupLib fileSystemRepresentation], srcPath) == 0) {
            NSLog(@"[DK] ✅ rename 「%@」备份 → Library/", currentAccount);
        } else {
            NSLog(@"[DK] ⚠️ rename 恢复失败 (errno=%d), 逐个子目录搬移", errno);
            [self _moveSubdirectories:targetBackupLib toDirectory:sandboxLib];
        }
    } else {
        // 新账号无备份：创建空 Library/
        // 如果 rename 成功，Library/ 已被移走，sandboxLib 不存在。
        // 如果 rename 失败，Library/ 已被递归清空，sandboxLib 是空目录。
        // 两种情况下都需要确保子目录存在。
        if (![fm fileExistsAtPath:sandboxLib]) {
            [fm createDirectoryAtPath:sandboxLib
          withIntermediateDirectories:YES
                           attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                error:nil];
        }
        NSLog(@"[DK] 「%@」无备份，创建空目录结构", currentAccount);
        for (NSString *sub in @[@"Preferences", @"Caches", @"Cookies", @"Application Support"]) {
            NSString *subPath = [sandboxLib stringByAppendingPathComponent:sub];
            if (![fm fileExistsAtPath:subPath]) {
                [fm createDirectoryAtPath:subPath
              withIntermediateDirectories:YES
                               attributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                    error:nil];
            }
        }
    }

    // Step 3: 写入所有权标记
    [self _writeLibraryOwner:currentAccount];
    NSLog(@"[DK] ✅ 数据所有权修复完成: %@ → %@", oldOwner, currentAccount);
}

@end