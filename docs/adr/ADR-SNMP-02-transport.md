# ADR-SNMP-02 — The transport protocol, and BSD sockets in the sandboxed app too

| | |
|---|---|
| **Status** | proposed — awaiting the product owner's ruling; becomes *accepted* when the pull request carrying it merges |
| **Date** | 2026-10-30 |
| **Decides** | the exact API of `SNMPTransport`, and whether the sandboxed Mac App Store app uses the POSIX transport or a `Network.framework` adapter |
| **Decision** | **A datagram-pipe protocol** (send, receive, close); timeout, retry, cancellation and response matching live above it in `SNMPCore`. **POSIX sockets everywhere, the sandboxed app included.** No `Network.framework` adapter is written for v1.0. |
| **Supersedes** | nothing. Settles [ADR-SNMP-01](ADR-SNMP-01-portability-boundary.md) §8 open item 4 and the "exact API of `SNMPTransport`" that §6 left open; it does not edit that record |
| **Governs** | the `SNMPTransport` protocol and the address type in `SNMPCore`, the request dispatcher above it, `SNMPTransportPOSIX`, and the in-memory fake the no-network suite uses |

---

## 1. Context — the forces in tension

ADR-SNMP-01 put transport behind a protocol defined in the core, with a BSD-sockets UDP implementation as the default below the boundary, and left two things open: the protocol's API, and whether the shipped, sandboxed macOS app should use that default or a `Network.framework` adapter above the boundary. Nothing can be built against the transport until the first is fixed, and the second decides whether the shipped product runs the code the Linux build and the CLI run.

| Force | Pulls toward |
|---|---|
| **C-12 / ADR-SNMP-01** — `SNMPCore` imports `Foundation` only; `Darwin`, `Network` and `sockaddr` are forbidden in it | An address type and an error type written in pure Swift; all socket code in `SNMPTransportPOSIX` |
| **C-1** — Swift 6 strict concurrency, macOS 14 | `async`/`await`, `Sendable` everywhere; no runtime feature newer than macOS 14 |
| **FR-5, FR-22, FR-6** — many targets concurrently; per-request timeout, bounded retry and backoff; prompt cancellation returning partial results | One socket serving many in-flight requests; timing and cancellation owned by code that knows what a request is |
| **FR-1** — IPv4 and IPv6, link-local targets carry a zone (`fe80::1%en0`), a missing required zone is rejected with an explanation | A zone carried in the address value, resolved to an interface index only below the boundary |
| **NFR-9** — the suite runs in ≤ 60 s with the network denied | A fake that is a full conformance of the same protocol, and timeouts driven by an injectable clock rather than wall time |
| **NFR-8, INV-4** — hostile input never crashes; no partial result on auth failure | Malformed, truncated or unmatched datagrams discarded, never delivered |
| **C-3, C-7, C-11** — App Sandbox with both network entitlements; local-network consent on macOS 15+ | Use whatever API the sandbox and the consent gate treat best — if they treat one better |
| **Cost** — one person's product | One transport implementation exercised by every build, not two |

## 2. The product-owner answer

None yet. This record is **proposed**. The product owner rules on two questions: the API in §3, and the open-item-4 ruling in §4. Engineering's recommendation is stated as the decision; if the ruling differs, this record is revised before it merges, not superseded after.

## 3. Decision — the transport API

### 3.1 Shape: a datagram pipe, matching above it

The transport moves datagrams and knows nothing of SNMP. It does not decode BER, does not time out, does not retry and does not match responses to requests. A single **dispatcher** actor in `SNMPCore` does all four for every request on that transport. Reasons: matching needs the message header (`request-id` for v1/v2c, `msgID` for v3), which only the core can decode; timeouts and retries are FR-22 policy, not I/O; and a pipe is the smallest contract the fake and the POSIX transport must both honour identically.

### 3.2 The address type (in `SNMPCore`, pure Swift)

```swift
public struct SNMPAddress: Sendable, Hashable, CustomStringConvertible {
    public enum Host: Sendable, Hashable {
        case ipv4(IPv4)
        case ipv6(IPv6, zone: IPv6Zone?)
    }
    public struct IPv4: Sendable, Hashable { public let bits: UInt32 }               // host byte order
    public struct IPv6: Sendable, Hashable { public let high: UInt64, low: UInt64 }  // host byte order
    public enum IPv6Zone: Sendable, Hashable {
        case name(String)    // "en0" — as the user typed it
        case index(UInt32)   // "4"   — numeric form, or as received
    }

    public let host: Host
    public let port: UInt16

    /// Throws `SNMPError.invalidAddress` for a fe80::/10 address without a zone,
    /// or a zone on an address that is not link-local (FR-1: rejected with an explanation).
    public init(host: Host, port: UInt16 = 161) throws
    /// Parses "192.0.2.1", "2001:db8::1", "fe80::1%en0", "fe80::1%4", "[fe80::1%en0]:1161".
    public init(_ text: String, defaultPort: UInt16 = 161) throws
}
```

- **The zone is part of the address value**, as RFC 4007 §11 writes it. A link-local address without one is not a complete address, so it cannot be constructed; a zone on a global address is meaningless and is rejected rather than silently ignored.
- **The core never resolves a zone.** `if_nametoindex` is a C-library call and belongs to the POSIX transport, which resolves `.name` at every send (an interface index can change when an interface is re-created). `.index` passes through. On receive, the transport reports `sin6_scope_id` as `.name` when `if_indextoname` succeeds and `.index` otherwise.
- **Addresses are numeric.** Name resolution (INV-3(b)) is not part of `SNMPTransport`; a host name is resolved before an `SNMPAddress` exists. Who resolves, and how, is §8 item 4.
- Text parsing is hand-written in the core: `inet_pton` is a C-library call and forbidden there.

### 3.3 The protocol

```swift
public protocol SNMPTransport: Sendable {
    /// Largest datagram `send` accepts. POSIX: 65_507 (the IPv4 UDP payload limit,
    /// which is also below the IPv6 limit of 65_527, so one constant serves both).
    var maximumDatagramSize: Int { get }

    /// Hands one datagram to the network and returns. Never waits for a reply.
    /// Throws `SNMPTransportError` or `CancellationError`; nothing else.
    func send(_ datagram: [UInt8], to destination: SNMPAddress) async throws

    /// Suspends until the next datagram from any source arrives, and returns it.
    /// One caller at a time (the dispatcher's reader task).
    /// Throws `SNMPTransportError` or `CancellationError`; nothing else.
    func receive() async throws -> InboundDatagram

    /// Idempotent. Wakes a suspended `receive` with `.closed`; later calls throw `.closed`.
    func close() async
}

public struct InboundDatagram: Sendable {
    public let bytes: [UInt8]
    public let source: SNMPAddress
}

public enum SNMPTransportError: Error, Sendable, Equatable {
    case datagramTooLarge(size: Int, limit: Int)
    case unknownZone(String)                          // the named interface does not exist now
    case addressFamilyUnavailable(ipv6: Bool)         // e.g. socket(AF_INET6) failed: no IPv6 stack
    case sendFailed(code: Int32, description: String) // errno and strerror, verbatim
    case receiveFailed(code: Int32, description: String) // fatal; the transport is now closed
    case concurrentReceive                            // a second receive() while one is pending
    case closed
}
```

The errors are untyped `throws` with the thrown set stated and asserted by the conformance suite (§3.5), because a typed `throws(SNMPTransportError)` cannot also carry `CancellationError`, and cancellation must surface the standard way for structured concurrency to compose. Codes are reported, never interpreted, by the core: `errno` values differ between Darwin and Linux. `SNMPError` gains `case transport(SNMPTransportError)`, `case timedOut(attempts: Int)` and `case invalidAddress(String)`.

**Contract details an implementation must honour:**

| Concern | Rule |
|---|---|
| **Datagram size** | `send` of more than `maximumDatagramSize` bytes throws `.datagramTooLarge` without touching the network. Receive buffers are `maximumDatagramSize + 1` bytes; a datagram that does not fit (POSIX: `MSG_TRUNC` set in `recvmsg`'s `msg_flags`) is **discarded, never delivered truncated**. Every conformance must accept at least 484 octets (RFC 3417 §3). The engine advertises `maximumDatagramSize` as its v3 `msgMaxSize`; FR-23's back-off on `tooBig` is the dispatcher's, not the transport's. |
| **Transient send failure** | `EAGAIN`/`EWOULDBLOCK`/`ENOBUFS` are UDP loss: `send` returns normally and the datagram is dropped; the request's timeout and retry recover it. Every other `sendto` failure throws `.sendFailed`. |
| **Inbound buffering** | Bounded at 1,024 datagrams per transport; beyond that the newest is dropped, as a kernel socket buffer does. Unread datagrams survive a cancelled `receive`. |
| **Cancellation of `receive`** | If the calling task is cancelled, `receive` throws `CancellationError` promptly — it does not wait for the next datagram. |
| **Sockets** (POSIX) | One **unconnected** socket per address family, created on first use, bound to the wildcard address on an ephemeral port, shared by every target. `sendto`/`recvmsg`, never `connect`: an agent on a multihomed device may answer from an address other than the one asked, and a connected socket discards that answer in the kernel, where no diagnostic sees it. IPv6 sockets set `IPV6_V6ONLY`; dual-stack mapping is not used. |
| **Threads** (POSIX) | Sockets are non-blocking. One dedicated `Foundation.Thread` per transport blocks in `poll` on the sockets and a self-pipe; received datagrams go into the bounded buffer, and `receive` awaits it through a continuation. `close` writes the self-pipe. Nothing blocks the cooperative thread pool. The class is `final … : @unchecked Sendable`, its state guarded by `NSLock` (`Synchronization.Mutex` needs macOS 15; C-1 is macOS 14). |
| **Logging** | None. A transport sees credentials in v1/v2c community strings; INV-2 is simpler kept than audited. |

### 3.4 Requests: matching, timeout, retry, cancellation (in `SNMPCore`, above the transport)

```swift
public actor SNMPDispatcher {
    public init(transport: any SNMPTransport, clock: any Clock<Duration> = ContinuousClock())
    /// Sends `request`, retries per `policy`, returns the matching response.
    /// Throws `SNMPError.timedOut(attempts:)`, `SNMPError.transport(_)`, or `CancellationError`.
    public func exchange(_ request: OutboundRequest, to target: SNMPAddress,
                         policy: RetryPolicy) async throws -> InboundResponse
}

public struct RetryPolicy: Sendable, Hashable {
    public var timeout: Duration        // per attempt
    public var retries: Int             // attempts = retries + 1
    public var backoffFactor: Double    // timeout × factor after each attempt
    public var maximumTimeout: Duration // cap on the grown timeout
}
```

- **Matching key.** `request-id` (v1/v2c) or `msgID` (v3), drawn from `SystemRandomNumberGenerator` in `1 ... Int32.max` (some agents mishandle negative `request-id`s) and unique among requests in flight on that dispatcher. A retry keeps its `request-id`; a v3 retry takes a **new** `msgID`, and every `msgID` a request has used stays registered until it completes, so a late answer to attempt 1 still completes it. The response's source address is **not** part of the key, for the multihomed reason above; it is returned in `InboundResponse.source` so the UI can show it.
- **The reader.** The dispatcher runs one task looping on `transport.receive()`. It decodes only the header; a datagram that will not decode, or whose id matches nothing in flight (late, duplicated, foreign), is discarded and counted. What happens to a datagram that matches but fails v3 authentication is the USM record's to decide under INV-4, not this one's.
- **Timeout.** Per attempt, measured on the injected `Clock`: the attempt races `clock.sleep(for: timeout)` against its response in a task group. After the last attempt, `exchange` throws `SNMPError.timedOut(attempts:)`. Timeouts are never a transport error.
- **Cancellation.** Cancelling the task that called `exchange` makes it throw `CancellationError` at once — mid-sleep or mid-send — and unregisters its ids, so a late response is discarded as unmatched. Cancellation is per request; the reader task and the transport keep running for other requests. FR-6's "return what was collected so far" is the walk's job: it catches `CancellationError` and returns its partial result.
- **Send failure.** `.sendFailed` on any attempt fails the request at once with `SNMPError.transport(_)` — retrying in milliseconds does not repair an unreachable network.
- **Defaults** for `RetryPolicy` are FR-22's to state in the specification; §8 item 3 proposes values.

### 3.5 The fake transport — NFR-9 on the same protocol

The no-network suite substitutes a fake for the POSIX transport; it is a full `SNMPTransport`, not a mock of the dispatcher, so every dispatcher behaviour above is tested against the same contract the POSIX transport honours. It opens no socket, so it passes under CI's `(deny network*)` profile. Timing comes from the same test clock the dispatcher is given, so a five-retry timeout runs in microseconds, not seconds — which is how a suite with timeout tests stays inside 60 s. It lives in a proposed test-support target, `SNMPTestSupport` (`Foundation`, `SNMPCore`), below the boundary and never linked into the app.

```swift
public final class FakeTransport: SNMPTransport, @unchecked Sendable {
    public enum Reply: Sendable {
        case answer([UInt8], from: SNMPAddress? = nil, after: Duration = .zero) // nil: from the destination
        case drop                                                              // UDP loss
        case fail(SNMPTransportError)                                          // send throws this
    }
    /// Script: given what was sent and where, what comes back. Test code decodes and
    /// encodes with the real codec, so the fake itself knows no SNMP.
    public typealias Agent = @Sendable (_ sent: [UInt8], _ to: SNMPAddress) -> [Reply]

    public let maximumDatagramSize = 65_507
    private let lock = NSLock()
    private var queue: [InboundDatagram] = []        // bounded at 1_024, as §3.3
    private var waiter: CheckedContinuation<InboundDatagram, Error>?
    private var isClosed = false
    public private(set) var sent: [(bytes: [UInt8], to: SNMPAddress)] = []

    public init(clock: TestClock, agent: @escaping Agent) // TestClock: a manual Clock in the same target

    public func send(_ d: [UInt8], to dst: SNMPAddress) async throws {
        // closed → .closed; d.count > maximumDatagramSize → .datagramTooLarge;
        // record in `sent`; for each Reply: .fail throws, .drop does nothing,
        // .answer enqueues at clock.now + after (deliver() resumes `waiter` or appends to `queue`).
    }
    public func receive() async throws -> InboundDatagram {
        // withTaskCancellationHandler: pop `queue` if non-empty; a second waiter →
        // .concurrentReceive; closed → .closed; otherwise park in `waiter`.
        // onCancel: resume `waiter` with CancellationError; the queue is untouched.
    }
    public func close() async { /* isClosed = true; resume `waiter` with .closed */ }
}
```

A shared **conformance suite** (`SNMPTransportConformance`) states §3.3's contract once as tests — size limit, discard of oversize input, cancellation of a pending `receive`, `close` waking `receive`, `.concurrentReceive`, the thrown-error set — and runs against `FakeTransport` in the NFR-9 lane and against `SNMPTransportPOSIX` on loopback in a **separate** CI step outside the deny-network profile, since loopback is network to that profile. The dispatcher's own tests (matching, late and duplicate answers, an answer from a different source, a v3 retry's new `msgID`, timeout after N attempts, cancellation mid-retry) run on the fake only.

## 4. Decision — open item 4: POSIX in the sandboxed app

**The sandboxed Mac App Store app uses `SNMPTransportPOSIX`, the same transport as the CLI and the future Linux collector. No `Network.framework` adapter is written for v1.0.** The protocol keeps one possible later without changing the core (§7).

### 4.1 Evidence

| # | Claim | Source |
|---|---|---|
| E1 | The sandbox's network entitlements apply to **UDP sockets**, and restrict data flow, not only initiation: "an app with only the client entitlement enabled can send, but not receive, data. Apps using UDP usually require both entitlements." Nothing ties the entitlements to a particular API. C-7 already requests both. | [com.apple.security.network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client), [com.apple.security.network.server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server) |
| E2 | Local network privacy is enforced "deep in the networking stack, and thus [the checks] apply to all networking APIs. This includes Network framework, BSD Sockets, … `URLSession`". Sending a UDP unicast to a local address requires access; receiving one does not. Introduced on macOS 15. | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) |
| E3 | "There's no general API that returns whether the current process has local network access." The one `Network.framework` signal Apple documents — `.waiting` with `unsatisfiedReason == .localNetworkDenied` — is documented for a **TCP** `NWConnection`. Nothing documents a UDP denial signal from either API. | TN3179, *Check for local network access* |
| E4 | While the consent alert is up, the system "may deny the operation immediately, before the user has responded". Apple's advice: an API that waits for connectivity, or "if you can't …, add appropriate retry logic". FR-22's retry is that logic. TN3179's own way to raise the alert before any traffic is to `connect` a **BSD** UDP socket to a link-local address. | TN3179, *Essentials*, *Trigger the local network alert* |
| E5 | Apple calls `Network.framework` "the best choice" for UDP *flows* between two peers and BSD sockets "a bunch of extra work"; where "a cross-platform codebase … mandates the use of sockets", it lists best practices to follow instead. Two concern this product: two-step resolve-then-send "will still be incompatible with VPN On Demand", and dual-stack code should be tested on an IPv6-only network. | [TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api), *UDP*, *Connect by name*, *BSD Sockets best practices* |
| E6 | Local network privacy tracks a program by its code signature and needs an Apple-issued signing identity to do so reliably; command-line tools run from Terminal are allowed automatically. A reset of the privilege needs macOS 27.2's remove button, or a fresh VM snapshot or user account on earlier versions. | TN3179, *macOS considerations*, *Build-time considerations*, *Reset local network state* |
| E7 | Local network use, "direct unicast or multicast connections to local hosts" included, needs `NSLocalNetworkUsageDescription` (C-11 declares it). | [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription) |

### 4.2 Reading

- **The sandbox and the consent gate do not prefer an API (E1, E2).** Nothing in Apple's documentation gives a `Network.framework` adapter a permission POSIX lacks.
- **The diagnostic advantage is unproven for UDP (E3).** The one thing an adapter might buy — telling "Local Network denied" from "no answer", which C-11 currently says is impossible — is documented for TCP only. If it holds for UDP too, that is a reason; it is tested, not assumed (§4.3).
- **The waiting-for-connectivity advantage is covered (E4).** FR-22 retries, and C-11 already asks for consent before the first query; the app raises the alert with E4's BSD-socket technique, which needs `getifaddrs` and so lives in the app, above the boundary.
- **Apple's general preference (E5) is for connection-shaped flows.** A manager is one socket talking to many agents, unconnected so a multihomed agent's answer arrives (§3.3); a `NWConnection` per target is a connected flow. VPN On Demand cannot be triggered by a POSIX send — accepted and disclosed (§6). C-6 makes SNMP a LAN-first product.
- **One implementation, exercised everywhere.** An adapter would be a second conformance of the same contract that only the signed app runs: SC-3's interop runs and every agent-facing test would need doing twice.

### 4.3 What remains to confirm on a signed, sandboxed build

These cannot be checked from this repository's CI or a CLI build (E6), and are not asserted here. They become §8 item 1. The test: a **sandboxed app signed with an Apple-issued identity**, with the C-7 entitlements and C-11's usage description, on **macOS 15.1 or later**, privilege reset before each run (E6), sending an SNMP GET of `sysUpTime.0` through `SNMPTransportPOSIX` and, for comparison only, a UDP `NWConnection`:

| # | Check | Expected | If not |
|---|---|---|---|
| T1 | *Allow*: GET to an IPv4 agent on the local subnet, to an IPv6 link-local agent with a `%zone`, and to a routed or VPN-reached agent | All answer | The POSIX default fails in the sandbox → reopen (§7) |
| T2 | Client entitlement only | Request sent, reply never received | C-7's rationale needs restating |
| T3 | *Deny*: what POSIX `sendto` returns (success, `EHOSTUNREACH`, `EPERM`, …), and whether the UDP `NWConnection` enters `.waiting` with `.localNetworkDenied` | Neither distinguishes denial (C-11's premise) | If POSIX returns a distinct errno, map it to a dedicated error. If only `Network.framework` signals it, reopen (§7) — the likely remedy is a diagnosis-only probe in the app, not a second transport |
| T4 | *Undetermined*: the first query sent while the alert is up | Dropped; the next retry after *Allow* succeeds within the default `RetryPolicy` | Tune FR-22's defaults, or trigger the alert earlier |
| T5 | E4's technique from the sandboxed app, before any query | The alert appears, with the C-11 purpose string | C-11's "ask before the first query" needs another mechanism |

## 5. Options rejected

### For the API

**A request/response transport** — `exchange(datagram, to:, timeout:) -> datagram` on the protocol. *Lost on FR-5 and cost:* the transport would need to decode BER to match, every conformance (POSIX, fake, any adapter) would re-implement matching, timeout and retry, and many requests could not share one socket without each conformance inventing its own demultiplexer.

**Inbound datagrams as an `AsyncSequence`.** Closest to the chosen design. *Lost on C-1:* a protocol requirement constrained to `any AsyncSequence<InboundDatagram, …>` with a stated failure type needs the macOS 15 runtime; a plain `AsyncStream` cannot report a fatal socket error. A single `receive()` is also the smallest thing for the fake to implement correctly.

**Callbacks or delegates.** *Lost on C-1:* Swift 6 strict concurrency makes `Sendable` callback plumbing the error-prone path, and cancellation would have to be hand-built.

### For open item 4

**`Network.framework` adapter in the sandboxed app; POSIX on Linux and in the CLI.** *Lost on cost and on evidence:* it gains no permission (E1, E2), its one plausible advantage is undocumented for UDP (E3), its waiting behaviour is covered by FR-22 (E4), a connected `NWConnection` per target cannot receive a multihomed agent's answer from another address, and the shipped product would run a transport neither the CLI nor the Linux build exercises. Kept as the remedy if §4.3 shows a reason (§7).

**`Network.framework` everywhere on Apple platforms** — excluded by ADR-SNMP-01 (the Linux collector) and C-2 (no `swift-nio-transport-services`, which TN3151 suggests for exactly this).

## 6. Consequences

**What becomes possible:** transport, dispatcher and USM work can proceed against fixed signatures; the dispatcher is fully testable with no network and no wall-clock waits; the CLI, the Linux collector and the app run one transport, so an interop result from any of them holds for all.

**What it costs — accepted knowingly**

- The POSIX transport carries TN3151's "extra work": non-blocking sockets, a reader thread, two C-library branches (`Darwin`, `Glibc`/`Musl`), zone resolution, and testing on an IPv6-only network.
- **VPN On Demand is not triggered** by the app's SNMP traffic (E5). A target behind an on-demand VPN answers only once the VPN is already up. Disclosed in user documentation, not discovered.
- Matching ignores the source address, so on v1/v2c an off-path attacker who guesses a 31-bit `request-id` within the timeout could inject a response. v1/v2c offer no integrity anyway; v3 authentication closes it.
- C-11's diagnosis of denied local-network access remains a heuristic until T3 says otherwise.

## 7. Reversal cost and reopening triggers

Adding a `Network.framework` adapter later is one new conformance above the boundary, run through the conformance suite, injected by the app: no core change, because the dispatcher only sees `any SNMPTransport`. That cheapness is why the default can be decided now on documentary evidence.

This record is **reopened** — by a superseding record — when any of these is observed:

1. **T1 fails**: the POSIX transport does not work in the signed sandboxed app.
2. **T3 shows a UDP denial signal only `Network.framework` gives**, and C-11's heuristic proves unworkable for users.
3. **Apple documents an App Sandbox or local-network-privacy restriction specific to BSD sockets.**
4. **A product requirement needs connection-shaped behaviour** — VPN On Demand, DTLS (out of scope in §5 of the specification), or connect-by-name.

## 8. Open items

Recorded here so they are not mistaken for decided:

1. **Run T1–T5 (§4.3) on a signed, sandboxed build** before v1.0 is submitted, and record the results — including T3's actual errno — in a follow-up record. Until then §4's ruling rests on documentation.
2. **Target naming** for `SNMPTestSupport` (proposed), alongside ADR-SNMP-01 §8 item 3's `SNMPTransportPOSIX`; and the CI step that runs the conformance suite on loopback outside the deny-network profile.
3. **FR-22 defaults** belong in the specification. Proposal: 1 s timeout, 2 retries, backoff factor 2, cap 8 s — 7 s worst case for an unanswered request, which T4 must find long enough for a user to answer the consent alert.
4. **Name resolution**: where the host-name-to-`SNMPAddress` step lives (a resolver protocol in the core with a `getaddrinfo` conformance beside the POSIX transport is the obvious shape), and how both address families are tried (TN3151's connect-by-name and Happy Eyeballs advice, adapted to a datagram protocol).

---

*Format note.* As ADR-SNMP-01: status, date, context as forces, the decision, the alternatives that lost with the force each lost on, consequences including accepted cost, and the observations that reopen the record. Accepted records are not edited; they are superseded.
