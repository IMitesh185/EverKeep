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

## 2026-11-07 implementation

Policy version 2 additionally requires thumbnail-scale evidence, colour-channel comparison and
completed text/face-region checks. Photos need one complete comparison; videos need at least eight
valid samples (the adapter requests twelve). Unknown/non-finite metrics and invalid sizes fail.
Native fit/fill previews are checked after import and before requesting deletion.

Current numeric defaults and the sampled-motion heuristic are provisional, not lab-calibrated.
They must not be described as proof of invisible loss. Real-footage calibration and device testing
remain release gates. Old ready candidates cannot inherit approval under the new policy.
