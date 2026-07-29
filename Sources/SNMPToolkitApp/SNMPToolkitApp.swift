import SwiftUI

/// The application entry point.
///
/// The three-pane shell — targets sidebar · browser · inspector — is built out
/// in its own change; this establishes the target and window scene.
@main
struct SNMPToolkitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
