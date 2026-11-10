"""Experiment 0: encode each clip at a CRF ladder and score every result."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

from everkeep_lab.config import VIDEO_SUFFIXES, RunSettings
from everkeep_lab.encode import encode_x265
from everkeep_lab.errors import LabError
from everkeep_lab.model import ClipInfo, Failure, Skipped, Trial, TrialKey
from everkeep_lab.probe import probe_clip
from everkeep_lab.quality import measure, vmaf_model_for
from everkeep_lab.store import ResultStore
from everkeep_lab.tools import Runner

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class RunOutcome:
    trials: tuple[Trial, ...]
    clips: tuple[ClipInfo, ...]
    skipped: tuple[Skipped, ...]
    failures: tuple[Failure, ...]


def discover_clips(clips_dir: Path) -> list[Path]:
    if not clips_dir.is_dir():
        raise LabError(f"clips folder not found: {clips_dir}")
    found = sorted(
        path
        for path in clips_dir.iterdir()
        if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES
    )
    if not found:
        raise LabError(f"no video files ({', '.join(sorted(VIDEO_SUFFIXES))}) in {clips_dir}")
    return found


def run_experiment(
    clips_dir: Path,
    out_dir: Path,
    settings: RunSettings,
    *,
    run: Runner,
    store: ResultStore,
    force: bool = False,
) -> RunOutcome:
    """Run every clip at every CRF. One failing clip or trial never stops the rest."""
    refs = discover_clips(clips_dir)
    cache: dict[TrialKey, Trial] = {} if force else {trial.key: trial for trial in store.load()}
    trials: list[Trial] = []
    clips: list[ClipInfo] = []
    skipped: list[Skipped] = []
    failures: list[Failure] = []

    for ref in refs:
        try:
            info = probe_clip(ref, run)
        except LabError as exc:
            log.error("failed to probe %s: %s", ref.name, exc)
            failures.append(Failure(ref.name, None, str(exc)))
            continue
        if info.hdr:
            log.warning(
                "skipping %s: HDR (VMAF is trained on SDR); re-shoot with HDR Video off", ref.name
            )
            skipped.append(Skipped(ref.name, "HDR: VMAF is trained on SDR"))
            continue
        clips.append(info)
        model = vmaf_model_for(info.long_side)
        for crf in settings.crfs:
            key: TrialKey = (
                info.name,
                info.size_bytes,
                crf,
                settings.preset,
                settings.vmaf_subsample,
                model,
            )
            cached = cache.get(key)
            if cached is not None:
                log.info("cached: %s crf %d", ref.name, crf)
                trials.append(cached)
                continue
            try:
                trial = _run_trial(ref, info, crf, model, settings, out_dir / "encodes", run)
            except LabError as exc:
                log.error("failed: %s crf %d: %s", ref.name, crf, exc)
                failures.append(Failure(ref.name, crf, str(exc)))
                continue
            store.append(trial)
            trials.append(trial)
            log.info(
                "done: %s crf %d -> %.0f%% saved, VMAF %.1f",
                ref.name,
                crf,
                trial.savings * 100,
                trial.vmaf_mean,
            )

    return RunOutcome(tuple(trials), tuple(clips), tuple(skipped), tuple(failures))


def _run_trial(
    ref: Path,
    info: ClipInfo,
    crf: int,
    model: str,
    settings: RunSettings,
    encodes_dir: Path,
    run: Runner,
) -> Trial:
    dist = encodes_dir / f"{ref.stem}_crf{crf}_{settings.preset}.mov"
    seconds = encode_x265(ref, dist, crf=crf, preset=settings.preset, run=run)
    scores = measure(
        dist, ref, info, subsample=settings.vmaf_subsample, threads=settings.threads, run=run
    )
    return Trial(
        clip=info.name,
        clip_size_bytes=info.size_bytes,
        in_codec=info.codec,
        in_resolution=info.resolution,
        in_fps=info.fps,
        in_mbps=info.mbps,
        crf=crf,
        preset=settings.preset,
        vmaf_model=model,
        vmaf_subsample=settings.vmaf_subsample,
        out_size_bytes=dist.stat().st_size,
        encode_seconds=round(seconds, 1),
        vmaf_mean=round(scores.vmaf_mean, 2),
        vmaf_hmean=round(scores.vmaf_hmean, 2),
        vmaf_min=round(scores.vmaf_min, 2),
        vmaf_p1=round(scores.vmaf_p1, 2),
        ssim=round(scores.ssim, 4),
    )
