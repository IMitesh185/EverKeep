# Everkeep (dev)

Private repository. It contains product mechanism; keep it private.

Everkeep is an intelligent iPhone photo and video preservation product. It keeps a memory for
less storage only where a measurement, not a guess, shows nothing visible is lost.
"Everkeep" is a working name; other App Store apps already use it.

## Status

Phase 1 is a Windows measurement lab; the app is also written. On 2026-11-06 the owner chose to
build v1 before Experiment 0, so the gates below now decide whether the app ships, not whether it is
built. If Experiment 0 misses its bar, the savings premise is wrong and the app does not go out.

| Gate | Question | Where |
|---|---|---|
| Experiment 0 | At least 30% smaller at mean VMAF 95 on 3 of 4 real clips? | [lab/](lab/) |
| Experiment 0b | How far below the x265 ceiling is a phone-class hardware encoder? | not started |
| App | Do photo/video preferences, scan, prepare, approve and replace work on a simulator? | [core/](core/), [app/](app/); updated 2026-11-07, pending Codemagic execution |
| iOS spikes | Replace, delete, reclaim and fidelity mechanics on iOS | [spikes/ios-e1/](spikes/ios-e1/) (E1 only) |
| Device benchmark | Real iPhone; needs the paid Apple Developer Program | not started |

## Layout

| Path | Purpose |
|---|---|
| `lab/` | Python measurement tooling for Experiment 0. Never shipped in the app. |
| `core/` | Swift package: policy, planner, quality policy, transactions and orchestrator behind ports. No Apple frameworks. |
| `app/` | iOS app: PhotoKit, ImageIO, Vision and AVFoundation adapters, SQLite preferences, review screens and native/UI tests. |
| `spikes/ios-e1/` | Throwaway iOS feasibility spike, built and run on Codemagic. |
| `docs/` | Requirements, architecture, risks and architecture decision records. |
| [`codemagic.yaml`](codemagic.yaml) | Manual Mac CI workflows for core tests, simulator end-to-end tests, and Appetize builds. |
| `.github/workflows/` | GitHub Actions CI workflows for the Swift core package and Python evaluation lab. |

## Rules

- Decision logic is written once, in Swift. Python measures; it does not decide.
- No personal photos or videos in the repository. Spike media is synthetic.
- No savings figure appears in any public material until Experiment 0 supports it.
- Originals are never deleted silently, and any failure keeps the original.

## Preservation choices

- **Protected:** no re-encoding, resizing, repair or replacement.
- **Almost identical:** retain photo/video dimensions and video frame rate, with stricter measured checks.
- **Space first:** standard videos may reduce to 720p while preserving frame rate and passthrough tracks.
  Detected text prevents automatic downscaling. Full-resolution retries are available if smaller
  frames fail. Photo dimensions remain unchanged; stronger encoding is allowed.
- **Unassigned:** ask the user; never choose a destructive preference from age, faces or motion.
  Favorites are protected by default, but an explicit per-item choice can override that default.

Photos is the only permanent media library. Everkeep requests native previews for selection and
review; there is no separate gallery, vault or original-thumbnail archive. Candidates are temporary.
Users can choose individually or explicitly apply a preference to unassigned items in the current
filter. Existing choices and protected items are not overridden by that bulk operation.

Supported candidates are ordinary SDR JPEG/PNG/HEIC photos, screenshots and H.264/HEVC videos.
PNG starts with a lossless trial; images with an alpha channel stay PNG. Text-sensitive images
receive gentler settings. HDR/wide-colour, Live Photos, RAW/depth resources, edited/special media,
unsupported formats and cloud-only originals stay unchanged.

Validation checks colour-channel similarity, thumbnail-scale similarity, detected text and face
regions, actual size reduction, and media integrity. Video checks decode every frame, require the
same frame count and verify duration, frame rate, colour tags and passthrough tracks. The visual
checks sample 12 frames; they do not prove that every moment is unchanged. OCR results are used
locally for comparison and are not written into the catalogue.

Approval revalidates the candidate and the original's revision. Preferences are checked again
before import and deletion. The imported asset's native fit/fill previews must pass before any
original deletion is requested. Declining deletion or failing post-import verification keeps the
original and may leave both copies. Old staged candidates lacking the new validation policy are
discarded, not silently approved.

**Thresholds and motion heuristics remain uncalibrated development defaults.** This implementation
is not a claim of invisible loss or a substitute for the lab and real-device gates.

The UI reports verified **file-size reduction**, not immediate device space freed. Originals remain
in Recently Deleted until permanently removed. With iCloud Photos, replacement/deletion propagates
to other synced devices; it is not a local-only storage optimization.

## Start

```powershell
cd lab
python -m venv $env:LOCALAPPDATA\everkeep-venv
& $env:LOCALAPPDATA\everkeep-venv\Scripts\python -m pip install -e ".[dev]"
& $env:LOCALAPPDATA\everkeep-venv\Scripts\python -m everkeep_lab doctor
```

## Run the app

For a pre-build visual walkthrough, open [the interactive HTML preview](app/Preview/index.html)
in a browser. It mirrors the current SwiftUI screens with synthetic demo data; it does not access
Photos, compress media or validate native rendering. Fonts and system controls are approximations.

The Swift app opens on the same design: a faded photograph of one of the person's own memories behind
translucent glass, one rotary dial (Photos, Live Photos, Videos, Screenshots) as the only navigation, a main
screen with the selected category, storage consumed, potential savings and **Review & preserve**, and a
review of the actual media with deselect, protect and a closer look where Everkeep is unsure. The HTML
file [redesign.html](app/Preview/redesign.html) is its interactive reference, with demo numbers and
sample photographs. Where they differ, the app is the more honest of the two:

- Sizes come from a measuring pass over the real library, kept in `survey-v1.json`. Potential savings are
  estimates (the planner's bit-rate and quality ladders are uncalibrated) and carry a leading "~".
  Measured savings appear only after the smaller copies have been made and checked.
- Live Photos are not optimized in version 1, so their potential savings read "None".
- The before/after comparison shows a real smaller copy only after **Prepare**. Before that it shows the
  original alone.
- Favorites are never offered. Photos where a person may be the subject, and videos with fast movement,
  start left out until the person has taken a look.
- Stopping a scan returns to Welcome, as in the preview. What it found is kept, but the library does not
  count as scanned until a scan runs to the end. Later launches refresh the library quietly behind the dial.

The original four-tab interface is still built in Debug and opens with the launch argument
`-EKClassicUI YES`; `app-e2e` uses it to test the engine path. Release builds always open the new design.

This Windows machine has no Swift/Xcode toolchain. Develop here and build/run on Codemagic, then
use Appetize for manual simulator checks. Push the
repository to GitHub and add it in Codemagic with the `codemagic.yaml` project type. Every workflow
is manual, so nothing builds on push. The configuration is at the repository root alongside `core/`, `app/`, `lab/`, and `spikes/`.

| Workflow | What it does |
|---|---|
| `core-tests` | Builds and tests `core/`, including preferences, planners, quality gates, migration and protection/revision regression cases. |
| `app-e2e` | Creates an isolated simulator and runs two passes, each on a freshly erased simulator seeded with a video and a generated synthetic photo. Pass `classic` runs the native adapter tests and the four-tab flow (explicit preferences, protection, both media types, deletion approval). Pass `memory` drives the default interface: scan, turn the dial, review the real media, look closer, prepare, preserve and the system delete prompt for photos and videos. Keeps a recording, screenshot, log and `.xcresult` for each pass. |
| `app-simulator` | Generates the synthetic photo and builds `EverKeep-simulator.zip`, the zipped simulator `.app` that Appetize accepts. The Debug Welcome screen has an **Add demo media** link (the classic Overview has **Add two demo items to Photos**). Each tap intentionally adds a fresh synthetic pair. |

Run `core-tests`, then `app-e2e`, then `app-simulator`. Upload the simulator zip to Appetize,
allow Photos access, add demo media, scan, and review what Everkeep would change. A simulator pass
does not validate real iPhone encoder quality, HDR/Live Photo fidelity or iCloud behaviour.

For a manual Mac build, generate the photo before running XcodeGen:

```bash
cd app
swift Samples/make_photo.swift Samples/e2e-photo.jpg
xcodegen generate
```

Appetize's free plan is 30 minutes a month in sessions of 3 minutes, so use it for a last manual look
and do the testing in `app-e2e`.

Keep the virtual environment outside any synced folder. See [lab/README.md](lab/README.md) to
run Experiment 0 and [docs/README.md](docs/README.md) for the design.
