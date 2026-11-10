"""Runs the real ffmpeg pipeline on a synthetic clip. Skipped without a full ffmpeg build."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from everkeep_lab.config import RunSettings
from everkeep_lab.experiment import run_experiment
from everkeep_lab.store import ResultStore
from everkeep_lab.tools import check_capabilities, subprocess_runner

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def real_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        pytest.skip("ffmpeg and ffprobe are not on PATH")
    if check_capabilities(subprocess_runner).missing:
        pytest.skip("this ffmpeg build lacks libx265 or libvmaf")


def test_pipeline_scores_a_synthetic_clip(real_ffmpeg: None, tmp_path: Path) -> None:
    clips = tmp_path / "clips"
    clips.mkdir()
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x240:rate=24",
            "-t",
            "2",
            "-c:v",
            "libx265",
            "-pix_fmt",
            "yuv420p",
            "-tag:v",
            "hvc1",
            str(clips / "synthetic.mov"),
        ],
        check=True,
    )
    out = tmp_path / "out"
    settings = RunSettings(crfs=(28,), preset="ultrafast", vmaf_subsample=1, threads=2)
    outcome = run_experiment(clips, out, settings, run=subprocess_runner, store=ResultStore(out))
    assert not outcome.failures
    (trial,) = outcome.trials
    assert 0 < trial.vmaf_mean <= 100
    assert 0 < trial.ssim <= 1
    assert trial.out_size_bytes > 0
