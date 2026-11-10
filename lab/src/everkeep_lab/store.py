"""Append-only result storage (JSON lines), CSV export and the run manifest."""

from __future__ import annotations

import csv
import dataclasses
import json
import logging
import os
from collections.abc import Sequence
from dataclasses import asdict
from pathlib import Path

from everkeep_lab import __version__
from everkeep_lab.config import Bar, RunSettings
from everkeep_lab.errors import ParseError
from everkeep_lab.model import ClipInfo, Skipped, Trial
from everkeep_lab.tools import Capabilities

log = logging.getLogger(__name__)

RESULTS_FILE = "results.jsonl"


class ResultStore:
    """One JSON object per line. A re-run appends; the newest record per key wins."""

    def __init__(self, out_dir: Path) -> None:
        self.out_dir = out_dir
        self.path = out_dir / RESULTS_FILE

    def load(self) -> list[Trial]:
        if not self.path.exists():
            return []
        lines = [
            line for line in self.path.read_text(encoding="utf-8").splitlines() if line.strip()
        ]
        trials: list[Trial] = []
        for index, line in enumerate(lines):
            try:
                trials.append(Trial.from_dict(json.loads(line)))
            except (ValueError, ParseError) as exc:
                if index == len(lines) - 1:
                    log.warning("ignoring truncated last line in %s", self.path)
                    break
                raise ParseError(f"{self.path}: line {index + 1} is malformed: {exc}") from exc
        return trials

    def latest(self) -> list[Trial]:
        newest = {trial.key: trial for trial in self.load()}
        return sorted(newest.values(), key=lambda trial: (trial.clip, trial.crf))

    def append(self, trial: Trial) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(trial.to_dict(), sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())


def write_csv(trials: Sequence[Trial], path: Path) -> None:
    derived = ["ratio", "savings"]
    fieldnames = [field.name for field in dataclasses.fields(Trial)] + derived
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for trial in sorted(trials, key=lambda t: (t.clip, t.crf)):
            row = trial.to_dict()
            row["ratio"] = round(trial.ratio, 4)
            row["savings"] = round(trial.savings, 4)
            writer.writerow(row)


def write_manifest(
    path: Path,
    *,
    capabilities: Capabilities,
    settings: RunSettings,
    bar: Bar,
    clips: Sequence[ClipInfo],
    skipped: Sequence[Skipped],
    generated_at: str,
) -> None:
    payload = {
        "generated_at": generated_at,
        "tool_version": __version__,
        "capabilities": asdict(capabilities),
        "settings": asdict(settings),
        "bar": asdict(bar),
        "clips": [asdict(clip) for clip in clips],
        "skipped": [asdict(item) for item in skipped],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
