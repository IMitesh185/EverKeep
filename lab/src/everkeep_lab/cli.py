"""Command line interface: doctor, exp0 run, exp0 report."""

from __future__ import annotations

import argparse
import logging
import sys
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from everkeep_lab import __version__
from everkeep_lab.config import PRESETS, Bar, RunSettings
from everkeep_lab.errors import LabError
from everkeep_lab.experiment import run_experiment
from everkeep_lab.report import format_report
from everkeep_lab.store import ResultStore, write_csv, write_manifest
from everkeep_lab.tools import Runner, check_capabilities, require_capabilities, subprocess_runner

EXIT_OK = 0
EXIT_TRIAL_FAILURES = 1
EXIT_ERROR = 2


def build_parser() -> argparse.ArgumentParser:
    defaults = RunSettings()
    parser = argparse.ArgumentParser(prog="everkeep-lab", description="Lab tooling for Everkeep.")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("doctor", help="check that ffmpeg has libx265 and libvmaf")

    exp0 = commands.add_parser("exp0", help="Experiment 0: how much smaller at the same quality")
    actions = exp0.add_subparsers(dest="action", required=True)

    run_cmd = actions.add_parser("run", help="encode each clip at a CRF ladder and score it")
    run_cmd.add_argument("--clips", type=Path, required=True, help="folder of source clips")
    run_cmd.add_argument("--out", type=Path, required=True, help="folder for results and encodes")
    run_cmd.add_argument("--crf", type=int, nargs="+", default=list(defaults.crfs))
    run_cmd.add_argument("--preset", choices=sorted(PRESETS), default=defaults.preset)
    run_cmd.add_argument(
        "--subsample", type=int, default=defaults.vmaf_subsample, help="score every Nth frame"
    )
    run_cmd.add_argument("--threads", type=int, default=defaults.threads)
    run_cmd.add_argument("--force", action="store_true", help="re-encode even if cached")

    report_cmd = actions.add_parser("report", help="reprint the report from stored results")
    report_cmd.add_argument("--out", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None, *, runner: Runner = subprocess_runner) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "doctor":
            return _doctor(runner)
        if args.action == "run":
            return _exp0_run(args, runner)
        return _exp0_report(args)
    except LabError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR


def _doctor(runner: Runner) -> int:
    caps = check_capabilities(runner)
    print(caps.ffmpeg_version)
    print(f"libx265: {'ok' if caps.has_libx265 else 'MISSING'}")
    print(f"libvmaf: {'ok' if caps.has_libvmaf else 'MISSING'}")
    return EXIT_ERROR if caps.missing else EXIT_OK


def _exp0_run(args: argparse.Namespace, runner: Runner) -> int:
    settings = RunSettings(
        crfs=tuple(dict.fromkeys(args.crf)),
        preset=args.preset,
        vmaf_subsample=args.subsample,
        threads=args.threads,
    )
    caps = check_capabilities(runner)
    require_capabilities(caps)
    args.out.mkdir(parents=True, exist_ok=True)
    store = ResultStore(args.out)
    bar = Bar()
    with _logging_to(args.out / "exp0.log"):
        outcome = run_experiment(
            args.clips, args.out, settings, run=runner, store=store, force=args.force
        )
    write_csv(outcome.trials, args.out / "results.csv")
    write_manifest(
        args.out / "manifest.json",
        capabilities=caps,
        settings=settings,
        bar=bar,
        clips=outcome.clips,
        skipped=outcome.skipped,
        generated_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
    )
    print(format_report(outcome.trials, bar, skipped=outcome.skipped, failures=outcome.failures))
    return EXIT_TRIAL_FAILURES if outcome.failures else EXIT_OK


def _exp0_report(args: argparse.Namespace) -> int:
    trials = ResultStore(args.out).latest()
    if not trials:
        raise LabError(f"no results found in {args.out}")
    write_csv(trials, args.out / "results.csv")
    print(format_report(trials, Bar()))
    return EXIT_OK


@contextmanager
def _logging_to(path: Path) -> Iterator[None]:
    logger = logging.getLogger("everkeep_lab")
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    handlers: list[logging.Handler] = [
        logging.StreamHandler(),
        logging.FileHandler(path, encoding="utf-8"),
    ]
    previous_level = logger.level
    logger.setLevel(logging.INFO)
    for handler in handlers:
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    try:
        yield
    finally:
        for handler in handlers:
            logger.removeHandler(handler)
            handler.close()
        logger.setLevel(previous_level)
