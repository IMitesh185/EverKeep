"""A fake ffmpeg and ffprobe that fabricate plausible, deterministic output."""

from __future__ import annotations

import json
import re
from collections.abc import Sequence
from pathlib import Path

from everkeep_lab.errors import ToolFailedError
from everkeep_lab.model import Trial
from everkeep_lab.tools import CommandResult

CLIP_SIZE = 1_000_000
SIZE_BY_CRF = {20: 600_000, 24: 450_000, 28: 330_000, 32: 240_000}
VMAF_BY_CRF = {20: 98.0, 24: 96.0, 28: 94.0, 32: 90.0}


def probe_payload(
    *,
    width: int = 3840,
    height: int = 2160,
    rate: str = "60/1",
    transfer: str = "bt709",
    size: int = CLIP_SIZE,
    bit_rate: int = 50_000_000,
) -> str:
    return json.dumps(
        {
            "streams": [
                {
                    "codec_name": "hevc",
                    "width": width,
                    "height": height,
                    "r_frame_rate": rate,
                    "color_transfer": transfer,
                }
            ],
            "format": {"size": str(size), "bit_rate": str(bit_rate)},
        }
    )


def make_clips(folder: Path, names: Sequence[str]) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for name in names:
        (folder / name).write_bytes(b"x")


def make_trial(
    clip: str = "a.mov", *, crf: int = 28, ratio: float = 0.5, vmaf: float = 96.0
) -> Trial:
    return Trial(
        clip=clip,
        clip_size_bytes=CLIP_SIZE,
        in_codec="hevc",
        in_resolution="3840x2160",
        in_fps=60.0,
        in_mbps=50.0,
        crf=crf,
        preset="medium",
        vmaf_model="vmaf_4k_v0.6.1",
        vmaf_subsample=5,
        out_size_bytes=round(ratio * CLIP_SIZE),
        encode_seconds=1.0,
        vmaf_mean=vmaf,
        vmaf_hmean=vmaf - 0.1,
        vmaf_min=vmaf - 5.0,
        vmaf_p1=vmaf - 4.0,
        ssim=0.99,
    )


class FakeToolchain:
    """Stands in for ffmpeg and ffprobe. Records every call it receives."""

    def __init__(self, *, has_libx265: bool = True, has_libvmaf: bool = True) -> None:
        self.has_libx265 = has_libx265
        self.has_libvmaf = has_libvmaf
        self.probes: dict[str, str] = {}
        self.fail_crfs: set[int] = set()
        self.calls: list[list[str]] = []

    def encodes(self) -> list[list[str]]:
        return [call for call in self.calls if "libx265" in call]

    def __call__(self, cmd: Sequence[str], *, cwd: Path | None = None) -> CommandResult:
        argv = list(cmd)
        self.calls.append(argv)
        if argv[0] == "ffprobe":
            return self._ffprobe(argv)
        if argv[0] == "ffmpeg":
            return self._ffmpeg(argv, cwd)
        raise AssertionError(f"unexpected tool: {argv[0]}")

    def _ffprobe(self, argv: list[str]) -> CommandResult:
        if "-version" in argv:
            return CommandResult("ffprobe version fake\n", "")
        name = Path(argv[-1]).name
        if name not in self.probes:
            raise ToolFailedError(argv, 1, "moov atom not found")
        return CommandResult(self.probes[name], "")

    def _ffmpeg(self, argv: list[str], cwd: Path | None) -> CommandResult:
        if "-version" in argv:
            return CommandResult(
                "ffmpeg version fake-7.1 Copyright (c) test\nbuilt with test\n", ""
            )
        if "-encoders" in argv:
            line = " V....D libx265 libx265 H.265 / HEVC\n" if self.has_libx265 else " V....D x\n"
            return CommandResult(line, "")
        if "-filters" in argv:
            line = (
                " ... libvmaf VV->V Calculate the VMAF\n" if self.has_libvmaf else " ... x V->V\n"
            )
            return CommandResult(line, "")
        if "libx265" in argv:
            return self._encode(argv)
        graph = argv[argv.index("-lavfi") + 1]
        if "libvmaf" in graph:
            return self._vmaf(argv, cwd)
        return CommandResult(
            "", "[Parsed_ssim_2 @ 0x1] SSIM Y:0.99 U:0.99 V:0.99 All:0.99 (20.0)\n"
        )

    def _encode(self, argv: list[str]) -> CommandResult:
        crf = int(argv[argv.index("-crf") + 1])
        if crf in self.fail_crfs:
            raise ToolFailedError(argv, 1, "encoder exploded")
        out = Path(argv[-1])
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"\0" * SIZE_BY_CRF[crf])
        return CommandResult("", "")

    def _vmaf(self, argv: list[str], cwd: Path | None) -> CommandResult:
        assert cwd is not None, "libvmaf must run in a scratch directory"
        dist = Path(argv[argv.index("-i") + 1])
        match = re.search(r"_crf(\d+)_", dist.name)
        assert match is not None
        mean = VMAF_BY_CRF[int(match.group(1))]
        payload = {
            "frames": [{"metrics": {"vmaf": mean + delta}} for delta in (-2.0, 0.0, 2.0)],
            "pooled_metrics": {
                "vmaf": {
                    "min": mean - 2.0,
                    "max": mean + 2.0,
                    "mean": mean,
                    "harmonic_mean": mean - 0.1,
                }
            },
        }
        (cwd / "vmaf.json").write_text(json.dumps(payload), encoding="utf-8")
        return CommandResult("", "")
