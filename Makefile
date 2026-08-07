# DK Multi-Account Tweak Makefile
# Target: iOS (rootless + rootful兼容)
# 支持多应用注入

export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

# 支持 rootless 和 rootful
THEOS_PACKAGE_SCHEME = rootless

# 注入目标进程（可多个）
INSTALL_TARGET_PROCESSES = TRAE MonkeyCode

# ============================================================
# 从 VERSION 文件读取版本号，作为编译宏注入
# ============================================================
DK_VERSION := $(shell cat $(THEOS_PROJECT_DIR)/VERSION 2>/dev/null || echo "1.0.0")
DK_BUILD_TIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

include $(THEOS)/makefiles/common.mk

# ============================================================
# Tweak 定义
# ============================================================
TWEAK_NAME = dk

# 源文件
dk_FILES = Tweak.x \
           DKAccountManager.m \
           DKAccountUI.m \
           DKDataIsolation.m \
           DKAppDataManager.m \
           DKFileManagerHook.m \
           DKUserDefaultsHook.m \
           DKKeychainHook.m \
           DKNetworkSessionManager.m \
           DKPushNotificationBridge.m \
           DKContentFilterBypass.m \
           DKLogManager.m \
           DKWeChatAntiDetect.m \
           DKWeChatJailBreakHook.m \
           fishhook/fishhook.c

# 编译选项 — 版本号作为预处理器宏注入
dk_CFLAGS = -fobjc-arc -Wno-error -I. \
            -DDK_VERSION='@"$(DK_VERSION)"' \
            -DDK_BUILD_TIME='@"$(DK_BUILD_TIME)"'
dk_CCFLAGS = -fobjc-arc -Wno-error -I. \
             -DDK_VERSION='@"$(DK_VERSION)"' \
             -DDK_BUILD_TIME='@"$(DK_BUILD_TIME)"'
dk_OBJCFLAGS = -fobjc-arc -Wno-error -I. \
               -DDK_VERSION='@"$(DK_VERSION)"' \
               -DDK_BUILD_TIME='@"$(DK_BUILD_TIME)"'

# 链接框架（新增 UserNotifications）
dk_FRAMEWORKS = UIKit Foundation Security CoreGraphics UserNotifications
# 注：AppSupport 私有框架在 iOS SDK 中不存在，已移除

# 链接库（-lobjc 由 Theos 自动添加，无需重复）
dk_LDFLAGS = -lsubstrate

# 安装路径
dk_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# 构建后处理：复制 dylib 到输出目录
# ============================================================
after-dk-stage::
	@mkdir -p $(THEOS_PROJECT_DIR)/output
	@cp $(THEOS_OBJ_DIR)/dk.dylib $(THEOS_PROJECT_DIR)/output/dk.dylib 2>/dev/null || true
	@echo "✅ dylib copied to output/"

after-dk-all::
	@mkdir -p $(THEOS_PROJECT_DIR)/output
	@cp $(THEOS_OBJ_DIR)/dk.dylib $(THEOS_PROJECT_DIR)/output/dk.dylib 2>/dev/null || true
	@echo "✅ dylib copied to output/"