"""Perceptual quality scores (VMAF and SSIM) computed with ffmpeg."""

from __future__ import annotations

import json
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path

from everkeep_lab.config import VMAF_4K_MIN_LONG_SIDE
from everkeep_lab.errors import ParseError
from everkeep_lab.model import ClipInfo, Scores
from everkeep_lab.tools import Runner

_SYNC = "[0:v]setpts=PTS-STARTPTS[d];[1:v]setpts=PTS-STARTPTS[r];"
_VMAF_LOG = "vmaf.json"


@dataclass(frozen=True)
class VmafScores:
    mean: float
    hmean: float
    minimum: float
    p1: float


def vmaf_model_for(long_side: int) -> str:
    return "vmaf_4k_v0.6.1" if long_side >= VMAF_4K_MIN_LONG_SIDE else "vmaf_v0.6.1"


def build_vmaf_graph(model: str, subsample: int, threads: int) -> str:
    """The libvmaf filter graph; its log path is relative to avoid Windows drive letters."""
    return (
        f"{_SYNC}[d][r]libvmaf=model=version={model}:n_subsample={subsample}:"
        f"n_threads={threads}:log_fmt=json:log_path={_VMAF_LOG}"
    )


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[int(p * (len(ordered) - 1))]


def parse_vmaf_json(text: str) -> VmafScores:
    try:
        data = json.loads(text)
        pooled = data["pooled_metrics"]["vmaf"]
        frames = [
            float(frame["metrics"]["vmaf"])
            for frame in data.get("frames", [])
            if "vmaf" in frame.get("metrics", {})
        ]
        return VmafScores(
            mean=float(pooled["mean"]),
            hmean=float(pooled["harmonic_mean"]),
            minimum=float(pooled["min"]),
            p1=percentile(frames, 0.01),
        )
    except (KeyError, ValueError, TypeError, AttributeError) as exc:
        raise ParseError(f"unexpected libvmaf log: {exc!r}") from exc


def parse_ssim_summary(text: str) -> float:
    matches = re.findall(r"All:([0-9.]+)", text)
    if not matches:
        raise ParseError("no SSIM summary in ffmpeg output")
    return float(matches[-1])


def measure_vmaf(
    dist: Path, ref: Path, info: ClipInfo, *, subsample: int, threads: int, run: Runner
) -> VmafScores:
    graph = build_vmaf_graph(vmaf_model_for(info.long_side), subsample, threads)
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-i",
                str(dist.resolve()),
                "-i",
                str(ref.resolve()),
                "-lavfi",
                graph,
                "-f",
                "null",
                "-",
            ],
            cwd=workdir,
        )
        try:
            text = (workdir / _VMAF_LOG).read_text(encoding="utf-8")
        except FileNotFoundError as exc:
            raise ParseError("libvmaf wrote no log; use ffmpeg 6+ with libvmaf 2+") from exc
        return parse_vmaf_json(text)


def measure_ssim(dist: Path, ref: Path, *, run: Runner) -> float:
    graph = f"{_SYNC}[d][r]ssim"
    result = run(
        [
            "ffmpeg",
            "-v",
            "info",
            "-i",
            str(dist),
            "-i",
            str(ref),
            "-lavfi",
            graph,
            "-f",
            "null",
            "-",
        ]
    )
    return parse_ssim_summary(result.stderr)


def measure(
    dist: Path, ref: Path, info: ClipInfo, *, subsample: int, threads: int, run: Runner
) -> Scores:
    vmaf = measure_vmaf(dist, ref, info, subsample=subsample, threads=threads, run=run)
    return Scores(
        vmaf_mean=vmaf.mean,
        vmaf_hmean=vmaf.hmean,
        vmaf_min=vmaf.minimum,
        vmaf_p1=vmaf.p1,
        ssim=measure_ssim(dist, ref, run=run),
    )
