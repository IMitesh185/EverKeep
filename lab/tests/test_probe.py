"""Tests for ffprobe parsing."""

from __future__ import annotations

import pytest

from everkeep_lab.errors import ParseError
from everkeep_lab.probe import fps_from_ratio, parse_probe_json
from tests.fakes import probe_payload


def test_parses_an_sdr_clip() -> None:
    info = parse_probe_json(probe_payload(), "a.mov")
    assert (info.name, info.codec, info.width, info.height) == ("a.mov", "hevc", 3840, 2160)
    assert info.fps == 60.0
    assert info.mbps == 50.0
    assert info.size_bytes == 1_000_000
    assert not info.hdr


@pytest.mark.parametrize("transfer", ["smpte2084", "arib-std-b67"])
def test_flags_hdr_transfer_functions(transfer: str) -> None:
    assert parse_probe_json(probe_payload(transfer=transfer), "a.mov").hdr


def test_portrait_clip_uses_the_longer_side() -> None:
    info = parse_probe_json(probe_payload(width=2160, height=3840), "p.mov")
    assert info.long_side == 3840
    assert info.resolution == "2160x3840"


@pytest.mark.parametrize(("ratio", "expected"), [("60/1", 60.0), ("30", 30.0), ("0/0", 0.0)])
def test_fps_from_ratio(ratio: str, expected: float) -> None:
    assert fps_from_ratio(ratio) == expected


def test_fps_from_ratio_handles_ntsc_rates() -> None:
    assert fps_from_ratio("60000/1001") == pytest.approx(59.94, abs=0.01)


@pytest.mark.parametrize("text", ["not json", "{}", '{"streams": [], "format": {}}'])
def test_rejects_unexpected_output(text: str) -> None:
    with pytest.raises(ParseError):
        parse_probe_json(text, "a.mov")
