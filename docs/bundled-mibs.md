# The bundled standard MIB set

C-6 requires the app to be fully functional with no internet connectivity, so the
standard MIB modules cannot be fetched on demand — they ship inside the bundle.
This document is the record of *which* modules ship and why, as the acceptance
criteria of SNMP-24 require. Licences are recorded separately, in `NOTICE`.

The files live in `Sources/MIBKit/Resources/StandardMIBs/` and are declared as a
SwiftPM resource of the `MIBKit` target.

## The set

19 modules. The first column is the file in the resource directory.

| Module | Source | Why it is in the bundle |
|---|---|---|
| `SNMPv2-SMI` | RFC 2578 | SMIv2 base module; everything imports from it |
| `SNMPv2-TC` | RFC 2579 | Base textual conventions (`DisplayString`, `TimeStamp`, `TruthValue`, …) |
| `SNMPv2-CONF` | RFC 2580 | `MODULE-COMPLIANCE`, `OBJECT-GROUP`, `NOTIFICATION-GROUP` |
| `SNMPv2-MIB` | RFC 3418 | System group, `sysUpTime`, standard traps — the SMIv2 replacement for `RFC1213-MIB` |
| `SNMPv2-TM` | RFC 3417 | Transport mappings; defines `snmpUDPDomain` |
| `INET-ADDRESS-MIB` | RFC 4001 | `InetAddress` family, imported by IP-MIB, TCP-MIB, UDP-MIB |
| `IANAifType-MIB` | IANA registry | `IANAifType` — the enumeration behind `ifType` |
| `IANA-ADDRESS-FAMILY-NUMBERS-MIB` | IANA registry | `AddressFamilyNumbers` textual convention |
| `IF-MIB` | RFC 2863 | Interfaces table; `ifInOctets` and `ifOperStatus` are the FR-9/FR-10 witnesses |
| `IP-MIB` | RFC 4293 | IPv4/IPv6 layer counters and address tables |
| `TCP-MIB` | RFC 4022 | TCP connection table and counters |
| `UDP-MIB` | RFC 4113 | UDP endpoint table and counters |
| `HOST-RESOURCES-MIB` | RFC 2790 | Storage, devices, running software — the host-side view |
| `ENTITY-MIB` | RFC 6933 | Physical entity inventory (version 4) |
| `BRIDGE-MIB` | RFC 4188 | 802.1D bridge/switch objects |
| `SNMP-FRAMEWORK-MIB` | RFC 3411 | **Addition.** `ENTITY-MIB` imports `SnmpAdminString` from it |
| `UUID-TC-MIB` | RFC 6933 | **Addition.** `ENTITY-MIB` imports `UUIDorZero` from it |
| `IANA-ENTITY-MIB` | IANA registry | **Addition.** `ENTITY-MIB` imports `IANAPhysicalClass` from it |

### Additions to the candidate set

The candidate set named in SNMP-24 AC1 was 15 modules. Three were added, all for
the same reason: `ENTITY-MIB` (RFC 6933, Entity MIB version 4) imports
`SnmpAdminString` from `SNMP-FRAMEWORK-MIB`, `UUIDorZero` from `UUID-TC-MIB`, and
`IANAPhysicalClass` from `IANA-ENTITY-MIB`. AC5 requires `IMPORTS` across the
bundled set to resolve entirely within the bundle — no bundled module may depend
on a module the user has to supply — so shipping `ENTITY-MIB` without these three
would have left a hole the user cannot fill.

`URI-TC-MIB` (RFC 5017) was fetched as a fourth candidate addition and then
dropped: nothing in the set imports from it. `ENTITY-MIB` version 4 carries no
`Uri`-typed object. A module no other bundled module references, and that no
acceptance criterion asks for, has no reason to ship.

`IANA-ENTITY-MIB` is taken from the live IANA registry rather than from RFC 6933's
initial copy, for the same reason `IANAifType-MIB` is: IANA, not the RFC, is the
module's maintainer, and the registry copy is the current one.

### Removals from the candidate set

None. No candidate was dropped, whether for licensing (see `NOTICE`) or any other
reason.

## `RFC1213-MIB` is deliberately not bundled

`RFC1213-MIB` is the module most people reach for first, and it is the one module
in this area that this product cannot read. It is written in SMIv1. §5 of the
product specification states that the parser targets SMIv2 and that a genuinely
SMIv1-only module will not compile. Bundling it would ship a file the product
rejects, in the place where a rejection is least explicable to a user: our own
bundle.

`SNMPv2-MIB` (RFC 3418) supersedes it and is bundled in its place. The objects
users actually reach `RFC1213-MIB` for are covered: the system group by
`SNMPv2-MIB`, the interfaces group by `IF-MIB`, and the ip/tcp/udp groups by
`IP-MIB`, `TCP-MIB` and `UDP-MIB`.

Reversing this decision requires citing a parser change that makes SMIv1 compile,
per SNMP-24 AC2.

## Extraction

Modules sourced from RFCs are extracted from the canonical RFC text at
`https://www.rfc-editor.org/rfc/rfc<n>.txt`. Extraction removes page furniture
(running headers, `[Page N]` footers, form feeds) and the common leading
indentation, and takes the module from its `DEFINITIONS ::= BEGIN` line to its
matching `END`. The match must track nesting: `SNMPv2-SMI`, `SNMPv2-TC` and
`SNMPv2-CONF` each contain `MACRO ::= BEGIN … END` blocks, so the first `END`
after the header is not the module's own.

Modules sourced from IANA are downloaded from `https://www.iana.org/assignments/`
and need only the indentation stripped.

No MIB text is otherwise altered. `StandardMIBBundleTests` re-checks the
structural properties this relies on — every file opens with its own
`DEFINITIONS ::= BEGIN`, closes with `END`, and carries no page residue.

## Relationship to SC-0

This set is the baseline corpus that SC-0 measures against. SC-0 requires every
OID resolution, enumeration label, DISPLAY-HINT rendering and decoded table index
over the bundled set to match `net-snmp`'s `snmptranslate` and `snmpwalk -O`
output. SNMP-48 AC11's corpus definition refers to the files listed in the table
above; the two lists are the same list, and changing one changes the other.

## What this document does not yet cover

`swift test` proves the resource is present, complete, licence-recorded, import-
closed and lazily read. Two of SNMP-24's criteria cannot be closed until their
dependencies land, and are tracked there rather than silently assumed here:

- **AC5, "compiles with zero diagnostics"** — needs the SMIv2 parser (SNMP-20,
  TO DO). The import-closure half of AC5 is checked now, textually.
- **AC6, offline `ifInOctets` ↔ `1.3.6.1.2.1.2.2.1.10` resolution and the
  `ifOperStatus` enumeration label** — needs the parser and the registration tree
  (SNMP-20, SNMP-21).
- **AC7's measurement** — the loader is lazy by construction and a test proves no
  module is read until it is asked for, but the cold-launch comparison against an
  empty resource directory needs the app's launch instrumentation (NFR-6).
- **AC8's sandbox half** — the resource is declared and readable under
  `swift test`; reading it from the App Sandbox in a signed build needs SNMP-39,
  and signing needs SNMP-44.
