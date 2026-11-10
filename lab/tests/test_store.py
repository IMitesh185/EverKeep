"""Tests for result storage, CSV export and the manifest."""

from __future__ import annotations

import csv
import json
import logging
from pathlib import Path

import pytest

from everkeep_lab.config import Bar, RunSettings
from everkeep_lab.errors import ParseError
from everkeep_lab.store import ResultStore, write_csv, write_manifest
from everkeep_lab.tools import Capabilities
from tests.fakes import make_trial


def test_load_without_a_file_is_empty(tmp_path: Path) -> None:
    assert ResultStore(tmp_path).load() == []


def test_append_then_load_round_trips(tmp_path: Path) -> None:
    store = ResultStore(tmp_path)
    trial = make_trial()
    store.append(trial)
    assert store.load() == [trial]


def test_latest_keeps_the_newest_record_per_key(tmp_path: Path) -> None:
    store = ResultStore(tmp_path)
    store.append(make_trial(ratio=0.5))
    newer = make_trial(ratio=0.4)
    store.append(newer)
    assert store.latest() == [newer]


def test_truncated_last_line_is_ignored(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    store = ResultStore(tmp_path)
    store.append(make_trial())
    with store.path.open("a", encoding="utf-8") as handle:
        handle.write('{"clip": "a.mov", "cl')
    with caplog.at_level(logging.WARNING):
        trials = store.load()
    assert len(trials) == 1
    assert "truncated" in caplog.text


def test_malformed_middle_line_raises(tmp_path: Path) -> None:
    store = ResultStore(tmp_path)
    store.path.write_text("garbage\n" + json.dumps(make_trial().to_dict()) + "\n", encoding="utf-8")
    with pytest.raises(ParseError, match="line 1"):
        store.load()


def test_csv_has_derived_columns_and_sorted_rows(tmp_path: Path) -> None:
    path = tmp_path / "results.csv"
    write_csv(
        [make_trial("b.mov", crf=24), make_trial("a.mov", crf=28), make_trial("a.mov", crf=20)],
        path,
    )
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert [(row["clip"], row["crf"]) for row in rows] == [
        ("a.mov", "20"),
        ("a.mov", "28"),
        ("b.mov", "24"),
    ]
    assert {"ratio", "savings"} <= set(rows[0])


def test_manifest_records_the_environment_and_the_bar(tmp_path: Path) -> None:
    path = tmp_path / "manifest.json"
    write_manifest(
        path,
        capabilities=Capabilities("ffmpeg version fake", has_libx265=True, has_libvmaf=True),
        settings=RunSettings(),
        bar=Bar(),
        clips=[],
        skipped=[],
        generated_at="2026-11-06T00:00:00+00:00",
    )
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["bar"]["min_vmaf_mean"] == 95.0
    assert data["capabilities"]["has_libvmaf"] is True
    assert data["settings"]["crfs"] == [20, 24, 28, 32]
    assert data["generated_at"] == "2026-11-06T00:00:00+00:00"
