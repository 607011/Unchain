# Build/install/run/debug Unchain entirely from the command line, no Xcode.app
# window ever needed. See README.md "Generating the project" for the
# underlying commands this wraps.
#
# `run` and `debug` target a real device rather than the Simulator on
# purpose: Bluetooth doesn't work in the iOS Simulator at all, and this app
# is useless without it. `DEVICE` defaults to Oliver's iPhone; override on
# the command line for a different device, e.g. `make run DEVICE=Eipättpro`.
# `xcrun devicectl list devices` shows what's currently paired/connected.
#
# Note on this Mac: scheme/destination-based `xcodebuild` fails here
# ("Supported platforms for the buildables in the current scheme is empty"),
# so every build below uses `-target`/`-sdk` instead of `-scheme`/
# `-destination`, which works reliably (see README).

TARGET        := Unchain
CONFIGURATION := Debug
BUNDLE_ID     := net.ersatzworld.unchain
DEVICE        ?= Fourteen
BUILD_DIR     := build
APP_PATH      := $(BUILD_DIR)/$(CONFIGURATION)-iphoneos/$(TARGET).app
LAUNCH_JSON   := $(BUILD_DIR)/devicectl-launch.json

.PHONY: generate build install run debug clean

# Regenerates Unchain.xcodeproj/ from project.yml (XcodeGen) – cheap, so this
# always runs rather than trying to guess whether project.yml changed.
generate:
	xcodegen generate

build: generate
	xcodebuild -target $(TARGET) -sdk iphoneos -configuration $(CONFIGURATION) -allowProvisioningUpdates build

install: build
	xcrun devicectl device install app --device $(DEVICE) $(APP_PATH)

# Launches, replacing any already-running instance, and streams the app's
# stdout/stderr/os_log output until it's stopped (Ctrl-C).
run: install
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing --console $(BUNDLE_ID)

# Launches suspended (waiting for a debugger, per `devicectl`'s own advice –
# see `xcrun devicectl device process launch --help`) and attaches lldb.
# `--json-output` is the only interface devicectl itself documents as stable
# for scripts; the `..` search finds `processIdentifier` wherever it's
# nested without hard-coding the exact JSON shape.
debug: install
	@mkdir -p $(BUILD_DIR)
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing --start-stopped --json-output $(LAUNCH_JSON) $(BUNDLE_ID)
	@pid=$$(jq -r '.. | objects | .processIdentifier? // empty' $(LAUNCH_JSON) | head -1); \
	if [ -z "$$pid" ]; then \
		echo "Couldn't find the process identifier in $(LAUNCH_JSON) – inspect it manually."; \
		exit 1; \
	fi; \
	echo "Attaching lldb to process $$pid on $(DEVICE) ..."; \
	xcrun lldb -o "device select $(DEVICE)" -o "device process attach -p $$pid"

clean:
	rm -rf $(BUILD_DIR) Unchain.xcodeproj
