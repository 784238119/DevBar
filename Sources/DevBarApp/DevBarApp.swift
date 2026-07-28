import SwiftUI

@main
struct DevBarApp: App {
    var body: some Scene {
        MenuBarExtra("DevBar", systemImage: "terminal.fill") {
            Text("DevBar")
        }
        .menuBarExtraStyle(.window)
    }
}
