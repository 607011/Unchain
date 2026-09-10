import Foundation

/// The build-stamp footer text shown at the bottom of `DeviceListView` –
/// a purely diagnostic "which exact build is this" string for Oliver's own
/// use (comparing what's actually running on a phone against what he just
/// pushed), not anything App Store Connect ever sees. The three pieces of
/// data it's built from are written into `Generated/Info.plist` by
/// `Scripts/stamp-build-info.sh`, run right after `xcodegen generate` (see
/// the Makefile's `generate` target) – not read here directly from `git`
/// itself, since a shipped app has no `.git` directory to read from at
/// runtime at all.
enum AppVersionInfo {
    /// `git describe --tags --always --dirty` at the time
    /// `Generated/Info.plist` was last (re)generated – a real tag once one
    /// exists (none do yet in this repo), until then the short commit
    /// hash, `-dirty` appended for a local build made from uncommitted
    /// changes. `nil` before the app has ever gone through that script at
    /// all (a fresh `git clone` built via raw `xcodegen generate` without
    /// `make`, say) – `Generated/Info.plist` still has every *other* key
    /// XcodeGen itself always writes, just not this one.
    private static var gitDescribe: String? {
        Bundle.main.object(forInfoDictionaryKey: "UnchainGitDescribe") as? String
    }

    /// The same build's own timestamp, ISO-8601/UTC (`stamp-build-info.sh`
    /// writes it with `date -u +"%Y-%m-%dT%H:%M:%SZ"`) – kept as the raw
    /// string rather than parsed back into a `Date` and reformatted, since
    /// there's nothing to reformat it *to*: ISO-8601 is exactly what was
    /// asked for, and round-tripping through `Date` would risk silently
    /// localizing or reflowing it instead.
    private static var buildTimestamp: String? {
        Bundle.main.object(forInfoDictionaryKey: "UnchainBuildTimestamp") as? String
    }

    /// `CFBundleVersion` – the auto-incrementing build number
    /// `stamp-build-info.sh` sets to the repo's total commit count. Read
    /// via the same key any other app-version display would use, rather
    /// than a second custom one, since this value's own meaning (a real,
    /// `App Store Connect`-valid `CFBundleVersion`) doesn't change here.
    private static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// `"9e6ec09-dirty (83) · 2026-09-10T10:47:16Z"` – `nil` only in the
    /// "never been through `stamp-build-info.sh`" case above, so
    /// `DeviceListView` can just omit the footer entirely rather than show
    /// a half-empty one.
    static var footerText: String? {
        guard let gitDescribe else { return nil }
        var text = gitDescribe
        if let buildNumber { text += " (\(buildNumber))" }
        if let buildTimestamp { text += " · \(buildTimestamp)" }
        return text
    }
}
