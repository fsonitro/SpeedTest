import SwiftUI

@main
struct SpeedTestApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
        } label: {
            // A single Text keeps both icon and numbers visible in the menu bar.
            if let text = state.menuBarText {
                Text("\(Image(systemName: "speedometer")) \(text)")
                    .monospacedDigit()
            } else {
                Image(systemName: "speedometer")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
