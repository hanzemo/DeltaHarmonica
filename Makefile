# =====================================================================
# DeltaHarmonica Makefile
# 越狱环境：Dopamine (iOS 16, rootless, roothide)
# 注入目标：SpringBoard（防封号）
# 编译：macOS + Theos，执行 `make package`
# =====================================================================

TARGET := iphone:clang:latest:15.0

# rootless（Dopamine / roothide 均为 rootless）
THEOS_PACKAGE_SCHEME := rootless

ARCHS := arm64 arm64e
ifeq ($(shell uname -m), x86_64)
	ARCHS := arm64
endif

# 注入目标：SpringBoard（不再注入游戏）
INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

# ---------------- Tweak：DeltaHarmonica ----------------
TWEAK_NAME := DeltaHarmonica

DeltaHarmonica_FILES := Tweak.xm DFHCore.m DFHMIDIParser.m DFHPlayer.m
DeltaHarmonica_CFLAGS := -fobjc-arc -I.
DeltaHarmonica_LDFLAGS := -framework UIKit -framework Foundation -framework CoreGraphics
DeltaHarmonica_LDFLAGS += -weak_framework IOKit

# ---------------- 命令行工具：dfhctl ----------------
TOOL_NAME := dfhctl

dfhctl_FILES := dfhctl.m
dfhctl_CFLAGS := -fobjc-arc
dfhctl_LDFLAGS := -framework Foundation -framework CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"
