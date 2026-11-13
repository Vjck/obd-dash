import SwiftUI

@main
struct ObdDashApp: App {
    @StateObject private var obd = OBDManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(obd)
                .preferredColorScheme(.dark)
        }
    }
}
