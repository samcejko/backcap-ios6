# Backcap - a SpringBoard tweak for iOS 6 that caps the number of background apps (0-6) and closes unused
# background apps when locking the device, while keeping music and active apps running.
# Built with Theos for iOS 6.x (armv7, the iOS 9.3 SDK, deployment target 6.0). CI builds it, see .github/workflows/build.yml.

TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
DEBUG ?= 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Backcap

Backcap_FILES := $(wildcard src/*.m)

Backcap_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore

Backcap_CFLAGS := -Isrc \
                  -Os -fvisibility=hidden \
                  -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                  -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-parameter \
                  -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# Objective-C only: ARC; APIs newer than iOS 6.0 are turned into errors by src/BCCommon.h
Backcap_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

include $(THEOS_MAKE_PATH)/tweak.mk

BACKCAP_STAGED_DYLIB := $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Backcap.dylib

after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(BACKCAP_STAGED_DYLIB)" || true
	ldid -S "$(BACKCAP_STAGED_DYLIB)"
