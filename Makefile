# DFMHUD — TrollStore 独立悬浮 App（不是注入 dylib）
#
# 依据：派大星.RS.R 实测形态 = MH_EXECUTE + NSPrincipalClass=HUDMainApplication
#       + task_for_pid-allow / platform-application / accessibility-window-hosting
#
# 目标：iOS 14.0 – 17.x，arm64，TrollStore 安装
# 产物：DFMHUD.tipa

ARCHS        = arm64
TARGET       = iphone:clang:latest:14.0
INSTALL_PATH = /Applications

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DFMHUD

# --- 自身源码（.mm 走 ObjC++，.cpp 走 C++）---
DFMHUD_FILES  = $(wildcard src/*.mm) $(wildcard src/*.cpp)

# --- ImGui 核心（1.91.8，已 vendored）---
IMGUI_DIR = third_party_imgui
DFMHUD_FILES += $(IMGUI_DIR)/imgui.cpp \
                $(IMGUI_DIR)/imgui_draw.cpp \
                $(IMGUI_DIR)/imgui_tables.cpp \
                $(IMGUI_DIR)/imgui_widgets.cpp \
                $(IMGUI_DIR)/backends/imgui_impl_metal.mm

# theos 里 .mm 归 CFLAGS 管，.cpp 归 CCFLAGS 管，所以 C++ 标准要两处都给
DFMHUD_CFLAGS = -fobjc-arc \
                -std=c++17 \
                -I$(THEOS_PROJECT_DIR)/src \
                -I$(THEOS_PROJECT_DIR)/$(IMGUI_DIR) \
                -I$(THEOS_PROJECT_DIR)/$(IMGUI_DIR)/backends \
                -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS

DFMHUD_CCFLAGS = -std=c++17 \
                 -I$(THEOS_PROJECT_DIR)/src \
                 -I$(THEOS_PROJECT_DIR)/$(IMGUI_DIR) \
                 -I$(THEOS_PROJECT_DIR)/$(IMGUI_DIR)/backends \
                 -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS

# Metal / MetalKit / 图形 / 私有框架依赖
DFMHUD_FRAMEWORKS = UIKit Foundation Metal MetalKit QuartzCore CoreGraphics \
                    CoreFoundation CoreServices Security IOKit

DFMHUD_LIBRARIES  = c++

DFMHUD_LDFLAGS = -Xlinker -dead_strip

# --- kfd 内核后端（可选）---
# CI 拉不到 kfd 时工程照样能编，只是运行时只有 task_for_pid 一条路。
ifeq ($(wildcard $(THEOS_PROJECT_DIR)/third_party/kfd/kfd.h),)
$(info [DFMHUD] kfd 未提供 -> 仅 task_for_pid 后端)
else
DFMHUD_CFLAGS  += -DJB_HAVE_KFD=1 -I$(THEOS_PROJECT_DIR)/third_party/kfd
DFMHUD_CCFLAGS += -DJB_HAVE_KFD=1 -I$(THEOS_PROJECT_DIR)/third_party/kfd
$(info [DFMHUD] kfd 已提供 -> 启用 tfp0 内核后端)
endif

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "killall -9 DFMHUD 2>/dev/null || true"
