"""Tests for the ffmpeg runner and the capability checks."""

from __future__ import annotations

import sys

import pytest

from everkeep_lab.errors import ToolFailedError, ToolMissingError
from everkeep_lab.tools import check_capabilities, require_capabilities, subprocess_runner
from tests.fakes import FakeToolchain


def test_check_capabilities_reads_version_and_features() -> None:
    caps = check_capabilities(FakeToolchain())
    assert caps.ffmpeg_version.startswith("ffmpeg version fake-7.1")
    assert caps.has_libx265
    assert caps.has_libvmaf
    assert caps.missing == []


@pytest.mark.parametrize(
    ("has_libx265", "has_libvmaf", "missing"),
    [(False, True, "libx265"), (True, False, "libvmaf")],
)
def test_require_capabilities_names_what_is_missing(
    has_libx265: bool, has_libvmaf: bool, missing: str
) -> None:
    caps = check_capabilities(FakeToolchain(has_libx265=has_libx265, has_libvmaf=has_libvmaf))
    with pytest.raises(ToolMissingError, match=missing):
        require_capabilities(caps)


def test_runner_reports_a_missing_binary() -> None:
    with pytest.raises(ToolMissingError):
        subprocess_runner(["definitely-not-a-real-tool-xyz"])


def test_runner_raises_with_exit_code_and_stderr() -> None:
    code = "import sys; sys.stderr.write('boom'); sys.exit(3)"
    with pytest.raises(ToolFailedError) as info:
        subprocess_runner([sys.executable, "-c", code])
    assert info.value.returncode == 3
    assert "boom" in info.value.stderr_tail


def test_runner_captures_stdout() -> None:
    result = subprocess_runner([sys.executable, "-c", "print('hi')"])
    assert result.stdout.strip() == "hi"
