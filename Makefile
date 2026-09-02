# Build/install/run/debug Unchain entirely from the command line, no Xcode.app
# window ever needed. See README.md "Generating the project" for the
# underlying commands this wraps.
#
# `run` and `debug` target a real device rather than the Simulator on
# purpose: Bluetooth doesn't work in the iOS Simulator at all, and this app
# is useless without it. `DEVICE` auto-detects whichever iPhone is currently
# connected via USB (see `CONNECTED_DEVICE` below) – override on the command
# line for a different, not-currently-plugged-in device, e.g. `make run
# DEVICE=Eipättpro`. `xcrun devicectl list devices` shows what's currently
# paired/connected.
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
# Auto-detects the iPhone currently connected via USB, so `make run` picks
# up whichever of Oliver's or his wife's phones is actually plugged in right
# now, without needing `DEVICE=...` on the command line every time it's the
# other one. `--filter "connectionProperties.transportType == 'wired'"` is
# what actually distinguishes a live USB connection from a Wi-Fi-paired-but-
# not-connected device (both otherwise show up in `xcrun devicectl list
# devices` the same way); `awk 'NF==1{print; exit}'` guards against
# `devicectl`'s own "No devices found." message (several words, not one)
# being mistaken for a device name when nothing's plugged in, and – if
# somehow more than one device is wired at once – takes only the first.
CONNECTED_DEVICE := $(shell xcrun devicectl list devices --filter "connectionProperties.transportType == 'wired'" --columns Name --hide-default-columns --hide-headers 2>/dev/null | awk 'NF==1{print; exit}')
# Falls back to WD14 if nothing's connected by USB right now – override on
# the command line the same way as before if that's ever wrong, e.g.
# `make run DEVICE=Fourteen`.
DEVICE        ?= $(if $(CONNECTED_DEVICE),$(CONNECTED_DEVICE),WD14)
BUILD_DIR     := build
APP_PATH      := $(BUILD_DIR)/$(CONFIGURATION)-iphoneos/$(TARGET).app
LAUNCH_JSON   := $(BUILD_DIR)/devicectl-launch.json
ARCHIVE_PATH  := $(BUILD_DIR)/$(TARGET).xcarchive

# The Watch companion, installed/launched separately from the targets above
# – `install`/`run` only ever push `Unchain.app` (with `UnchainWatch.app`
# embedded inside it, per project.yml) to the iPhone, which is *not* the
# same as the paired Watch actually picking up that new embedded build.
# That normally waits on the Watch app's own "Automatic App Install" sync,
# which doesn't reliably (or quickly) pick up a plain development install –
# in practice, the Watch keeps showing whatever it last had installed
# directly. `install-watch`/`run-watch` below push straight to the Watch
# instead, the same way `install`/`run` do for the iPhone, bypassing that
# sync entirely.
WATCH_TARGET    := UnchainWatch
WATCH_BUNDLE_ID := net.ersatzworld.unchain.watchkitapp
WATCH_DEVICE    ?= watchOLA
WATCH_APP_PATH  := $(BUILD_DIR)/$(CONFIGURATION)-watchos/$(WATCH_TARGET).app

.PHONY: generate build install run debug archive clean install-watch run-watch debug-watch

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

# Builds and installs straight to the paired Watch – see the note above on
# why this is a separate path from `install`. Deliberately its own
# `xcodebuild` invocation, not a dependency on `build`: `-target
# $(WATCH_TARGET)` alone still resolves to its own watchOS platform (same
# reasoning as `build`'s own note on omitting `-sdk`), so there's no need to
# build the whole iPhone app first just to get an up-to-date watch one.
install-watch: generate
	xcodebuild -target $(WATCH_TARGET) -configuration $(CONFIGURATION) -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(WATCH_DEVICE) $(WATCH_APP_PATH)

# Launches, replacing any already-running instance, and streams the app's
# stdout/stderr/os_log output until it's stopped (Ctrl-C) – same as `run`,
# just for the Watch.
run-watch: install-watch
	xcrun devicectl device process launch --device $(WATCH_DEVICE) --terminate-existing --console $(WATCH_BUNDLE_ID)

# Launches suspended and attaches lldb – same as `debug`, just for the
# Watch. Needs the Watch unlocked and Developer Mode on (Settings → Privacy
# & Security → Developer Mode, on the Watch itself) or `process launch`
# fails outright rather than just queuing.
debug-watch: install-watch
	@mkdir -p $(BUILD_DIR)
	xcrun devicectl device process launch --device $(WATCH_DEVICE) --terminate-existing --start-stopped --json-output $(LAUNCH_JSON) $(WATCH_BUNDLE_ID)
	@pid=$$(jq -r '.. | objects | .processIdentifier? // empty' $(LAUNCH_JSON) | head -1); \
	if [ -z "$$pid" ]; then \
		echo "Couldn't find the process identifier in $(LAUNCH_JSON) – inspect it manually."; \
		exit 1; \
	fi; \
	echo "Attaching lldb to process $$pid on $(WATCH_DEVICE) ..."; \
	xcrun lldb -o "device select $(WATCH_DEVICE)" -o "device process attach -p $$pid"

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
