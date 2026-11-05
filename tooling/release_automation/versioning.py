"""Calendar version rules shared by candidate preparation and publishing."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .errors import ReleaseError

# Canonical numeric spelling only: no leading zeroes, month 1-12, patch >= 0.
VERSION_PATTERN = re.compile(r"^(?P<year>[0-9]{4})\.(?P<month>[1-9]|1[0-2])\.(?P<patch>0|[1-9][0-9]*)$")
TAG_PATTERN = re.compile(r"^v?(?P<version>[0-9]{4}\.(?:[1-9]|1[0-2])\.(?:0|[1-9][0-9]*))$")
MIX_VERSION_PATTERN = re.compile(r'(?m)^(?P<prefix>\s*version:\s*")[^"]+(?P<suffix>")')

# America/Regina has observed UTC-06:00 year round since 1966 (no DST). The
# fixed fallback keeps the calculation deterministic on hosts without an IANA
# database, such as a bare Windows Python install.
REGINA_FIXED_OFFSET = timezone(timedelta(hours=-6), "America/Regina")


def release_timezone():
    try:
        return ZoneInfo("America/Regina")
    except ZoneInfoNotFoundError:
        return REGINA_FIXED_OFFSET


@dataclass(frozen=True, order=True)
class Version:
    year: int
    month: int
    patch: int

    @property
    def canonical(self) -> str:
        return f"{self.year}.{self.month}.{self.patch}"

    def tag(self, prefix: str = "v") -> str:
        return f"{prefix}{self.canonical}" if prefix else self.canonical

    def to_dict(self) -> dict[str, int]:
        return {"year": self.year, "month": self.month, "patch": self.patch}


def parse_version(value: str, *, context: str = "version") -> Version:
    if not isinstance(value, str):
        raise ReleaseError("invalid_version", f"{context} must be a string")
    match = VERSION_PATTERN.fullmatch(value.strip())
    if not match:
        raise ReleaseError(
            "invalid_version",
            f"{context} must use canonical YEAR.MONTH.PATCH spelling (for example 2026.11.0); got {value!r}",
        )
    version = Version(int(match.group("year")), int(match.group("month")), int(match.group("patch")))
    # Defensive: the regex already enforces these, but keep the invariant local.
    if not (1 <= version.month <= 12) or version.patch < 0:
        raise ReleaseError("invalid_version", f"{context} is outside the supported calendar range")
    return version


def parse_tag(tag: str) -> Version | None:
    """Return a calendar version for a release tag, or None for unrelated tags."""
    if not isinstance(tag, str):
        return None
    match = TAG_PATTERN.fullmatch(tag.strip())
    if not match:
        return None
    return parse_version(match.group("version"), context=f"tag {tag!r}")


def normalize_clock(value: datetime | str | None) -> datetime:
    """Normalize an injected clock to America/Regina.

    Naive timestamps are treated as UTC so tests and workflow payloads are
    unambiguous.
    """
    if value is None:
        value = datetime.now(timezone.utc)
    elif isinstance(value, str):
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            value = datetime.fromisoformat(text)
        except ValueError as exc:
            raise ReleaseError("invalid_clock", f"clock must be an ISO-8601 timestamp; got {value!r}") from exc
    if not isinstance(value, datetime):
        raise ReleaseError("invalid_clock", "clock must be a datetime or ISO-8601 string")
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(release_timezone())


def release_parts(release: dict[str, Any]) -> Version | None:
    """Extract a calendar version from a GitHub release object."""
    return parse_tag(release.get("tag_name", ""))


def stable_releases(releases: Iterable[dict[str, Any]]) -> list[tuple[Version, dict[str, Any]]]:
    found: list[tuple[Version, dict[str, Any]]] = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        version = release_parts(release)
        if version is not None:
            found.append((version, release))
    return found


def highest_stable_release(releases: Iterable[dict[str, Any]]) -> tuple[Version, dict[str, Any]] | None:
    found = stable_releases(releases)
    if not found:
        return None
    # Highest version wins. If two releases claim the same version, preparation
    # treats that as a duplicate tag/release collision.
    return max(found, key=lambda item: (item[0], str(item[1].get("published_at") or "")))


def duplicate_release_versions(releases: Iterable[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for version, _release in stable_releases(releases):
        counts[version.canonical] = counts.get(version.canonical, 0) + 1
    return {version: count for version, count in counts.items() if count > 1}


def calculate_next_version(
    now: datetime | str | None,
    baseline: Version | None,
    *,
    override: str | None = None,
    bootstrap: str | None = None,
) -> Version:
    """Calculate the next stable calendar version.

    Rules:
    - Same year and month as the published baseline: increment patch.
    - Later month or year: reset patch to zero.
    - A date before the baseline month is an error.
    - An explicit override must be canonical and strictly newer than baseline.
    - No baseline requires an explicit bootstrap version.
    """
    local_now = normalize_clock(now)

    if baseline is None:
        if override and not bootstrap:
            raise ReleaseError(
                "missing_baseline",
                "no published stable release exists; pass an explicit bootstrap version",
            )
        if not bootstrap:
            raise ReleaseError(
                "missing_baseline",
                "no published stable release exists; pass an explicit bootstrap version",
            )
        return parse_version(bootstrap, context="bootstrap version")

    if override is not None:
        candidate = parse_version(override, context="version override")
        if candidate <= baseline:
            raise ReleaseError(
                "override_not_newer",
                f"version override {candidate.canonical} must be strictly newer than baseline {baseline.canonical}",
            )
        return candidate

    if (local_now.year, local_now.month) < (baseline.year, baseline.month):
        raise ReleaseError(
            "clock_before_latest_release",
            f"release date {local_now.date()} is earlier than the latest release month {baseline.canonical}",
        )

    if (local_now.year, local_now.month) == (baseline.year, baseline.month):
        return Version(baseline.year, baseline.month, baseline.patch + 1)

    return Version(local_now.year, local_now.month, 0)


def extract_mix_version(text: str) -> str | None:
    match = MIX_VERSION_PATTERN.search(text)
    return match.group(0).split('"', 2)[1] if match else None


def update_mix_version(text: str, version: str | Version) -> str:
    """Update the first canonical ``version: "..."`` entry in mix.exs.

    This matches the format used by ``tooling/version_bump.sh`` so both helpers
    remain interchangeable.
    """
    canonical = version.canonical if isinstance(version, Version) else parse_version(version).canonical
    updated, count = MIX_VERSION_PATTERN.subn(
        lambda match: f'{match.group("prefix")}{canonical}{match.group("suffix")}',
        text,
        count=1,
    )
    if count != 1:
        raise ReleaseError("mix_version_missing", 'mix.exs does not contain a version: "..." entry')
    return updated


def version_from_tag(tag: str, *, context: str = "tag") -> Version:
    version = parse_tag(tag)
    if version is None:
        raise ReleaseError("invalid_tag", f"{context} must look like vYYYY.MM.PATCH; got {tag!r}")
    return version


def compare_versions(left: Version, right: Version) -> int:
    return (left > right) - (left < right)
