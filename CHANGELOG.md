# Changelog

## [1.0.109] - 2026-08-07

- b7c7f3e fix: 修复编译错误 - 合并重复的 UIApplication hook
- 9e156ac fix: 限制 WKWebView 和 APNs Hook 仅对 MonkeyCode 生效
- 2d1c0ee fix: 添加 WKWebView cookie 隔离和 APNs deviceToken 隔离


## [1.0.108] - 2026-08-07

- 2702819 feat: 适配 MonkeyCode 多开账号支持


## [1.0.107] - 2026-08-01

- f9fb9e8 feat: 新增账号置顶功能 — 长按账号后可置顶到默认账号下方


## [1.0.106] - 2026-07-26

- 58775d5 fix: 重命名后立即刷新菜单，避免显示过期列表


## [1.0.105] - 2026-07-26

- cf84364 fix: 修复重命名账号后菜单同时显示新旧名称 — 交叉校验持久化列表自动清理残留目录


## [1.0.104] - 2026-07-26

- fix: 修复重命名账号后菜单同时显示新旧名称 — refreshAccountList 交叉校验持久化列表，自动清理残留目录

## [1.0.103] - 2026-07-26

- fix: dyld_get_image_name 在新版SDK已移除，改用 dlsym 动态获取

## [1.0.102] - 2026-07-26

- feat: 新增 5 个防封号关键 Hook — HasInstallJailbreakPlugin: / getJailbreakSuspiciousModules / BypassFileCheckB: / CheckAllVersion / _bypassWCFace
- docs: 修正 DKWeChatAntiDetect.h 注释（fishhook → MSHookFunction）

## [1.0.100] - 2026-07-25

- 6864a54 fix: 修复切换默认账号无响应问题 (v1.0.99)