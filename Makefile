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
# so every build below uses `-target` instead of `-scheme`/`-destination`,
# which works reliably (see README).
#
# `build` deliberately passes no `-sdk` at all (unlike most of this file's
# earlier history) now that `Unchain` embeds `UnchainWatch` (see
# project.yml) – a blanket `-sdk iphoneos` gets applied to *every* target in
# the build, including the embedded watch one, forcing it to (wrongly) also
# try building against the iOS SDK instead of its own watchOS one. Omitting
# `-sdk` entirely lets each target resolve its own platform from its own
# project.yml settings instead – verified to still default the main
# `Unchain` target to `Debug-iphoneos` exactly as before (see `APP_PATH`
# below), so nothing else here needed to change.

TARGET        := Unchain
CONFIGURATION := Debug
BUNDLE_ID     := net.ersatzworld.unchain
DEVICE        ?= Fourteen
BUILD_DIR     := build
APP_PATH      := $(BUILD_DIR)/$(CONFIGURATION)-iphoneos/$(TARGET).app
LAUNCH_JSON   := $(BUILD_DIR)/devicectl-launch.json
ARCHIVE_PATH  := $(BUILD_DIR)/$(TARGET).xcarchive

.PHONY: generate build install run debug archive clean

# Regenerates Unchain.xcodeproj/ from project.yml (XcodeGen) – cheap, so this
# always runs rather than trying to guess whether project.yml changed.
generate:
	xcodegen generate

build: generate
	xcodebuild -target $(TARGET) -configuration $(CONFIGURATION) -allowProvisioningUpdates build

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

# A Release-configuration archive for device distribution – what App Store
# Connect submission ultimately needs. Unlike every other target above,
# `archive` needs `-scheme` rather than `-target`/`-sdk` (the only interface
# `xcodebuild archive` supports at all), and it works fine here despite the
# note up top about scheme-based builds otherwise failing on this Mac – that
# problem is specific to the plain `build` action, not `archive`. Signs
# automatically with whatever `DEVELOPMENT_TEAM` is baked into project.yml,
# same as `build`/`install`/`run`/`debug` – this produces a Development-
# signed archive (verifies the app actually compiles & links in Release,
# catching anything the -Onone Debug builds above wouldn't), not an
# App-Store-ready one: submitting still needs Xcode's own "Distribute App"
# flow (or a hand-written exportOptions.plist with method: app-store) to
# re-sign with an Apple Distribution certificate instead.
archive: generate
	xcodebuild archive -scheme $(TARGET) -configuration Release -archivePath $(ARCHIVE_PATH) -allowProvisioningUpdates

clean:
	rm -rf $(BUILD_DIR) Unchain.xcodeproj
