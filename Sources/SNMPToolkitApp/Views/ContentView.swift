import MIBKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("AI SNMP Toolkit")
                .font(.largeTitle.weight(.semibold))
            Text("MIBKit \(MIBKit.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
