# ADR-0006: No hot/warm/cold in the engine

- Status: Proposed
- Date: 2026-11-06

## Context

Principle 2 bans age as a decision driver, yet the constitution keeps hot/warm/cold as internal
labels "for operational convenience". That reintroduces an age rule through the back door.

## Decision

The engine has no age-derived states. If a descriptive label is ever needed for display, it is
computed outside the engine and never feeds a decision.

## Consequences

- The decision inputs are technical signals and explicit protection only.
- The constitution's section 4.4 is amended by this record once the owner accepts it.
