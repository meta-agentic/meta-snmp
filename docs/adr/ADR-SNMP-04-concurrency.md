# ADR-SNMP-04 — Work runs in tasks, shared state lives in a few actors

| | |
|---|---|
| **Status** | Proposed — the product owner rules on it; becomes *accepted* when the pull request carrying it merges |
| **Date** | 2026-11-04 |
| **Decides** | actors or structured tasks inside the core; what is `Sendable` at each module boundary; how FR-5, FR-6 and NFR-3 are held by the design |
| **Decision** | **Each target's work is a task that owns its state. Actors hold only state shared between tasks, and do no work.** A target's task cannot throw, and it returns what it collected. The main actor receives bounded updates, one at a time, and per-target summaries; it never receives the rows of a collection or frees them. **How a v3 password reaches a target's task is not settled here (open item 1).** |
| **Builds on** | [ADR-SNMP-01](ADR-SNMP-01-portability-boundary.md), whose import rule keeps Apple frameworks out of the core. Refines [ADR-SNMP-02](ADR-SNMP-02-transport.md) on two points of `SNMPDispatcher` (Decision 3). Uses the protocols of [ADR-SNMP-03](ADR-SNMP-03-crypto.md) unchanged |
| **Governs** | `Sources/SNMPCore`, `Sources/MIBKit`, `Sources/SNMPCrypto`, `Sources/SNMPTransportPOSIX`, `Sources/snmpcli`, and the crossing from those into `Sources/SNMPToolkitApp` |

---

## Background

Today the engine is a BER codec and an OID type, both plain value types, plus one actor, `StandardMIBBundle`. Nothing collects yet. Sessions, walks, USM and the MIB tree are about to be written, and under C-1 (Swift 6, strict concurrency) the choice made now is written into every signature they expose.

Three requirements drive the choice. FR-5: collect from many targets at once, and one target's failure must not affect another. FR-6: cancel promptly and keep what was collected. NFR-3: no main-actor work over 16 ms during collection, filtering or charting.

The trap in this choice is that an actor looks like isolation and is not. Swift's actors protect memory from data races. They do not isolate failures, they do not serialise a method across an `await`, and they do not make cancellation any less cooperative. So each property below names what holds it and how strongly, and says so where nothing does.

All timings below come from a throwaway prototype of this design, not kept in this repository, on an 11-core Apple silicon Mac with Swift 6.3.3, compiled for a macOS 14 target in Swift 6 language mode with warnings as errors, against a fake transport. They show the shape of each effect and are not product benchmarks.

```mermaid
flowchart TB
    subgraph app["Above the boundary"]
        Main["Main actor<br/>views and CollectionModel"]
        Host["CollectionHost actor<br/>owns the collection, the pump and the rows"]
    end
    subgraph core["SNMPCore"]
        Col["SNMPCollection<br/>owns one root task per target"]
        T1["Target A task<br/>walk state, encode, decode"]
        T2["Target B task<br/>walk state, encode, decode"]
        Disp["SNMPDispatcher actor<br/>ids, continuations, FIFO ceiling<br/>no encoding, no decoding"]
    end
    subgraph posix["SNMPTransportPOSIX"]
        Thr["Dedicated thread<br/>poll on non-blocking sockets"]
    end
    Main -- "run, cancel" --> Host
    Host -- "start, cancel" --> Col
    Col --> T1
    Col --> T2
    T1 -- "exchange" --> Disp
    T2 -- "exchange" --> Disp
    Disp -- "send, receive" --> Thr
    T1 -- "VarBindBatch, at most 512" --> Host
    T2 -- "VarBindBatch, at most 512" --> Host
    Host -- "await apply, one bounded update at a time; then summaries" --> Main
```

## Decision 1 — Tasks do the work; actors hold shared state and do no work

**Decision.** The core is written as `async` functions over value types, run by tasks. A new actor is justified only by mutable state that several tasks share and that outlives any one of them.

**What it means.** A walk's cursor, its rows and its retry position are local variables of one task. The actors are a short list:

| Actor | Shared state | Status |
|---|---|---|
| `SNMPDispatcher` | ids in flight, parked continuations, the ceiling's queue | ADR-02, refined below |
| `USMEngineState` | one engine's discovered ID, boots and time, shared by concurrent requests to it | proposed; the USM record decides it |
| `StandardMIBBundle` | the cache of bundled module text | exists |
| The compiled-MIB store | the current tree, replaced whole when a module is imported | proposed; MIBKit's own story names it |

**Consequences**

1. Walk state cannot be shared by accident: the compiler rejects a captured `var` mutated from two concurrent tasks.
2. Code in a task is sequential, so a walk never has to re-check its state after an `await`. In an actor it would have to: ten concurrent calls that read a counter, awaited, and wrote it back left the counter at 1, not 10.
3. Actors stay fast because nothing long runs in them. This is a rule a compiler cannot check: a blocking or expensive call inside an actor compiles without complaint and stalls every caller. In the prototype, a `poll` inside an actor kept another caller waiting 278 ms.
4. Nothing in the compiler or the import rule keeps a blocking call out. Foundation re-exports the C library on this platform, so `poll`, `sleep` and `Data(contentsOf:)` all compile in a target that imports only Foundation; ADR-01's rule stops `import Darwin`, not these. The check in Decision 6 names the usual ones, and a blocking call it does not name passes.
5. Blocking calls belong on the POSIX transport's dedicated thread, as ADR-02 has it. They must not reach the cooperative pool, which is exactly as wide as the core count: 44 blocking tasks on 11 cores ran in waves of 11.
6. State read from a synchronous path cannot be an actor, since a synchronous function cannot `await` one. `OutboundRequest.encode` is synchronous, so what it needs is either captured as an immutable snapshot before the exchange or held in a lock-guarded class on the closed list in Decision 2. The compiler helps here: `NSLock.lock()` and `unlock()` are unavailable in async code, leaving `withLock`, which cannot hold a lock across an `await`.
7. One existing exception is accepted: `StandardMIBBundle.source(of:)` reads a bundled file inside the actor. It holds one pool thread for one small local file and delays only that actor's callers. User-imported MIBs, which may sit on a slow volume, are not to be read this way; MIBKit's story settles how.

## Decision 2 — Only values cross a module boundary

**Decision.** Everything public that crosses a module boundary is a `Sendable` value type, or a type on the short list below. `sending` is not used in public signatures. `@unchecked Sendable` is limited to a closed list of named types.

**What it means.**

| Boundary | What crosses | Why it is `Sendable` |
|---|---|---|
| `SNMPCrypto` to `SNMPCore` | `[UInt8]`, the hash and cipher values, `CryptoError` | value types, no shared state (ADR-03) |
| `SNMPCore` to `AuthenticationProtocol` and `PrivacyProtocol` conformers | `LocalizedKey`, `PrivacyKey`, `[UInt8]`, `OID` | value types; the protocols refine `Sendable` |
| `SNMPCore` to `SNMPTransportPOSIX` | `SNMPTransport`, `SNMPAddress`, `InboundDatagram`, `SNMPTransportError` | value types; the conformer is on the closed list |
| `SNMPCore` to the app and `snmpcli` | `SNMPEngine`, `CollectionRequest`, `TargetID`, `VarBind`, `VarBindBatch`, `CollectionOutcome`, `SNMPError` | value types, checked by the compiler |
| `SNMPCore` to the app and `snmpcli` | `SNMPCollection`, `SNMPDispatcher` | a `final class` of `let`s, checked by the compiler; an actor |
| `MIBKit` to the app and `snmpcli` | `StandardMIBBundle`; the compiled tree as an immutable value; filter results as node indices | an actor; value types whose sharing costs no copy |
| The app's pump to the main actor | `BoundedUpdate`, `CollectionSummary` | value types; the first is bounded by construction, the second has no rows (Decision 5) |
| The credential store to `SNMPCore` | **not settled: open item 1** | whichever option is chosen must be `Sendable` and copyable to sit in a `CollectionRequest`; the three options all compile |

**Consequences**

1. The closed list of `@unchecked Sendable` types is the POSIX transport, `FakeTransport`, `TestClock` and `SaltSource`, all from ADR-02 and ADR-03. Adding one is a change to this record. The compiler does not check these four, so ADR-02's locking rule and the ThreadSanitizer lane carry them.
2. `nonisolated(unsafe)`, `assumeIsolated` and `@preconcurrency` are not used below the boundary.
3. The compiler does not keep a credential out of a request. A `~Copyable` credential is refused as a stored field of a copyable struct and as an array element, but a `@Sendable` closure or a `Task` body can capture one and use it by borrow, and that compiles. So "`encode` captures derived keys, not the password" is a rule for review. It helps that a captured value does not print: a closure describes itself as `(Function)` and reflects no children, which suits INV-2.
4. The v1/v2c community string is an INV-1 credential and goes on the wire in every message, so `encode` has to hold it on every attempt. It therefore crosses into the target's task as a `Sendable` value. Its redacted form belongs with open item 1.
5. A non-`Sendable` type may still be used inside one task, such as a parser's working state. The compiler permits that and rejects any use after it has been handed to another isolation domain.
6. `MIBKit` cannot import `SNMPCore` (ADR-01), so turning a `VarBind` into a named, formatted row needs both modules and happens above them, in the pump.

**Why no `sending`.** It compiles and does avoid a copy, but it asks every caller to prove a region property, to save a copy that a value type of arrays does not make anyway.

## Decision 3 — The dispatcher holds state, and every request passes its ceiling

**Decision.** `exchange` runs on the calling target's task and enters the actor only to register an id, take a slot, or receive a response. All encoding, including v3 authentication and encryption, happens off the actor. The FR-5 ceiling counts requests in flight and is enforced inside `exchange`, first come first served.

```swift
public struct InFlightCeiling: Sendable, Hashable {
    public let value: Int
    /// Throws `SNMPError.invalidConfiguration` outside 1...512.
    public init(_ value: Int) throws
    public static let `default`: InFlightCeiling   // 16; see open item 2
}

public actor SNMPDispatcher {
    public init(transport: any SNMPTransport, clock: any Clock<Duration> = ContinuousClock(),
                ceiling: InFlightCeiling = .default)
    @concurrent public func exchange(_ request: OutboundRequest, to target: SNMPAddress,
                                     policy: RetryPolicy) async throws -> InboundResponse
    public func shutdown() async
}
```

**What it means.** This refines ADR-02 on two points: `exchange` becomes `@concurrent` where it was isolated to the actor, and `init` gains `ceiling`, with a default. Existing call sites still compile. `SNMPError` gains `case invalidConfiguration(String)`. Each request waits for a slot, holds it through all its attempts, and gives it back. The timeout clock starts only once a slot is held, so waiting in the queue does not use up retries. The reader decodes only the id, off the actor, and hands the response to the actor to complete the waiting request.

**Consequences**

1. One target's expensive encoding does not delay another's traffic. With a 50 ms `encode` on one target, a healthy target's worst round trip was 150 to 200 ms when encoding ran on the actor, and 0.1 ms when it ran on the caller's task.
2. The engine reaches the socket only through `exchange`, because the dispatcher's transport is private. So the ceiling holds without any call site remembering it, and it covers retries too.
3. A walk has at most one request outstanding, so it holds a slot only while waiting on the network. Targets interleave when answers are quick: six walks sharing two slots had collected 50 to 75 rows each when cancelled. Slow targets still slow the others; see "How the design fails".
4. Each attempt can draw one reply, so up to ceiling × attempts replies can be outstanding against ADR-02's inbound buffer of 1,024 datagrams. At the default that is 48. At the cap of 512 with two or more retries it could exceed the buffer, and the excess is dropped as UDP loss and retried. The cap is a sanity limit and does not rule that out.
5. One serial actor is not a throughput limit here: 56,000 to 88,000 exchanges a second in the prototype, against about 107 a second for NFR-1's rate on eight targets. That figure excludes the network and real cryptography.
6. A task created inside an actor method that captures `self` inherits the actor's isolation, which the compiler showed on the prototype's reader. So the reader is a `nonisolated` function, started with an explicit `.userInitiated` priority, not with whatever priority the first caller happened to have.
7. A test holds the off-actor property, not the compiler: a deliberately slow `encode` on one target, with a latency assertion on another. Nothing stops a later change from adding an isolated method that encodes.

**Why `@concurrent` and not plain `nonisolated`.** A plain `nonisolated async` function runs off the actor today, but under the `NonisolatedNonsendingByDefault` feature (SE-0461, Swift 6.2) it runs on the caller's actor, which from a view model means the main actor. The prototype confirmed it. The setting belongs to the module defining the function: turned on for the core, plain functions and protocol witnesses ran on the main actor; turned on only for the app, nothing moved; `@concurrent` stayed off the main actor in all four combinations. It costs a minimum compiler of Swift 6.2 and no runtime requirement above macOS 14.

## Decision 4 — One root task per target, which cannot throw

**Decision.** Starting a collection creates one `Task<CollectionOutcome, Never>` per target, owned by an `SNMPCollection`. Inside each one, everything is structured.

```swift
public enum CollectionStop: Sendable, Equatable {
    case finished, cancelled, limitReached(retainedBytes: Int), timedOut(attempts: Int)
    case agentMisbehaved(String), transportFailed(SNMPTransportError)
}

public enum CollectionOutcome: Sendable {
    case collected([VarBind], stop: CollectionStop)
    case securityFailure(SNMPError)                  // INV-4: carries no varbinds
    public var summary: CollectionSummary { get }
}

public enum CollectionSummary: Sendable, Equatable { // what the main actor sees at the end: no rows
    case collected(varbinds: Int, stop: CollectionStop)
    case securityFailure(SNMPError)
}

public struct WalkLimit: Sendable, Hashable {
    public let maximumRetainedBytes: Int
    /// Throws `SNMPError.invalidConfiguration` below 1 MiB. There is no unbounded value.
    public init(maximumRetainedBytes: Int) throws
    public static let `default`: WalkLimit           // 256 MiB per target; see open item 4
}

public final class SNMPCollection: Sendable {
    public let batches: AsyncStream<VarBindBatch>
    public func cancel()
    public func cancel(_ target: TargetID)
    public func outcomes() async -> [TargetID: CollectionOutcome]
    deinit                                           // cancels every target
}

public struct SNMPEngine: Sendable {
    public init(dispatcher: SNMPDispatcher)
    public func start(_ requests: [CollectionRequest]) -> SNMPCollection
}
```

**What it means.** Targets have no parent task in common, so a thrown failure has no path from one to another. A cancelled walk catches `CancellationError` and returns its rows; a failure does the same with its own stop reason. `CollectionRequest` carries the target, the address, the operation, the retry policy and the security parameters, whose v3 password route is open item 1; a walk's `WalkLimit` is part of its operation.

The walk charges each varbind against its limit as `112 + 4 × arcs + value octets`, approximately what it retains, and stops at the limit. So the limit holds however an agent shapes its answers. At a 64 MiB limit, resident memory grew by 63 MB for ordinary rows, 70 MB for 60 KB values and 66 MB for 8,000-arc OIDs.

**What holds FR-5, one target's failure not affecting another**

| Property | Held by | Strength |
|---|---|---|
| A failure cannot propagate out of a target's work | `Task<CollectionOutcome, Never>`: a throwing body does not compile | Compiler |
| Targets share no walk state | local variables in the task; a shared `var` does not compile. A walk could still share state through an actor, which review must catch | Compiler, for that form |
| A silent target ends | `RetryPolicy`, validated when built, bounds every `exchange` | Test |
| A target's expensive work does not stall the others | `exchange` encodes on the caller; decoding is in the walk's task | Test |
| One target's memory is limited | a `WalkLimit` is required (compiler), and the walk charges it (test) | Compiler and test |
| **What targets do share** | **Review only.** `SNMPDispatcher`, `USMEngineState`, `SaltSource`, the collection's `batches` stream and pump, the pool and process memory. Each critical section is meant to be short, and a stalled pump cannot stall a walk because the stream does not push back | Not structural |
| **Slow targets taken together** | **Nothing.** They take a growing share of the ceiling; see "How the design fails" | Not structural; accepted cost |
| **Memory across many targets** | **Nothing.** Each target has its limit, and the total is targets × limit | Not structural; open item 4 |
| **A trap in any task** | **Nothing.** A trap ends the whole process and no concurrency design prevents it. NFR-8's fuzzing and a codec that throws are the guard | Not structural |
| **A flood from one target** | **Nothing separates it.** The inbound buffer is shared, so a flood causes loss for everyone; retries recover or the others time out | Not structural |
| **A socket failure** | **Shared by design.** A fatal receive error fails every target, and it reports as `.transportFailed`, not as any target's fault | Not structural |

**What holds FR-6, prompt cancellation that keeps the results**

| Property | Held by | Strength |
|---|---|---|
| No caller can lose results to an error | `outcomes()` does not throw and `.collected` carries rows | Compiler, for the signature |
| The walk actually returns its rows | a walk that catches the error and returns an empty array also compiles | Test |
| Cancellation reaches everything inside a target | the structured children of its task; there is no unstructured task inside a walk | Check, Decision 6 |
| Waiting on the network ends at once | `exchange` throws `CancellationError` at once, whether waiting for a slot or for a response | Test |
| No slot is lost | `exchange` releases on both its success and failure paths | Test |
| A view going away stops its walks | a view's task runs `CollectionHost.run`, and the pump's cancellation handler cancels the collection; cancelling that task ended the walks and the pump | Test |
| A dropped handle with no consumer stops its walks | `deinit` cancels every target: no further requests went out | Test |
| **A pump nobody cancels** | **Nothing.** The pump's frame holds the collection, so `deinit` cannot run, and the walks go on until they finish or reach their limit | Not structural; bounded by the limit |
| **Other suspensions** | **Not necessarily prompt.** A walk also awaits `USMEngineState`, which is short, and possibly a credential read (open item 1), which may wait on the user | Depends on open item 1 |
| **Work between suspensions** | **Cooperative, as all Swift cancellation is.** A CPU loop cancelled at its start ran its full 200 ms, and a parent waits for it. In a walk that work is one datagram, or one key localisation of 1 MiB of hashing, more with an AES key extension | Bounded, not enforced |

**Consequences**

1. In the prototype, six walks returned all their rows within 0.06 ms of being cancelled, including those queued at the ceiling, and a later request still got a slot.
2. One target can be cancelled alone, which is the only remedy for a slow target. A `TaskGroup` cannot do this: `addTask` returns no handle, and the group has only `cancelAll`. That is why targets are not children of one group.
3. These root tasks are unstructured, so ownership stands in for structure, with the limits the table above states. An unfinished `SNMPCollection` is cancelled when released; a finished one still holds every row in its tasks' results until released, which matters for who releases it (Decision 5).
4. `start` is a synchronous, `nonisolated` function, so its tasks do not inherit the main actor when the app calls it. In the prototype, no `encode` or `decode` ran on the main thread when `start` was called from the main actor.
5. `securityFailure` has no varbinds, so the type itself holds INV-4 for the outcome. Rows sent through `batches` before the failure were already delivered; those are provisional until the outcome arrives, and the app discards them on `securityFailure` (open item 5). This part is held by a test, not by the type.
6. `batches` is an unbounded `AsyncStream`, because `AsyncStream` has no back-pressure. It is still bounded overall: no more can pass through it than the walk limit, and its elements share storage with the walk's rows.

## Decision 5 — The main actor gets bounded updates, one at a time

**Decision.** The engine does not run on the main actor. The only rows the main actor receives are `BoundedUpdate`s, by an awaited call from a single pump per collection. At the end it receives a `CollectionSummary` per target, with no rows. An app-side actor owns the collection and the rows, so the main actor never holds the last reference to them.

```swift
// In the app. The type names are this record's; the row store's shape is the UI/engine boundary record's.
struct BoundedUpdate: Sendable {
    static let maximumRows = 512               // and each Row field is cut to 512 octets when built
    let rows: [Row]
    private init(rows: [Row])
    static func split(_ rows: [Row]) -> [BoundedUpdate]   // the only way to make one; drops nothing
}

@concurrent func pump(_ collection: SNMPCollection, store: RowStore, model: CollectionModel) async {
    await withTaskCancellationHandler {
        for await batch in collection.batches {
            // format, keep the full rows in the store and pace to the screen here, off the main actor
            for update in BoundedUpdate.split(batch.varbinds.map(Row.init)) { await model.apply(update) }
        }
    } onCancel: { collection.cancel() }
    let outcomes = await collection.outcomes()
    await store.keep(outcomes)                 // the rows stay off the main actor
    await model.finish(outcomes.mapValues(\.summary))
}

actor CollectionHost {                         // the main actor holds this, never the collection or the store's rows
    private var current: SNMPCollection?
    func run(_ requests: [CollectionRequest]) async {
        let collection = engine.start(requests)
        current = collection
        await pump(collection, store: store, model: model)
        current = nil                          // released here, not on the main actor
    }
    func cancel(_ target: TargetID) { current?.cancel(target) }
}
```

**What it means.** A per-job limit is not enough, and the measurement that shows it decides the design. The same 100,000 rows at 5 µs each on the main actor gave:

| Delivery to the main actor | Longest run-loop turn | Turns over 16 ms |
|---|---|---|
| One unstructured `Task { @MainActor }` per row | 488.7 ms | 2 |
| One awaited call per row | 1.1 ms | 0 |
| Awaited batches of 512, paced | 10.5 ms | 0 |

Every job in the first row is tiny, yet they drain together in one run-loop turn and freeze the window. Awaiting each call is what lets the run loop turn between them. Batching on top of that stops the main thread being busy all the time.

Releasing rows is work too. Freeing 1,000,000 ordinary rows on the main actor took 47 to 69 ms in two separate measurements, with no other processing. That is why the rows must not reach the main actor even as a reference. In the prototype, with the host driven from the main actor, none of about 19,000 rows was released on the main thread.

**How far structure carries NFR-3**

| Layer | Held by | Strength |
|---|---|---|
| Engine async work runs off the main actor | where a function is an actor method or `@concurrent`, the compiler moves it. That every entry point is so declared is a rule; the check confirms only the absence of `@MainActor` | Compiler per function; rule overall |
| Each update has a bounded size | `BoundedUpdate` has a private initialiser and only `split` makes one, so the bound cannot be skipped and no row is dropped | Compiler, for the type |
| Updates cannot pile up in one turn | one pump per collection, awaiting each `apply` | Reading the pump; measured |
| **`BoundedUpdate` is the only crossing** | **Nothing in the type system.** A view's `Task { }` can iterate the public `batches` or call `outcomes()` on the main actor. The check confines both to one file | Rule and check |
| **Rows are freed off the main actor** | **Ownership by `CollectionHost`.** Any main-actor code holding the last reference frees them there | Rule and test |
| **Expensive synchronous engine calls** | **Nothing in the type system.** Public entry points of unbounded cost are `async`. `Task { }` from a view inherits the main actor, and a synchronous call in it runs on the main thread; an `async` `@concurrent` one does not | Rule and check |
| **A `@MainActor` method that is simply slow** | **Nothing.** The compiler has no notion of time | Measured only |
| **SwiftUI layout, Charts, drawing** | **Nothing.** The framework owns that time on the main thread | Measured only |

NFR-3 is therefore not structurally guaranteed as a whole. Structure removes the engine as a cause and bounds what the engine can ask of the main actor. The remainder is verified.

**How it is verified**

1. **A check** that no `@MainActor` appears below the boundary and that the isolation setting is not enabled (Decision 6).
2. **A test in the no-network suite** that starts a collection from the main actor and asserts `encode` and `decode` never see the main thread. It needs no timing, so it can run in CI.
3. **A run-loop probe in the app's test build:** a `CFRunLoopObserver` records the busy span of every main run-loop turn, from after waiting to before waiting. In the prototype it read a deliberate 40 ms job as 40.0 ms.
4. **The gate:** one scripted workload combining NFR-10's scale scenario with NFR-4's chart session, since NFR-10 alone has no charting and NFR-3 names charting. It runs with the probe in a release build, on the baseline Mac, before each release candidate, and passes when the longest span is 16 ms or less, with the figures recorded. The baseline Mac is open item 3. It is not a gate on hosted CI, whose runners are too noisy for a 16 ms limit.

The probe is stricter than NFR-3's wording, since one turn may hold several jobs plus AppKit's layout. It cannot be replaced by the standard tooling: Apple's tools report from 250 ms by default ([WWDC23, *Analyze hangs with Instruments*](https://developer.apple.com/videos/play/wwdc2023/10248)), and the lowest Instruments setting is 33 ms according to an [Apple forum answer](https://developer.apple.com/forums/thread/763010), so a 16 ms overrun is invisible to them. See open item 3.

**Consequences**

1. Key localisation stays off the main actor: it hashes 1 MiB, about 6 to 7 ms for a naive Swift SHA-256 on this Mac, a large part of the budget on fast hardware. `localizedKey` is public and synchronous in ADR-03, so the app must not call it; the check in Decision 6 covers that.
2. Filtering (NFR-2) runs as a `@concurrent` function over an immutable tree and is cancelled by the next keystroke. It must check for cancellation at intervals, which is discipline a test confirms, not structure.
3. Bulk CPU work such as compiling MIBs runs below collection's priority and yields between chunks. With twice the core count of tasks in 50 ms chunks, a `.userInitiated` wake-up took 1.4 ms when those tasks ran at `.medium`, and no measurable delay at `.utility`. A wake-up at `.medium` among them took 58.7 ms. Tasks that never yield starved the pool entirely: that run had not finished when stopped after 60 s. The main actor was not delayed by a saturated pool of blocked tasks, but collection would be, and a starved reader looks like a false timeout.

## Decision 6 — The rules a compiler cannot check are a script

**Decision.** The rules above that the compiler does not hold run as a check that prints nothing when clean, alongside ADR-01's import check, and join the portable-core CI lane.

```sh
B="Sources/SNMPCrypto Sources/SNMPCore Sources/MIBKit Sources/SNMPTransportPOSIX Sources/snmpcli"
S='--include=*.swift'
# Below the boundary: no main actor, no isolation escape hatch, no blocking wait, no Dispatch.
grep -rnE '@MainActor|MainActor\.|nonisolated\(unsafe\)|assumeIsolated|@preconcurrency|Thread\.sleep|DispatchSemaphore|DispatchGroup|DispatchQueue|\.wait\(\)' $B "$S" 2>/dev/null
grep -rnE '(^|[^.[:alnum:]_])(poll|sleep|usleep|nanosleep|select)\(' $B "$S" 2>/dev/null | grep -v '/SNMPTransportPOSIX/'
grep -rlE '(Data|String)\(contentsOf:' $B "$S" 2>/dev/null | grep -vE '/StandardMIBBundle\.swift$'
# Unstructured tasks only where this record places them; @unchecked Sendable only on the closed list.
grep -rlE '\bTask(<[^>]*>)?(\.init)?[[:space:]]*[({]|\bTask(<[^>]*>)?\.detached' $B "$S" 2>/dev/null | grep -vE '/(SNMPDispatcher|SNMPEngine)\.swift$'
grep -rl '@unchecked Sendable' $B "$S" 2>/dev/null | grep -vE '/(POSIXTransport|SaltSource)\.swift$'
# The setting that would move plain async functions onto the caller's actor.
grep -nE 'NonisolatedNonsendingByDefault|defaultIsolation' Package.swift
# The app never localises a key itself, and touches a collection's rows in one file.
grep -rn 'localizedKey(' Sources/SNMPToolkitApp "$S"
grep -rlE '\.batches|\.outcomes\(\)' Sources/SNMPToolkitApp "$S" | grep -vE '/CollectionHost\.swift$'
```

**What it means.** Each rule is checked by reading text, the same trade ADR-01 made. It catches the plain mistake, not a determined one, and not a blocking call or a spelling it does not list. Where a row in this record says "check", this is all it means.

**Consequences**

1. Every line prints nothing on today's tree, and each fired on a fixture written to trip it.
2. A file-name allow-list ties these checks to the names `SNMPDispatcher.swift`, `SNMPEngine.swift`, `POSIXTransport.swift`, `SaltSource.swift`, `StandardMIBBundle.swift` and `CollectionHost.swift`. A rename updates this record.
3. The first story that uses `@concurrent` raises `swift-tools-version` to 6.2, so an older compiler fails with a clear message.

## How the design fails

**A silent target.** Each `exchange` takes its slot for the whole retry budget, 7 s with the defaults ADR-02 proposes, then the walk stops with `.timedOut` and keeps its rows. It takes only one such exchange, so a silent target frees its slot for good. Silent targets alone delay a healthy request by at most `⌈silent ÷ ceiling⌉ × 7 s`. In the prototype, with eight silent targets, a ceiling of 8 and a 700 ms budget, a healthy walk arriving behind them finished at 736 ms. So 32 silent targets at the default ceiling of 16 could delay a healthy target by 14 s before it sends its first request. That is the accepted cost.

**A slow target.** A target answering just inside its timeout is not a failure and nothing stops it: at 900 ms a round trip, a 10,000-varbind walk at 25 repetitions takes six minutes. Unlike a silent target it comes back to the queue, so it keeps taking a share of the ceiling for its whole walk. A few are harmless, but many together are not. A simulation of the first-come queue, with targets answering at the end of the 7 s budget and the default ceiling of 16:

| Slow targets | Wait per healthy request | A healthy 400-request walk |
|---|---|---|
| 16 | about 0.4 s | about 3 minutes |
| 32 | about 7 s | about 50 minutes |

That lasts as long as those walks do, and there is no walk deadline. This is an accepted cost. The remedy is the user's: `cancel(target)` ends a target alone and keeps its rows, so the app must show which targets are slow. Nothing cuts one off automatically (open item 4).

**A very large table.** Rows reach the main actor bounded (Decision 5), and cancellation works throughout, so the window stays alive. Memory is what grows, by about 144 bytes per ordinary varbind: 137 MB per million. The walk stops at `WalkLimit`, default 256 MiB, or roughly 1.6 million ordinary varbinds, with `.limitReached`, keeps its rows and says it was cut short. A table larger than that cannot be fully collected without raising it.

A limit is required because FR-23's check cannot end every walk: an agent returning ever-increasing OIDs inside the subtree passes it forever. It is in bytes because such an agent can also send about 60 KB per value, at about 64 KB retained per varbind. A limit on varbind count would then allow about 60 GB. Two costs remain. The limit is per target, so eight targets at the limit hold 2 GiB and thirty-two hold 8 GiB, with no overall limit. Process death would then end every target, so FR-5 holds against memory only as far as the number of targets the user configured. Rows already kept in the store also stay until the store releases them, which is the UI/engine boundary record's to bound.

## Rejected alternatives

- **One actor per target or session holding the walk:** an actor does not serialise across `await`, so walk state would need re-checking after each one; it isolates no failure, since a trap ends the process anyway; and it makes cancellation no easier.
- **One engine actor doing the work:** every target queues behind the slowest encode, the 150 to 200 ms against 0.1 ms in Decision 3.
- **All targets as children of one `TaskGroup`:** no way to cancel one target, since `addTask` returns no handle, and the slow-target remedy depends on that.
- **A ceiling that counts targets for the length of their collection:** one slow walk holds a slot for minutes and everything queued behind it waits, where a per-request ceiling keeps them interleaved. It also needs a shared gate to hold across collections, which the dispatcher provides for free.
- **Custom executors, or an actor pinned to a thread:** `DispatchSerialQueue` as an actor's executor compiles for macOS 14, but no actor here blocks, so it pays for nothing. `TaskExecutor` needs macOS 15, and `Task.immediate` needs macOS 26, both above C-1.
- **A walk limit counting varbinds:** about 60 GB per target from an agent sending 60 KB values.
- **One byte budget shared by all targets:** one hostile target could spend it and stop the honest ones, which is the coupling FR-5 forbids.
- **Sending the finished rows to the main actor:** freeing a million of them there takes 47 to 69 ms.
- **Pushing each varbind to the main actor as it arrives:** 488.7 ms in one run-loop turn, Decision 5's table.
- **Turning on `NonisolatedNonsendingByDefault` in the core:** plain async engine functions would run on the main actor when called from it.
- **Threads and completion handlers:** cancellation and `Sendable` plumbing would be written by hand, and ADR-02 rejected callbacks at the transport on the same grounds.

## What would reopen this

1. The NFR-10 run shows spans over 16 ms caused by framework layout that no bounded input removes. Then NFR-3's figure or the UI technology has to change, and the product owner decides which.
2. The dispatcher actor shows up as a real bottleneck in NFR-1's run against a real agent.
3. A requirement needs fault isolation between targets, which only separate processes can provide.
4. The USM record needs synchronous shared state that neither a snapshot nor the closed list can hold.
5. C-1 moves to macOS 15 or later: `Mutex` and typed `AsyncSequence` become available, and ADR-02's and this record's lock-guarded classes and `AsyncStream` should be looked at again.

## Open items

1. **How a v3 password reaches a target's task. A credential decision, not settled here.** ADR-03's `localizedKey(password: borrowing Credential, engineID:)` needs the password after discovery, on the network, inside the target's task, because a first-contact target has no engine ID at `start`. A `~Copyable` credential cannot sit in a `CollectionRequest` or an array of them, so this record's `start` gives it no route. The concurrency design holds under each option, because each gives `CollectionRequest` a `Sendable`, copyable field, and all three compiled that way:
   - **A: a credential source (recommended).** `CollectionRequest` carries `any CredentialSource`, a `Sendable` protocol the core defines with `func withCredential<R: Sendable>(_ body: (borrowing Credential) throws -> R) async throws -> R`, conformed to by the Keychain adapter. It leaves ADR-03 unchanged and matches ADR-01's credential-store protocol, and the password exists only inside the borrow. Costs: the read can wait on the user, so cancellation is not prompt during it and the adapter must not block the pool; and the community string needs a derived `Sendable` redacted form.
   - **B: split key localisation.** Derive `Ku` before `start` and carry it as a redacted `Sendable` value, then localise per engine. Changes ADR-03's API. `Ku` works for every engine using that password, and lives for the whole collection.
   - **C: a copyable, redacted `Credential`.** Simplest, and carries the community string the same way. Changes ADR-03's `borrowing` signature and settles its open item 6, and leaves the password in memory for the whole collection.
2. **The ceiling's number and meaning.** FR-5 requires a "stated concurrency ceiling" and the specification states none. This record reads it as requests in flight, so any number of targets may be collecting while at most that many wait on the network. Proposed default: 16, twice NFR-10's eight targets. The product owner confirms the reading and the number, and the specification states them.
3. **NFR-3's "measured by" text and its baseline.** The text says "main-thread hang instrumentation", which cannot see 16 ms. Proposed wording: the run-loop probe and combined workload of Decision 5. Still to confirm: whether a whole turn must fit in 16 ms, which is stricter than "no main-actor work exceeds 16 ms", and which Mac is the baseline. A pass on the fastest available machine says little; the proposal is the slowest Apple silicon Mac the product intends to support.
4. **Limits.** A default of 256 MiB per target is a proposal. Still open: whether a user can raise it, whether an overall memory limit is wanted despite the coupling it brings, and whether a walk deadline is wanted against slow targets.
5. **INV-4 and rows already shown.** This record reads INV-4 strictly: on a security failure the app discards that walk's earlier rows, although they had been authenticated. Keeping them, clearly marked, is the alternative; it needs the product owner's reading of the invariant.
6. **A forged datagram with a matching id.** `exchange` completes on the first match, and authentication happens later, in the walk's task. Whether a matching datagram that fails authentication ends the walk or is discarded while the exchange keeps waiting belongs to the USM record, as ADR-02 says. If discarded, `OutboundRequest` needs a validation closure, which would also run on the caller's task.
7. **The row store** behind `BoundedUpdate`, its retention, its pacing, and whether 512 is the right bound once a real table view is attached belong to the UI/engine boundary record. The 10.5 ms in Decision 5 came from a model array that grew on the main actor, and is a warning against that shape at scale.
8. **Not yet run.** The prototype compiled for a macOS 14 target but ran only on macOS 26, and it has not run on Linux. It ran with no real socket and no real cryptography. Both prototypes, the first and the later one for the limit and the host, were clean under ThreadSanitizer on macOS, and their signatures compiled across two modules against the repository's real `OID`. The slow-target figures are a simulation. The availability statements were compiled for a macOS 14 target. The Instruments figures come from Apple's talk and a forum answer, not reference documentation.
9. **Building it.** The probe, the check script and the tests named here are not yet written; each belongs to the story that first needs it.

---

*Format note.* Status, date and governed scope as in ADR-SNMP-01, written as a decision walkthrough: background, each decision with what it means and its consequences, then how it fails, what lost, what reopens it and what is still open. Accepted records are not edited; they are superseded.
