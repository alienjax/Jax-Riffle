TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

# Keep the tweak's function names in the binary, so a freeze report can say where SpringBoard was stuck.
# (Not stripping would otherwise also turn optimisation off.)
STRIP = 0
OPTFLAG = -Os

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JaxRiffle

JaxRiffle_FILES = Tweak.x
JaxRiffle_CFLAGS = -fobjc-arc
JaxRiffle_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
