"""Tests for the data records."""

from __future__ import annotations

import pytest

from everkeep_lab.errors import ParseError
from everkeep_lab.model import Trial
from tests.fakes import make_trial


def test_ratio_and_savings() -> None:
    trial = make_trial(ratio=0.25)
    assert trial.ratio == pytest.approx(0.25)
    assert trial.savings == pytest.approx(0.75)


def test_round_trips_through_a_dict() -> None:
    trial = make_trial()
    assert Trial.from_dict(trial.to_dict()) == trial


def test_unknown_fields_are_rejected() -> None:
    data = make_trial().to_dict()
    data["surprise"] = 1
    with pytest.raises(ParseError):
        Trial.from_dict(data)


def test_key_ignores_the_scores() -> None:
    assert make_trial(vmaf=90.0).key == make_trial(vmaf=99.0).key
