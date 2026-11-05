"""Typed release errors with stable, machine-readable codes."""

from __future__ import annotations

from typing import Any


class ReleaseError(Exception):
    """A release rule was violated.

    ``code`` is stable and safe to show in workflow annotations. ``message``
    describes the blocked action without including credentials or request
    bodies.
    """

    def __init__(self, code: str, message: str, *, details: dict[str, Any] | None = None):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.details = details or {}

    def to_dict(self) -> dict[str, Any]:
        return {"status": "error", "code": self.code, "message": self.message, "details": self.details}


class MergeConflict(ReleaseError):
    """A local git merge could not be completed."""

    def __init__(self, message: str, *, details: dict[str, Any] | None = None):
        super().__init__("merge_conflict", message, details=details)


class GitHubConflict(ReleaseError):
    """The GitHub merge API reported a conflict or an unmergeable branch."""

    def __init__(self, message: str, *, status: int, details: dict[str, Any] | None = None):
        super().__init__("github_merge_conflict", message, details={"status": status, **(details or {})})
        self.status = status
