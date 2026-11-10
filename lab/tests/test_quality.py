"""Tests for the VMAF and SSIM commands and parsers."""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

from everkeep_lab.errors import ParseError
from everkeep_lab.probe import parse_probe_json
from everkeep_lab.quality import (
    build_vmaf_graph,
    measure,
    parse_ssim_summary,
    parse_vmaf_json,
    percentile,
    vmaf_model_for,
)
from tests.fakes import FakeToolchain, probe_payload


@pytest.mark.parametrize(
    ("long_side", "model"),
    [
        (3840, "vmaf_4k_v0.6.1"),
        (3000, "vmaf_4k_v0.6.1"),
        (2999, "vmaf_v0.6.1"),
        (1920, "vmaf_v0.6.1"),
    ],
)
def test_model_follows_the_long_side(long_side: int, model: str) -> None:
    assert vmaf_model_for(long_side) == model


def test_graph_syncs_timestamps_and_uses_a_relative_log_path() -> None:
    graph = build_vmaf_graph("vmaf_v0.6.1", subsample=5, threads=8)
    assert graph.count("setpts=PTS-STARTPTS") == 2
    assert "model=version=vmaf_v0.6.1" in graph
    assert "n_subsample=5" in graph
    assert "n_threads=8" in graph
    assert "log_path=vmaf.json" in graph
    assert "\\" not in graph
    assert ":/" not in graph


def test_percentile() -> None:
    assert math.isnan(percentile([], 0.01))
    assert percentile([7.0], 0.01) == 7.0
    assert percentile([float(n) for n in range(1, 102)], 0.01) == 2.0


def test_parse_vmaf_json_reads_pooled_and_frame_metrics() -> None:
    text = json.dumps(
        {
            "frames": [{"metrics": {"vmaf": v}} for v in (90, 95, 99, 98)],
            "pooled_metrics": {"vmaf": {"min": 90, "max": 99, "mean": 95.5, "harmonic_mean": 95.3}},
        }
    )
    scores = parse_vmaf_json(text)
    assert (scores.mean, scores.hmean, scores.minimum, scores.p1) == (95.5, 95.3, 90.0, 90.0)


@pytest.mark.parametrize("text", ["not json", "{}", '{"pooled_metrics": {}}'])
def test_parse_vmaf_json_rejects_unexpected_logs(text: str) -> None:
    with pytest.raises(ParseError):
        parse_vmaf_json(text)


def test_parse_ssim_uses_the_last_summary() -> None:
    text = "x All:0.9 (1)\n[Parsed_ssim_2 @ 0x1] SSIM Y:0.99 U:0.98 V:0.98 All:0.987654 (19.1)"
    assert parse_ssim_summary(text) == 0.987654


def test_parse_ssim_without_a_summary_raises() -> None:
    with pytest.raises(ParseError):
        parse_ssim_summary("nothing useful here")


def test_measure_combines_vmaf_and_ssim(tmp_path: Path) -> None:
    toolchain = FakeToolchain()
    info = parse_probe_json(probe_payload(), "a.mov")
    scores = measure(
        tmp_path / "a_crf24_medium.mov",
        tmp_path / "a.mov",
        info,
        subsample=5,
        threads=2,
        run=toolchain,
    )
    assert scores.vmaf_mean == 96.0
    assert scores.vmaf_p1 == 94.0
    assert scores.ssim == 0.99
    assert len(toolchain.calls) == 2
