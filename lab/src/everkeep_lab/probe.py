"""Read clip properties with ffprobe."""

from __future__ import annotations

import json
from pathlib import Path

from everkeep_lab.errors import ParseError
from everkeep_lab.model import ClipInfo
from everkeep_lab.tools import Runner

_ENTRIES = "stream=codec_name,width,height,r_frame_rate,color_transfer:format=size,bit_rate"
_HDR_TRANSFERS = frozenset({"smpte2084", "arib-std-b67"})


def fps_from_ratio(ratio: str) -> float:
    num, _, den = ratio.partition("/")
    divisor = float(den or 1)
    return float(num) / divisor if divisor else 0.0


def parse_probe_json(text: str, name: str) -> ClipInfo:
    try:
        data = json.loads(text)
        stream = data["streams"][0]
        fmt = data["format"]
        return ClipInfo(
            name=name,
            codec=stream.get("codec_name", "unknown"),
            width=int(stream["width"]),
            height=int(stream["height"]),
            fps=round(fps_from_ratio(stream.get("r_frame_rate", "0/1")), 2),
            mbps=round(int(fmt.get("bit_rate", 0)) / 1e6, 1),
            size_bytes=int(fmt["size"]),
            hdr=stream.get("color_transfer") in _HDR_TRANSFERS,
        )
    except (KeyError, IndexError, ValueError, TypeError, AttributeError) as exc:
        raise ParseError(f"unexpected ffprobe output for {name}: {exc!r}") from exc


def probe_clip(path: Path, run: Runner) -> ClipInfo:
    result = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            _ENTRIES,
            "-of",
            "json",
            str(path),
        ]
    )
    return parse_probe_json(result.stdout, path.name)
