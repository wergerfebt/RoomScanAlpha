import SwiftUI

@main
struct RoomScanAlphaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        DeviceCapability.logCapabilities()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
