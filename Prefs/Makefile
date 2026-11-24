TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = JaxRifflePrefs

JaxRifflePrefs_FILES = JRFRootListController.m
JaxRifflePrefs_FRAMEWORKS = UIKit
JaxRifflePrefs_PRIVATE_FRAMEWORKS = Preferences
JaxRifflePrefs_INSTALL_PATH = /Library/PreferenceBundles
JaxRifflePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
