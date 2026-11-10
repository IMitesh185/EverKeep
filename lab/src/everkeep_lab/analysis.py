"""Apply the pre-registered bar to measured trials."""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from everkeep_lab.config import Bar
from everkeep_lab.model import Trial


@dataclass(frozen=True)
class Verdict:
    cleared: bool
    clips: tuple[str, ...]
    winners: tuple[str, ...]
    needed: int
    best: dict[str, Trial]


def best_per_clip(trials: Iterable[Trial], bar: Bar) -> dict[str, Trial]:
    """The smallest output per clip that still clears the VMAF bar."""
    best: dict[str, Trial] = {}
    for trial in trials:
        if trial.vmaf_mean < bar.min_vmaf_mean:
            continue
        current = best.get(trial.clip)
        if current is None or trial.ratio < current.ratio:
            best[trial.clip] = trial
    return best


def evaluate(trials: Sequence[Trial], bar: Bar) -> Verdict:
    clips = tuple(sorted({trial.clip for trial in trials}))
    best = best_per_clip(trials, bar)
    winners = tuple(
        clip for clip in clips if clip in best and best[clip].savings >= bar.min_savings
    )
    needed = max(1, math.ceil(bar.min_clip_share * len(clips)))
    return Verdict(
        cleared=len(winners) >= needed, clips=clips, winners=winners, needed=needed, best=best
    )
