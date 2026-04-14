import SwiftUI

@main
struct ObsidianClipperApp: App {

    @StateObject private var settings = ClipperSettings()

    var body: some Scene {
        WindowGroup {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
