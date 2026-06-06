APP_NAME := OpenNOW
BUILD_DIR := build
OBJ_DIR := $(BUILD_DIR)/obj
SRC := $(shell find src -name '*.mm' | sort)
BIN := $(BUILD_DIR)/$(APP_NAME)
INFO_PLIST := OpenNOW-Info.plist

CXX := clang++
ARCHFLAGS ?= -arch arm64
OPTFLAGS ?= -O3 -DNDEBUG
WEBRTC_FRAMEWORK_DIR ?= third_party/webrtc-official
ifneq ($(strip $(WEBRTC_FRAMEWORK_DIR)),)
WEBRTC_FLAT_FRAMEWORK := $(WEBRTC_FRAMEWORK_DIR)/WebRTC.framework
WEBRTC_MACOS_XCFRAMEWORK := $(WEBRTC_FRAMEWORK_DIR)/WebRTC.xcframework/macos-x86_64_arm64
ifneq ($(shell test -d '$(WEBRTC_FLAT_FRAMEWORK)' && printf yes),)
WEBRTC_FRAMEWORK_SEARCH_DIR := $(WEBRTC_FRAMEWORK_DIR)
else
ifneq ($(shell test -d '$(WEBRTC_MACOS_XCFRAMEWORK)/WebRTC.framework' && printf yes),)
WEBRTC_FRAMEWORK_SEARCH_DIR := $(WEBRTC_MACOS_XCFRAMEWORK)
else
WEBRTC_FRAMEWORK_SEARCH_DIR := $(WEBRTC_FRAMEWORK_DIR)
endif
endif
WEBRTC_CFLAGS := -DOPN_HAVE_LIBWEBRTC=1 -F$(WEBRTC_FRAMEWORK_SEARCH_DIR)
WEBRTC_LIBS := -F$(WEBRTC_FRAMEWORK_SEARCH_DIR) -framework WebRTC -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,$(WEBRTC_FRAMEWORK_SEARCH_DIR)
else
WEBRTC_CFLAGS :=
WEBRTC_LIBS :=
endif
SENTRY_SDK_DIR ?= third_party/sentry-native/install
SENTRY_ABS_SDK_DIR := $(abspath $(SENTRY_SDK_DIR))
ifneq ($(shell test -f '$(SENTRY_ABS_SDK_DIR)/include/sentry.h' && test -f '$(SENTRY_ABS_SDK_DIR)/lib/libsentry.dylib' && printf yes),)
SENTRY_CFLAGS := -DOPN_HAVE_SENTRY=1 -DOPN_SENTRY_INSTALL_PREFIX=\"$(SENTRY_ABS_SDK_DIR)\" -I$(SENTRY_ABS_SDK_DIR)/include
SENTRY_LIBS := -L$(SENTRY_ABS_SDK_DIR)/lib -lsentry -Wl,-rpath,$(SENTRY_ABS_SDK_DIR)/lib
else
SENTRY_CFLAGS :=
SENTRY_LIBS :=
endif

CXXFLAGS := $(ARCHFLAGS) $(OPTFLAGS) -std=c++20 -Wall -Wextra -Wpedantic -Wno-deprecated-declarations -Wno-gnu-conditional-omitted-operand -fobjc-arc -Isrc $(WEBRTC_CFLAGS) $(SENTRY_CFLAGS)
LDFLAGS := $(ARCHFLAGS) -framework Cocoa -framework QuartzCore -framework Metal -framework MetalKit -framework CoreImage -weak_framework MetalFX -framework AuthenticationServices -framework AVFoundation -framework AVKit -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework OpenGL -framework GameController -framework ApplicationServices -framework CoreAudio -framework AudioUnit -framework ScreenCaptureKit -Wl,-sectcreate,__TEXT,__info_plist,$(INFO_PLIST) $(WEBRTC_LIBS) $(SENTRY_LIBS)
TEST_SRC := tests/backend_tests.mm
TEST_HEADERS := tests/doctest.h
TEST_DEPS := src/streaming/OPNStreamBackend.mm src/streaming/OPNStreamPreferences.mm src/streaming/OPNSessionAdPresentation.mm src/streaming/OPNSessionParsing.mm src/auth/OPNAuthService.mm src/games/OPNGameDataCache.mm src/games/OPNGameService.mm src/common/OPNLocale.mm src/common/OPNDiscordPresence.mm src/common/OPNSessionHealthReport.mm src/common/OPNGameRemediation.mm src/common/OPNGFNError.mm src/common/OPNProtocolDebug.mm src/common/OPNHTTP.mm src/common/OPNSentry.mm
TEST_BIN := $(BUILD_DIR)/backend_tests
APP_OBJS := $(patsubst %.mm,$(OBJ_DIR)/%.o,$(SRC))
TEST_OBJS := $(patsubst %.mm,$(OBJ_DIR)/%.o,$(TEST_SRC) $(TEST_DEPS))
DEPS := $(sort $(APP_OBJS:.o=.d) $(TEST_OBJS:.o=.d))

.PHONY: all run clean test qt-configure qt-build qt-run qt-clean libwebrtc-sdk qt-configure-webrtc qt-build-webrtc qt-run-webrtc

all: $(BIN)


$(OBJ_DIR)/%.o: %.mm
	mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(OBJ_DIR)/tests/backend_tests.o: $(TEST_HEADERS)

$(BIN): $(APP_OBJS) $(INFO_PLIST)
	mkdir -p $(BUILD_DIR)
	$(CXX) $(APP_OBJS) $(LDFLAGS) -o $(BIN)

$(TEST_BIN): $(TEST_OBJS) $(INFO_PLIST)
	mkdir -p $(BUILD_DIR)
	$(CXX) $(TEST_OBJS) $(LDFLAGS) -Wl,-undefined,dynamic_lookup -framework Foundation -o $(TEST_BIN)

test: $(TEST_BIN)
	./$(TEST_BIN)

run: $(BIN)
	@printf 'Starting $(APP_NAME) with terminal info logs enabled.\n'
	OPN_INFO_LOGS=$${OPN_INFO_LOGS:-1} ./$(BIN)

clean:
	rm -rf $(BUILD_DIR)

qt-configure:
	cmake -S qt -B $(BUILD_DIR)/qt -DCMAKE_BUILD_TYPE=RelWithDebInfo

qt-build: qt-configure
	cmake --build $(BUILD_DIR)/qt

qt-run: qt-build
	cmake --build $(BUILD_DIR)/qt --target run

qt-clean:
	rm -rf $(BUILD_DIR)/qt

libwebrtc-sdk:
	scripts/build-libwebrtc-sdk.sh

qt-configure-webrtc:
	cmake -S qt -B $(BUILD_DIR)/qt-webrtc -DCMAKE_BUILD_TYPE=RelWithDebInfo -DOPNQT_ENABLE_LIBWEBRTC=ON

qt-build-webrtc: qt-configure-webrtc
	cmake --build $(BUILD_DIR)/qt-webrtc

qt-run-webrtc: qt-build-webrtc
	cmake --build $(BUILD_DIR)/qt-webrtc --target run

-include $(DEPS)
