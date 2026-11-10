# Everkeep (dev)

Private repository. It contains product mechanism; keep it private.

Everkeep is an intelligent iPhone photo and video preservation product. It keeps a memory for
less storage only where a measurement, not a guess, shows nothing visible is lost.
"Everkeep" is a working name; other App Store apps already use it.

## Status

Phase 1 is a Windows measurement lab; v1 of the app is also written. On 2026-11-06 the owner chose to
build v1 before Experiment 0, so the gates below now decide whether the app ships, not whether it is
built. If Experiment 0 misses its bar, the savings premise is wrong and the app does not go out.

| Gate | Question | Where |
|---|---|---|
| Experiment 0 | At least 30% smaller at mean VMAF 95 on 3 of 4 real clips? | [lab/](lab/) |
| Experiment 0b | How far below the x265 ceiling is a phone-class hardware encoder? | not started |
| App v1 | Does scan, prepare, approve and replace work end to end on a simulator? | [core/](core/), [app/](app/); written, never compiled or run |
| iOS spikes | Replace, delete, reclaim and fidelity mechanics on iOS | [spikes/ios-e1/](spikes/ios-e1/) (E1 only) |
| Device benchmark | Real iPhone; needs the paid Apple Developer Program | not started |

## Layout

| Path | Purpose |
|---|---|
| `lab/` | Python measurement tooling for Experiment 0. Never shipped in the app. |
| `core/` | Swift package: policy, planner, quality policy, transactions and orchestrator behind ports. No Apple frameworks. |
| `app/` | iOS app: PhotoKit and AVFoundation adapters, SQLite catalogue, SwiftUI screens and the end-to-end UI test. |
| `spikes/ios-e1/` | Throwaway iOS feasibility spike, built and run on Codemagic. |
| `docs/` | Requirements, architecture, risks and architecture decision records. |
| `codemagic.yaml` | iOS CI workflows. Codemagic requires it at the repository root. |
| `.github/workflows/` | CI: lab lint, types and tests, and the core's Swift tests on Linux. |

## Rules

- Decision logic is written once, in Swift. Python measures; it does not decide.
- No personal photos or videos in the repository. Spike media is synthetic.
- No savings figure appears in any public material until Experiment 0 supports it.
- Originals are never deleted silently, and any failure keeps the original.

## Start

```powershell
cd lab
python -m venv $env:LOCALAPPDATA\everkeep-venv
& $env:LOCALAPPDATA\everkeep-venv\Scripts\python -m pip install -e ".[dev]"
& $env:LOCALAPPDATA\everkeep-venv\Scripts\python -m everkeep_lab doctor
```

## Run the app

Swift cannot be compiled on this Windows machine, so the app builds and runs on CI. Push the
repository to GitHub and add it in Codemagic with the `codemagic.yaml` project type. Every workflow
is manual, so nothing builds on push.

| Workflow | What it does |
|---|---|
| `core-tests` | Builds and tests `core/`. The `core-ci` GitHub workflow runs the same tests on Linux for every push. |
| `app-e2e` | Seeds a simulator's Photos library with `app/Samples/e2e-sample.mp4`, runs a UI test that drives scan, prepare, approve and the system delete prompt, and keeps a screen recording, a screenshot and the log. |
| `app-simulator` | Builds `EverKeep-simulator.zip`, the zipped simulator `.app` that Appetize accepts. |

Appetize's free plan is 30 minutes a month in sessions of 3 minutes, so use it for a last manual look
and do the testing in `app-e2e`.

Keep the virtual environment outside any synced folder. See [lab/README.md](lab/README.md) to
run Experiment 0 and [docs/README.md](docs/README.md) for the design.
