# ADR-0004: Fail-closed quality gate

- Status: Accepted
- Date: 2026-11-06

## Context

A false pass, meaning quality loss that goes unnoticed, destroys trust. A false fail only costs
some savings.

## Decision

A candidate is rejected unless every required check ran and passed. A missing metric, a decode
error, or a duration or track mismatch all reject. Thresholds are versioned (`policyVersion`)
and come from lab measurements, never from guesses.

## Consequences

- Fewer optimizations early on.
- Thresholds need calibration data before the first release.
