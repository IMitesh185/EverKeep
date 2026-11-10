"""Shared fixtures."""

from __future__ import annotations

from pathlib import Path

import pytest

from tests.fakes import FakeToolchain, make_clips, probe_payload


@pytest.fixture
def toolchain() -> FakeToolchain:
    fake = FakeToolchain()
    fake.probes = {"a.mov": probe_payload(), "b.mov": probe_payload()}
    return fake


@pytest.fixture
def clips_dir(tmp_path: Path) -> Path:
    folder = tmp_path / "clips"
    make_clips(folder, ["a.mov", "b.mov"])
    return folder
