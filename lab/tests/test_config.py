"""Tests for the pre-registered bar and the run settings."""

from __future__ import annotations

from typing import Any

import pytest

from everkeep_lab.config import Bar, RunSettings
from everkeep_lab.errors import ConfigError


def test_bar_matches_the_registered_values() -> None:
    registered = Bar(
        min_vmaf_mean=95.0, min_savings=0.30, min_clip_share=0.75, registered_on="2026-11-06"
    )
    assert Bar() == registered


def test_default_settings_are_valid() -> None:
    assert RunSettings().crfs == (20, 24, 28, 32)


@pytest.mark.parametrize(
    "kwargs",
    [
        {"crfs": ()},
        {"crfs": (52,)},
        {"crfs": (-1,)},
        {"preset": "bogus"},
        {"vmaf_subsample": 0},
        {"threads": 0},
    ],
)
def test_invalid_settings_are_rejected(kwargs: dict[str, Any]) -> None:
    with pytest.raises(ConfigError):
        RunSettings(**kwargs)
