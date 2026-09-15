import MIBKit
import SwiftUI

struct ContentView: View {
    @State private var showingAcknowledgements = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("META SNMP TOOLKIT")
                .font(.largeTitle.weight(.semibold))
            Text("MIBKit \(MIBKit.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Acknowledgements") { showingAcknowledgements = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAcknowledgements) {
            VStack(spacing: 0) {
                AcknowledgementsView()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingAcknowledgements = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAcknowledgements)) { _ in
            showingAcknowledgements = true
        }
    }
}

extension Notification.Name {
    /// Posted by the Help menu command, so the notice is reachable from the
    /// menu bar as well as from the placeholder shell.
    static let showAcknowledgements = Notification.Name("META_SNMP_showAcknowledgements")
}
