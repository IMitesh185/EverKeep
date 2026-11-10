# ADR-0005: Video first

- Status: Proposed, gated by Experiment 0
- Date: 2026-11-06

## Context

Photos are already efficient (HEIC), and the constitution itself lists "already efficient media"
as a recommendation. Video is where the bytes are.

## Decision

v1 recommends and processes video only. `ImageCompressionEngine` is deferred.

## Consequences

- Revisit once the lab has a photo branch that shows at least 15% savings at SSIM 0.98 or higher.
- Smaller v1 surface to test and to fail safely.
