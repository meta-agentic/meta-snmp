import Foundation

/// Provider-agnostic AI access and the tool-calling loop over locally
/// collected SNMP data.
///
/// The module is scaffolded here; provider adapters and the tool loop land in
/// their own changes.
public enum AIBridge {
    /// Providers the bridge is designed to speak to. The user supplies the
    /// credential for whichever they pick — none is bundled.
    public enum Provider: String, Sendable, CaseIterable {
        case anthropic
        case gemini
        case openAICompatible
        case ollama
    }
}
