#!/bin/sh
# Patches three values into $1 (an Info.plist), read back at runtime via
# `Bundle.main.infoDictionary` by `AppVersionInfo`/`DeviceListView`'s
# version footer. Run right after `xcodegen generate` (see the Makefile's
# `generate` target) against the just-(re)written `Generated/Info.plist` –
# deliberately *not* an Xcode Run Script build phase patching the built
# product's own Info.plist instead: tried that first, and
# `ENABLE_USER_SCRIPT_SANDBOXING` (project.yml) blocks it two different
# ways at once – it denies the `git` subprocess reading `.git` at all
# unless every path `git` might touch is declared as a script-phase input
# up front (impractical for `git`, which reads all over `.git` depending
# on repo state), and separately denies writing back into the built
# Info.plist unless *that* is declared as a script-phase output too – which
# then collides with Xcode's own Info.plist-processing step, which already
# claims to produce that same file ("Multiple commands produce …").
# Patching the *source* plist here, as a plain shell step outside Xcode's
# build system entirely, sidesteps both problems – neither `git` nor
# `PlistBuddy` runs sandboxed here at all.
#
# Trade-off worth knowing: this only refreshes whenever `xcodegen generate`
# itself runs, not on every single Xcode build after that – exactly right
# for `make build`/`install`/`run`/`archive` (all depend on `generate` in
# the Makefile, so every one of those gets a fresh stamp), but a stamp
# from Xcode.app's own ▶️ without running `make generate`/`xcodegen
# generate` first will just show however stale `Generated/Info.plist`
# already was.
#
# Deliberately does NOT touch `CFBundleShortVersionString` for what it'd
# mean to App Store Connect: a `git describe` string like
# "v1.2.0-3-gabc1234" isn't a valid `CFBundleShortVersionString` (Apple
# requires a plain dot-separated integer sequence there) – the real git
# description goes into its own custom key instead, purely for the in-app
# footer's own use, invisible to App Store Connect, leaving
# `CFBundleShortVersionString` free for whatever marketing version is
# deliberately set for a real release. `CFBundleVersion` *is* touched
# below, since a plain integer commit count is both a valid value for that
# field and exactly what "automatically incrementing build number" means
# here.
set -e

PLIST="${1:?usage: stamp-build-info.sh <path-to-Info.plist>}"
if [ ! -f "$PLIST" ]; then
  echo "stamp-build-info.sh: $PLIST does not exist, skipping" >&2
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# `--always`: falls back to the short commit hash once no tag is reachable
# at all yet (true right now – this repo has never been tagged; `git tag
# v0.1.0` or similar starts giving this something more meaningful to show).
# `--dirty`: flags a local build made from uncommitted changes, which a
# clean CI/archive build never has anyway.
GIT_DESCRIBE=$(git describe --tags --always --dirty 2>/dev/null || echo "unknown")
# Total commit count on whatever's currently checked out – strictly
# increases with every commit on a normal, append-only `main`, which is
# exactly what CFBundleVersion needs (TestFlight/App Store both require it
# to strictly increase between uploads of the same marketing version), and
# needs nothing stored/bumped anywhere to get there. Falls back to "0" for
# a shallow clone with no history at all (a full clone always has ≥1) –
# see the CI workflow's own `fetch-depth: 0` note for why that shouldn't
# actually happen there either.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo "0")
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

set_string() {
  key="$1"
  value="$2"
  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$PLIST"
}

set_string "CFBundleVersion" "$BUILD_NUMBER"
set_string "UnchainGitDescribe" "$GIT_DESCRIBE"
set_string "UnchainBuildTimestamp" "$BUILD_TIMESTAMP"

echo "stamp-build-info.sh: ${GIT_DESCRIBE} (${BUILD_NUMBER}), built ${BUILD_TIMESTAMP} -> ${PLIST}"
