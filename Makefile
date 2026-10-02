# PiPBar — 画中画增强（iOS 16 / roothide / arm64e）
# 作用进程：SpringBoard（系统画中画的宿主，FreePIP 验证过的机制路线）
#
# 构建约定与 yxh41/mapadkiller-ios 一致：
#   * roothide 官方 theos 分支（roothide/theos）构建，直接产出 iphoneos-arm64e deb
#   * -Werror：不用废弃 UIKit API（keyWindow / windows / UI_USER_INTERFACE_IDIOM 等）
#   * 版本号以 control 为准（CI 注入 0.0.1+<commit hash>）

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := PiPBar
PiPBar_FILES := Tweak.x
PiPBar_FRAMEWORKS := UIKit Foundation
PiPBar_CFLAGS := -fobjc-arc -Werror

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	@echo "PiPBar: installed. Respring, then start a Picture-in-Picture video."
	@killall -9 SpringBoard 2>/dev/null || true
