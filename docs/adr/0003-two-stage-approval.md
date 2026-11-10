# ADR-0003: Two-stage approval, batched

- Status: Proposed
- Date: 2026-11-06

## Context

The preview screen shows a real candidate (actual size and quality), but the constitution places
approval before any encoding. Per-item approval does not scale to thousands of items.

## Decision

Stage 1: the user opts in to prepare candidates for a batch, which spends compute. Stage 2: the
user approves the validated candidates, with per-item exclusions. The system's delete
confirmation is the third touchpoint, expected once per batch (to be confirmed by spike E4).

## Consequences

- Compute can be spent on candidates the user rejects, so recommendations show estimates first.
- No encoding starts without an opt-in.
