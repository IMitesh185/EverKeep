"""Plain-text report for Experiment 0."""

from __future__ import annotations

from collections.abc import Sequence

from everkeep_lab.analysis import evaluate
from everkeep_lab.config import Bar
from everkeep_lab.model import Failure, Skipped, Trial


def _first_line(message: str) -> str:
    return message.splitlines()[0] if message else ""


def format_report(
    trials: Sequence[Trial],
    bar: Bar,
    *,
    skipped: Sequence[Skipped] = (),
    failures: Sequence[Failure] = (),
) -> str:
    verdict = evaluate(trials, bar)
    lines = ["clip | input Mbps | smallest passing CRF | saved | VMAF mean | VMAF p1 | SSIM"]
    for clip in verdict.clips:
        best = verdict.best.get(clip)
        if best is None:
            lines.append(f"{clip} | no CRF reached VMAF {bar.min_vmaf_mean:.0f}; add lower CRFs")
        else:
            lines.append(
                f"{clip} | {best.in_mbps} | {best.crf} | {best.savings:.0%} | "
                f"{best.vmaf_mean:.1f} | {best.vmaf_p1:.1f} | {best.ssim:.4f}"
            )
    lines.extend(f"{item.clip} | skipped: {item.reason}" for item in skipped)
    for failure in failures:
        where = "probe" if failure.crf is None else f"CRF {failure.crf}"
        lines.append(f"{failure.clip} | {where} failed: {_first_line(failure.message)}")
    lines.append("")
    lines.append(
        f"clips with >= {bar.min_savings:.0%} saved at VMAF >= {bar.min_vmaf_mean:.0f}: "
        f"{len(verdict.winners)} of {len(verdict.clips)} (need {verdict.needed})"
    )
    lines.append(
        "BAR CLEARED: continue to the iOS spikes"
        if verdict.cleared
        else "BAR NOT CLEARED: stop and rethink before spending CI minutes"
    )
    return "\n".join(lines)
