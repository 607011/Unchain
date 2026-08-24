import SwiftUI

@main
struct BahooApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DeviceListView()
        }
        .onChange(of: scenePhase) { newPhase in
            // No background operation needed: the screen should only stay awake
            // while the app is active in the foreground.
            UIApplication.shared.isIdleTimerDisabled = (newPhase == .active)
        }
    }
}
