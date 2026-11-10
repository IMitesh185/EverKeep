"""Plain data records shared across the lab tooling."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

from everkeep_lab.errors import ParseError

TrialKey = tuple[str, int, int, str, int, str]


@dataclass(frozen=True)
class ClipInfo:
    """Properties of a source clip, read with ffprobe."""

    name: str
    codec: str
    width: int
    height: int
    fps: float
    mbps: float
    size_bytes: int
    hdr: bool

    @property
    def long_side(self) -> int:
        return max(self.width, self.height)

    @property
    def resolution(self) -> str:
        return f"{self.width}x{self.height}"


@dataclass(frozen=True)
class Scores:
    """Perceptual scores of a re-encode against its source."""

    vmaf_mean: float
    vmaf_hmean: float
    vmaf_min: float
    vmaf_p1: float
    ssim: float


@dataclass(frozen=True)
class Trial:
    """One clip encoded at one CRF and scored against the original."""

    clip: str
    clip_size_bytes: int
    in_codec: str
    in_resolution: str
    in_fps: float
    in_mbps: float
    crf: int
    preset: str
    vmaf_model: str
    vmaf_subsample: int
    out_size_bytes: int
    encode_seconds: float
    vmaf_mean: float
    vmaf_hmean: float
    vmaf_min: float
    vmaf_p1: float
    ssim: float

    @property
    def ratio(self) -> float:
        return self.out_size_bytes / self.clip_size_bytes

    @property
    def savings(self) -> float:
        return 1.0 - self.ratio

    @property
    def key(self) -> TrialKey:
        """Identity used to decide whether a stored trial can be reused."""
        return (
            self.clip,
            self.clip_size_bytes,
            self.crf,
            self.preset,
            self.vmaf_subsample,
            self.vmaf_model,
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Trial:
        try:
            return cls(**data)
        except TypeError as exc:
            raise ParseError(f"stored trial has unexpected fields: {exc}") from exc


@dataclass(frozen=True)
class Skipped:
    """A clip left out of the run, with the reason."""

    clip: str
    reason: str


@dataclass(frozen=True)
class Failure:
    """A clip, or one CRF of it, that could not be processed."""

    clip: str
    crf: int | None
    message: str
