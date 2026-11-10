"""Run ffmpeg and ffprobe, and check that the build has what the lab needs."""

from __future__ import annotations

import re
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from everkeep_lab.errors import ToolFailedError, ToolMissingError


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str


class Runner(Protocol):
    def __call__(self, cmd: Sequence[str], *, cwd: Path | None = None) -> CommandResult:
        """Run `cmd` and return its output; raise on a non-zero exit."""


def subprocess_runner(cmd: Sequence[str], *, cwd: Path | None = None) -> CommandResult:
    """The real runner. Arguments are passed as a list, never through a shell."""
    try:
        proc = subprocess.run(
            list(cmd),
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except FileNotFoundError as exc:
        raise ToolMissingError(f"{cmd[0]} was not found on PATH") from exc
    if proc.returncode != 0:
        raise ToolFailedError(cmd, proc.returncode, proc.stderr)
    return CommandResult(proc.stdout, proc.stderr)


@dataclass(frozen=True)
class Capabilities:
    ffmpeg_version: str
    has_libx265: bool
    has_libvmaf: bool

    @property
    def missing(self) -> list[str]:
        gaps = []
        if not self.has_libx265:
            gaps.append("libx265 encoder")
        if not self.has_libvmaf:
            gaps.append("libvmaf filter")
        return gaps


def check_capabilities(run: Runner) -> Capabilities:
    run(["ffprobe", "-hide_banner", "-version"])
    version_lines = run(["ffmpeg", "-hide_banner", "-version"]).stdout.splitlines()
    encoders = run(["ffmpeg", "-hide_banner", "-encoders"]).stdout
    filters = run(["ffmpeg", "-hide_banner", "-filters"]).stdout
    return Capabilities(
        ffmpeg_version=version_lines[0].strip() if version_lines else "unknown",
        has_libx265=re.search(r"\blibx265\b", encoders) is not None,
        has_libvmaf=re.search(r"\blibvmaf\b", filters) is not None,
    )


def require_capabilities(caps: Capabilities) -> None:
    if caps.missing:
        raise ToolMissingError(
            f"this ffmpeg build lacks: {', '.join(caps.missing)}; install a 'full' build"
        )
