# everkeep-lab

Measurement tooling for Everkeep. It answers one question before anything else is built: how much
smaller can real iPhone video get at a quality you cannot tell apart? It is lab code and is never
shipped in the app.

## Requirements

- Python 3.10 or newer. No runtime dependencies.
- `ffmpeg` and `ffprobe` 6 or newer on `PATH`, from a "full" build that includes `libx265` and
  `libvmaf`.

## Setup

Keep the virtual environment outside any synced folder.

```powershell
python -m venv $env:LOCALAPPDATA\everkeep-venv
& $env:LOCALAPPDATA\everkeep-venv\Scripts\python -m pip install -e ".[dev]"
everkeep-lab doctor
```

`doctor` prints the ffmpeg version and fails if `libx265` or `libvmaf` is missing.

## Experiment 0

1. Record 4 clips of 10 s or less with HDR Video off (Settings, Camera, Record Video):
   static indoor, handheld motion outdoors, low light, and fine detail such as foliage or text.
   Use mundane scenes, not family footage.
2. Copy the original `.MOV` files into `lab/clips/`. That folder is git-ignored.
3. Time one clip first, then run the full ladder:

```powershell
everkeep-lab exp0 run --clips clips --out out --crf 28
everkeep-lab exp0 run --clips clips --out out
```

4. Read the printed table. Results are cached, so an interrupted run resumes; add `--force` to
   re-encode. `everkeep-lab exp0 report --out out` reprints the report without encoding.

| Output (in `--out`) | Contents |
|---|---|
| `results.jsonl` | One record per clip and CRF, appended as each finishes |
| `results.csv` | The same results with `ratio` and `savings` columns |
| `manifest.json` | ffmpeg version, settings, the bar and per-clip properties |
| `exp0.log` | Run log |
| `encodes/` | The re-encoded clips, to inspect by eye |

### The bar

Registered on 2026-11-06 in `config.py` and never edited after seeing results.

| Check | Threshold |
|---|---|
| Mean VMAF of a candidate | at least 95 |
| Bytes saved by the smallest passing candidate | at least 30% |
| Clips that must clear both | 75%, rounded up (3 of 4) |

### Reading the result

- x265 is the ceiling. A phone's hardware encoder will land below it (Hypothesis), so a pass
  here does not promise the same savings on a device.
- Mean VMAF can hide short bad stretches. Check `vmaf_p1` and watch every passing encode.
- VMAF is trained on SDR content, so HDR clips are skipped and reported.
- Encode times are software x265 on your PC and say nothing about phone speed.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed |
| 1 | Completed, but some trials failed |
| 2 | Error, such as a missing tool or no clips |

## Development

```powershell
ruff check . ; ruff format --check . ; mypy ; pytest -m "not integration"
pytest -m integration -rs   # real ffmpeg on a synthetic clip; skips without a full build
```

| Module | Responsibility |
|---|---|
| `cli.py` | Argument parsing, logging, exit codes |
| `experiment.py` | Runs the ladder per clip, caches, isolates failures |
| `tools.py` | Runs ffmpeg and ffprobe, checks capabilities |
| `probe.py` | Reads clip properties |
| `encode.py` | Builds and runs the x265 command |
| `quality.py` | VMAF and SSIM commands and parsers |
| `analysis.py` | Applies the bar |
| `store.py` | JSON lines, CSV and manifest |
| `report.py` | Plain-text report |
| `config.py`, `model.py`, `errors.py` | Settings, records, exceptions |
