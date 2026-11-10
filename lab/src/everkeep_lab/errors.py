"""Exception types for expected, user-reportable failures."""

from __future__ import annotations

from collections.abc import Sequence


class LabError(Exception):
    """Base class for failures the CLI reports without a traceback."""


class ConfigError(LabError):
    """Invalid settings."""


class ToolMissingError(LabError):
    """A required external tool or capability is not available."""


class ToolFailedError(LabError):
    """An external tool exited with a non-zero status."""

    def __init__(self, cmd: Sequence[str], returncode: int, stderr: str) -> None:
        self.cmd = list(cmd)
        self.returncode = returncode
        self.stderr_tail = stderr[-1500:].strip()
        super().__init__(f"{self.cmd[0]} exited {returncode}: {self.stderr_tail}")


class ParseError(LabError):
    """Tool output or stored data did not have the expected shape."""
