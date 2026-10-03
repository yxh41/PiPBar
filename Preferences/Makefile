include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PiPBarPrefs

PiPBarPrefs_FILES = PiPBarSettingsController.m PiPBarSliderCell.m
PiPBarPrefs_INSTALL_PATH = /Library/PreferenceBundles
PiPBarPrefs_FRAMEWORKS = UIKit
PiPBarPrefs_PRIVATE_FRAMEWORKS = Preferences
PiPBarPrefs_RESOURCES = Resources/Root.plist
# Info.plist（含 NSPrincipalClass）通过 layout/ 直装到 .bundle 根，避免依赖
# roothide theos bundle.mk 的 INFOPLIST_PATH 机制（不可靠，mapadkiller 踩过）
PiPBarPrefs_CFLAGS = -fobjc-arc -Werror

include $(THEOS_MAKE_PATH)/bundle.mk
