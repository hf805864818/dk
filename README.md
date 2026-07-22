# DK Multi-Account Tweak

为 TRAE 应用提供多账号切换功能的越狱插件，支持账号数据隔离和登录态保持。

## 功能特性

- **多账号管理**: 创建、切换、删除多个账号，每个账号数据完全隔离
- **登录态保持**: 切换账号后无需重新登录，各账号保持在线状态
- **三指长按触发**: 三手指长按屏幕显示圆形悬浮按钮
- **竖排菜单**: 点击悬浮按钮弹出账号列表，支持添加/切换/删除账号
- **数据隔离**: 基于 NSFileManager / NSUserDefaults / Keychain 的完整数据隔离
- **自动编译**: GitHub Actions 自动编译生成 .deb 和 .dylib

## 安装方式

### 方式一：包管理器安装（推荐）

1. 从 [Releases](https://github.com/hf805864818/dk/releases) 下载最新的 `.deb` 文件
2. 使用 Sileo / Cydia / Zebra 安装
3. 重启 SpringBoard

### 方式二：手动注入

1. 下载 `dk.dylib`
2. 注入到 TRAE.app 可执行文件中
3. 使用 `yololib` 或 `optool` 注入

## 使用方法

1. 打开 TRAE 应用
2. **三指长按**屏幕任意位置
3. 出现圆形蓝色 **DK** 悬浮按钮（可拖拽）
4. 点击按钮弹出账号菜单：
   - 首次使用：点击 **"➕ 添加账号"** 创建新账号
   - 已有账号：点击账号名即可切换
   - 长按账号名可删除账号

## 开发

### 构建要求

- Theos 构建系统
- iOS 15.0+ SDK
- macOS 或 Linux 构建环境

### 本地构建

```bash
# 设置 Theos 环境变量
export THEOS=/opt/theos

# 编译
make clean
make package

# 产物位置
# .deb: packages/
# .dylib: output/
```

### 版本管理

```bash
# 递增版本号（patch/minor/major）
./scripts/bump-version.sh patch

# 生成更新日志
./scripts/gen-changelog.sh
```

## 项目结构

```
dk/
├── Makefile                    # Theos 构建配置
├── control                     # 包管理信息
├── dk.plist                    # 注入过滤配置
├── Tweak.x                     # 主 Hook 入口（Logos 语法）
├── DKAccountManager.h/m        # 账号管理核心
├── DKAccountUI.h/m             # 悬浮按钮 + 菜单 UI
├── DKDataIsolation.h/m         # 数据隔离核心
├── DKFileManagerHook.h/m       # NSFileManager Hook
├── DKUserDefaultsHook.h/m      # NSUserDefaults Hook
├── DKKeychainHook.h/m          # Keychain Hook
├── DKNetworkSessionManager.h/m  # 网络会话管理
├── VERSION                     # 版本号文件
├── CHANGELOG.md                # 更新日志
├── .github/workflows/build.yml # CI/CD 自动编译
└── scripts/
    ├── bump-version.sh          # 版本号递增脚本
    └── gen-changelog.sh         # 更新日志生成脚本
```

## 技术架构

### 数据隔离原理

```
┌─────────────────────────────────────┐
│          TRAE App (注入后)           │
├─────────────────────────────────────┤
│  DKAccountUI (三指手势 + 悬浮按钮)  │
├─────────────────────────────────────┤
│  DKAccountManager (账号增删改查)    │
├─────────────────────────────────────┤
│  DKDataIsolation (路径映射)         │
│  ├── DKFileManagerHook (文件隔离)   │
│  ├── DKUserDefaultsHook (配置隔离)  │
│  └── DKKeychainHook (钥匙串隔离)    │
├─────────────────────────────────────┤
│  DKNetworkSessionManager            │
│  (Cookie/Token 保存与恢复)          │
├─────────────────────────────────────┤
│  账号数据存储:                      │
│  /var/mobile/Documents/DKAccounts/  │
│  ├── 账号A/                         │
│  │   ├── Documents/                 │
│  │   ├── Library/Preferences/       │
│  │   ├── Library/Cookies/           │
│  │   └── .dk_metadata.plist        │
│  └── 账号B/                         │
│      └── ...                        │
└─────────────────────────────────────┘
```

## 许可证

MIT License

## 免责声明

本插件仅供学习和研究使用。使用本插件可能违反目标应用的服务条款，请自行承担风险。
