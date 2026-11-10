"""The pre-registered bar and the run settings for Experiment 0."""

from __future__ import annotations

from dataclasses import dataclass

from everkeep_lab.errors import ConfigError

VIDEO_SUFFIXES = frozenset({".mov", ".mp4", ".m4v"})
VMAF_4K_MIN_LONG_SIDE = 3000
MAX_CRF = 51
PRESETS = frozenset(
    {
        "ultrafast",
        "superfast",
        "veryfast",
        "faster",
        "fast",
        "medium",
        "slow",
        "slower",
        "veryslow",
        "placebo",
    }
)


@dataclass(frozen=True)
class Bar:
    """Pass bar, registered before any result was seen. Do not edit it afterwards."""

    min_vmaf_mean: float = 95.0
    min_savings: float = 0.30
    min_clip_share: float = 0.75
    registered_on: str = "2026-11-06"


@dataclass(frozen=True)
class RunSettings:
    """Encoding and scoring parameters for one run."""

    crfs: tuple[int, ...] = (20, 24, 28, 32)
    preset: str = "medium"
    vmaf_subsample: int = 5
    threads: int = 8

    def __post_init__(self) -> None:
        if not self.crfs:
            raise ConfigError("at least one CRF is required")
        if any(not 0 <= crf <= MAX_CRF for crf in self.crfs):
            raise ConfigError(f"CRF values must be between 0 and {MAX_CRF}")
        if self.preset not in PRESETS:
            raise ConfigError(f"unknown x265 preset: {self.preset}")
        if self.vmaf_subsample < 1 or self.threads < 1:
            raise ConfigError("subsample and threads must be at least 1")
