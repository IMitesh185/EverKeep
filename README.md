# Everkeep (dev)

Private repository. It contains product mechanism; keep it private.

Everkeep is an intelligent iPhone photo and video preservation product. It keeps a memory for
less storage only where a measurement, not a guess, shows nothing visible is lost.
"Everkeep" is a working name; other App Store apps already use it.

## Status

Phase 1, Windows lab. Nothing else is built until Experiment 0 clears its bar.

| Gate | Question | Where |
|---|---|---|
| Experiment 0 | At least 30% smaller at mean VMAF 95 on 3 of 4 real clips? | [lab/](lab/) |
| Experiment 0b | How far below the x265 ceiling is a phone-class hardware encoder? | not started |
| iOS spikes | Replace, delete, reclaim and fidelity mechanics on iOS | [spikes/ios-e1/](spikes/ios-e1/) (E1 only) |
| Device benchmark | Real iPhone; needs the paid Apple Developer Program | not started |

## Layout

| Path | Purpose |
|---|---|
| `lab/` | Python measurement tooling for Experiment 0. Never shipped in the app. |
| `spikes/ios-e1/` | Throwaway iOS feasibility spike, built on Codemagic and run there or on Appetize. |
| `docs/` | Requirements, architecture, risks and architecture decision records. |
| `codemagic.yaml` | iOS CI workflows. Codemagic requires it at the repository root. |
| `.github/workflows/` | Lab CI: lint, types and tests. |

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

Keep the virtual environment outside any synced folder. See [lab/README.md](lab/README.md) to
run Experiment 0 and [docs/README.md](docs/README.md) for the design.
