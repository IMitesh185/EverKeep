"""Tests for applying the pre-registered bar."""

from __future__ import annotations

import pytest

from everkeep_lab.analysis import best_per_clip, evaluate
from everkeep_lab.config import Bar
from tests.fakes import make_trial

BAR = Bar()


def test_clears_when_enough_clips_save_enough() -> None:
    trials = [make_trial(f"c{i}.mov", ratio=r) for i, r in enumerate((0.5, 0.6, 0.65, 0.9))]
    verdict = evaluate(trials, BAR)
    assert verdict.cleared
    assert verdict.needed == 3
    assert verdict.winners == ("c0.mov", "c1.mov", "c2.mov")


def test_fails_when_too_few_clips_clear() -> None:
    trials = [make_trial(f"c{i}.mov", ratio=r) for i, r in enumerate((0.5, 0.6, 0.8, 0.9))]
    assert not evaluate(trials, BAR).cleared


@pytest.mark.parametrize(("vmaf", "passes"), [(95.0, True), (94.99, False)])
def test_vmaf_threshold_is_inclusive(vmaf: float, passes: bool) -> None:
    assert bool(best_per_clip([make_trial(vmaf=vmaf)], BAR)) is passes


@pytest.mark.parametrize(("ratio", "wins"), [(0.70, True), (0.71, False)])
def test_savings_threshold_is_inclusive(ratio: float, wins: bool) -> None:
    verdict = evaluate([make_trial(ratio=ratio)], BAR)
    assert (len(verdict.winners) == 1) is wins


def test_picks_the_smallest_passing_output_not_the_lowest_crf() -> None:
    trials = [
        make_trial(crf=20, ratio=0.6, vmaf=98.0),
        make_trial(crf=24, ratio=0.4, vmaf=96.0),
        make_trial(crf=28, ratio=0.3, vmaf=94.0),
    ]
    assert best_per_clip(trials, BAR)["a.mov"].crf == 24


@pytest.mark.parametrize(("clips", "needed"), [(1, 1), (2, 2), (3, 3), (4, 3), (5, 4), (8, 6)])
def test_clip_share_rounds_up(clips: int, needed: int) -> None:
    trials = [make_trial(f"c{i}.mov") for i in range(clips)]
    assert evaluate(trials, BAR).needed == needed


def test_no_trials_never_clears() -> None:
    verdict = evaluate([], BAR)
    assert not verdict.cleared
    assert verdict.needed == 1
