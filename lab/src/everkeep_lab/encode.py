"""Re-encode a clip with x265, the lab's ceiling encoder."""

from __future__ import annotations

import time
from pathlib import Path

from everkeep_lab.tools import Runner


def build_x265_command(ref: Path, out: Path, *, crf: int, preset: str) -> list[str]:
    return [
        "ffmpeg",
        "-y",
        "-v",
        "error",
        "-i",
        str(ref),
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-c:v",
        "libx265",
        "-preset",
        preset,
        "-crf",
        str(crf),
        "-tag:v",
        "hvc1",
        "-x265-params",
        "log-level=error",
        "-c:a",
        "copy",
        str(out),
    ]


def encode_x265(ref: Path, out: Path, *, crf: int, preset: str, run: Runner) -> float:
    """Encode `ref` to `out` and return the wall-clock seconds it took."""
    out.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    run(build_x265_command(ref, out, crf=crf, preset=preset))
    return time.monotonic() - started
