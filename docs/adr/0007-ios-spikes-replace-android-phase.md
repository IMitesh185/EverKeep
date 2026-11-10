# ADR-0007: iOS spikes replace the Android phase

- Status: Proposed, awaiting the owner
- Date: 2026-11-06

## Context

The constitution's Phase 2 is an Android feasibility prototype. Engine code does not transfer,
because codec APIs differ. Android is also the easier platform: media can be overwritten in place
after user consent, and the media-management permission removes per-operation prompts (Verified,
Android docs, 2026-11-06). So it under-tests the iPhone risks.

## Decision

Phase 2 becomes iOS spikes on Codemagic (E1 now, then E4 and E5) and, once Experiment 0 and the
spikes justify it, a real-device benchmark.

## Consequences

- No Android toolchain, and no second mobile language, on a 4 hours per week budget.
- Phone-class processing time and battery are measured only on a real iPhone, which needs the
  paid Apple Developer Program.
