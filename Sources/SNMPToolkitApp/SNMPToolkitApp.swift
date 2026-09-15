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
        .commands {
            // The bundled MIB modules travel under a notice that has to reach
            // the user, so the surface gets a permanent place in the menu bar
            // rather than only a control in the placeholder shell.
            CommandGroup(replacing: .help) {
                Button("Acknowledgements") {
                    NotificationCenter.default.post(name: .showAcknowledgements, object: nil)
                }
            }
        }
    }
}
