# ADR-SNMP-07 — The UI/engine boundary: what the app sees, how it reads secrets, how a SET is confirmed

| | |
|---|---|
| **Status** | Proposed — the product owner rules on it; becomes *accepted* when the pull request carrying it merges |
| **Date** | 2026-11-11 |
| **Decides** | what the app sees of the core (sessions, streams of varbinds, chart series); the credential-store protocol the core owns and the Keychain adapter implements; how SET confirmation tokens are minted and checked (INV-5) |
| **Decision** | **The app hands the core references and values, and gets back a handle, batches of varbinds and one outcome per target.** It never sees a socket, a key or BER. Rows stay in an app-side store; the main actor holds a count and a window of at most 512 rows. **Secrets are read through a read-only `CredentialStore` the core defines**, and the macOS adapter is the only file that imports `Security`. **A SET has its own path, which spends a non-copyable `SetConfirmation`.** The token carries the exact request it confirms, can be used once, lasts 60 seconds, and is minted by one call that only the app's confirmation flow makes. **How a v3 password reaches the walk (ADR-04 open item 1) is the product owner's choice (§3.3). This record is written for the recommended option, B.** |
| **Builds on** | [ADR-SNMP-01](ADR-SNMP-01-portability-boundary.md) §3.2 clarification 3 (the Keychain is above the boundary), [ADR-SNMP-02](ADR-SNMP-02-transport.md) (the dispatcher, `RetryPolicy`), [ADR-SNMP-03](ADR-SNMP-03-crypto.md) (§2.3, open item 6), [ADR-SNMP-04](ADR-SNMP-04-concurrency.md) (Decision 5, open items 1, 4, 5 and 7). It refines ADR-04 Decision 5 on what `BoundedUpdate` carries. Under option B it also refines ADR-03 §2.3's `localizedKey` requirement |
| **Governs** | the public surface of `Sources/SNMPCore` that `Sources/SNMPToolkitApp` and `Sources/snmpcli` use; in the app, the collection host, the row and series stores, the Keychain adapter and the SET confirmation flow |

---

## 1. Context — the forces

ADR-01 put the app above the boundary and the Keychain with it. ADR-04 fixed how results cross: a collection handle, an event stream, one pump per collection and a bounded update to the main actor. It left three things to this record: the row store behind that update, the app-wide `RunKey`, and the route by which a v3 password reaches a target's task. Nothing above the core can be built until the app knows what it holds, how it reads a secret and how it writes a value.

| Force | Pulls toward |
|---|---|
| **C-12 / ADR-01 §3.2** — `Security` never below the line | a protocol in the core, with the Keychain call in one app file |
| **INV-1** — no credential outside the Keychain; enforced by a non-encodable type | a credential type the core can read and the app cannot read back |
| **INV-2** — no credential in a log, crash report or error message | a type that cannot be printed, and derived values that redact |
| **INV-5** — no SET without per-operation confirmation; "the SET path asserts a confirmation token that only the UI confirmation flow can mint" | a token the SET path cannot do without, bound to what was confirmed |
| **FR-3** — SET disabled by default, needing a configured write credential and per-operation confirmation | app rules on top of INV-5 |
| **FR-6 / ADR-04 open item 1** — prompt cancellation, but a first-contact v3 target needs its password after discovery | where and when the password is read |
| **NFR-3 / NFR-10** — 16 ms on the main actor while 8 targets walk and a 100,000-node tree filters; ADR-04's `WalkLimit` allows about 1.6 million varbinds per target | main-actor work that does not grow with a run's size |
| **FR-17 / FR-18 / NFR-4** — live charts, counter-to-rate, 8 series at 1 s at 60 fps | a bounded number of points on the main actor, and a stated rate rule |
| **ADR-01's second product** — a headless Linux collector or CLI | everything that is not UI below the line: the rate rule, the SET token, the store protocol |

## 2. The product-owner answer

None yet. This record is **proposed**. The product owner rules on the password route in §3.3 (options A, B and C; the recommendation is B) and on the readings and numbers listed in §7. Engineering's recommendation is stated as the decision; if the ruling differs, this record is revised before it merges, not superseded after (ADR-02's rule).

## 3. Decision

### 3.1 What the app sees of the core

**The whole surface.** The app uses these types from the core, and nothing else:

| The app uses | Fixed by | What it is |
|---|---|---|
| `SNMPDispatcher`, `SNMPEngine` | ADR-02, ADR-04 | built once at launch over the POSIX transport and held by `CollectionHost` for the life of the process |
| `SNMPAddress`, `RetryPolicy` | ADR-02 | where a target is, and how patiently to ask it |
| `TargetID` | here | the app's stable identity for a configured target; opaque to the core; ADR-06 persists it |
| `SecurityConfiguration`, `USMUser`, `CredentialReference` | here, §3.3 | references and protocol choices, never a secret |
| `CredentialStore`, `Credential`, `CredentialFailure` | here, §3.3 | the protocol the Keychain adapter conforms to; the adapter makes a `Credential` and nothing above the core can read one |
| `ResolvedSecurity` | here, §3.3 | what a request carries; only `ResolvedSecurity.resolve` makes one |
| `CollectionRequest`, `CollectionRequest.Operation`, `PollSpec` | here | one target's job |
| `SNMPCollection`, `CollectionEvent`, `CollectionOutcome`, `CollectionSummary`, `WalkLimit` | ADR-04 | the handle and what it streams |
| `VarBindBatch` | its fields here | rows as they arrive |
| `VarBind`, `SNMPValue`, `OID` | the codec stories | values |
| `CounterRate`, `SeriesPoint`, `SeriesGap` | here, §3.5 | the rate rule |
| `SetRequest`, `SetConfirmation`, `SetOutcome` | here, §3.4 | the SET path |
| `SNMPError` | ADR-05 places the cases this record adds | the failures |

**What the app never sees:** a socket or the transport once it is built, BER, `USMEngineState`, `SaltSource`, `LocalizedKey`, `PrivacyKey`, `MasterKey`, or the bytes of a `Credential`. The app can hold a `ResolvedSecurity` and cannot open it. Some public entry points are not for the app either. Only the engine calls `SNMPDispatcher.exchange`. ADR-04's check already keeps ADR-03's key functions out of the app, and keeps `start`, `events` and `outcomes` inside `CollectionHost.swift`.

**Sessions.** The core keeps no session object for the app to hold. The word covers three different things:

- **An SNMP session**, meaning what to talk to and how. This is the `TargetID`, `SNMPAddress`, `ResolvedSecurity` and `RetryPolicy` that each request carries. The core keeps nothing between requests except USM engine state (the discovered engine ID, boots and time). It holds that per remote engine, inside the `SNMPEngine` and for its lifetime (ADR-04's proposed `USMEngineState`, which the USM record decides), and the app does not see it. So a second walk to a v3 target discovered earlier does not repeat discovery.
- **An investigation** is FR-20's saved session: its targets, polls and results. It belongs to the app, ADR-06 persists it, and the core sees none of it.
- **A run** is what `CollectionHost` keys by `RunKey` (§3.2).

```swift
// SNMPCore
public struct TargetID: Sendable, Hashable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID)
}

public struct CollectionRequest: Sendable {
    public enum Operation: Sendable {
        case get([OID])
        case getNext([OID])
        case getBulk([OID], nonRepeaters: Int, maxRepetitions: Int)
        case walk(OID, limit: WalkLimit)                           // GETNEXT: v1, or an agent that mishandles GETBULK
        case bulkWalk(OID, maxRepetitions: Int, limit: WalkLimit)  // v2c and v3
        case poll(PollSpec)                                        // FR-17: one GET per tick until stopped (§3.5)
    }
    public init(target: TargetID, address: SNMPAddress, operation: Operation,
                policy: RetryPolicy, security: ResolvedSecurity)
}

public struct VarBindBatch: Sendable {
    public let target: TargetID
    public let sequence: Int                        // per target, from 0, without gaps
    public let receivedAt: ContinuousClock.Instant  // arrival of the response that carried them
    public let varbinds: [VarBind]
}
```

`CollectionEvent` is unchanged from ADR-04: `.rows(VarBindBatch)` and then `.finished(TargetID, CollectionOutcome)`. A poll uses the same events: one batch per answered tick. **No operation writes.** SET has its own path (§3.4). The ranges of `maxRepetitions` and `nonRepeaters` are for the engine stories to bound.

### 3.2 Rows: a store off the main actor and a window onto it (ADR-04 open items 4 and 7)

**Decision.** Each run keeps all its rows in a `RowStore` actor in the app. The main actor's model holds a total count and a window of at most 512 rows. This refines ADR-04 Decision 5: `BoundedUpdate` still has a private initialiser and is still the only way rows reach the main actor, but it now carries the window, not every row of the run.

```swift
// In the app.
struct RunKey: Sendable, Hashable {
    enum Slot: Sendable, Hashable { case results, inspector, chart(UUID) }
    let investigation: UUID   // the app's identity for an open investigation; ADR-06 persists it
    let slot: Slot
}

struct BoundedUpdate: Sendable {
    static let maximumRows = 512    // and each Row field is still cut to 512 octets when built (ADR-04)
    let totalRows: Int
    let windowStart: Int
    let rows: [Row]                 // rows windowStart ..< windowStart + rows.count of the current ordering
    fileprivate init(totalRows: Int, windowStart: Int, rows: [Row])   // only RowStore makes one
}

actor RowStore {
    func append(_ batch: VarBindBatch)
    func keep(_ outcome: CollectionOutcome, for target: TargetID)     // ADR-04's call at `.finished`
    func window(from start: Int, count: Int) -> BoundedUpdate        // formats at most 512 rows
    func setOrdering(_ ordering: Ordering?)                           // built off the actor, see rule 2
}
```

**Rules**

1. **One copy of each row.** While a target runs, the store keeps its batches as they arrive. At `.finished`, it replaces them with the outcome's array, which holds the same varbinds, so a finished walk is not held twice. The store's memory is ADR-04's per-target charge plus 4 bytes per row for each active ordering. Formatted text is never stored: the store formats a window when asked, at most 512 rows.
2. **Sorting and filtering happen off the main actor** (FR-15). A `@concurrent` function runs over a snapshot of the store's arrays, which is a copy-on-write copy and copies no element. It builds an `Ordering`, a permutation of `Int32` row indices, which the store then swaps in. The next keystroke cancels it, as ADR-04 Decision 5 consequence 4 does for the MIB filter. A text filter formats every row inside that function, never in the actor and never on the main actor.
3. **Pacing.** The pump appends each batch to the store. While rows arrive, at most every 100 ms (ADR-04's flush interval), and immediately when a target finishes, it asks the store for a fresh `BoundedUpdate` for the model's current window and awaits `model.apply`. Each update costs the main actor one array replacement of at most 512 rows and a count, however large the run is. This answers ADR-04's warning that its 10.5 ms measurement came from an array that grew on the main actor: no array on the main actor grows now.
4. **Scrolling** asks the store, through `CollectionHost`, for the new window. Rows not yet delivered draw as placeholders until it arrives.
5. **512 stays the bound.** The window is the visible rows plus overscan above and below. At the 17 to 24 pt row heights of a macOS table, a tall display shows roughly 100 to 130 rows, so 512 allows about one and a half screens of overscan on each side. The NFR-10 run confirms it (open item 4).
6. **The grid is pulled by row index.** AppKit's `NSTableView` asks its data source for the row count and then for a view for each visible row ([`NSTableViewDataSource`](https://developer.apple.com/documentation/appkit/nstableviewdatasource)), which is exactly the window model. SwiftUI's `Table` takes its rows as a collection of identifiable values. Whether it reads every element's identity on an update is not documented and was not measured here; if it does, that is O(rows) main-actor work at 1.6 million rows. So the result grid is an `NSTableView` inside an `NSViewRepresentable`, unless the NFR-10 run shows a SwiftUI `Table` over the windowed model staying inside 16 ms (open item 4).
7. **Retention.** A store lives until a new run replaces it on the same `RunKey`, or until its investigation closes (`CollectionHost.discard`). It is never freed on the main actor (ADR-04) and nothing expires it on a timer. At worst it holds targets × `WalkLimit` for each results slot, with one results slot per open investigation.
8. **INV-4 and rows already shown** (ADR-04 open item 5 is still the product owner's reading). Under the strict reading, when `.finished(target, .securityFailure)` arrives, the store drops that target's rows and the next update shows the error in their place. Under the alternative reading, the rows stay, marked. Either way it is one rule in `keep`. Until the product owner rules, this record follows ADR-04's strict reading.
9. **Export** (FR-19) reads the store from a `@concurrent` writer, never from the model. The writer neutralises formula injection.

**`RunKey`** (ADR-04 open item 4). Each open investigation has one results grid, one inspector (FR-16's current value, a `.get`) and one slot per chart. ADR-04's restart rule applies per key: a new walk in an investigation's results slot stops the walk before it, while charts run independently of each other and of the grid.

### 3.3 Secrets: the credential-store protocol

**The protocol is decided whichever route the product owner picks.**

```swift
// SNMPCore — Foundation only.
public struct CredentialReference: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String          // opaque; the Keychain adapter's account name
    public init(rawValue: String)
}

/// INV-1's credential type (settles ADR-03 open item 6). Not copyable, not Codable. Its bytes are
/// internal to SNMPCore: code above the boundary can make a Credential but never read one back.
public struct Credential: ~Copyable, Sendable {
    public init(bytes: [UInt8])
}

public protocol CredentialStore: Sendable {
    /// Reads the secret `reference` names and lends it to `body` for the duration of the call.
    func withCredential<R>(_ reference: CredentialReference,
                           _ body: (borrowing Credential) throws(SNMPError) -> R) async throws(SNMPError) -> R
}

public enum CredentialFailure: Sendable, Equatable {
    case notFound, accessDenied, storeUnavailable, storeFailed(code: Int32)
}
// SNMPError gains `credentialUnavailable(CredentialReference, CredentialFailure)`; ADR-05 places it.
```

| Property | Held by | Strength |
|---|---|---|
| The core has no way to ask a store to write, update or delete a secret | the protocol has one requirement, and it reads | Compiler, for the protocol. Nothing stops code in the core writing bytes it was lent to a file through `Foundation`; INV-1's persisted-state test and review cover that |
| App code cannot read a secret back out of a `Credential` | its bytes are `internal` to `SNMPCore` | Compiler |
| A `Credential` cannot be printed, interpolated, dumped or reflected | `print`, `String(describing:)`, `String(reflecting:)`, string interpolation, `dump` and `Mirror(reflecting:)` all need a copyable argument (§3.7) | Compiler |
| A `Credential` cannot sit in a request or an array | a non-copyable stored property of a copyable struct, or an array element, is refused | Compiler |
| A `Credential` is not persisted by `Codable` | it does not conform | Compiler, for `Codable` |
| **The secret exists only inside the borrow** | **No.** The adapter holds copyable bytes between the Keychain read and `init`, and code inside `SNMPCore` can copy the bytes it is lent. No zeroisation is promised (ADR-03 §2.2) | Review |
| `Security` appears only in the adapter | §3.6 | Check |

**Why read-only.** The app's settings UI saves and deletes Keychain items through the adapter's own methods, which are app API and not part of the core's protocol. The core therefore has no store call that writes a secret, and the only code that writes one to the Keychain is one app file.

**Why lend it rather than return it.** A returned `Credential` would leave the caller holding a non-copyable value across suspension points. A borrow ends with the call. It also keeps option A open.

**Why the adapter is not an actor.** The prototype confirms ADR-04: the compiler refuses an actor's conformance, because the non-`Sendable` closure cannot be sent into the actor and the non-`Sendable` result cannot be sent back (§3.7). The Keychain adapter keeps no state, so it is a struct.

**The macOS adapter** sits above the boundary and is the only file that imports `Security`:

```swift
// Sources/SNMPToolkitApp/Credentials/KeychainCredentialStore.swift
import Security
import SNMPCore

struct KeychainCredentialStore: CredentialStore {
    @concurrent func withCredential<R>(_ reference: CredentialReference,
                                       _ body: (borrowing Credential) throws(SNMPError) -> R) async throws(SNMPError) -> R
    // App API, not part of CredentialStore: the settings UI's only way to write.
    func save(_ secret: [UInt8], replacing: CredentialReference?) throws(SNMPError) -> CredentialReference
    func delete(_ reference: CredentialReference) throws(SNMPError)
}
```

| Concern | Rule |
|---|---|
| **API and implementation** | `SecItem`, the generic-password class, the data protection keychain. [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) recommends both, and says either `kSecUseDataProtectionKeychain` or `kSecAttrSynchronizable` set to true selects that keychain. The adapter uses the first, because the second would also sync the item |
| **iCloud** | `kSecAttrSynchronizable` is false on every add and every query, as INV-3 requires ("Keychain items are created non-synchronizable") |
| **Identity** | `kSecAttrService` is a constant. `kSecAttrAccount` is the reference's `rawValue`, a fresh UUID minted at `save`. No other attribute carries anything the user typed except a label naming the target, and never the secret |
| **Where it runs** | `@concurrent`, so it is never on the main actor. `SecItemCopyMatching` is a synchronous call, and it is accepted on the pool for the reason ADR-04 Decision 1 consequence 7 accepts `StandardMIBBundle`'s read: one short call, no user interaction |
| **Prompts** | Items are created with no access-control object, so a read never shows UI. A Touch ID-protected item would put a wait for the user into resolution, so v1 has none |
| **Status codes** | `errSecItemNotFound` → `.notFound`; `errSecMissingEntitlement` → `.storeUnavailable`; `errSecInteractionNotAllowed` and `errSecAuthFailed` → `.accessDenied`; every other `OSStatus` → `.storeFailed(code:)`, verbatim, as ADR-02 reports `errno` |
| **Unprovisioned builds** | TN3137: a program reaches the data protection keychain only through entitlements authorised by a provisioning profile, embedded in an app-like bundle. A `swift run` build has neither. In such a build the adapter reports `.storeUnavailable`, and the app offers `SessionCredentialStore` instead: secrets held in memory until quit and never written, so INV-1 holds. There is no fallback to the file-based keychain, which would leave the same secret in two implementations for FR-25 to migrate |
| **Access group** | Items live in the app's default access group, which derives from the team and the bundle identifier. A change of either orphans every item, so the bundle identifier is fixed before the first release that stores a secret. Migration belongs to ADR-06 |

**Headless products.** `snmpcli` and the Linux collector have no Keychain. Each supplies its own `CredentialStore`; a prompt, the environment and a mode-0600 file are the obvious candidates. That choice is not made here. INV-1's "outside the Keychain" is a requirement on the macOS app, and the specification has to restate it for the headless products before either ships (open item 6).

#### The route: how a v3 password reaches the walk (ADR-04 open item 1) — the product owner's choice

ADR-03's `localizedKey(password: borrowing Credential, engineID:)` needs the remote engine ID, which a first-contact target only has after discovery, inside its own task. A non-copyable `Credential` cannot sit in a `CollectionRequest`; the compiler refuses it (§3.7). The three options are ADR-04's, restated with what each does to the store protocol.

**Option B — resolve before start (recommended; this record is written for it).** `ResolvedSecurity.resolve` reads each password once through the store, before `start`, and derives Ku with RFC 3414 §A.2's 1 MiB expansion. The request carries Ku as a redacted, copyable `MasterKey`, and the target's task localises it per engine after discovery. A community string becomes a redacted, copyable `CommunityString` the same way.

```swift
// SNMPCore
public enum SecurityConfiguration: Sendable, Hashable {
    case v1(community: CredentialReference)
    case v2c(community: CredentialReference)
    case v3(USMUser)
}

public struct USMUser: Sendable, Hashable {
    public struct Auth: Sendable, Hashable {
        public let protocolID: AuthProtocolID           // names one of ADR-03's six HMACAuthentication instances
        public let password: CredentialReference
    }
    public struct Priv: Sendable, Hashable {
        public let protocolID: PrivProtocolID           // DES, AES-128, AES-192, AES-256 (ADR-03 §2.4)
        public let password: CredentialReference
        public let keyExtension: AESKeyExtension?       // ADR-03 §2.5's per-user setting
    }
    public let userName: String
    public let auth: Auth?                              // nil: noAuthNoPriv
    public let priv: Priv?
    /// Throws SNMPError.invalidConfiguration for privacy without authentication: RFC 3411's security levels have no such level.
    public init(userName: String, auth: Auth?, priv: Priv?) throws(SNMPError)
}

/// Redacted, copyable. No public initialiser.
public struct ResolvedSecurity: Sendable, CustomStringConvertible, CustomReflectable {
    public var securityName: String { get }             // the user name, or "v1 community" / "v2c community"
    @concurrent
    public static func resolve(_ configuration: SecurityConfiguration,
                               from store: some CredentialStore) async throws(SNMPError) -> ResolvedSecurity
}
```

Before `start`, the host resolves each distinct configuration in the run once. Resolution is `@concurrent`, so it runs on neither the main actor nor the host actor. A target whose configuration fails to resolve gets a summary of `.securityFailure(.credentialUnavailable(…))` and does not start; the other targets start (FR-5). Ku and community strings live in the requests for the run's lifetime and go with the run; nothing is cached across runs. Resolution cannot be cancelled part-way, but it does at most two derivations per distinct user, about 6 to 7 ms each (ADR-04 Decision 5 consequence 3), and the host checks for cancellation before `start`.

Option B costs a change to ADR-03 §2.3. `localizedKey(password:engineID:)` becomes two requirements:

```swift
func masterKey(password: borrowing Credential) throws(SNMPError) -> MasterKey               // RFC 3414 §A.2: Ku
func localizedKey(master: MasterKey, engineID: [UInt8]) throws(SNMPError) -> LocalizedKey   // Kul; throws if `master` came from another protocol
```

The privacy password goes the same way, through the authentication protocol's `masterKey` and `localizedKey`, and then into ADR-03's unchanged `privacyKey(from:engineID:)`. RFC 3414 §2.6 localises the privacy key with the user's authentication protocol, and ADR-03's AES key extensions already rely on that. B also carries ADR-04's other costs: Ku works for every engine that shares the password and lives for the whole run, and every credential is read up front, even for a target that never answers.

**Option A — read inside the walk.** The request carries a credential source (a store and a reference), and the target's task calls `withCredential` after discovery. ADR-03 stays as it is and `Credential` stays non-copyable. The costs: if a store ever prompts, the user's wait happens inside a walk. For FR-6, the protocol's typed `throws(SNMPError)` would have to become untyped so it can carry `CancellationError`, and every adapter would have to abandon a read when cancelled. The community string needs its own route regardless.

**Option C — a copyable, redacted `Credential`.** The store returns the credential by value. It is the simplest option. The costs: ADR-03's `borrowing` signature changes, and the password itself stays in memory for the run. The compiler refusals in the table above are lost: a copyable credential can be printed and relies on its redacted description (ADR-05), and it can sit in a request.

**Recommendation: B**, as in ADR-04. It is the only option that keeps cancellation prompt for every target, keeps the user's wait out of the walk and keeps the password out of the walk, while keeping the compile-time refusals. The ADR-03 change is the product owner's to accept. If B is not chosen, §3.3's route and the `CollectionRequest` signature are revised before this record merges; §3.1, §3.2, §3.4 and §3.5 do not change.

### 3.4 SET: a separate path that spends a token (INV-5, FR-3)

```swift
// SNMPCore
public struct SetRequest: Sendable {
    public static let maximumWrites = 16                 // proposal, open item 3
    public let target: TargetID
    public let address: SNMPAddress
    public let security: ResolvedSecurity                // resolved from the target's write credential
    public let writes: [VarBind]                         // each OID with the typed value to write
    public let timeout: Duration
    /// Throws SNMPError.invalidConfiguration for no writes, more than maximumWrites, or an exception value.
    public init(target: TargetID, address: SNMPAddress, security: ResolvedSecurity,
                writes: [VarBind], timeout: Duration = .seconds(2)) throws(SNMPError)
}

/// INV-5's token. No public initialiser, not copyable; it carries the request it confirms.
public struct SetConfirmation: ~Copyable, Sendable { }

public enum SetOutcome: Sendable {
    case applied([VarBind])                              // noError, with the agent's response varbinds
    case rejected(errorStatus: Int, errorIndex: Int)     // RFC 3416 §4.2.5 (v1: RFC 1157 §4.1.5)
    case notSent(SetRefusal)                             // nothing went on the wire
    case unknown(SNMPError)                              // sent once and not answered, or cancelled after sending: the agent may have applied it
    case securityFailure(SNMPError)                      // INV-4
}
public enum SetRefusal: Sendable, Equatable { case expired(age: Duration), cancelled }

extension SNMPEngine {
    public init(dispatcher: SNMPDispatcher, clock: some Clock<Duration> = ContinuousClock())   // gains `clock`
    public static let confirmationLifetime: Duration     // 60 s; proposal, open item 3
    /// The only way to mint a SetConfirmation. The app's confirmation flow calls it, and nothing else does (§3.6).
    public func confirmSet(_ request: SetRequest) -> SetConfirmation
    /// Sends exactly the confirmed request, once.
    @concurrent public func set(_ confirmation: consuming SetConfirmation) async -> SetOutcome
}
```

**How a token is minted.** `confirmSet` records the time on the engine's clock and wraps the request. The app mints in one function, after the user's answer, and spends the token in the same task:

```swift
// Sources/SNMPToolkitApp/Set/SetFlow.swift — the only caller of confirmSet in the app.
@MainActor
static func run(_ request: SetRequest, engine: SNMPEngine, sheet: SetConfirmationSheet) async -> SetOutcome? {
    guard await sheet.ask(request) == .confirmed else { return nil }   // the sheet's buttons only answer
    let confirmation = engine.confirmSet(request)
    return await engine.set(confirmation)
}
```

This shape is forced. A button cannot mint the token and hand it to a `Task`: the compiler refuses to consume a non-copyable value captured by an escaping closure (§3.7).

**How it is checked.** Before anything goes on the wire, `set` checks the token's age against `confirmationLifetime` on the engine's clock and returns `.notSent(.expired(age:))` if it is older. It then checks for cancellation and returns `.notSent(.cancelled)` if the task has been cancelled. There is no separate request to compare the token with, because the token is the request. Then `set` makes one exchange through the dispatcher with `retries: 0`, so the FR-5 ceiling covers SETs too.

**Why a held token expires.** A non-copyable value can still be kept in a class's stored property and spent later; the prototype compiles that (§3.7). The lifetime bounds how stale a confirmation can be when it is spent.

**A SET is sent exactly once.** Nothing retries a SET automatically, because a retransmission is a second write. For a `TestAndIncr` spin lock (RFC 2579) or a `RowStatus` `createAndGo`, the second write fails after the first one succeeded, and the user would be told "rejected" about a write that was applied. So a timeout returns `.unknown`. The app says so, offers to re-read the values with a GET, and a resend needs a new confirmation. There is one exception, which the USM record may use: a USM report showing that the message was not processed (an unknown engine ID during discovery, or not in the time window; RFC 3414 §3.2) allows one resend after resynchronisation, because the agent dropped the message before any write.

**What holds INV-5**

| Property | Held by | Strength |
|---|---|---|
| No SET without a token | only `set(_: consuming SetConfirmation)` writes; no `Operation` case writes; `SetConfirmation` has no public initialiser | Compiler |
| What is sent is what was confirmed | the token carries the request | Compiler, by construction |
| One token, one write | `consuming`, and not copyable | Compiler |
| At most one datagram per token | `set` uses `retries: 0` | Test |
| A stale token does not fire | the 60 s lifetime on the engine's clock | Test |
| **Only the confirmation flow mints** | **Not structural.** `confirmSet` is public, so any module that imports `SNMPCore` can call it. The check in §3.6 allows one file in the app, one proposed file in `snmpcli`, and none in `AIBridge`; a UI test drives the sheet | Check and test |
| **The user saw what will be written** | **Not structural.** The sheet displays the `SetRequest` it was handed, and a UI test holds that | Test |
| FR-3: off by default, with a write credential | the app enables its Set command only for a target with SET turned on and a write credential configured; persisted off by default (ADR-06) | Test |

INV-5's own test is "the SET path asserts a confirmation token that only the UI confirmation flow can mint". The first half is held by the compiler and the runtime tests above. The second half is held by a check and a UI test, not by a type, and this record does not claim more.

**The confirmation sheet** shows the target's name and address; the security name and level, never the secret; each OID by name and by number; the value to write, both formatted per the MIB and raw; and the current value if one was read. For v1 and v2c it warns that the write community travels in clear. Cancel is the default button, so Return does not confirm. From v1.1, `AIBridge` may build a `SetRequest` and hand it to this flow (INV-7), but it never mints a token.

### 3.5 Chart series (FR-17, FR-18)

```swift
// SNMPCore
public struct PollSpec: Sendable {
    public static let maximumOIDs = 16                  // per target per chart; the core adds sysUpTime.0
    public let oids: [OID]
    public let interval: Duration                       // at least 1 s
    public let silenceLimit: Duration                   // stop with .timedOut after this long without an answer
    public init(oids: [OID], interval: Duration, silenceLimit: Duration = .seconds(60)) throws(SNMPError)
}

public struct CounterRate: Sendable {                   // FR-18, for one counter
    public init()
    public mutating func add(_ value: SNMPValue, upTime: UInt32, at: ContinuousClock.Instant) -> SeriesPoint
}
public enum SeriesPoint: Sendable, Equatable {
    case value(at: ContinuousClock.Instant, Double)
    case gap(at: ContinuousClock.Instant, SeriesGap)
}
public enum SeriesGap: Sendable, Equatable { case first, agentRestarted, counterDiscontinuity, missingSample }
```

**The poll.** Each tick is one GET carrying `sysUpTime.0` first and then the series' OIDs, so all the samples in a tick come from the same moment. Ticks run on the engine's clock. A tick that falls due while the previous exchange is still in flight is skipped, so requests never pile up. Each answered tick is one `VarBindBatch`, with its `receivedAt`. A lost tick is a gap, not a stop. The poll stops when cancelled, or with `.timedOut` after `silenceLimit` without an answer. Until then, a silent polled target holds one ceiling slot, which adds a case to ADR-04's "How the design fails". A poll's outcome carries only the last tick's varbinds. The history lives in the app's series store, so a poll's memory does not grow with time, and `WalkLimit` does not apply to it.

**The rate rule**

| Case | Result | Why |
|---|---|---|
| Time base | the local arrival instants | `sysUpTime` counts centiseconds, so its ±10 ms resolution is ±1% of a 1 s interval; arrival jitter on a LAN is of the order of a millisecond. `sysUpTime` is used only to detect a restart |
| `sysUpTime` went backwards | `.gap(.agentRestarted)` | the agent's counters restarted with it |
| A `Counter32` went backwards | one wrap: new + 2³² − old | RFC 2578 §7.1.6. Two wraps within one interval cannot be seen: a 10 Gb/s interface wraps `ifInOctets` every 3.4 s, so charts of fast links use the Counter64 `ifHC…` objects (RFC 2863) |
| A `Counter64` went backwards | `.gap(.counterDiscontinuity)` | a genuine 64-bit wrap is implausible, so a decrease is a reset |
| An exception value, a changed type, or a lost tick | `.gap(.missingSample)` | |
| `Gauge32`, `Integer32`, `TimeTicks` | plotted as values, with no rate | |

The rule lives in the core so that the headless collector does not have to write it again. The pump applies it to each batch. FR-24, which forbids Counter64 rates against a v1 target, is checked when a chart is configured, above the core, because only the MIB knows an object's type before a value arrives.

**In the app.** A `SeriesStore` actor per chart run keeps a full-resolution ring per series, sized as window ÷ interval (an hour at 1 s is 3,600 points). The main actor receives at most 600 points per series. A longer window is decimated off the main actor, keeping the minimum and maximum of each bucket so peaks survive. The main actor gets one update per tick per chart, so eight series hold at most 4,800 points on the main actor, whatever the window. Export reads the full resolution from the store. The NFR-4 run confirms 600 (open item 3).

### 3.6 The checks (added to ADR-04 Decision 6)

```sh
S='--include=*.swift'
A=Sources/SNMPToolkitApp
# Security.framework only in the Keychain adapter (ADR-01 §3.2 clarification 3).
grep -rlE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]*)*(public|package|internal|private|fileprivate)?[[:space:]]*import[[:space:]]+Security([^[:alnum:]_]|$)' $A "$S" 2>/dev/null | grep -vE '/KeychainCredentialStore\.swift$'
# A secret becomes a Credential only in the two stores.
grep -rl 'Credential(bytes:' $A "$S" 2>/dev/null | grep -vE '/(KeychainCredentialStore|SessionCredentialStore)\.swift$'
# SET confirmations are minted in one file of the app, one file of snmpcli, and nowhere else.
grep -rl 'confirmSet(' $A "$S" 2>/dev/null | grep -vE '/SetFlow\.swift$'
grep -rl 'confirmSet(' Sources/snmpcli "$S" 2>/dev/null | grep -vE '/SetPrompt\.swift$'
grep -rlE 'confirmSet\(|SetConfirmation' Sources/AIBridge "$S" 2>/dev/null
```

Each line prints nothing on today's tree, and each fired on a fixture written to trip it, while the allowed files, and an `import SecurityInterface`, did not. As in ADR-04, they catch the plain mistake, not a determined one, and the file names they allow are part of this record: a rename updates it.

**The negative-compilation harness** (SC-5 counts it as a check) holds the compiler rows in §3.3 and §3.4 with one fixture each: a token made outside the core, a token spent twice, a token stored in a copyable struct or an array, a token consumed inside a `Task` closure, a `Credential` printed or interpolated, its bytes read from outside the core, a `ResolvedSecurity` made outside the core. **The harness must compile through SIL** (a full build, or `swiftc -emit-sil`), not `-typecheck`. Move checking runs in SIL, so `-typecheck` accepts a token spent twice and a token consumed in a closure, and a harness built on it would pass for the wrong reason (§3.7).

### 3.7 Validation (Linux, Swift 6.4.2)

Every core declaration in §3.1 and §3.3 to §3.5 was transcribed into a throwaway package outside this repository and built with the official Swift 6.4.2 toolchain (GPG-verified) on Ubuntu 24.04, in Swift 6 language mode with `-strict-concurrency=complete` and warnings as errors. The package had an `SNMPCore` importing only `Foundation`, and a second module standing in for the app. The second module held an in-memory store in place of the Keychain adapter, the `SetFlow` of §3.4, a `RowStore` and `RunKey`. Stand-ins replaced what other records own: the dispatcher behind `SNMPEngine` (a one-attempt fake wire), `OID`, `SNMPValue`, and the password-to-key hash. The two ADR-03 requirements of §3.3 were therefore not compiled; `MasterKey` and the derivation through the store were.

**Tests**, 9 of 9 passing, also under ThreadSanitizer:

- v3 resolution with authentication and privacy through the store; the description, debug description and `dump` of a `ResolvedSecurity` hold no secret, and its mirror has no children;
- a missing reference throws `.credentialUnavailable(ref, .notFound)`, and a password under 8 octets throws `.passwordTooShort(minimum: 8)`;
- `resolve` called from the main actor read both secrets on another thread and returned to the caller's thread;
- a token 61 s old returns `.notSent(.expired(age: 61 s))` with nothing sent; a SET whose reply is lost returns `.unknown(.timedOut)` with exactly one write sent, and that write is the confirmed request;
- the flow sends nothing when the sheet answers Cancel, and one write when it answers Confirm;
- the `SetRequest`, `PollSpec` and `USMUser` validations;
- the rate rule: 4,294,967,290 then 5 a second later gives 11 per second; a `sysUpTime` decrease, a `Counter64` decrease and a `Gauge32` give their gaps.

**Negative fixtures**, each refused with the diagnostic quoted:

| Fixture | Diagnostic |
|---|---|
| `SetConfirmation(…)` outside the core | "initializer is inaccessible due to 'internal' protection level" |
| a token spent twice | "'c' consumed more than once" |
| a token as a stored property of a struct | "stored property 'c' of 'Copyable'-conforming struct 'Op' has non-Copyable type 'SetConfirmation'" |
| a token in an array | "type 'SetConfirmation' does not conform to protocol 'Copyable'" |
| `Task { await engine.set(c) }` | "noncopyable 'c' cannot be consumed when captured by an escaping closure or borrowed by a non-Escapable type" |
| `print(credential)`; `dump(credential)`; `Mirror(reflecting: credential)`; `String(reflecting: credential)` | "argument type 'Credential' does not conform to expected type 'Copyable'", and for `dump` and `String(reflecting:)`, "requires that 'Credential' conform to 'Copyable'" |
| `"\(credential)"`; `String(describing: credential)` | "no exact matches in call to instance method 'appendInterpolation'"; "no exact matches in call to initializer" |
| `credential.bytes` outside the core | "'bytes' is inaccessible due to 'internal' protection level" |
| `ResolvedSecurity(…)` outside the core | "initializer is inaccessible due to 'internal' protection level" |
| an actor conforming to `CredentialStore` | "non-Sendable type 'R' cannot be returned from actor-isolated implementation to caller of protocol requirement 'withCredential'"; in the same protocol shape with `R: Sendable`, "non-Sendable parameter type … cannot be sent from caller of protocol requirement … into actor-isolated implementation" |

A token minted and spent in one async function compiles, and so does a token kept in a class's optional stored property and spent later, which is why tokens expire.

**What the prototype changed in the design.** The first sketch minted the token in the button's action and spent it in a `Task`. That does not compile, so the token is now minted after the sheet answers, inside the flow (§3.4). Under `-typecheck`, the fixtures for spending a token twice and for consuming one in a closure both passed; only a SIL build refuses them, so the harness rule in §3.6 says so. Under Swift Testing on Linux, a `@MainActor` test body reported `Thread.isMainThread == false`. A "never on the main thread" assertion therefore passes vacuously there, and the off-main test compares against the caller's thread instead. ADR-04's test 2 (`encode` and `decode` never on the main thread) needs the same care to mean anything in the Linux lane.

**Not run here**, because it needs a Mac, a signed build or a device: anything with `Security` (the adapter, its status mapping, the data protection keychain in a provisioned sandboxed build, `errSecMissingEntitlement` in an unprovisioned one); `NSTableView` against SwiftUI `Table`; the 512-row window and the 600-point chart under NFR-10 and NFR-4; a macOS 14 build; and a SET against a real agent. Each is open item 5 or 4.

## 4. Options rejected

- **SET as a `CollectionRequest` operation.** The token cannot be stored in a copyable request (the compiler refuses it), walks retry while a SET must not, and its outcome has a different shape.
- **A copyable token with a runtime ledger of spent tokens.** That would add an actor for something the compiler holds for nothing, and swap a compile error for a runtime test.
- **An authority protocol, `engine.set(request, confirmedBy: some ConfirmationAuthority)`.** It moves the rule from a call to a conformance, which is no more structural, and makes a core call wait on a person.
- **`@_spi(SetConfirmation)` on `confirmSet`.** An underscored attribute that comes to the same textual check, read through import lines instead.
- **A token signed with a per-process key.** Within one process the engine both mints and checks the token, so a signature proves nothing that the carried request does not.
- **Every row to the main actor**, ADR-04 Decision 5's first sketch. The model's array grows with the run, up to about 1.6 million rows per target, and ADR-04 measured 47 to 126 ms on the main actor to free each million.
- **Formatting rows as they arrive.** It roughly doubles memory with strings, when a window needs at most 512 formatted rows.
- **SwiftUI `Table` by default.** Its cost at this scale is unmeasured and undocumented; `NSTableView`'s pull model is documented.
- **Write and delete in the store protocol.** It would give the core a path that writes secrets.
- **Falling back to the file-based keychain in unprovisioned builds.** That leaves two implementations for FR-25 to migrate.
- **Rates from `sysUpTime` deltas.** Their resolution is 1% at a 1 s interval.
- **The rate rule in the app only.** The headless collector would have to write it again.
- **Polling by starting a `.get` collection per tick from the app.** The app would schedule the ticks, create a collection per tick, and own the skip rule.

## 5. Consequences

**What becomes possible.** The app shell, credential entry, the result grid, the inspector, the chart and the SET stories can be written against fixed signatures, and the core's collection and USM stories know what they serve.

**What it costs, accepted knowingly**

- Under B, a change to ADR-03 §2.3 (§3.3), which the product owner accepts or not.
- Ku in memory for the length of a run, and every credential read up front.
- An `NSTableView` bridged into a SwiftUI app, and a moment of placeholders while a scroll's window is fetched.
- "Only the flow mints" is a check, not a type.
- A SET is never retried, so the user deals with `.unknown`.
- A silent polled target holds a ceiling slot until its `silenceLimit`.
- Unprovisioned development builds forget their secrets at quit.
- The bundle identifier is frozen before the first release that stores a secret.

**Artefacts changed with this record.** `README.md` lists ADR-03 and this record beside the others. The specification is not changed; the numbers it should state are open item 3.

**Not decided here.** Where the new error cases sit in the taxonomy (ADR-05). How `TargetID`, `CredentialReference`, `SecurityConfiguration` and investigations are persisted and migrated (ADR-06). The MIB browsing surface (MIBKit's story). USM engine state and report handling (the USM record). `AIBridge`.

## 6. Reversal cost and reopening triggers

The store protocol and the token are small types, and reversing either touches the core's SET path and one adapter. Choosing A or C instead of B reshapes `resolve` and ADR-03 §2.3 and nothing else in this record. Going back from the window model to full rows on the main actor needs no core change.

This record is **reopened**, by a superseding record, when any of these is observed:

1. **The NFR-10 run** shows the windowed grid over 16 ms on the baseline Mac, for a cause in the window model.
2. **A Keychain read prompts or blocks** long enough to show up in resolution, for example under a policy that requires user presence.
3. **The signed, sandboxed build cannot use the data protection keychain.**
4. **A requirement needs a SET without per-operation confirmation**, such as bulk configuration (a non-goal in §3 of the specification), or needs one retried automatically.
5. **A Swift release lets a non-copyable value be consumed in an escaping closure, or be printed.** The flow's shape and the "cannot be printed" row are then looked at again.

## 7. Open items

1. **The password route (§3.3): A, B or C.** The product owner's decision. The recommendation is B, which changes ADR-03 §2.3.
2. **INV-4 and rows already shown** (ADR-04 open item 5). Still the product owner's reading; §3.2 rule 8 implements the strict one.
3. **Numbers to confirm, and for the specification to state:** the confirmation lifetime (60 s); at most 16 writes per SET; the SET timeout (2 s); a poll interval of at least 1 s; at most 16 OIDs per target per chart; the silence limit (60 s); at most 600 displayed points per series; and FR-17's selectable windows (proposal: 1, 5, 15 and 60 minutes).
4. **The grid technology**: `NSTableView` unless the NFR-10 run, with ADR-04's run-loop probe on the baseline Mac, shows a SwiftUI `Table` over the window model inside 16 ms. The same run confirms the 512-row window.
5. **To run on a Mac** (not run here; they join the project's dated list of Mac-only checks): the Keychain adapter on a provisioned, sandboxed build (save, read and delete; the item not synchronizable; the status mapping), and `.storeUnavailable` from an unprovisioned `swift run` build. On the hardware bench's managed switch, used as a live agent: a SET of a writable scalar such as `sysContact.0` is `.applied`; a SET of `sysDescr.0` is `.rejected` with `notWritable` (v2c) or `noSuchName` (v1); and a SET whose reply is dropped is `.unknown`, with exactly one datagram sent.
6. **Headless credential stores**: which `CredentialStore` `snmpcli` and the Linux collector ship, and how the specification words INV-1 for them.
7. **Counter discontinuities**: whether interface charts consult `ifCounterDiscontinuityTime` (RFC 2863) as well as `sysUpTime`.
8. **Building it**: the check lines, the negative-compilation harness and the tests named here are not yet written; each belongs to the story that first needs it.

---

*Format note.* As ADR-SNMP-01: status, date, context as forces, the decision, the alternatives that lost and why, consequences including accepted cost, the observations that reopen the record, and open items. Accepted records are not edited; they are superseded.
