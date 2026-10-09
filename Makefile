# Single source of truth for the version. Stamped into both bundles'
# Info.plist at build time and shown in the app's menu, so "which build
# is actually running/installed" is answerable without guessing from
# file timestamps.
VERSION     := $(shell cat VERSION)
BUILD_STAMP := $(shell date +%Y%m%d-%H%M)

DRIVER_NAME := AIHeadset
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(DRIVER_NAME).driver
CONTENTS    := $(BUNDLE)/Contents
BINARY      := $(CONTENTS)/MacOS/$(DRIVER_NAME)

SRC         := driver/src/plugin.c driver/src/device.c driver/src/ringbuffer.c
HDR         := driver/src/config.h driver/src/device.h driver/src/ringbuffer.h
CFLAGS      := -std=c11 -Wall -Wextra -O2 -fno-common
ARCHS       := -arch arm64 -arch x86_64
FRAMEWORKS  := -framework CoreAudio -framework CoreFoundation

DAEMON_NAME       := AIHeadset
DAEMON_BUNDLE     := $(BUILD_DIR)/$(DAEMON_NAME).app
DAEMON_CONTENTS   := $(DAEMON_BUNDLE)/Contents
DAEMON_BINARY     := $(DAEMON_CONTENTS)/MacOS/$(DAEMON_NAME)
DAEMON_SRC        := $(wildcard daemon/AIHeadset/*.swift)
DAEMON_FRAMEWORKS := -framework AppKit -framework ApplicationServices -framework CoreAudio -framework AudioToolbox -framework Foundation

.PHONY: driver daemon run logs dist clean install install-app uninstall test

driver: $(BINARY)

$(BINARY): $(SRC) $(HDR) driver/Resources/Info.plist VERSION
	mkdir -p $(CONTENTS)/MacOS
	mkdir -p $(CONTENTS)/Resources
	cp driver/Resources/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_STAMP)" $(CONTENTS)/Info.plist
	clang $(CFLAGS) $(ARCHS) -bundle -o $(BINARY) $(SRC) $(FRAMEWORKS)

# Universal (arm64 + x86_64, plan 5.5). swiftc takes one -target per
# invocation, so it is built twice and lipo'd -- an arm64-only app is
# simply unopenable on an Intel Mac, and the failure message ("damaged")
# does not hint at architecture at all.
#
# -target is not optional: without it, this Swift toolchain defaults
# to targeting the *next* macOS (28.0) rather than the one actually
# running (27.0 on this machine). The binary still runs fine when
# exec'd directly (which is how the LaunchAgent starts it, and how
# `make daemon`'s own testing does it) -- but `open`/LaunchServices
# enforces the version check and refuses with -10825
# (kLSIncompatibleSystemVersionErr), which is a much worse way to
# discover this than a build flag.
daemon: $(DAEMON_BINARY)

DAEMON_ICON      := daemon/AIHeadset/Resources/AppIcon.icns
DAEMON_RESOURCES := $(wildcard daemon/AIHeadset/Resources/*.lproj/*.strings)

$(DAEMON_BINARY): $(DAEMON_SRC) $(DAEMON_RESOURCES) $(DAEMON_ICON) daemon/AIHeadset/Info.plist VERSION
	mkdir -p $(DAEMON_CONTENTS)/MacOS
	mkdir -p $(DAEMON_CONTENTS)/Resources
	cp daemon/AIHeadset/Info.plist $(DAEMON_CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(DAEMON_CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_STAMP)" $(DAEMON_CONTENTS)/Info.plist
	cp -R daemon/AIHeadset/Resources/*.lproj $(DAEMON_CONTENTS)/Resources/
	cp $(DAEMON_ICON) $(DAEMON_CONTENTS)/Resources/
	swiftc -O -target arm64-apple-macos13.0 -o $(BUILD_DIR)/AIHeadset-arm64 $(DAEMON_SRC) $(DAEMON_FRAMEWORKS)
	swiftc -O -target x86_64-apple-macos13.0 -o $(BUILD_DIR)/AIHeadset-x86_64 $(DAEMON_SRC) $(DAEMON_FRAMEWORKS)
	lipo -create -output $(DAEMON_BINARY) $(BUILD_DIR)/AIHeadset-arm64 $(BUILD_DIR)/AIHeadset-x86_64
	rm -f $(BUILD_DIR)/AIHeadset-arm64 $(BUILD_DIR)/AIHeadset-x86_64

# Fast local iteration loop: build, sign, relaunch. Deliberately no
# notarization -- verified empirically that a signed-but-unnotarized
# .app launches fine locally (spctl says "rejected", but that's the
# *distribution* assessment; a locally built bundle never picks up the
# quarantine xattr that would actually block it). Only the .driver
# genuinely needs notarizing, because coreaudiod's sandboxed XPC
# helper enforces it via AMFI. Notarize the app only when shipping it
# to another machine.
#
# Signing IS kept in the loop: TCC ties the microphone permission to
# the code signature, so a stable Developer ID identity means macOS
# remembers the grant across rebuilds.
run: daemon
	@pkill -f "$(DAEMON_BUNDLE)/Contents/MacOS/$(DAEMON_NAME)" 2>/dev/null || true
	@sleep 1
	./packaging/sign.sh $(DAEMON_BUNDLE) --local
	open $(DAEMON_BUNDLE)

# Tail the app's own log output (NSLog etc). Run in a second terminal.
logs:
	/usr/bin/log stream --predicate 'process == "$(DAEMON_NAME)"' --level info

# Pelna paczka do instalacji na innej maszynie: build + podpis +
# notaryzacja obu bundli + zip. Kilka minut (czekanie na Apple).
dist:
	./packaging/make_dist.sh

clean:
	rm -rf $(BUILD_DIR)

# Faza 1.7 (plan): install the plugin for local development. Requires
# sudo and briefly silences system audio while coreaudiod restarts.
#
# `launchctl kickstart -k system/com.apple.audio.coreaudiod` (as the
# plan shows) is blocked by SIP on at least some macOS builds (error
# 150). Killing the process directly works instead -- coreaudiod is a
# launchd-supervised daemon and gets relaunched automatically.
# UWAGA: `make driver` produkuje sterownik BEZ podpisu Developer ID, a
# coreaudiod takiego nie załaduje (AMFI). Dlatego instalacja sprawdza
# bilet notaryzacji i odmawia, zamiast pozwolić na "zainstalowane, ale
# urządzenie się nie pojawia" -- objaw, który nie wskazuje przyczyny.
install: driver
	@xcrun stapler validate "$(BUNDLE)" >/dev/null 2>&1 || { 		echo ""; 		echo "BŁĄD: $(BUNDLE) nie jest notaryzowany."; 		echo "coreaudiod go nie załaduje i urządzenie się nie pojawi."; 		echo ""; 		echo "  ./packaging/sign.sh $(BUNDLE)"; 		echo "  ./packaging/notarize.sh $(BUNDLE)"; 		echo "  make install"; 		echo ""; 		exit 1; }
	sudo rm -rf "/Library/Audio/Plug-Ins/HAL/$(DRIVER_NAME).driver"
	sudo cp -R "$(BUNDLE)" /Library/Audio/Plug-Ins/HAL/
	sudo killall coreaudiod
	@echo "Sterownik zainstalowany. Aplikacja: make install-app"

# Instaluje świeżo zbudowaną aplikację do /Applications. Uruchamianie
# z build/ powoduje App Translocation i uprawnienia nie mają się gdzie
# zapisać.
install-app: daemon
	pkill -f "$(DAEMON_BUNDLE)/Contents/MacOS/$(DAEMON_NAME)" 2>/dev/null || true
	pkill -f "/Applications/$(DAEMON_NAME).app" 2>/dev/null || true
	./packaging/sign.sh $(DAEMON_BUNDLE) --local
	rm -rf "/Applications/$(DAEMON_NAME).app"
	ditto "$(DAEMON_BUNDLE)" "/Applications/$(DAEMON_NAME).app"
	xattr -cr "/Applications/$(DAEMON_NAME).app"
	open "/Applications/$(DAEMON_NAME).app"

uninstall:
	sudo rm -rf "/Library/Audio/Plug-Ins/HAL/$(DRIVER_NAME).driver"
	sudo killall coreaudiod

# Testy jednostkowe (bez sieci i bez urządzeń audio). Lista w
# tools/run_tests.sh.
test:
	./tools/run_tests.sh
