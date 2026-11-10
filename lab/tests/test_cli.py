"""Tests for the command line interface, using the fake toolchain."""

from __future__ import annotations

from pathlib import Path

import pytest

from everkeep_lab import __version__
from everkeep_lab.cli import EXIT_ERROR, EXIT_OK, EXIT_TRIAL_FAILURES, main
from everkeep_lab.store import ResultStore
from tests.fakes import FakeToolchain, make_trial


def test_doctor_reports_a_healthy_toolchain(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["doctor"], runner=FakeToolchain()) == EXIT_OK
    assert "libvmaf: ok" in capsys.readouterr().out


def test_doctor_fails_when_libvmaf_is_missing(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["doctor"], runner=FakeToolchain(has_libvmaf=False)) == EXIT_ERROR
    assert "libvmaf: MISSING" in capsys.readouterr().out


def test_run_refuses_a_build_without_the_needed_features(
    clips_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = ["exp0", "run", "--clips", str(clips_dir), "--out", str(tmp_path / "out")]
    assert main(argv, runner=FakeToolchain(has_libvmaf=False)) == EXIT_ERROR
    assert "libvmaf" in capsys.readouterr().err


def test_run_writes_every_artifact(
    toolchain: FakeToolchain,
    clips_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    out = tmp_path / "out"
    argv = ["exp0", "run", "--clips", str(clips_dir), "--out", str(out)]
    assert main(argv, runner=toolchain) == EXIT_OK
    for name in ("results.jsonl", "results.csv", "manifest.json", "exp0.log"):
        assert (out / name).exists(), name
    assert "BAR CLEARED" in capsys.readouterr().out


def test_run_exit_code_flags_failed_trials(
    toolchain: FakeToolchain, clips_dir: Path, tmp_path: Path
) -> None:
    toolchain.fail_crfs = {24}
    argv = ["exp0", "run", "--clips", str(clips_dir), "--out", str(tmp_path / "out")]
    assert main(argv, runner=toolchain) == EXIT_TRIAL_FAILURES


def test_report_regenerates_from_stored_results(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    store = ResultStore(tmp_path)
    store.append(make_trial("a.mov", crf=24, ratio=0.4))
    assert main(["exp0", "report", "--out", str(tmp_path)]) == EXIT_OK
    assert "BAR CLEARED" in capsys.readouterr().out
    assert (tmp_path / "results.csv").exists()


def test_report_without_results_is_an_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main(["exp0", "report", "--out", str(tmp_path)]) == EXIT_ERROR
    assert "no results" in capsys.readouterr().err


def test_version_flag(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as info:
        main(["--version"])
    assert info.value.code == 0
    assert __version__ in capsys.readouterr().out
