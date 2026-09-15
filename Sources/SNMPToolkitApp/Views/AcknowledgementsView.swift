import MIBKit
import SwiftUI

/// Renders the copyright notice that ships inside the app bundle.
///
/// This is the surface that discharges the licence condition: the bundled MIB
/// modules may be redistributed only if their notice travels with the copy, and
/// most of them carry no copyright line of their own. Shipping the file is not
/// enough on its own — a user has to be able to reach it.
struct AcknowledgementsView: View {
    @State private var state: LoadState = .loading

    enum LoadState {
        case loading
        case loaded(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let notice):
                ScrollView {
                    Text(notice)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .failed(let message):
                // A packaging fault, not a user error — say so plainly rather
                // than showing an empty pane that looks like there is nothing
                // to acknowledge.
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            do {
                state = .loaded(try await StandardMIBBundle.shared.notice())
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}
