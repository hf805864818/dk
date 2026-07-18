# Changelog

## [1.0.64] - 2026-07-18

- 6e275d1 修复：重命名后旧名称仍显示在账号列表


## [1.0.63] - 2026-07-18

- cac2123 修复编译错误：删除 ⭐ 按钮时遗漏闭合括号
- 56101c3 长按菜单重构：⭐按钮改为「设为默认账号」选项


## [1.0.62] - 2026-07-18

- db2e7b3 新增长按重命名账号功能


## [1.0.61] - 2026-07-18

- cda2e92 修复：账号列表错误显示 .default_backup 和 _default_keychain_


## [1.0.60] - 2026-07-18

- 4f131fb 修复：refreshAccountList 找不到 B 账号（.dk_metadata.plist 被误删）


## [1.0.59] - 2026-07-18

- 550dc37 根本性修复：三大致命缺陷导致账号切换后数据丢失


## [1.0.58] - 2026-07-18

- da6b618 修复子账号 NSUserDefaults 隔离 plist 丢失问题


## [1.0.57] - 2026-07-18

- 347b639 fix: backup and restore Documents/ (MMKV data) alongside Library/ in ensureDataOwnershipForAccount


## [1.0.56] - 2026-07-17

- 5d3d4db fix: reorder _currentAccountName assignment in switchToAccount handler


## [1.0.55] - 2026-07-17

- 2d35d6b fix: re-apply session after restoring .default_backup to prevent stale token


## [1.0.54] - 2026-07-17

- f5b5670 fix: ensureDataOwnershipForAccount backup logic — don't overwrite valid backups


## [1.0.53] - 2026-07-17

- c43a553 fix: add DKFileManagerHook.m to Makefile source list
- f3cd363 fix: add extern declaration for DKRemapFilePath in Tweak.x
- e7cabb2 fix: add POSIX hooks (open/stat/access/fopen) to intercept MMKV/WCDB direct file I/O


## [1.0.52] - 2026-07-17

- a8bc754 fix: CFPreferences/Keychain Hook 缺少 isSwitching 守卫导致账号切换失败


## [1.0.51] - 2026-07-17

- 4163f36 fix: 拦截Keychain宽查询避免子账号读取默认账号登录态


## [1.0.50] - 2026-07-17

- c8e8276 fix: rename()失败时用递归删除代替不可靠的_moveSubdirectories，解决旧数据残留导致子账号启动显示默认账号界面


## [1.0.49] - 2026-07-17

- fd67045 根本修复: 子账号使用自定义 dk_<bundleID>.plist 绕过 cfprefsd 缓存


## [1.0.48] - 2026-07-17

- a8cdabc 关键修复: 非默认账号无条件清空 NSUserDefaults + 强制 cfprefsd 同步


## [1.0.47] - 2026-07-17

- 9ff1c24 根本修复: 目录搬移从 exit(0) 前移到 %ctor 启动时


## [1.0.46] - 2026-07-17

- a3c8fb5 根本修复: 子目录级搬移 + 数据所有权自动修复


## [1.0.45] - 2026-07-17

- 74c094f 关键修复: 消除 Hook 重定向与目录搬移的路径冲突


## [1.0.44] - 2026-07-17

- f700250 修复: 用 rename() 原子交换替代 removeItemAtPath 删除活跃目录


## [1.0.43] - 2026-07-17

- 571c5f2 修复: 目录搬移健壮性 + 菜单⭐按钮一键设为默认


## [1.0.42] - 2026-07-17

- be5371f 修复: 补回被误删的 Keychain extern 函数声明 (DKRemapKeychainQuery 等4个)
- ece0bef 新增: 指定默认账号功能 - 设为默认账号后更新插件无需重新登录
- bc19866 修复: 借鉴Crane容器级隔离 + 修补NSUserDefaults域级Hook + 移除文件路径Hook


## [1.0.41] - 2026-07-17

- 03d7e78 fix: 添加 CFPreferences 非 App 版本 Hook，修复切换账号后登录态丢失


## [1.0.40] - 2026-07-16

- ec714c7 修复账号切换数据丢失问题（根因版）


## [1.0.39] - 2026-07-16

- 9e16a1e 修复账号切换后数据丢失问题


## [1.0.38] - 2026-07-16

- 18061cb fix: 恢复 POSIX 文件 I/O Hook，解决子账号读取默认账号数据库的问题


## [1.0.37] - 2026-07-16

- 66a078c fix: 去掉 %ctor 中 2 秒延迟，Hook 在 App 初始化前立即安装


## [1.0.36] - 2026-07-16

- dfe1eab fix: 修复三个账号切换潜在问题


## [1.0.35] - 2026-07-16

- 17748ab fix: 用 fishhook 替换 MSHookFunction，修复 iOS 17 W^X 保护导致闪退


## [1.0.34] - 2026-07-16

- 8370a17 fix: 移除 dk.plist 中错误的 com.apple.AppStore 过滤 + 增强诊断日志


## [1.0.33] - 2026-07-16

- 53581d5 fix: .dk_current_account 写入被文件Hook重定向到子账号隔离目录


## [1.0.32] - 2026-07-16

- bed5c7b fix: 当前账号状态持久化到独立文件，解决子账号启动回默认的问题


## [1.0.30] - 2026-07-16

- 68ed0c9 fix: 子账号启动前临时清空默认账号Keychain


## [1.0.29] - 2026-07-16

- d6b22fe fix: 修复子账号启动后显示默认账号页面的问题


## [1.0.28] - 2026-07-16

- a91faf8 fix: 修复编译错误 - DKAccountUI.h 缺少 triggerShowFloatingButton 声明
- cf8b073 feat: 添加摇晃手机显示悬浮按钮功能


## [1.0.26] - 2026-07-16

- f1a1cef fix: 修复注入插件后App启动闪退 - 延迟安装所有Hook


## [1.0.23] - 2026-07-16

- f1ec95f fix: full defaults domain snapshot and multi-class keychain backup


## [1.0.22] - 2026-07-16

- fefd6d5 fix: remove sharedUserDefaults call and protect keychain delete
- f39effa fix: add CFPreferences hooks and default keychain backup


## [1.0.21] - 2026-07-16

- c9846c0 fix: strengthen defaults and keychain isolation


## [1.0.20] - 2026-07-16

- 886fec9 fix: prevent target session snapshot pollution during switch


## [1.0.19] - 2026-07-16

- 8068a3e fix: do not clear default account auth keys on restore


## [1.0.18] - 2026-07-16

- 38b665e feat: add multi-account data cleanup


## [1.0.17] - 2026-07-16

- 94b9a7e fix: clear stale auth state when switching accounts


## [1.0.16] - 2026-07-16

- 7108a09 fix: handle missing default snapshot after upgrade


## [1.0.15] - 2026-07-16

- f3afc76 fix: snapshot default account before adding sub accounts


## [1.0.14] - 2026-07-16

- 3a935bb fix: preserve default account session when switching


## [1.0.13] - 2026-07-16

- 83c8753 fix: 添加 POSIX openat() Hook — 修复切换回默认账号后登录页问题


## [1.0.12] - 2026-07-16

- cd02dfd fix: synchronize 非默认账号不调用 %orig; 添加 resetStandardUserDefaults 拦截; 添加 kSecAttrLabel/kSecAttrGeneric Keychain 映射


## [1.0.11] - 2026-07-16

- d38dd1c fix: 修复refreshAccountList默认账号恢复逻辑 + saveCurrentState写入原NSUserDefaults


## [1.0.10] - 2026-07-16

- 06aa633 fix: 将POSIX Hook函数声明移到%ctor之前解决编译错误
- d0de597 fix: 移除创建账号时复制NSUserDefaults + 添加POSIX open/stat/access Hook
- db711e4 fix: 新增 NSURL/NSFileHandle/NSKeyedArchiver 文件 Hook + POSIX fopen Hook


## [1.0.9] - 2026-07-16

- 27e01c4 fix: 添加 NSData/NSDictionary/NSArray 等文件操作 Hook


## [1.0.8] - 2026-07-16

- 7e5e395 fix: 真正修复账号隔离 + 添加 exit(0) 重启


## [1.0.7] - 2026-07-16

- ac22922 fix: 彻底重写 NSUserDefaults Hook 架构，消除无限递归崩溃


## [1.0.6] - 2026-07-16

- 9aa3f0e fix: 菜单添加默认账号，支持切换回原始 TRAE 登录
- 3a573a8 fix: 修复添加账号时栈溢出崩溃（已恢复）


## [1.0.5] - 2026-07-16

- 295bd0d fix: 缩小按钮尺寸 + 修复菜单闪一下消失的异步竞争


## [1.0.4] - 2026-07-16

- 4601560 fix: 修复悬浮按钮闪一下消失的异步竞争 bug


## [1.0.3] - 2026-07-16

- 645f1f8 fix: 将所有 %hook 块移到 %ctor 之前
- 25cff54 ci: 强制重新编译（清除缓存）
- 599c07a fix: %init 移到 %ctor 最开头（autoreleasepool 之前）
- 0482c5b fix: %ctor 中缺少 %init; 导致所有 %hook 不生效


## [1.0.2] - 2026-07-16

- 2d24488 fix: 全面修复三指长按无反应问题


## [1.0.1] - 2026-07-16

- 94bce4a fix: 全面修复编译问题
- 6a722c9 fix: DKPushNotificationBridge 头文件导入 + 常量名修正
- 0f74b5b fix: DKNetworkSessionManager.m 缺少 UIKit 头文件导入
- edb42db fix: 将 original_SecItem* 声明移到 %ctor 之前
- f5fe60c fix: 修复 2 个 Logos 编译错误
- cfba7ff fix: 修复 4 类 Theos/Logos 编译错误
- ac590b6 fix: 修复 CI 编译失败 + 敏感词过滤绕过添加独立开关
- 7c3b581 feat: 新增敏感词过滤绕过模块 (DKContentFilterBypass)
- 0b44793 feat: 版本号自动注入编译二进制
- 32413ef fix: 优化 GitHub Actions CI/CD 配置


All notable changes to DK Multi-Account Tweak will be documented in this file.

## [1.0.0] - 2026-07-16

### Added
- 初始版本发布
- 核心多账号数据隔离功能
- 三指长按触发圆形悬浮图标
- 竖排菜单标签栏（添加账号 / 已添加账号列表）
- 账号切换保持登录态
- 基于 NSFileManager / NSUserDefaults / Keychain 的 Hook 数据隔离
- GitHub Actions 自动编译 CI/CD