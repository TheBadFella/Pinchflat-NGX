"""Container manifest verification for the stable publisher."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from typing import Any, Iterable

from .errors import ReleaseError

DIGEST_PATTERN = re.compile(r"Digest:\s*(sha256:[0-9a-f]{64})")
PLATFORM_PATTERN = re.compile(r"Platform:\s*([^\s\r\n]+)")

REQUIRED_ARCHITECTURES: tuple[str, ...] = ("linux/amd64", "linux/arm64")


@dataclass(frozen=True)
class ManifestInfo:
    digest: str
    platforms: tuple[str, ...] = ()


class DockerRegistryClient:
    """Resolve image tags and platforms with ``docker buildx imagetools``.

    This runs on the release runner after the publisher finishes and never
    modifies registry state.
    """

    def __init__(self, *, timeout: int = 120):
        self.timeout = timeout

    def inspect(self, image: str, tag: str) -> ManifestInfo:
        reference = f"{image}:{tag}"
        completed = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", reference],
            text=True,
            capture_output=True,
            timeout=self.timeout,
            shell=False,
        )
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "")[-1500:]
            raise ReleaseError(
                "registry_tag_missing",
                f"container tag {reference} could not be inspected",
                details={"stderr": detail},
            )
        digest_match = DIGEST_PATTERN.search(completed.stdout)
        if not digest_match:
            raise ReleaseError(
                "registry_digest_missing",
                f"container tag {reference} did not report a manifest digest",
            )
        platforms = tuple(sorted(set(PLATFORM_PATTERN.findall(completed.stdout))))
        return ManifestInfo(digest=digest_match.group(1), platforms=platforms)


def required_stable_tags(version_tag: str) -> list[str]:
    return [version_tag, f"{version_tag}-postgres", "latest", "latest-postgres"]


def verify_stable_manifests(
    registry: Any,
    image: str,
    version_tag: str,
    *,
    required_platforms: Iterable[str] = REQUIRED_ARCHITECTURES,
) -> dict[str, str]:
    if registry is None:
        raise ReleaseError("registry_verification_required", "no container registry client was configured")

    required_arch_set = tuple(required_platforms)
    manifests: dict[str, ManifestInfo] = {}

    for tag in required_stable_tags(version_tag):
        info = registry.inspect(image, tag)
        if not isinstance(info, ManifestInfo) or not info.digest.startswith("sha256:"):
            raise ReleaseError("registry_digest_invalid", f"invalid digest for {image}:{tag}")

        # Check required multi-arch platforms
        missing_arch = [arch for arch in required_arch_set if arch not in info.platforms]
        if missing_arch:
            raise ReleaseError(
                "registry_architecture_missing",
                f"container tag {image}:{tag} is missing required architecture(s): {', '.join(missing_arch)}",
                details={"tag": tag, "platforms": list(info.platforms), "missing": missing_arch},
            )
        manifests[tag] = info

    # Check digest equality between release version tag and moving latest tag
    # 1. SQLite: version tag must match latest
    if manifests[version_tag].digest != manifests["latest"].digest:
        raise ReleaseError(
            "registry_digest_mismatch",
            f"SQLite version tag {version_tag} digest {manifests[version_tag].digest} "
            f"does not match 'latest' digest {manifests['latest'].digest}",
            details={"version_digest": manifests[version_tag].digest, "latest_digest": manifests["latest"].digest},
        )

    # 2. PostgreSQL: version tag must match latest-postgres
    pg_version_tag = f"{version_tag}-postgres"
    if manifests[pg_version_tag].digest != manifests["latest-postgres"].digest:
        raise ReleaseError(
            "registry_digest_mismatch",
            f"PostgreSQL version tag {pg_version_tag} digest {manifests[pg_version_tag].digest} "
            f"does not match 'latest-postgres' digest {manifests['latest-postgres'].digest}",
            details={"version_digest": manifests[pg_version_tag].digest, "latest_digest": manifests["latest-postgres"].digest},
        )

    return {tag: info.digest for tag, info in manifests.items()}
