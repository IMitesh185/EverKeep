"""Tests for the Experiment 0 orchestration, using the fake toolchain."""

from __future__ import annotations

from pathlib import Path

import pytest

from everkeep_lab.analysis import evaluate
from everkeep_lab.config import Bar, RunSettings
from everkeep_lab.errors import LabError
from everkeep_lab.experiment import run_experiment
from everkeep_lab.store import ResultStore
from tests.fakes import FakeToolchain, probe_payload

SETTINGS = RunSettings()


def test_runs_every_clip_at_every_crf(
    toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path
) -> None:
    out = tmp_path / "out"
    store = ResultStore(out)
    outcome = run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=store)
    assert len(outcome.trials) == 8
    assert not outcome.failures
    assert not outcome.skipped
    assert len(store.load()) == 8
    verdict = evaluate(outcome.trials, Bar())
    assert verdict.cleared
    assert verdict.best["a.mov"].crf == 24


def test_a_second_run_uses_the_cache(
    toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path
) -> None:
    out = tmp_path / "out"
    store = ResultStore(out)
    run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=store)
    again = run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=store)
    assert len(again.trials) == 8
    assert len(toolchain.encodes()) == 8


def test_force_re_encodes(toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path) -> None:
    out = tmp_path / "out"
    store = ResultStore(out)
    run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=store)
    run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=store, force=True)
    assert len(toolchain.encodes()) == 16
    assert len(store.latest()) == 8


def test_hdr_clips_are_skipped(toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path) -> None:
    toolchain.probes["b.mov"] = probe_payload(transfer="arib-std-b67")
    out = tmp_path / "out"
    outcome = run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=ResultStore(out))
    assert [item.clip for item in outcome.skipped] == ["b.mov"]
    assert {trial.clip for trial in outcome.trials} == {"a.mov"}


def test_a_failed_trial_does_not_stop_the_run(
    toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path
) -> None:
    toolchain.fail_crfs = {24}
    out = tmp_path / "out"
    store = ResultStore(out)
    outcome = run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=store)
    assert [failure.crf for failure in outcome.failures] == [24, 24]
    assert len(outcome.trials) == 6
    assert len(store.load()) == 6


def test_a_clip_that_cannot_be_probed_is_recorded_not_fatal(
    toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path
) -> None:
    del toolchain.probes["b.mov"]
    out = tmp_path / "out"
    outcome = run_experiment(clips_dir, out, SETTINGS, run=toolchain, store=ResultStore(out))
    assert [(failure.clip, failure.crf) for failure in outcome.failures] == [("b.mov", None)]
    assert {trial.clip for trial in outcome.trials} == {"a.mov"}


def test_missing_clips_folder_is_an_error(toolchain: FakeToolchain, tmp_path: Path) -> None:
    out = tmp_path / "out"
    with pytest.raises(LabError, match="not found"):
        run_experiment(tmp_path / "nope", out, SETTINGS, run=toolchain, store=ResultStore(out))


def test_empty_clips_folder_is_an_error(toolchain: FakeToolchain, tmp_path: Path) -> None:
    empty = tmp_path / "empty"
    empty.mkdir()
    out = tmp_path / "out"
    with pytest.raises(LabError, match="no video files"):
        run_experiment(empty, out, SETTINGS, run=toolchain, store=ResultStore(out))
