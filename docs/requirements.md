# Requirements

Source: the Product Constitution and the owner's preservation-workflow decisions. Status as of 2026-11-07.

## Confirmed

- Principles: unused is not unimportant; time is a signal, never a decision; preserve before
  optimizing; the user stays in control; optimize per item; preserve the experience, not the
  encoding; local-first with no account, cloud or subscription.
- A per-item `PreservationDecision` with an explanation: `KEEP_AS_IS`, `PROTECT`, `OPTIMIZE`,
  `OPTIMIZE_CONSERVATIVELY`, `DEFER`, `ASK_USER`, `NOT_ELIGIBLE`.
- A transactional pipeline. The original is touched only after a validated, verified replacement
  and user approval. Any failure keeps the original.
- Stack: Swift, SwiftUI, PhotoKit, AVFoundation, VideoToolbox, ImageIO, SQLite. Crash-safe and
  idempotent.
- OS limits:
  - No general last-viewed timestamp (Verified, Apple docs, 2026-11-05).
  - Background work is scheduled by iOS and interruptible (Verified).
  - No silent replace (Verified: edits keep the original).
  - Deleting needs user permission (Reported).
- The engine is validated before any UI polish.
- Per-item choices: Protected, Almost identical, Space first, or unassigned. Unassigned items require
  a choice; content classification never assigns personal importance. Explicit protection always wins.
- Photos remains the only permanent media library. No private gallery or original-thumbnail archive.
  Native previews from the replacement are acceptable when they pass the browsing-quality checks.
- Ordinary photos/screenshots and standard videos are in the implementation scope. HDR/wide-colour,
  Live Photos, RAW/depth, edited and other unvalidated special media remain unchanged.
- Almost identical preserves dimensions/frame rate. Space first may reduce standard videos to 720p,
  not their frame rate or audio. Photos retain dimensions; text-sensitive material gets stricter handling.
- Preparation and approval are separate. Approval rechecks the original revision, user preference,
  content/preview quality and the imported native Photos previews before requesting deletion.
- Verified file-size reduction is not immediate device space freed. iCloud Photos deletion affects
  synced devices. Neither the app nor a compressed copy can restore permanently discarded detail.
- Develop on Windows; execute Swift/native/UI checks on Codemagic and manually inspect the simulator
  build in Appetize. Local static/editor checks do not substitute for those executions.

## Flags: gaps in the constitution

| # | Gap | Status |
|---|---|---|
| F1 | A private vault moves preserved media out of Photos and adds a gallery, search, encryption and key management for no extra savings | Resolved: hybrid, [ADR-0002](adr/0002-preserved-output-destination.md) |
| F2 | "Restoration" cannot restore quality; it can only export back | Resolved by ADR-0002: no restoration screen in v1 |
| F3 | The preview screen needs an encoded candidate, but approval is placed before encoding | Resolved: [ADR-0003](adr/0003-two-stage-approval.md) |
| F4 | Hot/warm/cold reintroduces an age rule through the back door | Resolved: [ADR-0006](adr/0006-no-hot-warm-cold.md) |
| F5 | The Android phase under-tests the iPhone risks | Resolved: [ADR-0007](adr/0007-ios-spikes-replace-android-phase.md) |
| F6 | "700 MB to 180 MB" is unvalidated | Open: no savings figure in any UI, post or pitch until Experiment 0 supports it |

## Unresolved assumptions

| # | Assumption | Test |
|---|---|---|
| U1 | Savings at invisible quality with the phone's own encoder are large enough | Experiment 0, then 0b |
| U2 | The hardware HEVC encoder offers a quality-targeted mode, not only bitrate targets | Device benchmark |
| U3 | A cheap on-device validator tracks VMAF | Lab calibration |
| U4 | A replacement keeps date, location, favourite, albums, Live Photo pairing, HDR and spatial video | Fidelity matrix |
| U5 | One delete prompt per batch; atomic create-plus-delete in one change block; Recently Deleted retention and when space returns | Spikes E4 and E5 |
| U6 | The execution model: user-initiated runs, `BGContinuedProcessingTask` (exists, limits unverified), idle-only `BGProcessingTask` | Device benchmark |
| U7 | Staging works when the phone is nearly full (read the asset in place, stage only the output) | Spikes, device |
| U8 | iCloud Photos: how the new asset and the deletion sync; libraries where originals are not local | Device |
| U9 | App Review's view of bulk replace and delete; device testing needs the paid Apple Developer Program | Before any beta |
