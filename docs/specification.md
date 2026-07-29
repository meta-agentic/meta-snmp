# META SNMP TOOLKIT — Product Specification

**Status:** draft, pending acceptance · **Applies to:** v1.0 unless stated otherwise

This document defines what the product does, what it deliberately does not do, and the
conditions under which v1 is good enough to ship. It is the parent of the subsystem
specifications; where this document and a subsystem specification disagree, this one wins
until it is amended.

Requirements are numbered so they can be cited from acceptance criteria, tests and review
comments. **FR** functional · **NFR** non-functional · **C** constraint ·
**INV** invariant · **SC** success criterion.

---

## 1. Problem and users

Network engineers reach for SNMP when they need ground truth about a device: what the
interfaces are doing, whether a counter is climbing, what the vendor's private OIDs
actually expose. The tooling to do that on macOS is poor — the capable tools are
command-line, which makes exploration tedious and graphing a separate exercise, and the
graphical ones are aging cross-platform ports or wrapped in a monitoring platform far
larger than the question being asked.

The gap is not *collection*. The gap is **interpretation**: turning a few thousand numeric
rows into an answer, quickly, on a Mac.

### Primary users

| Actor | Context | What they need |
|---|---|---|
| **Network engineer** | Investigating a specific device, often under time pressure | Point at a host, find the right OID without knowing its number, read the value in the units the MIB intends |
| **NOC operator** | Watching behaviour over minutes, not months | See a counter as a rate, live, next to the other counters that might explain it |
| **Security-conscious operator** | Works on production infrastructure under policy | v3 authPriv, secrets that stay in the Keychain, and no unexplained outbound traffic |

### Explicitly not our user

Anyone who needs continuous, unattended monitoring with alerting and long-horizon
retention. This is an **interactive investigation tool**, and that distinction drives most
of the non-goals in §3.

---

## 2. Product shape

A sandboxed macOS application, distributed through the Mac App Store, that runs entirely
on the user's machine. No account, no server component, no telemetry.

**Publisher:** Meta-Agentic — <https://meta-agentic.ai>, source at
<https://github.com/meta-agentic>. The App Store Connect record's support, marketing and
privacy-policy URLs all resolve under that domain.

---

## 3. v1.0 scope and non-goals

### In scope for v1.0

- SNMP **v1, v2c and v3** collection, including v3 authentication and privacy
- GET, GETNEXT, GETBULK, walk and bulk-walk; SET behind explicit confirmation
- MIB compilation, an OID registration tree, and value formatting per the MIB
- Bundled standard MIBs; **import and export of private/vendor MIBs**
- Browsing: MIB tree with incremental filter, result grid, per-OID inspector
- **Live graphing** of numeric OIDs, with counter-to-rate derivation
- Export of results and chart series

v1.0 is therefore a **purely outbound, client-shaped** application. It needs only the
outgoing-connection entitlement, which is the simplest sandbox and the cleanest App Review
story the product can have.

### Deferred to v1.1

- **The diagnostic reasoning layer.** An attended layer that reasons over a single
  investigation, using an AI provider credential the user supplies. The app ships none.
- **Trap and inform reception** (FR-7), subject to C-8.

The store listing must not describe capabilities v1.0 lacks.

### Non-goals — deliberately not built

| Non-goal | Why |
|---|---|
| **Unattended operation of any kind** — background collection, threshold alerting, a notification pipeline | **This product only works while you are working.** It collects when you ask, reasons over what you have, and does nothing when the window is closed. A finding cannot surface while the user is away, by design |
| Fleet-wide or long-horizon retention — a time-series database | Session-scoped persistence only: enough that an investigation survives a restart, never a metrics store |
| Network discovery by scanning ranges | Ill-fitting for a sandboxed App Store app, and a poor App Review story |
| Device configuration management | SET exists for single values under confirmation; this is not a provisioning tool |
| SNMP agent (serving) functionality | A manager and a notification receiver, never an agent |
| Cross-platform (iOS, Windows, Linux) | The app is macOS-native throughout; portability would cost that |
| Team features — sharing, sync, collaboration | No server component (§2), so there is nothing to sync through |
| Localisation | English-only at v1 (C-10) |

---

## 4. Functional requirements

### Collection

- **FR-1** Query an SNMP agent over UDP using v1, v2c or v3, on a configurable port, over IPv4 or IPv6. IPv6 link-local targets accept a zone/scope identifier (`fe80::1%en0`); an address given without one where it is required is rejected with an explanation, not silently attempted.
- **FR-2** Perform GET, GETNEXT and GETBULK, and walk an arbitrary subtree.
- **FR-3** Perform SET, disabled by default, requiring both a configured write credential and per-operation confirmation.
- **FR-4** Authenticate v3 sessions with USM, supporting noAuthNoPriv, authNoPriv and authPriv.
- **FR-5** Collect from multiple targets concurrently, up to a stated concurrency ceiling, without one target's failure affecting another.
- **FR-6** Cancel any in-flight collection promptly, returning whatever was collected so far.
- **FR-7** *(v1.1 — deferred)* Receive v1 traps, v2c traps and informs, and v3 traps, acknowledging informs. The v1 trap PDU is structurally different from v2c/v3 — enterprise OID, generic/specific trap numbers and agent-address, versus a varbind-carried `snmpTrapOID` — and is parsed on its own path, not folded into the v2 shape. Subject to C-8: the listener cannot bind UDP/162.
- **FR-22** Apply a per-request timeout, a bounded retry count and a backoff policy, all configurable, with stated defaults. SNMP runs over UDP with no delivery guarantee; without this, every throughput and concurrency requirement is unachievable on a lossy link.
- **FR-23** Tolerate agent misbehaviour without looping or corrupting results: a non-increasing or repeating OID during a walk terminates it with a diagnostic, an agent returning fewer varbinds than the requested max-repetitions is accommodated rather than treated as an error, and an agent that misreports its maximum message size is handled by backing off on response-too-large.
- **FR-24** Reject a Counter64 request against a v1 target as structurally invalid, with an explanation. 64-bit counters do not exist in SMIv1 or the v1 protocol (RFC 2578 introduced them), so FR-18's rate derivation is defined for Counter64 only on v2c and v3 targets.
- **FR-25** Migrate persisted state (FR-20) and Keychain references (FR-21) forward across app versions. Every persisted format carries a schema version from v1.0, and an unmigratable file is quarantined rather than discarded or crashed on.

### Interpretation

- **FR-8** Compile SMIv2 MIB modules and resolve IMPORTS across them into one OID registration tree.
- **FR-9** Resolve numeric OIDs to names and names to OIDs, bidirectionally.
- **FR-10** Format values per the MIB: enumerations, TEXTUAL-CONVENTIONs and DISPLAY-HINTs.
- **FR-11** Present conceptual tables as rows, decoding INDEX values into typed components.
- **FR-12** Import private and vendor MIBs from files or folders, reporting per-file diagnostics that name file, line and column.
- **FR-13** Export imported modules, and the resolved tree or a subtree, in a re-importable form.

### Presentation

- **FR-14** Navigate the MIB tree with an incremental filter matching name, numeric OID and description.
- **FR-15** Present results in a sortable, filterable grid with multi-select copy.
- **FR-16** Show, for a selected OID, its MIB definition alongside its current value.
- **FR-17** Chart any numeric OID live at a configurable interval, over a selectable rolling window.
- **FR-18** Derive a per-second rate from Counter32/Counter64 series, and overlay multiple series.
- **FR-19** Export results and chart series as CSV and JSON. Exported cells are neutralised against spreadsheet formula injection — agent-supplied strings are untrusted, and a value opening with `=`, `+`, `-`, `@`, tab or carriage return is escaped so no spreadsheet evaluates it.

### Continuity

- **FR-20** Persist targets, poll configurations and saved sessions across launches, bounded by an enforced retention limit. Sessions are scoped to an investigation, not to a fleet.
- **FR-21** Store every secret in the macOS Keychain, referencing it from persisted state.

---

## 5. Protocol conformance scope

Full clause-level detail belongs to the engine specification (S2). This fixes the boundary.

| Standard | Depth |
|---|---|
| RFC 1157 (SNMPv1) | Manager role, in full, including v1 traps |
| RFC 3416 (v2 protocol operations) | Manager role, in full, including GETBULK and the exception varbinds |
| RFC 3414 (USM) | Manager role: HMAC-MD5-96, HMAC-SHA-96, engine discovery, timeliness, CBC-DES |
| RFC 7860 (SHA-2 for USM) | HMAC-SHA-224/256/384/512 |
| RFC 3826 (AES for USM) | CFB128-AES-128 |
| AES-192/256 (Blumenthal draft) | Implemented for vendor interop; **labelled non-standard in the UI** |
| RFC 2578–2580 (SMIv2) | Parsing to the depth needed for FR-8 to FR-11 |

**Cryptographic labelling.** The UI flags AES-192/256 as *non-standard*, which is a
provenance warning. CBC-DES needs the opposite label: it is fully standard and
cryptographically **weak** — a 56-bit key, unfit for protecting anything that matters. It
is supported for interop with devices that offer nothing better, and the UI must say so
where a user selects it. Labelling only non-standardness while staying silent on a broken
cipher gets the warning backwards.

**Out of scope, with reasons:** the agent role and the AgentX subagent protocol (never an
agent); SNMP over TCP, TLS or DTLS (negligible deployment, and the sandbox complicates
it); the View-based Access Control Model (an agent-side concern); and the proxy role.

**SMIv1-only modules — a known, disclosed gap.** The parser targets SMIv2 and accepts
SMIv1 constructs only where they remain legal in SMIv2 practice. A genuinely SMIv1-only
module will not compile, and this is not a diagnostics problem the user can act on: a file
only the vendor can reissue cannot be "fixed" by the person importing it. Older Cisco and
a long tail of embedded and industrial vendors never migrated, so this affects real MIBs
that FR-12's buyers will try to import. The product must therefore say what it does not
support — in the failure message and in the store listing — rather than let a buyer
discover it after paying. Whether to add an SMIv1 compatibility path is a post-v1
decision, taken on evidence from what users actually fail to import.

---

## 6. Constraints

- **C-1** macOS 14 or later; Swift 6 with strict concurrency.
- **C-2** No third-party runtime dependencies. Every dependency is a supply-chain and App Review liability, and everything needed is in the platform.
- **C-3** Distributed through the Mac App Store, under App Sandbox and the hardened runtime.
- **C-4** The app has **no server component**. Nothing is proxied through infrastructure we operate, because we operate none.
- **C-5** From v1.1, AI features are **bring-your-own-key**: the app ships no AI credentials.
- **C-6** The app must be fully functional with no internet connectivity. SNMP is a LAN protocol; nothing in the core workflow may require reaching the public internet.
- **C-7** **v1.0 requires the outgoing-connection entitlement only.** Trap reception is v1.1, so the inbound entitlement (`com.apple.security.network.server`) is *not* requested at launch. This is the narrowest sandbox the product can ship with and the simplest App Review story available to it — a client-shaped app asking only for client permissions. When traps arrive in v1.1, the inbound entitlement must be justified explicitly in the review notes, and C-8 applies.
- **C-8** *(applies from v1.1)* **The app cannot listen on UDP/162.** Binding a port below 1024 requires privilege a sandboxed, user-launched App Store app has no way to obtain — there is no entitlement for it. This is not a design choice between binding low or degrading gracefully; unprivileged binding is the only reachable outcome. The consequences are real and must be disclosed rather than discovered:
  - The receiver binds a **configurable unprivileged port**, default 1162.
  - Many devices send traps to a hardcoded 162 and cannot be redirected by an operator who does not control every device. For those, the app cannot receive traps at all without an external forwarder. **FR-7's reach is therefore partial**, and §3 and the store listing must say so.
  - The first bind raises the macOS Application Firewall's "accept incoming connections" prompt. This is a system dialog appearing mid-task for a user under time pressure, and the app must prepare the user for it rather than let it arrive unexplained.
- **C-9** The bundled standard MIBs (FR-8) must be redistributable under terms compatible with **paid** distribution. If a file is not redistributable it cannot ship, and the feature degrades. Each bundled file's licence is confirmed and recorded in a NOTICE file before it is bundled.
- **C-10** The app is accessible and English-only at v1. Full keyboard navigation, VoiceOver labels on every control, and Dynamic Type support are requirements, not aspirations. Localisation is an explicit non-goal for v1 — recorded here so the omission is a decision rather than an oversight.

---

## 7. Non-functional requirements

Each carries a number and how it is measured. An NFR without a measurement method is a
preference, and does not belong here.

Two are **provisional** — set from judgement, not measurement. They are marked as such,
and SC-4 does not gate on them until they are replaced with measured figures. A
specification that admits a number is a guess cannot also treat that number as an
acceptance gate.

| Id | Requirement | Measured by |
|---|---|---|
| **NFR-1** *(provisional)* | A bulk-walk retrieving 10,000 **varbinds** completes in ≤ 30 s, under stated conditions: same-subnet agent, RTT ≤ 2 ms, max-repetitions 25, no agent-side pacing. "Varbinds", not "rows" — under FR-11 a conceptual-table row can be 5–10 varbinds, a 10× difference | Timed run against a reference `snmpd` on the same subnet, with the conditions recorded alongside the figure. Throttled or bulk-capped agents are measured separately and reported, not averaged in |
| **NFR-2** | Incremental filtering of a 100,000-node MIB tree updates in ≤ 100 ms | Instrumented benchmark over the bundled set plus synthetic modules |
| **NFR-3** | The UI never blocks: no main-actor work exceeds 16 ms during collection, filtering or charting | Main-thread hang instrumentation under a scripted workload |
| **NFR-4** | A live chart with 8 series at a 1 s interval sustains 60 fps | Frame-rate capture during a scripted 10-minute session |
| **NFR-5** *(provisional)* | Peak memory during a 100,000-varbind walk stays ≤ 500 MB | Memory footprint sampled at peak |
| **NFR-10** | The scale scenarios compose: filtering a 100,000-node tree while a 10,000-varbind walk is in flight against 8 concurrent targets still satisfies NFR-2, NFR-3 and NFR-5 | The combined scenario run as one scripted workload, not as three separate best cases |
| **NFR-6** | Cold launch to interactive ≤ 2 s on Apple silicon | Launch instrumentation, median of 10 cold starts |
| **NFR-7** | Bundled MIBs load lazily — launch time is independent of how many MIBs are imported | NFR-6 re-measured with 200 imported modules; regression ≤ 10% |
| **NFR-8** | A malformed or hostile packet never crashes or hangs the app | Fuzzing the decoder; no crash, no unbounded loop, over a fixed corpus and duration |
| **NFR-9** | Test suite runs in ≤ 60 s and requires no network | CI wall time; suite passes with networking disabled |

---

## 8. Security and privacy invariants

These are the things that must never happen. Each is phrased so it can be enforced by a
test rather than by reviewer attention — an invariant that relies on discipline is not an
invariant.

- **INV-1** No credential — community string, v3 passphrase, or AI API key — is ever written outside the Keychain. *Enforced structurally: a credential is represented by a type that has no encodable conformance and whose debug description is redacted, so a new persisted field cannot reintroduce a leak by omission. Test: persisted state serialised from a credential-bearing fixture is asserted to contain none of them — this catches regressions, but the type is what prevents them.*
- **INV-2** No credential is ever written to a log, a crash report, or an error message. *Enforced by the same redacted type as INV-1. Test: the error taxonomy is exercised over credential-bearing fixtures and every rendered string asserted clean.*
- **INV-3** The app performs no outbound network activity **except**: (a) SNMP traffic to a user-configured target, (b) name resolution for those targets, and (c) from v1.1, requests to the user's own configured AI provider. It ships **no** telemetry, analytics, update check or crash-reporting call of its own.

  The exclusions are named rather than glossed, because the platform originates traffic the app does not: **DNS/mDNS** resolution of a user-entered hostname is in scope of (b) and permitted; **StoreKit** receipt and transaction validation is Apple-initiated at launch and outside this invariant's control — it is disclosed, not prevented; **Apple's crash and diagnostic reporting** is likewise platform-originated and requires the user to have opted in system-wide, so it is disclosed rather than prevented — the app ships no reporting call of its own and adds no payload of its own; **Keychain items are created non-synchronizable**, so no credential reaches iCloud; OS-level notarization and OCSP checks are outside the app process entirely.

  *Test: a scripted session is run under a network monitor with every connection attributed to (a), (b), (c) or a named platform exclusion. Any unattributed connection fails the test.* An idle-app check alone would not catch these and is not sufficient.
- **INV-4** A decryption or authentication failure is surfaced as a security error, never as an empty or partial result. *Test: v3 responses with corrupted authentication parameters are asserted to raise, not to return.*
- **INV-5** A SET is never issued without explicit per-operation user confirmation. *Test: the SET path asserts a confirmation token that only the UI confirmation flow can mint.*
- **INV-6** *(v1.1)* No credential class ever crosses the AI trust boundary. Enforced by INV-1's non-encodable credential type: outbound serialisation of a credential does not compile. *Test: a negative-compilation harness asserts that a payload embedding a credential fails to build. A compile-time property has no runtime test — the harness is what makes it checkable by CI rather than by hope.*
- **INV-7** *(v1.1)* Agent-supplied strings are treated as untrusted data in AI prompts and can never, alone, cause a network-touching tool to run. *Test: a hostile-fixture corpus of agent strings induces no unconfirmed tool call.*

**Diagnostic coverage, disclosed.** Because the app ships no crash reporting of its own,
post-launch crash signal comes only from users who enabled Apple's system-wide diagnostic
sharing, aggregated by Apple. There is no path from a report back to a specific user's
incident, and support must not promise diagnosis from a crash report alone.

---

## 9. Success criteria

- **SC-0** **Interpretive correctness.** For the bundled MIB set and at least two real vendor MIBs, every OID resolution, enumeration label, DISPLAY-HINT rendering and decoded table index matches a reference implementation (`net-snmp`'s `snmptranslate` and `snmpwalk -O` output) across a fixed corpus, with every divergence either fixed or documented as a deliberate difference.

  *This is first because it is the one that matters most.* The product's stated value is turning numbers into a trustworthy answer (§1). A tool that formats a value wrongly is worse than one that crashes: the crash is visible, and the wrong value is quietly believed. Every other criterion below measures speed, stability or compliance — none of them would catch this.
- **SC-2** A vendor MIB bundle written in SMIv2 imports and resolves, or fails with a diagnostic naming file, line and column. A module the parser does not support (see §5) is rejected with a message that says so plainly, rather than implying the user can fix a file that only the vendor can reissue.
- **SC-3** v3 authPriv works against three named, independent agent implementations: `net-snmp`, Cisco IOS and Juniper Junos — one open-source reference and two dominant enterprise stacks, independently implemented.
- **SC-4** Every **non-provisional** NFR in §7 is met and measured. NFR-1 and NFR-5 are excluded until their provisional figures are replaced with measured ones.
- **SC-5** Every v1-applicable invariant in §8 has a passing check in CI — runtime test or negative-compilation harness. INV-6 and INV-7 are v1.1 and out of scope for v1 acceptance.
- **SC-8** The decoder survives a fixed fuzzing corpus and duration (NFR-8) with no crash, hang or unbounded allocation.

---

## Revision

| Version | Date |
|---|---|
| draft-1 | 2026-07-26 |
| draft-2 | 2026-07-26 |
| draft-3 | 2026-07-27 |
| draft-4 | 2026-07-28 |
| draft-5 | 2026-07-29 |
