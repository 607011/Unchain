import Foundation
import ObjectiveC

/// The languages the user can explicitly pick in `SettingsView`, on top of
/// just following the device's own Language & Region setting. Kept in sync
/// with whatever `Localizable.xcstrings`/`InfoPlist.xcstrings` actually carry
/// translations for – currently just German (see the README's L10N section);
/// add a case here once Spanish/French land.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case de

    var id: String { rawValue }

    /// Deliberately *not* run through `String(localized:)`: `.en`/`.de` are
    /// language names shown in their *own* language regardless of which
    /// language is currently active – the same convention every OS/app
    /// language picker uses (a German speaker picking "English" needs to
    /// recognize that word even with the app still in German) – translating
    /// them would defeat the point. `.system` is the one genuinely
    /// UI-vocabulary case, so that one does localize.
    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }
}

/// Backs `SettingsView`'s language picker: lets the user override the app's
/// display language independently of the device's own Language & Region
/// setting, which `AppLanguage.system` (the default) just follows as normal.
///
/// SwiftUI/Foundation have no supported API to switch `String(localized:)`/
/// `Text`'s resolved locale at runtime – both ultimately resolve through
/// `Bundle.main.localizedString(forKey:value:table:)` (true for String
/// Catalogs too: they still compile down to per-`.lproj` `.strings` tables,
/// as seen by inspecting the built app – see the README). The standard
/// workaround, used here, is swizzling `Bundle.main`'s class so that method
/// reads from a *specific* `.lproj` bundle instead of letting the OS resolve
/// one from the device's preferred languages. Picking `.system` again simply
/// clears the override, at which point `super`'s normal, device-locale-driven
/// lookup takes over.
///
/// Known limitation: this only affects string *lookup*, not `Locale.current`
/// itself – the handful of `String(format: locale: .current, …)` numeric
/// formatters (e.g. FTP-derived watt values) still follow the true device
/// locale (decimal separator etc.), not this override. Scoped that way
/// deliberately for now, since the ask was about display language, not
/// number formatting.
enum LanguageManager {
    static let storageKey = "appLanguageOverride"

    /// Re-applies the currently stored override to `Bundle.main`. Call once
    /// at launch (see `UnchainApp.init`), and again whenever the setting
    /// changes (see `UnchainApp`'s `onChange`).
    static func apply() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: raw) ?? .system

        // Swizzle exactly once; re-applying after that just needs to update
        // the associated override bundle, not re-swap the class again.
        if object_getClass(Bundle.main) != BundleEx.self {
            object_setClass(Bundle.main, BundleEx.self)
        }

        guard language != .system,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let overrideBundle = Bundle(path: path) else {
            // `.system`, or the requested `.lproj` is missing for some
            // reason – clear the override so `BundleEx` falls through to
            // the OS's own default resolution again.
            objc_setAssociatedObject(Bundle.main, &overrideBundleKey, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        objc_setAssociatedObject(Bundle.main, &overrideBundleKey, overrideBundle, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Association key for the override `Bundle` stashed on `Bundle.main` once
/// it's been swizzled to `BundleEx` – see `LanguageManager.apply()`.
private var overrideBundleKey: UInt8 = 0

/// The class `Bundle.main` gets swizzled to by `LanguageManager`. Overrides
/// just the one method both `Text(_:)`/`LocalizedStringKey` and
/// `String(localized:)` resolve string lookups through; everything else
/// about `Bundle.main` (paths, other resources, …) is untouched, since this
/// subclasses `Bundle` itself rather than replacing it with a stand-in.
private final class BundleEx: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let overrideBundle = objc_getAssociatedObject(self, &overrideBundleKey) as? Bundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return overrideBundle.localizedString(forKey: key, value: value, table: tableName)
    }
}
