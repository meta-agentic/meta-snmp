# ADR-SNMP-03 — The USM cryptographic protocols, their test policy, AES key extension and reviewer

| | |
|---|---|
| **Status** | proposed — the product owner rules on it; becomes *accepted* when the pull request carrying it merges |
| **Date** | 2026-10-30 |
| **Decides** | the Swift API of `AuthenticationProtocol` and `PrivacyProtocol`; where the hand-written primitives live (ADR-01 §8 item 3); the test policy per primitive; the AES-192/256 key-extension algorithm (ADR-01 §8 item 2); who reviews the primitives and how that reviewer is pinned (ADR-01 §8 item 1, §4.1) |
| **Decision** | **`SNMPCrypto` is a separate, standard-library-only target** holding every primitive of ADR-01 §4 rows 1–9; **`SNMPCore` defines the two USM protocols** and their default conformers over it. **AES-192/256 implements both key extensions behind an explicit per-user setting, defaulting to the Reeder ("Cisco") extension.** One **pinned crypto-reviewer definition**, [`docs/review/crypto-reviewer.md`](../review/crypto-reviewer.md), reviews all three primitive families. |
| **Builds on** | [ADR-SNMP-01](ADR-SNMP-01-portability-boundary.md) — its §3.2 import rule, §4 primitive inventory and §4.1 review requirement bind this record; nothing here relaxes them |
| **Governs** | `Sources/SNMPCrypto` (to be created), the USM part of `Sources/SNMPCore`, their test targets, `docs/review/crypto-reviewer.md` |

---

## 1. Context — the forces

ADR-01 obliged us to hand-write nine USM primitives and left three questions open that now block their implementation: what the protocols look like, whether the primitives get their own target, and which AES-192/256 key extension to build. It also refused to merge any primitive without a named reviewer competent in cryptographic implementation.

| Force | Pulls toward |
|---|---|
| **ADR-01 §3.2** — `SNMPCrypto` may import the standard library only | an API over `[UInt8]`, no `Data`, no `OID`; a place where that rule can be checked mechanically |
| **ADR-01 §4.1** — known-answer tests, differential tests, a named reviewer, all three or no merge | a test policy that says, per primitive, which vector set and which oracle; and a reviewer definition that is stable enough to be cited |
| **INV-4** — authentication or decryption failure is a security error, never a partial result | a closed error type; MAC verified before decryption; constant-time comparison |
| **INV-1 / INV-2** — no credential in persisted state, logs or error messages | key types that are not `Codable` and redact their description; errors that carry lengths, never bytes |
| **SC-3** — authPriv against net-snmp, Cisco IOS and Juniper Junos | AES-192/256 key extension chosen on what those agents do, not on which draft is tidier |
| **NFR-9** — the suite runs in ≤ 60 s with no network | interop evidence recorded as offline fixtures, not live agents; a small budget for the 1 MiB password expansion |
| **ADR-01 §7** — degrade to Option B if the Linux product never starts | protocols first: the platform adapters must be able to replace the hand-written primitives without touching `SNMPCore`'s USM logic |

## 2. Decision

### 2.1 `SNMPCrypto` is a separate target (settles ADR-01 §8 item 3)

**`SNMPCrypto` is its own SwiftPM target, importing nothing — not even `Foundation`. `SNMPCore` depends on it.** It holds all nine rows of ADR-01 §4: the hashes, HMAC, USM password-to-key and localisation, DES and CBC, AES and CFB-128, the two AES key extensions, and constant-time comparison.

Reasons, in order of weight:

1. **The import rule becomes checkable.** ADR-01 §3.2 says `SNMPCrypto` may import the standard library only. As a folder inside `SNMPCore` that rule cannot be checked by reading an import list, because `SNMPCore` may import `Foundation`. As a target it is `check Sources/SNMPCrypto` with no allowed names, and the compiler enforces the dependency direction.
2. **The review scope is a directory.** The reviewer (§2.6) reviews `Sources/SNMPCrypto` and nothing else in the engine. A diff touching that directory needs a crypto review; a diff that does not, does not. A folder inside `SNMPCore` would make the question "is this file crypto?" a matter of judgement.
3. **The Option B degrade swaps a target.** If ADR-01 §7 trigger 1 fires, `SNMPCore`'s default conformers are re-pointed at `CryptoKit`/`CommonCrypto` adapters and `SNMPCrypto` is deleted whole. No USM logic moves.
4. **The second product links it unchanged** and the Linux lane builds it with no `Foundation` in sight.

The cost is a module boundary on a hot path: generic hash code across modules is not specialised unless it is `@inlinable`. The hash and block-cipher entry points are therefore declared `@inlinable` (or the package is built with cross-module optimisation; the implementation PR measures and picks). Payloads are bounded by `msgMaxSize`, so this is a measured detail, not a reason to merge the targets.

**Split of responsibilities.** `SNMPCrypto` computes; `SNMPCore` decides. `SNMPCrypto` knows nothing of `OID`, `snmpEngineBoots` state, BER or users. `SNMPCore` owns the protocol identifiers, the salt counters, the order of operations in RFC 3414 §3.1/§3.2, and the mapping of `CryptoError` onto `SNMPError`.

`Package.swift` gains, in the first implementation PR (not in this record, since an empty target does not build):

```swift
.target(name: "SNMPCrypto"),
.target(name: "SNMPCore", dependencies: ["SNMPCrypto"]),
.testTarget(name: "SNMPCryptoTests", dependencies: ["SNMPCrypto"], resources: [.copy("Vectors")]),
```

and ADR-01 §3.2's check gains `check Sources/SNMPCrypto` (prints nothing when the target imports nothing).

### 2.2 `SNMPCrypto` — the primitive API

Everything is `[UInt8]` in, `[UInt8]` out, `Sendable`, and throws one closed error type with **typed throws** (SE-0413, Swift 6), so a caller cannot be surprised by an error it did not handle:

```swift
// Sources/SNMPCrypto — standard library only.

public enum CryptoError: Error, Sendable, Equatable {
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidIVLength(expected: Int, actual: Int)
    case notBlockAligned(length: Int, blockSize: Int)   // DES-CBC input
    case passwordTooShort(minimum: Int)                 // RFC 3414 §11.2: 8 octets
    case localizedKeyTooShort(needed: Int, actual: Int) // a privacy key cannot be derived
}

public protocol HashFunction: Sendable {
    static var digestLength: Int { get }   // 16, 20, 28, 32, 48, 64
    static var blockLength: Int { get }    // 64 (MD5, SHA-1, SHA-224/256) or 128 (SHA-384/512)
    init()
    mutating func update(_ bytes: some Collection<UInt8>)
    consuming func finalize() -> [UInt8]
}
public struct MD5: HashFunction { … }      // RFC 1321
public struct SHA1: HashFunction { … }     // FIPS 180-4
public struct SHA224: HashFunction { … }   // FIPS 180-4 (SHA-256 core, different IV, truncated)
public struct SHA256: HashFunction { … }
public struct SHA384: HashFunction { … }   // SHA-512 core, different IV, truncated
public struct SHA512: HashFunction { … }

public enum HMAC<H: HashFunction> {
    public static func authenticationCode(key: [UInt8], message: some Collection<UInt8>) -> [UInt8]   // RFC 2104, full length
}

public enum USMKey<H: HashFunction> {
    /// RFC 3414 §A.2: expand to 1 048 576 octets, hash. Streams in blocks; never allocates 1 MiB.
    public static func passwordToKey(_ password: [UInt8]) throws(CryptoError) -> [UInt8]          // Ku, H.digestLength octets
    /// RFC 3414 §2.6 / §A.2: H(Ku ‖ engineID ‖ Ku).
    public static func localize(_ ku: [UInt8], engineID: [UInt8]) -> [UInt8]                       // Kul
    /// draft-blumenthal-aes-usm-04 §3.1.2.1: Kul ← Kul ‖ H(Kul), repeated, truncated to `length`.
    public static func extendBlumenthal(_ kul: [UInt8], to length: Int) -> [UInt8]
    /// draft-reeder-snmpv3-usm-3desede-00 §2.1: Kn+1 = localize(passwordToKey(Kn), engineID), concatenated, truncated.
    public static func extendReeder(_ kul: [UInt8], engineID: [UInt8], to length: Int) -> [UInt8]
}

public struct DES: Sendable {                       // FIPS 46-3; encrypt and decrypt
    public init(key: [UInt8]) throws(CryptoError)   // 8 octets; parity bits ignored
    public func encryptBlock(_ block: inout [UInt8])
    public func decryptBlock(_ block: inout [UInt8])
}
public enum DESCBC {                                // RFC 3414 §8.1.1.2/§8.1.1.3; no padding logic here
    public static func encrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws(CryptoError) -> [UInt8]
    public static func decrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws(CryptoError) -> [UInt8]
}

public struct AES: Sendable {                       // FIPS 197; forward cipher only
    public init(key: [UInt8]) throws(CryptoError)   // 16, 24 or 32 octets
    public func encryptBlock(_ block: inout [UInt8])
}
public enum AESCFB128 {                             // NIST SP 800-38A §6.3, s = 128
    public static func encrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws(CryptoError) -> [UInt8]
    public static func decrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws(CryptoError) -> [UInt8]
}

public enum ConstantTime {
    /// False at once on a length mismatch (lengths are public: N is fixed by the protocol).
    /// Otherwise ORs the XOR of every byte pair, with no data-dependent branch or early exit.
    @inline(never)
    public static func equals(_ a: [UInt8], _ b: [UInt8]) -> Bool
}
```

Two remarks the reviewer is entitled to rely on:

- **Both key extensions coincide with "no extension" when the localised key is already long enough**, and with each other when one round suffices. The draft's own Reeder pseudo-code feeds Kₙ into the next round while net-snmp feeds the growing concatenation ([`keytools.c` L582–L633][ns-keytools-reeder]); with the hashes in scope, AES-256 needs at most **one** extension round (16→32, 20→32, 28→32), so the two readings never diverge. `extendReeder` follows the draft text and a test asserts the one-round bound, so a future longer key fails loudly rather than silently picking a side.
- **No key zeroisation is promised.** Swift gives no portable guarantee that a buffer is wiped. Keys are short-lived values; this is part of the residual risk the reviewer rules on (§2.6).

### 2.3 `SNMPCore` — `AuthenticationProtocol`

```swift
// Sources/SNMPCore/USM — imports Foundation, SNMPCrypto.

/// A localised key: not Codable, description redacted (INV-1/INV-2). Same family as INV-1's credential type.
public struct LocalizedKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible { /* [UInt8], internal */ }

public protocol AuthenticationProtocol: Sendable {
    var identifier: OID { get }      // usmHMACMD5AuthProtocol … usmHMAC384SHA512AuthProtocol
    var keyLength: Int { get }       // M
    var macLength: Int { get }       // N — the truncation length

    /// RFC 3414 §2.6 + §A.2 (RFC 7860 §5 for SHA-2). `password` is INV-1's credential type.
    func localizedKey(password: borrowing Credential, engineID: [UInt8]) throws(SNMPError) -> LocalizedKey

    /// RFC 3414 §6.3.1, §7.3.1 / RFC 7860 §4.2.1: HMAC over the whole message with the N-octet
    /// msgAuthenticationParameters zeroed; returns the first N octets.
    func authenticationCode(wholeMessage: [UInt8], key: LocalizedKey) -> [UInt8]

    /// RFC 3414 §6.3.2, §7.3.2 / RFC 7860 §4.2.2: length ≠ N → .authenticationError;
    /// mismatch (ConstantTime.equals) → .authenticationFailure. Never returns a partial result (INV-4).
    func verify(wholeMessage: [UInt8], receivedCode: [UInt8], key: LocalizedKey) throws(SNMPError)
}
```

The default conformer is one value type, `HMACAuthentication`, with six static instances. Its numbers are fixed here, from RFC 3414 §6–7 and RFC 7860 §4.1–4.2:

| Instance | Hash | M — key octets | N — MAC octets (truncation) | Identifier |
|---|---|---|---|---|
| `.md5` | MD5 | 16 | 12 (HMAC-MD5-96) | 1.3.6.1.6.3.10.1.1.2 |
| `.sha1` | SHA-1 | 20 | 12 (HMAC-SHA-96) | 1.3.6.1.6.3.10.1.1.3 |
| `.sha224` | SHA-224 | 28 | 16 | 1.3.6.1.6.3.10.1.1.4 |
| `.sha256` | SHA-256 | 32 | 24 | 1.3.6.1.6.3.10.1.1.5 |
| `.sha384` | SHA-384 | 48 | 32 | 1.3.6.1.6.3.10.1.1.6 |
| `.sha512` | SHA-512 | 64 | 48 | 1.3.6.1.6.3.10.1.1.7 |

The verify path is the only caller of `ConstantTime.equals`. **Authentication is checked before decryption** (RFC 3414 §3.2 step 6 before step 8), so no decryption output — padding included — is ever observable for a message that failed its MAC: there is no padding oracle to defend against.

### 2.4 `SNMPCore` — `PrivacyProtocol`

```swift
public struct PrivacyKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible { /* redacted */ }

public protocol PrivacyProtocol: Sendable {
    var identifier: OID { get }
    var privacyParametersLength: Int { get }   // 8 for every protocol here

    /// Derives the cipher key (and DES pre-IV) from the user's localised key.
    /// Throws .localizedKeyTooShort if the auth protocol cannot supply enough material and no extension applies.
    func privacyKey(from kul: LocalizedKey, engineID: [UInt8]) throws(SNMPError) -> PrivacyKey

    /// `salt` is the 64-bit privParameters value, composed by the session's SaltSource (below).
    /// `engineBoots`/`engineTime` are the *authoritative* engine's (RFC 3826 §3.1.2.1); DES ignores them.
    func encrypt(scopedPDU: [UInt8], key: PrivacyKey, engineBoots: UInt32, engineTime: UInt32, salt: UInt64)
        throws(SNMPError) -> (encryptedPDU: [UInt8], privacyParameters: [UInt8])

    /// privacyParameters ≠ 8 octets, or a DES ciphertext not a multiple of 8 → .decryptionError (INV-4).
    func decrypt(encryptedPDU: [UInt8], key: PrivacyKey, engineBoots: UInt32, engineTime: UInt32, privacyParameters: [UInt8])
        throws(SNMPError) -> [UInt8]
}
```

The default conformers, with the key, IV and salt handling fixed here:

| Conformer | Key | IV | Salt (privParameters, 8 octets) | Padding |
|---|---|---|---|---|
| `DESPrivacy` — usmDESPrivProtocol, RFC 3414 §8 | first 8 octets of Kul (LSB of each octet ignored); needs Kul ≥ 16 | pre-IV = Kul[8..<16]; IV = pre-IV XOR salt | local `snmpEngineBoots` (4 octets, MSB first) ‖ 32-bit counter (MSB first) — §8.1.1.1 | encrypt pads with zero octets to a multiple of 8; decrypt ignores trailing octets (the BER length of the scopedPDU bounds it) |
| `AESPrivacy(.aes128)` — usmAesCfb128Protocol, RFC 3826 | first 16 octets of Kul | authoritative `snmpEngineBoots` ‖ `snmpEngineTime` ‖ salt, each MSB first — §3.1.2.1 | 64-bit counter, MSB first | none (CFB is a stream mode) |
| `AESPrivacy(.aes192, extension:)` / `(.aes256, extension:)` — non-standard | first 24 / 32 octets of Kul, **extended per §2.5 only if Kul is shorter** | as AES-128 | as AES-128 | none |

**Salt.** `SaltSource`, in `SNMPCore`, owns two counters per local engine: a 32-bit one for DES and a 64-bit one for AES, each initialised from `SystemRandomNumberGenerator` at start-up and incremented by one per encrypted message, wrapping. This follows RFC 3414 §8.1.1.1 and RFC 3826 §3.1.2.1 (the latter says *pseudo-random at boot*; ADR-01 §4's "seeded from `snmpEngineBoots`" is accurate only for DES's first four octets, and this record is the precise statement). The counter is atomic: two concurrent sessions never draw the same value. The salt is an **input** to `encrypt` so every privacy test, interop replay included, is deterministic.

### 2.5 AES-192/256 key extension (settles ADR-01 §8 item 2)

**Decision: implement both extensions behind an explicit per-user setting, `AESKeyExtension { .reeder, .blumenthal }`, defaulting to `.reeder`, labelled in the UI as "Cisco-compatible" and "draft (Blumenthal)". Never inferred from a privProtocol OID; never retried automatically.**

The setting only matters when Kul is shorter than the AES key: MD5 or SHA-1 with AES-192/256, and SHA-224 with AES-256. With SHA-256 and longer, both extensions reduce to truncation and the UI shows the setting disabled.

**Evidence, by agent:**

| Agent | What it does | Strength |
|---|---|---|
| **net-snmp** | Ships **both**, as distinct privacy protocols, compiled only with `./configure --enable-blumenthal-aes` (off by default) ([`config_project_with_enable` L435–L442][ns-configure]). `AES192`/`AES256` select the Blumenthal extension; `AES192C`/`AES256C` ("cisco / pysnmp variations") select Reeder via `USM_AES_REEDER_FLAG` ([`snmpusm.c` L196–L207][ns-usm-names], [`snmpusm.h` L163–L187][ns-usm-h], dispatch in [`keytools.c` L724–L741][ns-keytools-dispatch]). Both algorithms read directly in source ([Blumenthal L475–L562][ns-keytools-blum], [Reeder L565–L635][ns-keytools-reeder]). | **Strong** — primary source, pinned at net-snmp commit `1ed2eb4b`. |
| **Cisco IOS** | Offers `priv aes 192` / `aes 256` under CISCO-SNMP-USM-OIDS-MIB; Cisco's own page states "there is currently no standard for generating localized keys for 192- or 256-bit size keys for AES" and cites the Reeder draft for 3-DES — it does **not** say which extension AES-192/256 uses ([Cisco: AES and 3-DES Encryption Support for SNMP Version 3][cisco-aes]). That IOS uses the Reeder extension for AES-192/256 rests on net-snmp naming its Reeder variant after Cisco and on pysnmp's docstring "known to be used by many vendors including Cisco" ([pysnmp commit 236178f][pysnmp]), plus a Cisco community thread that could not be fetched (403) and is cited only as a pointer ([community thread][cisco-community]). | **Moderate, unconfirmed** — two independent implementations agree; no Cisco primary statement. Open item 1. |
| **Juniper Junos** | Documents `privacy-aes128`, `privacy-des`, `privacy-3des`, `privacy-none` and no AES-192/256 ([Juniper: configure the SNMPv3 authentication type and encryption type][junos]). | **Absent** — Junos offers no AES-192/256, so it neither supports nor contradicts either extension. SC-3 against Junos is met with AES-128. Open item 2. |

**Why both, and why Reeder by default.** On the available evidence, Reeder is the only choice that interoperates with the one SC-3 vendor that ships AES-192/256 at all (open item 1 confirms it); Blumenthal is what a net-snmp agent configured with plain `AES192`/`AES256` speaks, and net-snmp is the SC-3 reference. Building only one would fail one of SC-3's agents for the same menu entry. The marginal cost of the second is small: Reeder reuses `passwordToKey` and `localize` (row 5), Blumenthal reuses the bare hash (rows 1–3); each is a dozen lines, and each has a published known-answer vector (§2.7).

**Why no OID inference.** Implementations disagree on the OIDs: net-snmp maps Cisco's `1.3.6.1.4.1.9.12.6.1.1`/`.2` to its Reeder variant and leaves `.101`/`.102` commented out "as OIDs for AES+Reeder" in pysnmp ([`snmpusm.c` L143–L157][ns-usm-oids]), while pysnmp assigns `.101`/`.102` to its Reeder classes. A manager never sends privProtocol on the wire, so the OID is an import/export label, not an algorithm selector.

**Why no automatic fallback.** A wrong extension shows up as a decryption error report (`usmStatsDecryptionErrors`) or an undecodable response. The app surfaces a security error (INV-4) with a hint naming the other variant; it does not retry with the other key on its own, because silent retries make a misconfiguration look like success and double the work an attacker can provoke.

### 2.6 The reviewer (settles ADR-01 §8 item 1 and §4.1's naming requirement)

**The product owner decided that one cryptography-expert agent reviews all three primitive families** — (a) hashes, HMAC, key localisation and constant-time comparison; (b) DES-CBC; (c) AES-CFB and both key extensions. This record fixes how that reviewer is *named* so that §4.1's "named reviewer" means something checkable:

- **The name is a pinned, versioned definition**: [`docs/review/crypto-reviewer.md`](../review/crypto-reviewer.md), with a `version:` (semantic) and a `model:` line. The model is pinned by the product owner; this record leaves it as a placeholder. The brief, the checklist and the evidence a review must cite live in that file.
- **A review cites the definition by version and by the blob SHA of that file at review time**, and the commit SHA it reviewed. A review that cannot cite both is not a review.
- **Independence:** the reviewer is a fresh instance started from the definition alone, with the diff and the cited standards as its only inputs; it is never the agent, session or conversation that authored the code; it does not write or push fixes. The definition file can change only in a PR that changes nothing under `Sources/SNMPCrypto`, approved by the product owner, so no author tunes the reviewer in the same change as the code it reviews.
- **The same bar as any reviewer.** It may reject. Its first review of each family records whether it **confirms or rejects ADR-01 §4.1's acceptance of timing side channels** (and §2.2's no-zeroisation note) for that family; a rejection reopens this record. Until each family has that verdict, the acceptance is provisional.

### 2.7 Test policy per primitive (ADR-01 §4 rows)

Every row has known-answer tests (KAT). Differential tests run on Apple platforms only, in `SNMPCryptoTests`, behind `#if canImport(CryptoKit)` / `#if canImport(CommonCrypto)` per ADR-01 §3.2, over seeded random inputs (the seed is printed on failure so the case is reproducible). Vector files are committed under `Tests/SNMPCryptoTests/Vectors/` with their source URL and retrieval date in a header line.

| Row | Primitive | Known-answer vectors | Differential oracle |
|---|---|---|---|
| 1 | MD5 | RFC 1321 §A.5 test suite | CryptoKit `Insecure.MD5` |
| 2 | SHA-1 | FIPS 180-4 examples; RFC 3174 §7.3; NIST CAVP SHAVS `SHA1ShortMsg`/`LongMsg` (byte-oriented) | CryptoKit `Insecure.SHA1` |
| 3 | SHA-224/256/384/512 | NIST CAVP SHAVS short/long message files per digest | CryptoKit `SHA256`/`SHA384`/`SHA512`; **CommonCrypto `CC_SHA224` for SHA-224**, which CryptoKit lacks |
| 4 | HMAC, + truncation | RFC 2202 (MD5, SHA-1); RFC 4231 (SHA-224…512, incl. its truncated test case 5); truncation asserted against the §2.3 table | CryptoKit `HMAC<…>`; CommonCrypto `CCHmac(kCCHmacAlgSHA224)` for SHA-224 |
| 5 | Password-to-key, localisation | RFC 3414 §A.3.1 (MD5), §A.3.2 (SHA-1). **RFC 7860 publishes no SHA-2 vectors**; for SHA-2 the KAT is net-snmp-derived (open item 4) | the RFC 3414 §A.2 algorithm composed over CryptoKit/CommonCrypto hashes in the test target. Few cases: each run hashes 1 MiB, and NFR-9's 60 s budget is shared |
| 6 | DES, CBC | NIST SP 800-17 Appendix B tables (variable plaintext, variable key, permutation, substitution) for the block cipher, both directions | CommonCrypto `kCCAlgorithmDES`, `kCCModeCBC`, no padding |
| 7 | AES-128, CFB-128 | FIPS 197 Appendix C.1; NIST SP 800-38A §F.3.13/F.3.14 (CFB128-AES128) | CommonCrypto `kCCAlgorithmAES`, `kCCModeCFB` |
| 8 | AES-192/256 + key extension | Cipher: FIPS 197 C.2/C.3; SP 800-38A §F.3.15–F.3.18. **Extension: draft-blumenthal-aes-usm-04 Appendix A.1** (SHA-1 → 256 bits) and **draft-reeder-snmpv3-usm-3desede-00 Appendix B.1/B.2** (MD5 → 32, SHA-1 → 40 octets). Both drafts' values were reproduced independently with a Python `hashlib` script before this record was written; the Reeder appendix's own "not yet double-checked" note is thereby answered | Cipher only: CommonCrypto with 24/32-octet keys. **The key extension has no differential oracle** — no platform implements either draft. What replaces it: the two drafts' vectors; the one-round assertion of §2.2; and **cross-implementation interop captures** (below) against net-snmp `AES192`/`AES256`/`AES192C`/`AES256C` and Cisco IOS `aes 192`/`aes 256` |
| 9 | Constant-time comparison | functional: equal, unequal at every byte position, length mismatch, empty | **No oracle exists** — "constant time" is a property of the emitted code, not of its output. What replaces it: the reviewer inspects the release-build disassembly (arm64 and x86_64) for a data-dependent branch or early exit; a dudect-style timing test runs as a non-gating diagnostic only, because a shared CI runner cannot give a reliable timing signal |

**Interop captures** are the end-to-end check for rows 5–8 and the only external one for row 8. Each fixture is a recorded request/response pair (UDP payload only — no addresses, no pcap headers), from a lab agent configured with **throwaway** test users, together with the engine ID, boots, time, salt and the test passwords needed to replay it offline. They live under `Tests/SNMPCoreTests/Fixtures/Interop/<agent>/` with a provenance line per file: agent software and version, configuration line used, date. They cover, per agent, every auth × priv combination that agent offers. Replays run with no network (NFR-9). Fixtures are public-repo material: no production engine IDs, credentials or addresses.

**Merge gate, restated:** a primitive merges with its KATs green, its differential tests green where an oracle exists, its interop fixtures where §2.7 names them, and a crypto review per §2.6 — all four, or it does not merge.

## 3. Options rejected

**`SNMPCrypto` as a folder inside `SNMPCore`.** Cheaper by one manifest line and avoids cross-module specialisation. Lost on ADR-01 §3.2: the standard-library-only rule becomes unverifiable by import list, and the review scope stops being a directory.

**Primitive conformers of `AuthenticationProtocol`/`PrivacyProtocol` inside `SNMPCrypto`.** Lost on the dependency direction: the protocols mention `OID` and `SNMPError`, which need `Foundation`; putting them in `SNMPCrypto` breaks its import rule, and putting `SNMPCrypto` above `SNMPCore` reverses ADR-01 §3.1.

**Blumenthal only.** It is the draft that defines AES-192/256 for USM and net-snmp's default spelling. Lost on SC-3: the vendor that actually ships AES-192/256 is, on all available evidence, not using it.

**Reeder only.** Lost on SC-3 the other way: a net-snmp agent configured with `AES256` would fail the same menu entry.

**Infer the extension from the privProtocol OID.** Lost on evidence: net-snmp and pysnmp disagree about which OIDs mean Reeder (§2.5).

**A human named reviewer per family.** The product owner's decision, recorded above, is one pinned agent definition for all three; this record specifies how it is pinned and kept independent, and does not re-argue it.

## 4. Consequences

**Becomes possible.** USM implementation can start: every signature, length, IV and salt rule an implementer needs is fixed here, and every merge has a checkable gate.

**Costs accepted knowingly.**

- Two AES-192/256 variants to test, label and support, for a feature the specification already calls non-standard.
- A lab rig: a net-snmp agent built with `--enable-blumenthal-aes`, and access to a Cisco IOS device, to produce the interop captures. Without the Cisco capture, the default in §2.5 rests on moderate evidence only.
- `@inlinable` entry points in `SNMPCrypto` expose implementation to clients; acceptable for a package-internal library.
- A reviewer that is an agent definition, not a person. Its authority is the product owner's decision; its independence is structural (§2.6). It is not an external audit, and this record does not claim one.

**Artefacts changed with this record.** `docs/specification.md` §5's AES-192/256 row names both extensions and points here. `docs/review/crypto-reviewer.md` is created.

**Not decided here.** INV-1's credential type and its name; engine discovery and timeliness (RFC 3414 §3.2 steps around them); persistence of the local `snmpEngineBoots`; the UI wording beyond the two labels in §2.5; export-compliance classification (ADR-01 §8 item 5).

## 5. Reopening triggers

Superseded, never edited, when any of these is observed:

1. **A Cisco IOS capture decrypts only with the Blumenthal extension** (open item 1 resolves the other way) — the default flips.
2. **The reviewer rejects the timing-side-channel acceptance** for any family — the affected primitive needs a constant-time design or the family degrades to Option B per ADR-01 §7.
3. **A defect is found after merge in a reviewed primitive** — the reviewer definition, its checklist and the independence rule are re-examined before the next crypto merge.
4. **An agent in SC-3's set ships a third extension**, or an RFC standardises AES-192/256 for USM.

## 6. Open items

1. **Confirm Cisco IOS uses the Reeder extension for AES-192/256.** Test: on an IOS device, `snmp-server user <u> <g> v3 auth sha <p> priv aes 256 <p>` (and `aes 192`, and `auth md5`); capture one authPriv get-response; decrypt it offline with both extensions. Exactly one yields a scopedPDU that BER-decodes; commit that capture as a fixture. Record the IOS release.
2. **Confirm Junos offers no AES-192/256** on the release used for SC-3. Test: `set snmp v3 usm local-engine user <u> ?` on that release lists no `privacy-aes192`/`privacy-aes256`. If it does, capture and decide as in item 1.
3. **Confirm net-snmp's pairing on a running build.** Test: snmpd built with `--enable-blumenthal-aes`; users with `AES256` and `AES256C` and SHA-1 auth; captures decrypt with Blumenthal and Reeder respectively. The source reading in §2.5 predicts this; the capture proves it.
4. **SHA-2 key-localisation vectors.** RFC 7860 publishes none. Derive them from the net-snmp build in item 3 (its key-derivation output for `maplesyrup` and engine ID `00…02`, SHA-224…512) and commit them with that provenance; until then row 5's SHA-2 cases rest on the differential test alone.
5. **The model line** in `docs/review/crypto-reviewer.md` — pinned by the product owner.

---

[ns-keytools-blum]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/snmplib/keytools.c#L475-L562
[ns-keytools-reeder]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/snmplib/keytools.c#L565-L635
[ns-keytools-dispatch]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/snmplib/keytools.c#L724-L741
[ns-usm-oids]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/snmplib/snmpusm.c#L143-L157
[ns-usm-names]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/snmplib/snmpusm.c#L196-L207
[ns-usm-h]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/include/net-snmp/library/snmpusm.h#L163-L187
[ns-configure]: https://github.com/net-snmp/net-snmp/blob/1ed2eb4b76ee658cec7ca969e70aad61577eeb77/configure.d/config_project_with_enable#L435-L442
[cisco-aes]: https://www.cisco.com/en/US/docs/ios-xml/ios/snmp/configuration/15-0s/nm-snmp-encrypt-snmp-support.html
[cisco-community]: https://community.cisco.com/t5/network-management/snmpv3-aes192-256-key-localization-not-done-via-aes-draft/m-p/2954763
[pysnmp]: https://github.com/etingof/pysnmp/commit/236178fac0ab7535c1ff619f4cedd5ebb2338b59
[junos]: https://www.juniper.net/documentation/us/en/software/junos/network-mgmt/topics/topic-map/configure-the-snmpv3-authentication-type-and-encryption-type.html

**Standards cited:** RFC 1321, RFC 2104, RFC 2202, RFC 3174, RFC 3414 (§2.6, §3, §6–8, §A.2–A.3), RFC 3826 (§3.1.2.1), RFC 4231, RFC 7860 (§4–5), FIPS 46-3, FIPS 180-4, FIPS 197, NIST SP 800-17, NIST SP 800-38A, NIST CAVP SHAVS; [draft-blumenthal-aes-usm-04](https://datatracker.ietf.org/doc/html/draft-blumenthal-aes-usm-04) §3.1.2.1 and Appendix A.1; [draft-reeder-snmpv3-usm-3desede-00](https://datatracker.ietf.org/doc/html/draft-reeder-snmpv3-usm-3desede-00) §2.1 and Appendix B.

*Format note.* As ADR-01: status, date, context as forces, decision, rejected options with the force each lost on, consequences with accepted cost, reopening observations, open items.
