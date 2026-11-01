# =====================================================================
# DeltaHarmonica Makefile
# 越狱环境：Dopamine (iOS 16) + roothide
#
# roothide 编译要点（官方规范 roothide/Developer）：
#   - 使用 roothide/theos fork（与官方 theos 100% 兼容自动同步）
#   - THEOS_PACKAGE_SCHEME := roothide（非 rootless）
#   - 源码访问越狱文件用 jbroot() API（见 roothide.h）
#   - 产物需要 platform-application / no-sandbox 等 entitlements
# =====================================================================

TARGET := iphone:clang:latest:15.0

# roothide 打包方案（区别于标准 rootless 的固定 /var/jb，jbroot 随机化）
THEOS_PACKAGE_SCHEME := roothide

ARCHS := arm64 arm64e
ifeq ($(shell uname -m), x86_64)
	ARCHS := arm64
endif

# 注入目标：SpringBoard（仅注入系统进程，防封号）
INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

# ---------------- Tweak：DeltaHarmonica ----------------
TWEAK_NAME := DeltaHarmonica

DeltaHarmonica_FILES := Tweak.xm DFHCore.m DFHForeground.m DFHMIDIParser.m DFHPlayer.m
DeltaHarmonica_CFLAGS := -fobjc-arc -I.
DeltaHarmonica_LDFLAGS := -framework UIKit -framework Foundation -framework CoreGraphics
DeltaHarmonica_LDFLAGS += -weak_framework IOKit
# roothide 运行时（jbroot 等 API，theos 已内置 roothide.h，链接 libroothide）
DeltaHarmonica_LDFLAGS += -lroothide
DeltaHarmonica_LIBRARY_PATHS := $(THEOS)/lib

# roothide entitlements（参考 roothide/Developer 官方要求）
DeltaHarmonica_CODESIGN_FLAGS := -Sentitlements.plist

# ---------------- 命令行工具：dfhctl ----------------
TOOL_NAME := dfhctl

dfhctl_FILES := dfhctl.m
dfhctl_CFLAGS := -fobjc-arc -I.
dfhctl_LDFLAGS := -framework Foundation -framework CoreFoundation -lroothide
dfhctl_CODESIGN_FLAGS := -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"
