# Changelog

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