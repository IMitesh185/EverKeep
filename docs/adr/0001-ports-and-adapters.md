# ADR-0001: Ports and adapters

- Status: Accepted
- Date: 2026-11-06

## Context

Development happens on Windows and iOS builds run on Codemagic. Apple-only frameworks (Photos,
AVFoundation, SwiftUI) are not part of the Windows Swift toolchain (Reported), so code that
imports them can only be compiled on CI. Swift itself installs on Windows (Verified, swift.org,
2026-11-05).

## Decision

The core (policy engine, eligibility rules, compression planner, quality policy, transaction
state machine, orchestrator) is pure Swift behind protocols: `LibraryPort`, `CodecPort`,
`ValidationPort`, `StoragePort`, `DestinationPort` and `CatalogueStore`. Apple adapters implement
them and compile only on CI. Python in `lab/` measures and never decides, so decision logic is
written once.

## Consequences

- Core unit tests run on Windows with fakes. Adapters are exercised through CI simulator runs.
- One extra layer of indirection, and a strict dependency direction: adapters depend on the core,
  never the reverse.
