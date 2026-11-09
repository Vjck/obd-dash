import SwiftUI

@main
struct ObdDashApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .preferredColorScheme(.dark)
        }
    }
}
