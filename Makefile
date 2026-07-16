# DK Multi-Account Tweak Makefile
# Target: iOS (rootless + rootful兼容)
# 支持多应用注入

export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

# 支持 rootless 和 rootful
THEOS_PACKAGE_SCHEME = rootless

# 注入目标进程（可多个）
INSTALL_TARGET_PROCESSES = TRAE

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
           DKFileManagerHook.m \
           DKUserDefaultsHook.m \
           DKKeychainHook.m \
           DKNetworkSessionManager.m \
           DKPushNotificationBridge.m

# 编译选项
dk_CFLAGS = -fobjc-arc -Wno-error -I.
dk_CCFLAGS = -fobjc-arc -Wno-error -I.
dk_OBJCFLAGS = -fobjc-arc -Wno-error -I.

# 链接框架（新增 UserNotifications）
dk_FRAMEWORKS = UIKit Foundation Security CoreGraphics UserNotifications
dk_PRIVATE_FRAMEWORKS = AppSupport

# 链接库
dk_LDFLAGS = -lobjc -lsubstrate

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