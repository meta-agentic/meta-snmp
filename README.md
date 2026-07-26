# meta-snmp — AI SNMP Toolkit

A macOS app for collecting, browsing and interrogating SNMP agent data — sold on the
Mac App Store.

- **Collect** from SNMP v1, v2c and v3 agents (USM authentication and privacy).
- **Browse** results against a MIB tree, with incremental filtering.
- **Graph** any numeric OID live, with counter-to-rate derivation.
- **Import/export** private and vendor MIBs.
- **Ask** questions of the collected data in natural language, through *your own* AI
  provider — Claude, Gemini, an OpenAI-compatible endpoint, or a local Ollama model.

## Bring your own key

The app ships **no** AI credentials and proxies **nothing** through our servers. You
supply a provider key; it is stored in the macOS Keychain, and outbound payloads are
previewable before they are sent.

## Stack

Swift 6 · SwiftUI · SwiftPM · Network.framework · CryptoKit/CommonCrypto.
No third-party runtime dependencies. macOS 14+.

| Target | Kind | Purpose |
|--------|------|---------|
| `SNMPCore` | library | BER/ASN.1 codec, message & PDU model, USM security, UDP transport, sessions |
| `MIBKit` | library | SMIv2 parser, OID registration tree, value formatting, private-MIB I/O |
| `AIBridge` | library | Provider-agnostic AI client and the tool-calling loop over local data |
| `snmpcli` | executable | Headless driver for testing the engine against real agents |
| `SNMPToolkitApp` | executable | The SwiftUI application |

## Build

```bash
swift build
```

```bash
swift test
```

Building needs only the Swift toolchain. **Running the tests needs a full Xcode
install** — the test frameworks are not part of the Command Line Tools, so `swift test`
fails with `no such module 'XCTest'` on a CLT-only machine.
