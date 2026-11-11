# ADR-SNMP-07 — The UI/engine boundary: what the app sees, how it reads secrets, how a SET is confirmed

| | |
|---|---|
| **Status** | Proposed — the product owner ruled on §2 on 2026-11-11; becomes *accepted* when the pull request carrying it merges |
| **Date** | 2026-11-11 |
| **Decides** | what the app sees of the core (sessions, streams of varbinds, chart series); the credential-store protocol the core owns and the Keychain adapter implements; how SET confirmation tokens are minted and checked (INV-5) |
| **Decision** | **The app hands the core references and values, and gets back a handle, batches of varbinds and one outcome per target.** It never sees a socket, a key or BER. Rows stay in an app-side store; the main actor holds a count and a window of at most 512 rows. **Secrets are read through a read-only `CredentialStore` the core defines**, and the macOS adapter is the only file that imports `Security`. **A SET has its own path, which spends a non-copyable `SetConfirmation`.** The token carries the exact request it confirms, can be used once, expires 60 seconds (a proposal for the specification, §2 ruling 3) after the confirmation sheet is shown, is checked immediately before the datagram is sent, and is minted by one call that only the app's confirmation flow makes. **A v3 password reaches the walk (ADR-04 open item 1) by route B: Ku is derived before start (§2 ruling 1, 2026-11-11).** |
| **Builds on** | [ADR-SNMP-01](ADR-SNMP-01-portability-boundary.md) §3.2 clarification 3 (the Keychain is above the boundary), [ADR-SNMP-02](ADR-SNMP-02-transport.md) (the dispatcher, `RetryPolicy`), [ADR-SNMP-03](ADR-SNMP-03-crypto.md) (§2.3, open item 6), [ADR-SNMP-04](ADR-SNMP-04-concurrency.md) (Decisions 2, 3, 5 and 6, open items 1, 4, 5, 6 and 7) |
| **Supersedes in part** | Accepted records are not edited, so every change this record makes to one is listed here, and stated in full where it is made. **[ADR-SNMP-04](ADR-SNMP-04-concurrency.md) Decision 4:** `SNMPEngine.init(dispatcher:)` gains a parameter, `init(dispatcher: SNMPDispatcher, clock: some Clock<Duration> = ContinuousClock())` (§3.4). The change is compatible: `SNMPEngine(dispatcher:)` still compiles. **ADR-SNMP-04 Decision 5:** `BoundedUpdate` (its fields; its `private init(rows:)` becomes `fileprivate init(totalRows:unorderedRows:windowStart:rows:)`, which enforces the bound; `static func split` is removed), the pump's body (formatting moves from the pump into `RowStore`), and the NFR-3 table row "Each update has a bounded size", which becomes, in full: "Each update has a bounded size | `BoundedUpdate`'s `fileprivate` initialiser in `RowStore.swift`, which traps above `maximumRows` | Compiler for who can make one; precondition (run time) for the bound" (§3.2). **ADR-SNMP-04 Decision 6:** the key-function check line `grep -rn 'localizedKey(' Sources/SNMPToolkitApp "$S"`, replaced by §3.6's wider line. **[ADR-SNMP-02](ADR-SNMP-02-transport.md) §3.4:** `OutboundRequest` gains an optional pre-send hook, `beforeSend` (§3.4); existing call sites still compile. `exchange`'s documented thrown set (`SNMPError.timedOut`, `SNMPError.transport`, `CancellationError`) gains a fourth member when a request carries the hook: the hook's error, rethrown unchanged, with nothing sent for that attempt. **[ADR-SNMP-03](ADR-SNMP-03-crypto.md) §2.3** (route B, §2 ruling 1): the requirement `localizedKey(password:engineID:)` is removed and replaced by `masterKey(password:)` and `localizedKey(master:engineID:)` (§3.3). That change is incompatible: a conformer and a caller of the removed requirement no longer compile |
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

## 2. Decisions of the product owner

The product owner ruled on the four questions below on 2026-11-11, taking each of engineering's recommendations. The rest of this record is written as decided accordingly, and cites the ruling where it applies. The *Engineering's recommendation* column is kept as the record of what was put to the product owner.

| # | Question | Engineering's recommendation | Ruling | Sections that follow the ruling |
|---|---|---|---|---|
| 1 | **The v3 password route** (ADR-04 open item 1): A, B, C, or another? | B, on the comparison as restated in §3.3 | **B** (product owner, 2026-11-11) | §3.3's route, `CollectionRequest`, `SetRequest.security`, the ADR-03 entry under *Supersedes in part*, §3.6's key-function line |
| 2 | **INV-4 and rows already shown** (ADR-04 open item 5): on a security failure, are that target's earlier rows dropped (strict reading) or kept, clearly marked? | strict, as ADR-04 reads it | **Strict**: that target's earlier rows are dropped (product owner, 2026-11-11) | §3.2 rule 8, §3.5's series store |
| 3 | **§7 item 3's numbers**: are they accepted as stated here, or are they proposals for the specification to state, which this record then cites? | proposals for the specification | **Proposals for the specification** (product owner, 2026-11-11). Until the specification states them, the values in this record are in force as proposals; a later revision of the specification changes them without a superseding record. The amendment is a pending product-owner action, §7 item 9 | §3.2, §3.4, §3.5, §7 item 3 |
| 4 | **Writes per SET**: `maximumWrites = 1` for v1.0, or more than one with an amendment to the specification's §3 non-goal ("SET exists for single values under confirmation; this is not a provisioning tool")? | none: a scope question. §7 item 3 sets out both alternatives side by side, with the use case that needs more than one | **`maximumWrites = 1` for v1.0**; the specification's §3 non-goal stands as written (product owner, 2026-11-11) | §3.4 `SetRequest.maximumWrites`, the specification's §3 |

The product owner noted that the rulings can be refined once something runs. Because this record is frozen when it merges, a refinement after that is a new record that supersedes the part it changes, except for the numbers of ruling 3, which the specification may change on its own.

## 3. Decision

### 3.1 What the app sees of the core

**The whole surface.** The app uses these types from the core, and nothing else:

| The app uses | Fixed by | What it is |
|---|---|---|
| `SNMPDispatcher`, `SNMPEngine` | ADR-02, ADR-04 | built once at launch over the POSIX transport and held by `CollectionHost` for the life of the process |
| `SNMPAddress`, `RetryPolicy` | ADR-02 | where a target is, and how patiently to ask it |
| `TargetID` | here | the app's stable identity for a configured target; opaque to the core; ADR-06 persists it |
| `SecurityConfiguration`, `USMUser`, `CredentialReference` | here, §3.3 | references and protocol choices, never a secret |
| `AuthProtocolID`, `PrivProtocolID` | here, §3.3 | which of ADR-03's authentication and privacy protocols a user is configured with |
| `AESKeyExtension` | ADR-03 §2.5 | which AES-192/256 key extension a user is configured with |
| `CredentialStore`, `Credential`, `CredentialFailure` | here, §3.3 | the protocol the Keychain adapter conforms to; the adapter makes a `Credential` and nothing above the core can read one |
| `ResolvedSecurity` | here, §3.3 | what a request carries; only `ResolvedSecurity.resolve` makes one |
| `CollectionRequest`, `CollectionRequest.Operation`, `PollSpec` | here | one target's job |
| `SNMPCollection`, `CollectionEvent`, `CollectionOutcome`, `CollectionSummary`, `CollectionStop`, `WalkLimit` | ADR-04 | the handle, what it streams, and why a target stopped |
| `InFlightCeiling` | ADR-04 | the FR-5 ceiling the app builds the dispatcher with |
| `VarBindBatch` | its fields here | rows as they arrive |
| `VarBind`, `SNMPValue`, `OID` | the codec stories | values |
| `CounterRate`, `SeriesPoint`, `SeriesGap` | here, §3.5 | the rate rule |
| `SetRequest`, `PendingConfirmation`, `SetConfirmation`, `SetOutcome`, `SetRefusal` | here, §3.4 | the SET path |
| `SNMPError` | ADR-05 places the cases this record adds | the failures |

**What the app never sees:** a socket or the transport once it is built, BER, `USMEngineState`, `SaltSource`, `LocalizedKey`, `PrivacyKey`, `MasterKey`, `CommunityString`, or the bytes of a `Credential`. The app can hold a `ResolvedSecurity` and cannot open it. Some public entry points are not for the app either. Only the engine calls `SNMPDispatcher.exchange`. ADR-04 Decision 6's check keeps `start`, `events` and `outcomes` inside `CollectionHost.swift`. Its key-function line looked only for `localizedKey(`, which is not enough under option B: the 1 MiB derivation of 6 to 7 ms that the line exists for (ADR-04 Decision 5 consequence 3) moves to `masterKey(password:)`, a public, synchronous protocol requirement, and the app can make the `Credential` it takes. §3.6 therefore replaces that line with one that matches the names `masterKey`, `localizedKey` and `privacyKey` as words, calls and method references alike, in the app and in `AIBridge`.

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
                policy: RetryPolicy, security: ResolvedSecurity)   // `security`: route B, §2 ruling 1
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

**Decision.** Each run keeps all its rows in a `RowStore` actor in the app. The main actor's model holds a total count and a window of at most 512 rows. This supersedes part of ADR-04 Decision 5 (see the header). `BoundedUpdate` is still the only way rows reach the main actor, but it now carries a window, not every row of the run. ADR-04's `split` is removed, because nothing hands the main actor every row any more. The pump no longer formats rows; the store does (rule 3). The initialiser is `fileprivate`, not private: `RowStore` and `BoundedUpdate` are declared in one file, `RowStore.swift`, so only the store can make one. **The initialiser itself enforces the bound**, so the bound does not depend on the code of `RowStore.window`. ADR-04's NFR-3 row changes strength with it, and the header gives the new row in full: the compiler holds who can make a `BoundedUpdate` (only code in `RowStore.swift`), and a `precondition` holds the bound at run time, trapping an oversized window before it reaches the main actor. ADR-04's "Compiler, for the type" no longer describes the bound.

```swift
// In the app.
struct RunKey: Sendable, Hashable {
    enum Slot: Sendable, Hashable { case results, inspector, chart(UUID) }
    let investigation: UUID   // the app's identity for an open investigation; ADR-06 persists it
    let slot: Slot
}

// Sources/SNMPToolkitApp/Rows/RowStore.swift declares BoundedUpdate and RowStore, and nothing else.
struct BoundedUpdate: Sendable {
    static let maximumRows = 512    // and each Row field is still cut to 512 octets when built (ADR-04)
    let totalRows: Int              // the length of the current view (rule 2)
    let unorderedRows: Int          // rows arrived since the current ordering was built; 0 without one (rule 2)
    let windowStart: Int
    let rows: [Row]                 // view positions windowStart ..< windowStart + rows.count
    fileprivate init(totalRows: Int, unorderedRows: Int, windowStart: Int, rows: [Row]) {
        precondition(rows.count <= Self.maximumRows, "a BoundedUpdate holds at most maximumRows rows")
        precondition(windowStart >= 0 && windowStart + rows.count <= totalRows, "the window lies inside the view")
        self.totalRows = totalRows
        self.unorderedRows = unorderedRows
        self.windowStart = windowStart
        self.rows = rows
    }
}

actor RowStore {
    func append(_ batch: VarBindBatch)
    func keep(_ outcome: CollectionOutcome, for target: TargetID)     // ADR-04's call at `.finished`
    func window(from start: Int, count: Int) -> BoundedUpdate        // formats at most 512 rows
    func setOrdering(_ ordering: Ordering?)                           // built off the actor, see rule 2
}
```

**Rules**

1. **One copy of each row, at a stable index.** This rule and its test cover every operation except `.poll`: a poll's batches go to the chart's `SeriesStore` (§3.5), never to a `RowStore`, and `keep` is not called for a poll, whose outcome carries only the last tick. Each row gets a **stable index** at `append`: its position in the run's arrival order. An index is never reused and never compacted. The store keeps one entry per batch (the batch's first index, its target, its offset within that target's varbinds, and its count), so finding a row is a binary search over batches and costs nothing per row. While a target runs, the store keeps its batches as they arrive. At `.finished`, it replaces them with the outcome's array. **The outcome's array equals that target's batches concatenated in sequence order** (a test holds it), so every row keeps its index and its offset, and a finished walk is not held twice. The store's memory is ADR-04's per-target charge, one entry per batch, and 4 bytes per row for each active ordering. Formatted text is never stored: the store formats a window when asked, at most 512 rows.
2. **Sorting and filtering happen off the main actor** (FR-15). A `@concurrent` function runs over a snapshot of the store's arrays, which is a copy-on-write copy and copies no element. It builds an `Ordering`, a list of stable `Int32` row indices, which the store then swaps in. The next keystroke cancels it, as ADR-04 Decision 5 consequence 4 does for the MIB filter. A text filter formats every row inside that function, never in the actor and never on the main actor.
   - **The view** is what a window's positions index. Without an ordering, it is every row not dropped (rule 8), in arrival order. With one, it is the ordering's indices, less any row dropped since the ordering was built. `totalRows` is the view's length. Because an ordering holds stable indices, nothing in it goes stale when the store changes underneath it: `.finished` keeps every index (rule 1), and a drop marks rows instead of removing them (rule 8).
   - **Rows arriving under an ordering are not merged in on each flush.** A merge copies the whole ordering, 4 bytes per row, every 100 ms, which at a few million rows is tens of megabytes per flush. Instead they stay outside the view and are counted in `unorderedRows`, which the grid shows as "N new rows". The ordering is rebuilt off the actor while rows arrive: each rebuild starts when the previous one has finished, and no sooner than 1 s after it started (proposed, §7 item 3). It is rebuilt once more when the run finishes. Each rebuild costs a sort of the snapshot, O(n log n) comparisons, plus formatting every row while a text filter is active, all on the pool. A keystroke cancels a rebuild in flight and starts its own.
3. **Pacing.** This replaces the pump body of ADR-04 Decision 5: the pump no longer formats, coalesces or splits rows. It appends each batch, unformatted, to the store. While rows arrive, at most every 100 ms (ADR-04's flush interval), and immediately when a target finishes, it asks the store for a fresh `BoundedUpdate` for the model's current window and awaits `model.apply`. Each update costs the main actor one array replacement of at most 512 rows and three counts, however large the run is. This answers ADR-04's warning that its 10.5 ms measurement came from an array that grew on the main actor: no array on the main actor grows now.
4. **Scrolling** asks the store, through `CollectionHost`, for the new window. Rows not yet delivered draw as placeholders until it arrives.
5. **512 stays the bound.** The window is the visible rows plus overscan above and below. At the 17 to 24 pt row heights of a macOS table, a tall display shows roughly 100 to 130 rows, so 512 allows about one and a half screens of overscan on each side. The NFR-10 run confirms it (open item 4).
6. **The grid is pulled by row index.** AppKit's `NSTableView` asks its data source for the row count and then for a view for each visible row ([`NSTableViewDataSource`](https://developer.apple.com/documentation/appkit/nstableviewdatasource)), which is exactly the window model. SwiftUI's `Table` takes its rows as a collection of identifiable values. Whether it reads every element's identity on an update is not documented and was not measured here; if it does, that is O(rows) main-actor work at 1.6 million rows. So the result grid is an `NSTableView` inside an `NSViewRepresentable`, unless the NFR-10 run shows a SwiftUI `Table` over the windowed model staying inside 16 ms (open item 4).
7. **Retention.** A store lives until a new run replaces it on the same `RunKey`, or until its investigation closes (`CollectionHost.discard`). It is never freed on the main actor (ADR-04) and nothing expires it on a timer. At worst it holds targets × `WalkLimit` for each results slot, with one results slot per open investigation.
8. **INV-4 and rows already shown** (ADR-04 open item 5; §2 ruling 2). INV-4 is read strictly (§2 ruling 2, 2026-11-11), as ADR-04 read it. When `.finished(target, .securityFailure)` arrives, the store **marks** that target's rows as dropped: their indices stay allocated, the rows leave the view, and the next update shows the error in their place. Removing them from an active ordering is one O(n) pass off the actor. It is one rule in `keep`, and no index changes.
9. **Export** (FR-19) reads the store from a `@concurrent` writer, never from the model. The writer neutralises formula injection.

**`RunKey`** (ADR-04 open item 4). Each open investigation has one results grid, one inspector (FR-16's current value, a `.get`) and one slot per chart. ADR-04's restart rule applies per key: a new walk in an investigation's results slot stops the walk before it, while charts run independently of each other and of the grid.

### 3.3 Secrets: the credential-store protocol

**The protocol does not depend on the password route.**

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
| App code cannot read a secret back out of a `Credential` | its bytes are `internal` to `SNMPCore` | Compiler (safe Swift) |
| A `Credential` cannot be printed, interpolated, dumped or reflected | `print`, `String(describing:)`, `String(reflecting:)`, string interpolation, `dump` and `Mirror(reflecting:)` all need a copyable argument (§3.7) | Compiler (safe Swift) |
| A `Credential` cannot sit in a request or an array | a non-copyable stored property of a copyable struct, or an array element, is refused | Compiler (safe Swift) |
| A `Credential` is not persisted by `Codable` | it does not conform | Compiler, for `Codable` |
| **The secret exists only inside the borrow** | **No.** The adapter holds copyable bytes between the Keychain read and `init`, and code inside `SNMPCore` can copy the bytes it is lent. No zeroisation is promised (ADR-03 §2.2) | Review |
| `ResolvedSecurity`, `MasterKey` and `CommunityString` cannot be made outside the core | none has a public initialiser | Compiler (safe Swift) |
| `ResolvedSecurity`, `MasterKey` and `CommunityString` are not persisted by `Codable` | none conforms. A harness fixture (§3.6): a `Codable` struct holding a `ResolvedSecurity` fails to synthesise its conformance | Compiler, by absence of the conformance |
| `ResolvedSecurity`, `MasterKey` and `CommunityString` print redacted, and their mirrors are empty | their `description`, `debugDescription` and `customMirror` | Test |
| **What lives for the run cannot be copied, printed or kept in a request** | **No.** All three are copyable on purpose: a target's task needs the secret on every attempt (ADR-04 Decision 2 consequence 4). `print`, interpolation and `dump` accept them, and only their redaction keeps the secret out of the text | Test (the redaction row above) and review |
| `Security` appears only in the adapter | §3.6: the import and the symbols | Check |

**"Compiler (safe Swift)"** means the compiler holds the property for code that uses no unsafe constructs. With unsafe pointers it does not: code outside the core that copies a `SetConfirmation` with `withUnsafePointer`, `copyMemory` and `move()` can spend both copies, and `UnsafeRawPointer(p).load(as: [UInt8].self)` reads a `Credential`'s bytes back. The independent review on this pull request of commit 931324d built both outside the core, and both compiled and ran. Strict memory safety (`.strictMemorySafety()`, Swift 6.2 and later) flags both, and the review of commit af550e2 confirmed that with warnings as errors it refuses both (§3.7), so §3.6 turns it on, with warnings as errors, for every module that uses the core from above, and a check lists every use that is acknowledged with `unsafe` there.

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
    // App API, not part of CredentialStore: the settings UI's only way to write. Off the main actor, like the read.
    @concurrent func save(_ secret: [UInt8], replacing: CredentialReference?) async throws(SNMPError) -> CredentialReference
    @concurrent func delete(_ reference: CredentialReference) async throws(SNMPError)
}
```

| Concern | Rule |
|---|---|
| **API and implementation** | `SecItem`, the generic-password class, the data protection keychain. [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) recommends both, and says either `kSecUseDataProtectionKeychain` or `kSecAttrSynchronizable` set to true selects that keychain. The adapter uses the first, because the second would also sync the item |
| **iCloud** | `kSecAttrSynchronizable` is false on every add and every query, as INV-3 requires ("Keychain items are created non-synchronizable") |
| **Identity** | `kSecAttrService` is a constant. `kSecAttrAccount` is the reference's `rawValue`, a fresh UUID minted at `save`. No other attribute carries anything the user typed except a label naming the target, and never the secret |
| **Where it runs** | `@concurrent`, so neither a read nor a `save` or `delete` from the settings UI is ever on the main actor (NFR-3). `SecItemCopyMatching` is a synchronous call, and it is accepted on the pool for the reason ADR-04 Decision 1 consequence 7 accepts `StandardMIBBundle`'s read: one short call, no user interaction |
| **Prompts** | Items are created with no access-control object, so a read never shows UI. A Touch ID-protected item would put a wait for the user into resolution, so v1 has none |
| **Status codes** | `errSecItemNotFound` → `.notFound`; `errSecMissingEntitlement` → `.storeUnavailable`; `errSecInteractionNotAllowed` and `errSecAuthFailed` → `.accessDenied`; every other `OSStatus` → `.storeFailed(code:)`, verbatim, as ADR-02 reports `errno` |
| **Unprovisioned builds** | TN3137: a program reaches the data protection keychain only through entitlements authorised by a provisioning profile, embedded in an app-like bundle. A `swift run` build has neither. In such a build the adapter reports `.storeUnavailable`, and the app offers `SessionCredentialStore` instead: secrets held in memory until quit and never written, so INV-1 holds. There is no fallback to the file-based keychain, which would leave the same secret in two implementations for FR-25 to migrate |
| **Access group** | Items live in the app's default access group, which derives from the team and the bundle identifier. A change of either orphans every item, so the bundle identifier is fixed before the first release that stores a secret. Migration belongs to ADR-06 |

**Headless products.** `snmpcli` and the Linux collector have no Keychain. Each supplies its own `CredentialStore`; a prompt, the environment and a mode-0600 file are the obvious candidates. That choice is not made here. INV-1's "outside the Keychain" is a requirement on the macOS app, and the specification has to restate it for the headless products before either ships (open item 6).

#### The route: how a v3 password reaches the walk (ADR-04 open item 1) — B (§2 ruling 1, 2026-11-11)

ADR-03's `localizedKey(password: borrowing Credential, engineID:)` needs the remote engine ID, which a first-contact target only has after discovery, inside its own task. A non-copyable `Credential` cannot sit in a `CollectionRequest`; the compiler refuses it (§3.7). The three options are ADR-04's, restated with what each does to the store protocol. The product owner chose B on 2026-11-11 (§2 ruling 1); A and C stay here as the rationale.

**Option B — resolve before start (chosen: §2 ruling 1, 2026-11-11).** `ResolvedSecurity.resolve` reads each password once through the store, before `start`, and derives Ku with RFC 3414 §A.2's 1 MiB expansion. The request carries Ku as a redacted, copyable `MasterKey`, and the target's task localises it per engine after discovery. A community string becomes a redacted, copyable `CommunityString` the same way.

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
        public init(protocolID: AuthProtocolID, password: CredentialReference)
    }
    public struct Priv: Sendable, Hashable {
        public let protocolID: PrivProtocolID           // DES, AES-128, AES-192, AES-256 (ADR-03 §2.4)
        public let password: CredentialReference
        public let keyExtension: AESKeyExtension?       // ADR-03 §2.5's per-user setting; nil for DES and AES-128, always explicit for AES-192 and AES-256
        /// Throws SNMPError.invalidConfiguration for a non-nil keyExtension with .des or .aes128: ADR-03 §2.5's
        /// extensions lengthen a key only for AES-192 and AES-256. For those two, a nil argument is stored as ADR-03's
        /// default at configuration time, .reeder, so the stored value is always explicit: a persisted user never
        /// changes extension if that default flips (ADR-03 §5 trigger 1), and nil and .reeder are one configuration.
        public init(protocolID: PrivProtocolID, password: CredentialReference,
                    keyExtension: AESKeyExtension? = nil) throws(SNMPError)
    }
    public let userName: String
    public let auth: Auth?                              // nil: noAuthNoPriv
    public let priv: Priv?
    /// Throws SNMPError.invalidConfiguration for privacy without authentication: RFC 3411's security levels have no such level.
    public init(userName: String, auth: Auth?, priv: Priv?) throws(SNMPError)
}

/// The authentication protocols of ADR-03 §2.3, one per HMACAuthentication instance; the core maps each to it.
public enum AuthProtocolID: Sendable, Hashable, CaseIterable {
    case md5, sha1, sha224, sha256, sha384, sha512      // HMACAuthentication.md5 … .sha512
}

/// The privacy protocols of ADR-03 §2.4.
public enum PrivProtocolID: Sendable, Hashable, CaseIterable {
    case des, aes128, aes192, aes256
}

/// Redacted, copyable, not Codable. No public initialiser. Holds, internally, a CommunityString (v1, v2c)
/// or the user's name, protocols and MasterKeys (v3).
public struct ResolvedSecurity: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var securityName: String { get }             // the user name, or "v1 community" / "v2c community"
    public var description: String { get }              // names the security name and level; never a secret
    public var debugDescription: String { get }         // the same
    public var customMirror: Mirror { get }             // no children
    @concurrent
    public static func resolve(_ configuration: SecurityConfiguration,
                               from store: some CredentialStore) async throws(SNMPError) -> ResolvedSecurity
}

/// Ku, RFC 3414 §A.2: the 1 MiB expansion of a v3 password through one authentication protocol's hash.
/// Redacted, copyable, Sendable, not Codable, not Equatable. No public initialiser: only `masterKey(password:)`
/// makes one. Its bytes, and the authentication protocol that derived it, are internal to SNMPCore.
public struct MasterKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { get }              // "MasterKey(redacted)"
    public var debugDescription: String { get }         // the same
    public var customMirror: Mirror { get }             // no children
}

/// A v1/v2c community string: the redacted form ADR-04 Decision 2 consequence 4 left to this record.
/// Redacted, copyable, Sendable, not Codable, not Equatable. No public initialiser: only `resolve` makes one.
/// Its bytes are internal to SNMPCore; `encode` writes them into every message.
public struct CommunityString: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { get }              // "CommunityString(redacted)"
    public var debugDescription: String { get }         // the same
    public var customMirror: Mirror { get }             // no children
}
```

None of the three is `Equatable`: an equality operator over secret bytes is a timing oracle unless it is constant time, and nothing above the core needs to compare them.

Before `start`, the host resolves each distinct configuration in the run once. Resolution is `@concurrent`, so it runs on neither the main actor nor the host actor. A target whose configuration fails to resolve gets a summary of `.securityFailure(.credentialUnavailable(…))` and does not start; the other targets start (FR-5). Ku and community strings live in the requests for the run's lifetime and go with the run; nothing is cached across runs. Resolution cannot be cancelled part-way, but it does at most two derivations per distinct user, about 6 to 7 ms each (ADR-04 Decision 5 consequence 3), and the host checks for cancellation before `start`.

Option B costs a change to ADR-03 §2.3. `localizedKey(password:engineID:)` becomes two requirements:

```swift
func masterKey(password: borrowing Credential) throws(SNMPError) -> MasterKey               // RFC 3414 §A.2: Ku
func localizedKey(master: MasterKey, engineID: [UInt8]) throws(SNMPError) -> LocalizedKey   // Kul; throws if `master` came from another protocol
```

The privacy password goes the same way, through the authentication protocol's `masterKey` and `localizedKey`, and then into ADR-03's unchanged `privacyKey(from:engineID:)`. RFC 3414 §2.6 localises the privacy key with the user's authentication protocol, and ADR-03's AES key extensions already rely on that. B also carries ADR-04's other costs: Ku works for every engine that shares the password and lives for the whole run, and every credential is read up front, even for a target that never answers.

**Option A — read inside the walk.** The request carries a credential source (a store and a reference), and the target's task calls `withCredential` after discovery. ADR-03 stays as it is and `Credential` stays non-copyable. The costs: if a store ever prompts, the user's wait happens inside a walk. For FR-6, the protocol's typed `throws(SNMPError)` would have to become untyped so it can carry `CancellationError`, and every adapter would have to abandon a read when cancelled. The community string needs its own route regardless.

**Option C — a copyable, redacted `Credential`.** The store returns the credential by value. It is the simplest option. The costs: ADR-03's `borrowing` signature changes, and the password itself stays in memory for the run. The compiler refusals for `Credential` in the table above are lost: a copyable credential can be printed and relies on its redacted description (ADR-05), and it can sit in a request. It is still not `Codable`.

**What B protects that C does not, stated in full.** The version of this record at commit 931324d credited B with "keeping the compile-time refusals" and charged C with a credential that "can be printed … and can sit in a request". That overstates B. Under B the compile-time refusals protect the `Credential` only inside one borrow, during `resolve`. What lives for the whole run is a copyable, printable `ResolvedSecurity`, and it holds:

- **for v3, Ku** (`MasterKey`). Ku is not the password, but it authenticates as that user on every engine that shares the password. Protecting Ku is the reason RFC 3414 §2.6 localises keys per engine;
- **for v1 and v2c, the community string itself** (`CommunityString`). ADR-04 Decision 2 consequence 4 already found that it must cross into the target's task as a copyable value, because `encode` writes it into every message.

| What lives for the run | A | B | C |
|---|---|---|---|
| v3 | a store and a reference; the password is read inside the walk | Ku, copyable and redacted | the password, copyable and redacted |
| v1, v2c | the community string, which needs its own route regardless | the community string, copyable and redacted | the community string, copyable and redacted |
| Where the compile-time refusals hold | every read, inside a borrow in the walk | only inside the borrow during `resolve` | nowhere for the secret, beyond not being `Codable` |
| What keeps the secret out of a log for the run | the borrow | redaction (Test) | redaction (Test) |

So **for v1 and v2c, B and C give the same protection.** **For v3, B's only real gain over C is that the plaintext password is not kept for the run; Ku is kept in its place.** That gain is real but narrow: a password the user also uses outside SNMP is not exposed by a leak of the run's memory or of an unredacted log, while within SNMP a leaked Ku is as good as the password on every engine that shares it. B's extra costs against C: the incompatible ADR-03 change, the 6 to 7 ms derivation per distinct user before `start` rather than inside the target's task, and a wider key-function check (§3.6). A and C's extra costs are as stated above.

**Decision: B** (§2 ruling 1, 2026-11-11), as ADR-04 recommended, on the narrower ground just stated. Both B and C keep cancellation prompt for every target and keep the user's wait out of the walk; A keeps neither without extra machinery. Between B and C, B keeps the v3 password out of the run at the price of the incompatible ADR-03 change, which the header lists; for v1 and v2c the choice makes no difference.

### 3.4 SET: a separate path that spends a token (INV-5, FR-3)

```swift
// SNMPCore
public struct SetRequest: Sendable {
    public static let maximumWrites: Int = 1             // §2 ruling 4 (2026-11-11): one value per confirmation, as the specification's §3 non-goal says
    public let target: TargetID
    public let address: SNMPAddress
    public let security: ResolvedSecurity                // resolved from the target's write credential (route: §2 ruling 1)
    public let writes: [VarBind]                         // each OID with the typed value to write
    public let policy: RetryPolicy                       // the target's FR-22 policy; `set` derives its one wait from it
    /// Throws SNMPError.invalidConfiguration for no writes, more than maximumWrites, or an exception value.
    public init(target: TargetID, address: SNMPAddress, security: ResolvedSecurity,
                writes: [VarBind], policy: RetryPolicy) throws(SNMPError)
}

/// The sheet's half of INV-5's token, made when the confirmation sheet is shown, so that a token's age
/// counts the time the user spent looking at the sheet. No public initialiser, not copyable; carries the request.
public struct PendingConfirmation: ~Copyable, Sendable { }

/// INV-5's token. No public initialiser, not copyable; it carries the request it confirms.
public struct SetConfirmation: ~Copyable, Sendable { }

public enum SetOutcome: Sendable {
    case applied([VarBind])                              // noError, with the agent's response varbinds
    case rejected(errorStatus: Int, errorIndex: Int)     // RFC 3416 §4.2.5 (v1: RFC 1157 §4.1.5)
    case notSent(SetRefusal)                             // provably nothing went on the wire ("How it is checked")
    case unknown(any Error)                              // any other failure once the SET's exchange was entered: the agent may have applied it
    case securityFailure(SNMPError)                      // INV-4; reported as a security error; applied or not is unknown: re-read
}
public enum SetRefusal: Sendable, Equatable { case expired(age: Duration), cancelled, discoveryFailed(SNMPError) }   // discoveryFailed never carries a security error

extension SNMPEngine {
    public init(dispatcher: SNMPDispatcher, clock: some Clock<Duration> = ContinuousClock())   // gains `clock`
    public static let confirmationLifetime: Duration     // 60 s from beginConfirmation; proposed (§7 item 3)
    /// Records the instant on the engine's clock. The flow calls it as it shows the sheet.
    public func beginConfirmation(_ request: SetRequest) -> PendingConfirmation
    /// The only way to mint a SetConfirmation. The app's confirmation flow calls it, and nothing else does (§3.6).
    public func confirmSet(_ pending: consuming PendingConfirmation) -> SetConfirmation
    /// Sends exactly the confirmed request: once, or twice only under the resend rule below.
    @concurrent public func set(_ confirmation: consuming SetConfirmation) async -> SetOutcome
}

// SNMPCore — ADR-02 §3.4's OutboundRequest with one optional field added (header: Supersedes in part).
// Existing call sites, including trailing-closure ones, still compile: the new parameter comes last, with a default.
public struct OutboundRequest: Sendable {
    public enum Version: Sendable, Hashable { case v1, v2c, v3 }
    public let version: Version
    public let encode: @Sendable (_ requestID: Int32, _ msgID: Int32) throws -> [UInt8]
    /// Called by `exchange` on the caller's task, after the request holds its ceiling slot and immediately
    /// before each attempt is encoded and sent. If it throws, nothing is sent for that attempt, the request
    /// ends, and `exchange` rethrows the hook's error unchanged. Of the same kind as ADR-04 open item 6's
    /// validation closure.
    public let beforeSend: (@Sendable () throws -> Void)?
    public init(version: Version, encode: @escaping @Sendable (Int32, Int32) throws -> [UInt8],
                beforeSend: (@Sendable () throws -> Void)? = nil)
}
```

**How a token is minted.** `beginConfirmation` records the instant on the engine's clock and wraps the request; `confirmSet` turns it into the token. The app does both in one function, around the user's answer, and spends the token in the same task:

```swift
// Sources/SNMPToolkitApp/Set/SetFlow.swift — the only caller of confirmSet in the app.
@MainActor
static func run(_ request: SetRequest, engine: SNMPEngine, sheet: SetConfirmationSheet) async -> SetOutcome? {
    let pending = engine.beginConfirmation(request)                    // the token's age counts from here
    guard await sheet.ask(request) == .confirmed else { return nil }   // the sheet's buttons only answer
    let confirmation = engine.confirmSet(pending)
    return await engine.set(confirmation)
}
```

This shape is forced. A button cannot mint the token and hand it to a `Task`: the compiler refuses to consume a non-copyable value captured by an escaping closure (§3.7).

**How it is checked.** In this order:

1. **On entry**, `set` checks the token's age against `confirmationLifetime` on the engine's clock and returns `.notSent(.expired(age:))` if it is older. It then checks for cancellation and returns `.notSent(.cancelled)`.
2. **Discovery finishes before a SET is sent.** For a v3 target whose engine ID, boots and time are not yet known, `set` first runs discovery, which is separate exchanges that write nothing, and sends the SET only after it has succeeded. A discovery failure returns `.notSent(.discoveryFailed(_))`, and cancellation during it `.notSent(.cancelled)`. **A security failure during discovery returns `.securityFailure`**, never `.notSent`: v3 time synchronisation is authenticated, and an authentication or decryption failure there is surfaced as a security error (INV-4), although nothing was written. So `discoveryFailed` carries only non-security errors, such as a timeout or a transport failure. The USM record decides discovery's details.
3. **One exchange** through the dispatcher with `retries: 0`, so the FR-5 ceiling covers SETs too. Its `OutboundRequest` carries a pre-send hook that repeats both checks **after the slot is held and immediately before the datagram is encoded and sent**. This is where the check has to be: under ADR-04 Decision 3, `exchange` first waits, first come first served, for a ceiling slot, for as long as slow targets hold the slots ("How the design fails"), so a token checked only on entry at 59 s could go on the wire many seconds later. A hook refusal is rethrown unchanged and returns `.notSent(.expired(age:))` or `.notSent(.cancelled)`.
4. **Any other failure once the SET's `exchange` has been entered returns `.unknown`**, with the error. That includes cancellation while the request is still queued for a slot. `exchange` throws `CancellationError` whether it was waiting for a slot or for a response, and its untyped error does not say whether the datagram was sent (ADR-04's FR-6 table). Making it say so would change ADR-02's error contract, and this record does not. It accepts that a SET cancelled in the queue is reported as `.unknown` although nothing was sent. The app's re-read settles it. So `.notSent` is only ever returned from steps 1 to 3, all of them before the SET's first datagram, and it always means nothing was sent.
5. **`.securityFailure` does not mean the write was not applied.** A reply with a matching id that fails authentication (ADR-04 open item 6) can arrive after the agent applied the write. When it comes from discovery (step 2), nothing was sent, but the outcome does not say which of the two it is. So the app cannot tell them apart, and its message does not overstate either way: it reports a security error, says the write may or may not have been applied, and offers a re-read. A test pins the discovery case: a corrupted MAC on the time-synchronisation response returns `.securityFailure` and no SET datagram is sent. INV-4 still holds, because it is reported as a security error, never as applied, rejected or empty.

There is no separate request to compare the token with, because the token is the request. `set` waits for its one attempt for the target's `policy.maximumTimeout`, the longest that target's FR-22 policy ever waits for a single attempt (proposed, §7 item 3). It sends `RetryPolicy(timeout: policy.maximumTimeout, retries: 0, backoffFactor: policy.backoffFactor, maximumTimeout: policy.maximumTimeout)`, which satisfies ADR-02's validation by construction.

**Why the lifetime runs from the sheet.** A non-copyable value can still be kept in a class's stored property and spent later; the prototype compiles that (§3.7). Measured from the mint, the lifetime would bound only such a held token, because the flow mints after the sheet answers and spends at once. Measured from `beginConfirmation`, it also bounds how stale the confirmed view is, including the current value the sheet showed when it opened. A sheet left open past the lifetime confirms into `.notSent(.expired)`, and the app re-reads and asks again.

**A SET is sent once, and a second time only when the agent provably did not process the first.** Nothing retries a SET automatically, because a retransmission is a second write. For a `TestAndIncr` spin lock (RFC 2579) or a `RowStatus` `createAndGo`, the second write fails after the first one succeeded, and the user would be told "rejected" about a write that was applied. So a timeout returns `.unknown`. The app says so, offers to re-read the values with a GET, and a resend needs a new confirmation. The USM record may resend once, after resynchronisation, in exactly two cases and no others:

- after an **authenticated** `notInTimeWindow` report: RFC 3414 §3.2 step 7 sends that report at authNoPriv, so its MAC is checked before it is believed;
- when the SET was sent with **no engine ID**, so the agent could not have processed it. Because discovery finishes before a SET is sent (step 2), v1.0 never sends one that way. The case is named so that the bound below covers it.

The resend runs through the same pre-send hook, so a token that has expired meanwhile still does not fire. An `unknownEngineID` report is sent unauthenticated (RFC 3414 §3.2 step 3), so anyone on the path can forge one. If one answers a SET that was sent under a known engine ID, it never causes a resend: a forged report that arrives before the real response would otherwise cause a second write after the first was applied, which is the `TestAndIncr` and `createAndGo` failure this section exists to prevent. The outcome is then `.unknown`. The USM record decides the rest of report handling; **this bound is this record's: at most two datagrams per token, the second only under this rule.**

**What holds INV-5**

| Property | Held by | Strength |
|---|---|---|
| No SET without a token | only `set(_: consuming SetConfirmation)` writes; no `Operation` case writes; `SetConfirmation` and `PendingConfirmation` have no public initialiser | Compiler (safe Swift) |
| What is sent is what was confirmed | the token carries the request, bound when the sheet is shown | Compiler (safe Swift), by construction |
| One token, one write | `consuming`, and not copyable | Compiler (safe Swift) |
| At most two datagrams per token, the second only after an authenticated `notInTimeWindow` report or for a SET sent with no engine ID | `set` uses `retries: 0`; the resend rule above | Test: a lost reply sends one datagram; a forged, unauthenticated `unknownEngineID` report answering a SET sent under a known engine ID sends no second one and returns `.unknown`; an authenticated `notInTimeWindow` report sends exactly one more |
| A stale token does not fire | the lifetime on the engine's clock, measured from `beginConfirmation`, checked by the pre-send hook after the slot is held and discovery is done, immediately before each send | Test: a token that ages past the lifetime while queued behind a held slot sends nothing and returns `.notSent(.expired)` |
| `.notSent` means nothing was sent | `.notSent` comes only from the entry check, discovery and the hook, all before the SET's first datagram; every other failure after `exchange` is entered is `.unknown` | Test |
| **Only the confirmation flow mints** | **Not structural.** `confirmSet` is public, so any module that imports `SNMPCore` can call it. The check in §3.6 allows one file in the app, one proposed file in `snmpcli`, and none in `AIBridge`; a UI test drives the sheet | Check and test |
| **The user saw what will be written** | **Not structural.** The sheet displays the `SetRequest` it was handed, and a UI test holds that | Test |
| FR-3: off by default, with a write credential | the app enables its Set command only for a target with SET turned on and a write credential configured; persisted off by default (ADR-06) | Test |

INV-5's own test is "the SET path asserts a confirmation token that only the UI confirmation flow can mint". The first half is held by the compiler and the runtime tests above. The second half is held by a check and a UI test, not by a type, and this record does not claim more.

**The confirmation sheet** shows the target's name and address; the security name and level, never the secret; each OID by name and by number; the value to write, both formatted per the MIB and raw; and the current value if one was read. For v1 and v2c it warns that the write community travels in clear. Cancel is the default button, so Return does not confirm. From v1.1, `AIBridge` may build a `SetRequest` and hand it to this flow (INV-7), but it never mints a token.

### 3.5 Chart series (FR-17, FR-18)

```swift
// SNMPCore
public struct PollSpec: Sendable {
    public static let maximumOIDs = 16                  // per target per chart; the core adds sysUpTime.0; proposed (§7 item 3)
    public let oids: [OID]
    public let interval: Duration                       // at least 1 s; proposed (§7 item 3)
    public let silenceLimit: Duration                   // stop with .timedOut after this long without an answer; proposed (§7 item 3)
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
// SeriesGap has no security case on purpose: a security failure is never a gap (INV-4, below).
```

**The poll.** Each tick is one GET carrying `sysUpTime.0` first and then the series' OIDs, so all the samples in a tick come from the same moment. Ticks run on the engine's clock. A tick that falls due while the previous exchange is still in flight is skipped, so requests never pile up. Each answered tick is one `VarBindBatch`, with its `receivedAt`. A lost tick is a gap, not a stop. The poll stops when cancelled, or with `.timedOut` after `silenceLimit` without an answer. Until then, a silent polled target holds one ceiling slot, which adds a case to ADR-04's "How the design fails". A poll's outcome carries only the last tick's varbinds. The history lives in the app's series store, so a poll's memory does not grow with time, and `WalkLimit` does not apply to it.

**A security failure on any tick finishes the poll with `.securityFailure` (INV-4).** A tick whose response fails authentication or decryption is never a lost tick and never `.gap(.missingSample)`: that would be the empty result INV-4 forbids. The poll ends at once, `.finished(target, .securityFailure(_))` is its last event, and the series store treats that target's points already shown as §3.2 rule 8 treats rows under the strict reading (§2 ruling 2, 2026-11-11): they are dropped and the error is shown in their place. If the USM record decides, under ADR-04 open item 6, that a matching datagram failing authentication is discarded while the exchange keeps waiting for the genuine reply, a poll follows that rule exactly as a walk does. In no case does an authentication or decryption failure become a gap. A test in the no-network suite sends a tick whose response carries a corrupted MAC and asserts that the poll finishes with `.securityFailure` and emits no `.gap`.

**A tick answered with `tooBig`.** Sixteen `Counter64` OIDs plus `sysUpTime.0` make a response of about 600 octets over v3 authPriv, above the 484-octet floor RFC 3412 sets for `msgMaxSize`. An agent that accepts only the floor answers `tooBig`. The poll then splits the tick's OIDs into two GETs, each carrying `sysUpTime.0` first, halving again on a further `tooBig`, and keeps that split for the rest of the poll. A tick is then several GETs sent one after another, and it is in flight until the last one is answered. The samples of each GET share that GET's `sysUpTime`, which is all the rate rule needs, because rates are per counter. A GET of one OID that is still answered `tooBig` stops the poll with ADR-04's `CollectionStop.agentMisbehaved`.

**The rate rule**

| Case | Result | Why |
|---|---|---|
| Time base | the local arrival instants | `sysUpTime` counts centiseconds, so its ±10 ms resolution is ±1% of a 1 s interval; arrival jitter on a LAN is of the order of a millisecond. `sysUpTime` is used only to detect a restart |
| `sysUpTime` went backwards | `.gap(.agentRestarted)` | the agent's counters restarted with it |
| A `Counter32` went backwards | one wrap: new + 2³² − old | RFC 2578 §7.1.6. Two wraps within one interval cannot be seen: a 10 Gb/s interface wraps `ifInOctets` every 3.4 s, so charts of fast links use the Counter64 `ifHC…` objects (RFC 2863) |
| A `Counter64` went backwards | `.gap(.counterDiscontinuity)` | a genuine 64-bit wrap is implausible, so a decrease is a reset |
| An exception value, a changed type, or a lost tick | `.gap(.missingSample)` | |
| A tick that fails authentication or decryption | no point: the poll finishes with `.securityFailure` | INV-4: a security failure is never an empty or partial result, so never a gap |
| `Gauge32`, `Integer32`, `TimeTicks` | plotted as values, with no rate | |

The rule lives in the core so that the headless collector does not have to write it again. The pump applies it to each batch. FR-24, which forbids Counter64 rates against a v1 target, is checked when a chart is configured, above the core, because only the MIB knows an object's type before a value arrives.

**In the app.** A `SeriesStore` actor per chart run keeps a full-resolution ring per series, sized as window ÷ interval (an hour at 1 s is 3,600 points). The main actor receives at most 600 points per series (proposed, §7 item 3). A window of at most 600 samples is shown as it is, one point per sample (10 minutes at 1 s). A longer window is decimated off the main actor into **300 buckets, each drawn as two points, its minimum and its maximum**, so peaks survive: 300 × 2 = 600 points, not 600 buckets. The main actor gets one update per tick per chart, so eight series hold at most 4,800 points on the main actor, whatever the window. Export reads the full resolution from the store. The NFR-4 run confirms 600 (open item 3).

### 3.6 The checks (added to ADR-04 Decision 6; one line replaces one of its lines)

```sh
S='--include=*.swift'
A=Sources/SNMPToolkitApp
U="Sources/SNMPToolkitApp Sources/AIBridge Sources/snmpcli"
# Security.framework only in the Keychain adapter (ADR-01 §3.2 clarification 3): the import, and its symbols.
grep -rlE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]*)*(public|package|internal|private|fileprivate)?[[:space:]]*import[[:space:]]+Security([^[:alnum:]_]|$)' $A "$S" 2>/dev/null | grep -vE '/KeychainCredentialStore\.swift$'
grep -rlE 'SecItem[A-Za-z]*\(|kSec[A-Z]' $A "$S" 2>/dev/null | grep -vE '/KeychainCredentialStore\.swift$'
# A secret becomes a Credential only in the two stores.
grep -rlE 'Credential\.init([^[:alnum:]_]|$)|Credential\(bytes:|\.init\(bytes:' $A "$S" 2>/dev/null | grep -vE '/(KeychainCredentialStore|SessionCredentialStore)\.swift$'
# SET confirmations are minted in one file of the app, one file of snmpcli, and nowhere else.
# The pattern is the portable spelling of `confirmSet\b`: it matches a call and a function reference alike.
grep -rlE 'confirmSet([^[:alnum:]_]|$)' $A "$S" 2>/dev/null | grep -vE '/SetFlow\.swift$'
grep -rlE 'confirmSet([^[:alnum:]_]|$)' Sources/snmpcli "$S" 2>/dev/null | grep -vE '/SetPrompt\.swift$'
grep -rlE 'confirmSet([^[:alnum:]_]|$)|SetConfirmation|PendingConfirmation' Sources/AIBridge "$S" 2>/dev/null
# The app and AIBridge never derive or localise a key. Replaces ADR-04 Decision 6's `localizedKey(` line.
grep -rnE '(masterKey|localizedKey|privacyKey)([^[:alnum:]_]|$)' Sources/SNMPToolkitApp Sources/AIBridge "$S" 2>/dev/null
# Unsafe code above the core: strict memory safety makes every unacknowledged use an error, so list the acknowledged ones.
grep -rnE '(^|[^[:alnum:]_])unsafe[[:space:]]|@unsafe' $U "$S" 2>/dev/null | grep -vE '/KeychainCredentialStore\.swift:'
```

The independent review on this pull request of commit af550e2 ran every line above verbatim, with the `Credential` line and the key-function line in their earlier, call-only spelling (`Credential(\.init)?\(bytes:` and `(masterKey|localizedKey|privacyKey)\(`). On that commit's tree they printed nothing. On fixtures each fired: `import Security` and `@preconcurrency import Security` outside the adapter; `SecItemCopyMatching(` and `kSecClass`; `Credential(bytes:` and `Credential.init(bytes:`; a `confirmSet` method reference in the app, and a `confirmSet` call in `snmpcli` outside `SetPrompt.swift`; `PendingConfirmation` in `AIBridge`; `masterKey(` in `AIBridge`; an acknowledged `unsafe`. The allowed files and `import SecurityInterface` stayed silent. Those two lines match whole words because that review found the call-only spellings missed `let k = HMACAuthentication.sha256.masterKey; _ = try? k(cred)`, `let make = Credential.init; _ = make(bytes)` and `let c: Credential = .init(bytes: x)`; as widened, the independent review on this pull request of commit 2635d8b ran them: they caught all three and stayed silent on that commit's tree and on decoys. As in ADR-04, the lines catch the plain mistake, not a determined one, and the file names they allow are part of this record: a rename updates it. Each reads call text, which is why the names are matched as words: `let mint = engine.confirmSet; mint(r)` mints without the text `confirmSet(`. The symbol line exists because it cannot be checked on Linux whether Darwin's `Foundation` or `AppKit` make `Security`'s C API visible without `import Security`. If they do, the import line alone misses a Keychain call. Whether they do is a Mac check (§7 item 5). The Keychain adapter is the one file expected to need `unsafe`, for `SecItemCopyMatching`'s out-parameter; the full allow-list is set from a macOS build (§7 item 5).

**Strict memory safety above the core.** The modules that use the core from above it build with strict memory safety and warnings as errors. That is what turns "Compiler" in §3.3 and §3.4 into "Compiler (safe Swift)" for code that has not opted out with `unsafe`, and the last check line lists every place that has:

```swift
// Package.swift (needs swift-tools-version 6.2; the manifest is at 6.0 today, and the story that first builds these targets raises it).
let aboveTheCore: [SwiftSetting] = [.strictMemorySafety(), .treatAllWarnings(as: .error)]
// .executableTarget(name: "SNMPToolkitApp", …, swiftSettings: aboveTheCore)
// .target(name: "AIBridge", …, swiftSettings: aboveTheCore)
// .executableTarget(name: "snmpcli", …, swiftSettings: aboveTheCore)
```

**The negative-compilation harness** (SC-5 counts it as a check) holds the compiler rows in §3.3 and §3.4 with one fixture each: a token or a `PendingConfirmation` made outside the core, a token spent twice, a token stored in a copyable struct or an array, a token consumed inside a `Task` closure, a `Credential` printed or interpolated, its bytes read from outside the core, a `ResolvedSecurity`, `MasterKey` or `CommunityString` made outside the core, a `Codable` struct holding a `ResolvedSecurity` (its conformance fails to synthesise), and, in a module built with `aboveTheCore`, the two unsafe-pointer escapes of §3.3 written without `unsafe`. **The harness must compile through SIL** (a full build, or `swiftc -emit-sil`), not `-typecheck`. Move checking runs in SIL, so `-typecheck` accepts a token spent twice and a token consumed in a closure, and a harness built on it would pass for the wrong reason (§3.7).

### 3.7 Validation (Linux, Swift 6.4.2)

**Verified by the independent review on this pull request of commit af550e2** (Swift 6.4.2, `swift-6.4.2-RELEASE`, GPG-verified, on Ubuntu 24.04; a throwaway package at `swift-tools-version: 6.2`, Swift 6 mode; `SNMPCore` importing only Foundation with warnings as errors; the app module built with §3.6's `aboveTheCore` settings and `NonisolatedNonsendingByDefault`; stand-ins for `OID`, `SNMPValue`, the dispatcher and the key derivation):

- the core signatures of §3.1 and §3.3 to §3.5 compile as written, with `OutboundRequest`, `BoundedUpdate`, `RowStore`, `RunKey`, `SetFlow` and the two credential-store shapes; the `@concurrent` `CredentialStore` witnesses compile in the app module; `SNMPEngine(dispatcher:)` still compiles beside the new `clock:` default; ADR-02's trailing-closure `OutboundRequest(version:) { _, _ in … }` still binds to `encode`;
- 3 of 3 tests pass, also under ThreadSanitizer: a token minted at 59 s that queues behind a held slot is 64 s old when the slot frees and returns `.notSent(.expired(age: 64 s))` with no datagram sent; a lost reply returns `.unknown` with exactly one datagram; `ResolvedSecurity`'s description, `String(reflecting:)` and `dump` hold no secret and its mirror has no children;
- built through SIL, every negative fixture of §3.6 is refused, including a `PendingConfirmation` made outside the core, a token in `any Sendable` or copied generically, a `MasterKey` or `CommunityString` made outside the core, a `Codable` struct holding a `ResolvedSecurity`, a `BoundedUpdate` made outside `RowStore.swift`, and both unsafe-pointer escapes without `unsafe`; under `-typecheck` only, the spent-twice and `Task` fixtures are accepted, as §3.6 says;
- `.strictMemorySafety()` and `.treatAllWarnings(as:)` are refused at tools versions 6.0 and 6.1 and accepted at 6.2, and both are needed: without strict memory safety the unsafe escapes compile, and without warnings as errors they are only warnings.

The independent review on this pull request of commit 2635d8b (Swift 6.4.2, GPG-verified, Ubuntu 24.04, the same settings) compiled what was added in answer to the review of af550e2: the public initialisers of `USMUser.Auth` and `USMUser.Priv` with the key-extension rule, `AuthProtocolID` and `PrivProtocolID`, the `@concurrent` `save` and `delete` of the Keychain adapter (against a stand-in), and the `.securityFailure` path for discovery. 6 of 6 tests pass, also under ThreadSanitizer, and 24 negative fixtures are refused through SIL. The normalisation of a nil key extension and the discovery test of §3.4 step 5 were written after that review and are not compiled.

**The prototype of the record's first proposal**, at commit 931324d:

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

- An incompatible change to ADR-03 §2.3 (§3.3), accepted with route B (§2 ruling 1, 2026-11-11).
- Ku and community strings in memory for the length of a run, copyable and kept out of logs only by redaction; every credential read up front.
- A SET cancelled while it is queued for a ceiling slot is reported as `.unknown`, although nothing was sent, because `exchange` does not report whether it sent.
- Rows dropped under INV-4 keep their stable indices, so their memory is held until the run is replaced or discarded.
- An `NSTableView` bridged into a SwiftUI app, and a moment of placeholders while a scroll's window is fetched.
- "Only the flow mints" is a check, not a type.
- A SET is never retried, so the user deals with `.unknown`.
- A silent polled target holds a ceiling slot until its `silenceLimit`.
- Unprovisioned development builds forget their secrets at quit.
- The bundle identifier is frozen before the first release that stores a secret.

**Artefacts changed with this record.** `README.md` lists ADR-03 and this record beside the others, and no longer labels the merged ADR-02 and ADR-04 "(proposed)". The specification is not changed by this record; its §3 non-goal stands as written, because SET writes one value per confirmation (§2 ruling 4, 2026-11-11). The numbers of §7 item 3 are in force here as proposals until the specification states them; that amendment is the pending product-owner action of §7 item 9.

**Not decided here.** Where the new error cases sit in the taxonomy (ADR-05). How `TargetID`, `CredentialReference`, `SecurityConfiguration` and investigations are persisted and migrated (ADR-06). The MIB browsing surface (MIBKit's story). USM engine state and report handling (the USM record). `AIBridge`.

## 6. Reversal cost and reopening triggers

The store protocol and the token are small types, and reversing either touches the core's SET path and one adapter. Choosing A or C instead of B reshapes `resolve`, ADR-03 §2.3 and §3.6's key-function line, and nothing else in this record. Going back from the window model to full rows on the main actor needs no core change.

This record is **reopened**, by a superseding record, when any of these is observed:

1. **The NFR-10 run** shows the windowed grid over 16 ms on the baseline Mac, for a cause in the window model.
2. **A Keychain read prompts or blocks** long enough to show up in resolution, for example under a policy that requires user presence.
3. **The signed, sandboxed build cannot use the data protection keychain.**
4. **A requirement needs a SET without per-operation confirmation**, such as bulk configuration (a non-goal in §3 of the specification), or needs one retried automatically.
5. **A Swift release lets a non-copyable value be consumed in an escaping closure, or be printed.** The flow's shape and the "cannot be printed" row are then looked at again.

## 7. Open items

1. **The password route (§3.3).** Decided: B (§2 ruling 1, 2026-11-11), on the comparison in §3.3. B changes ADR-03 §2.3 incompatibly; the header lists the change.
2. **INV-4 and rows already shown** (ADR-04 open item 5). Decided: the strict reading (§2 ruling 2, 2026-11-11), as §3.2 rule 8 and §3.5 implement it.
3. **Numbers.** Every number below is **a proposal for the specification** (§2 ruling 3, 2026-11-11). Until the specification states it, it is in force as written in this record; a later revision of the specification changes it without a superseding record. The amendment that states them is §7 item 9. Each carries its basis.
   - **Confirmation lifetime: 60 s, measured from when the sheet is shown** (`beginConfirmation`, §3.4). Proposed for the specification (§2 ruling 3). Basis: measured from the mint, a lifetime would only limit a held token, because the flow mints after the sheet answers and spends at once; measured from the sheet, it also limits how stale the confirmed view can be, including the current value the sheet read when it opened. A minute is ample to read a sheet of a few values; a sheet left open longer is re-read and confirmed again.
   - **Writes per SET** (§2 ruling 4). **Decided (2026-11-11): (a), `maximumWrites = 1` for v1.0**; the specification is unchanged. The two alternatives as they were put:

     | | (a) `maximumWrites = 1` for v1.0 | (b) `maximumWrites = 16`, with a specification amendment |
     |---|---|---|
     | The specification | unchanged. Its §3 non-goal, "SET exists for single values under confirmation; this is not a provisioning tool", holds as written | §3's non-goal is amended, for example to "SET exists for one confirmed request of at most 16 values that the agent applies together (RFC 3416 §4.2.5); this is not a provisioning tool". The product owner rules on that text |
     | What it serves | a single writable scalar, such as `sysContact.0` or `ifAdminStatus.n` | also the writes that must travel in one PDU: creating a conceptual row with `RowStatus` `createAndGo`, which an agent may refuse unless the row's columns that have no default are set in the same PDU (RFC 2579, `RowStatus`); and a `TestAndIncr` spin lock set in the same PDU as the objects it guards (RFC 2579, `TestAndIncr`) |
     | What a v1.0 user does instead | creates a row with `createAndWait`, then sets each column, then `active`, each value confirmed separately, where the agent supports `createAndWait`; has no spin-lock-guarded write | — |
     | Basis for the number | one value per confirmation, as the non-goal says | RFC 3416 sets no limit on varbinds per SET. 16 is a legibility bound for one confirmation sheet, not a protocol one |
     | Cost | none now; raising it later changes a constant and the sheet, not a type | a sheet that shows up to 16 values legibly; §6 trigger 4 then reads against the amended non-goal |
   - **SET timeout: derived from the target's `RetryPolicy`, not a constant.** Proposed for the specification (§2 ruling 3). One attempt (`retries: 0`) that waits the target's `policy.maximumTimeout`, FR-22's configurable per-target cap: the longest that target's policy ever waits for a single attempt. That is 8 s under ADR-02's proposed FR-22 defaults (§8 item 3). Basis: a SET is never retried, so it gets the longest single wait the user configured, not the first attempt's shorter one.
   - **Poll interval: at least 1 s.** Proposed for the specification (§2 ruling 3). Basis: NFR-4 states 1 s, and at a shorter interval the arrival-time base of §3.5's rate rule gains nothing while `sysUpTime`'s centisecond resolution becomes a larger share of the interval.
   - **OIDs per target per chart: at most 16.** Proposed for the specification (§2 ruling 3). Basis: twice NFR-4's 8 series, the margin ADR-04 took for the ceiling; it is not derived from message size. A tick of 16 `Counter64` OIDs plus `sysUpTime.0` is a response of about 600 octets over v3 authPriv, above RFC 3412's 484-octet floor for `msgMaxSize`, so an agent that accepts only the floor answers `tooBig`; the tick then splits (§3.5).
   - **Silence limit: 60 s.** Proposed for the specification (§2 ruling 3). Basis: several of FR-22's worst-case unanswered requests (7 s each under ADR-02's proposed defaults), so a short outage leaves gaps in a chart instead of ending it, while a target that has gone away releases its ceiling slot within a minute.
   - **Displayed points per series: at most 600, which is 300 buckets × 2 points** (each bucket's minimum and maximum), not 600 buckets. Proposed for the specification (§2 ruling 3). A window of at most 600 samples is shown undecimated. Basis: 300 buckets is one per 2 pt across a 600 pt-wide plot, about the narrowest a minimum-to-maximum bar can be drawn and still be seen; eight series then put at most 4,800 points on the main actor. Not measured: the NFR-4 run confirms it.
   - **Rows in a window: at most 512**, and **ordering rebuilds no more often than every 1 s while rows arrive** (§3.2 rules 2 and 5). Proposed for the specification (§2 ruling 3). Basis: §3.2 rule 5 for 512 (argued adequately); the 1 s floor keeps a re-sort of millions of rows from running continuously while still showing new rows in order within a second or so.
   - **FR-17's selectable windows: 1, 5, 15 and 60 minutes.** Proposed for the specification (§2 ruling 3). Basis: the longest, 60 minutes at 1 s, is the 3,600-point ring of §3.5.
4. **The grid technology**: `NSTableView` unless the NFR-10 run, with ADR-04's run-loop probe on the baseline Mac, shows a SwiftUI `Table` over the window model inside 16 ms. The same run confirms the 512-row window.
5. **To run on a Mac** (not run here; they join the project's dated list of Mac-only checks): the Keychain adapter on a provisioned, sandboxed build (save, read and delete; the item not synchronizable; the status mapping), and `.storeUnavailable` from an unprovisioned `swift run` build. Whether a file that imports `Foundation` or `AppKit` but not `Security` can call `SecItemCopyMatching` (§3.6's symbol line). On the hardware bench's managed switch, used as a live agent: a SET of a writable scalar such as `sysContact.0` is `.applied`; a SET of `sysDescr.0` is `.rejected` with `notWritable` (v2c) or `noSuchName` (v1); and a SET whose reply is dropped is `.unknown`, with exactly one datagram sent. **Strict memory safety across the app:** build the app module and ADR-04's run-loop probe on macOS with `aboveTheCore`; under it, every AppKit, SwiftUI or CoreFoundation call that takes a pointer needs `unsafe` (the probe's `CFRunLoopObserver`, `withUnsafeBytes`, C out-parameters), and §3.6's last check line prints each one outside `KeychainCredentialStore.swift`. List the files that need `unsafe`, and set that line's allow-list from the list.
6. **Headless credential stores**: which `CredentialStore` `snmpcli` and the Linux collector ship, and how the specification words INV-1 for them.
7. **Counter discontinuities**: whether interface charts consult `ifCounterDiscontinuityTime` (RFC 2863) as well as `sysUpTime`.
8. **Building it**: the check lines, the negative-compilation harness and the tests named here are not yet written in this repository; each belongs to the story that first needs it.
9. **Pending product-owner action: amend the specification to state the numbers of §7 item 3** (§2 ruling 3). Not done in this pull request. Proposed text, a new list at the end of the specification's §4 *Functional requirements*:

   > **Stated values.** Until revised here, these values hold for v1.0:
   > - **FR-3** A SET confirmation expires 60 s after the confirmation sheet is shown. A SET is sent as one attempt that waits the target's configured maximum per-attempt timeout (FR-22). It is never retried on a timeout; it is resent at most once, and only when the agent provably did not process it (ADR-SNMP-07 §3.4).
   > - **FR-17** A poll interval is at least 1 s. A chart polls at most 16 OIDs per target. By default, a poll stops after 60 s without an answer. The selectable windows are 1, 5, 15 and 60 minutes. At most 600 points per series are displayed: a window of more than 600 samples is shown as 300 buckets, each drawn as its minimum and maximum.
   > - **FR-15** The result grid receives at most 512 rows at a time; a sort or filter is rebuilt at most once a second while rows arrive.

   When the specification states them, this record's constants follow it without a superseding record (§2 ruling 3).

---

*Format note.* As ADR-SNMP-01: status, date, context as forces, the decision, the alternatives that lost and why, consequences including accepted cost, the observations that reopen the record, and open items. Accepted records are not edited; they are superseded.
