import SwiftUI

@main
struct UnchainApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // Drives a full content-view rebuild on change – see the `.id` below –
    // so every already-rendered `Text`/computed label re-resolves under
    // whichever `.lproj` `LanguageManager` just swapped in.
    @AppStorage(LanguageManager.storageKey) private var languageOverride = AppLanguage.system.rawValue

    init() {
        // Re-apply whatever override was picked in a previous launch before
        // the very first view renders.
        LanguageManager.apply()
        // Subscribes for the lifetime of the process – see
        // `DiagnosticsReporter`'s own doc comment for what this actually
        // captures (crash/hang diagnostics via MetricKit) and why it works
        // without TestFlight or the App Store.
        DiagnosticsReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            // `.id` forces SwiftUI to fully discard and rebuild the tree
            // whenever the language changes, rather than just the one view
            // that happens to own `languageOverride` – otherwise, most
            // already-on-screen `Text`s/labels wouldn't refresh until their
            // own state happened to change for an unrelated reason. The one
            // side effect: a language change made from the Settings sheet
            // closes that sheet, since its presentation state is part of the
            // tree being discarded – an acceptable trade-off for a setting
            // that's reached rarely and changed even more rarely.
            DeviceListView()
                .id(languageOverride)
        }
        .onChange(of: scenePhase) { newPhase in
            // No background operation needed: the screen should only stay awake
            // while the app is active in the foreground.
            UIApplication.shared.isIdleTimerDisabled = (newPhase == .active)
        }
        .onChange(of: languageOverride) { _ in
            LanguageManager.apply()
        }
    }
}
