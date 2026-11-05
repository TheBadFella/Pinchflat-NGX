"""Validate a merged release candidate and publish exactly one stable release."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import Any

from .errors import GitHubConflict, ReleaseError
from .notes import (
    DISPATCH_MARKER,
    is_checklist_complete,
    parse_metadata,
    release_body_from_pr,
    validate_release_metadata,
)
from .registry import verify_stable_manifests
from .versioning import (
    Version,
    extract_mix_version,
    parse_version,
    highest_stable_release,
)

LOGGER = logging.getLogger(__name__)

REQUIRED_CHECKS = (
    "Build, Lint, and Test (sqlite)",
    "Build, Lint, and Test (postgres)",
    "PostgreSQL schema migration tests",
)

SUCCESS_CONCLUSIONS = {"success"}
FAILURE_CONCLUSIONS = {
    "failure",
    "cancelled",
    "timed_out",
    "action_required",
    "startup_failure",
    "skipped",
    "neutral",
    "stale",
}
PENDING_STATUSES = {"queued", "in_progress", "waiting", "requested", "pending"}


@dataclass
class PublishOptions:
    repository: str
    target_branch: str = "master"
    candidate_branch: str = "release/stable-candidate"
    sync_branch: str = "dev"
    tag_prefix: str = ""
    checks_wait_seconds: int = 2400
    checks_poll_seconds: int = 15
    publisher_wait_seconds: int = 3600
    publisher_poll_seconds: int = 20
    publisher_workflow: str = "docker_release.yml"
    publisher_platforms: str = "linux/amd64,linux/arm64"
    registry_image: str | None = None
    require_registry_verification: bool = True
    bot_logins: tuple[str, ...] = ("github-actions[bot]",)
    dry_run: bool = False


@dataclass
class PublishResult:
    status: str
    message: str = ""
    version: str | None = None
    tag: str | None = None
    merge_sha: str | None = None
    pr_number: int | None = None
    tag_created: bool = False
    release_created: bool = False
    publisher_event: str | None = None
    publisher_run_id: int | None = None
    publisher_dispatched: bool = False
    registry_digests: dict[str, str] = field(default_factory=dict)
    sync: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "message": self.message,
            "version": self.version,
            "tag": self.tag,
            "merge_sha": self.merge_sha,
            "pr_number": self.pr_number,
            "tag_created": self.tag_created,
            "release_created": self.release_created,
            "publisher_event": self.publisher_event,
            "publisher_run_id": self.publisher_run_id,
            "publisher_dispatched": self.publisher_dispatched,
            "registry_digests": self.registry_digests,
            "sync": self.sync,
        }


def _is_ancestor(github: Any, ancestor: str, descendant: str) -> bool:
    comparison = github.compare(ancestor, descendant)
    status = comparison.get("status")
    return status in ("ahead", "identical") and int(comparison.get("behind_by") or 0) == 0


def _select_release_pull(
    pulls: list[dict[str, Any]],
    *,
    options: PublishOptions,
    merge_sha: str,
) -> dict[str, Any] | None:
    candidates: list[dict[str, Any]] = []
    for pull in pulls:
        merged = bool(pull.get("merged") or pull.get("merged_at"))
        if not merged:
            continue
        base = (pull.get("base") or {}).get("ref")
        if base != options.target_branch:
            continue
        head = pull.get("head") or {}
        if head.get("ref") != options.candidate_branch:
            continue
        head_repo = (head.get("repo") or {}).get("full_name")
        if head_repo and str(head_repo).lower() != options.repository.lower():
            continue
        merge_commit = pull.get("merge_commit_sha")
        if merge_commit and merge_commit != merge_sha:
            continue
        candidates.append(pull)
    if not candidates:
        return None
    if len(candidates) > 1:
        raise ReleaseError(
            "ambiguous_release_pull",
            "multiple merged release candidate PRs are associated with this commit",
        )
    return candidates[0]


def _validate_pull_metadata(
    github: Any,
    pull: dict[str, Any],
    *,
    options: PublishOptions,
    merge_sha: str,
) -> tuple[dict[str, Any], Version, str]:
    metadata = parse_metadata(pull.get("body"))
    candidate_head = (pull.get("head") or {}).get("sha") or ""
    if not candidate_head:
        raise ReleaseError("release_pr_incomplete", "merged release PR has no head SHA")
    version = parse_version(str(metadata.get("proposed_version") or ""), context="proposed version")
    tag = version.tag(options.tag_prefix)

    validate_release_metadata(
        metadata,
        repository=options.repository,
        proposed_version=version.canonical,
        tag_name=tag,
        candidate_head_sha=candidate_head,
        target_branch=options.target_branch,
        candidate_branch=options.candidate_branch,
    )

    if metadata.get("tag_name") != tag:
        raise ReleaseError("metadata_mismatch", f"metadata tag {metadata.get('tag_name')!r} does not match {tag!r}")

    acceptance = metadata.get("acceptance") or {}
    if acceptance.get("head_sha") != candidate_head:
        raise ReleaseError(
            "acceptance_invalidated",
            "the accepted candidate head does not match the merged PR head",
        )

    # The visible checklist is the maintainer's approval for this exact head.
    checklist_complete = is_checklist_complete(pull.get("body"))
    acceptance_status = str(acceptance.get("status") or "")
    if not checklist_complete:
        raise ReleaseError(
            "acceptance_pending",
            "maintainer must complete the checklist for the current candidate before release",
            details={"acceptance_status": acceptance_status, "checklist_complete": checklist_complete},
        )

    # Verify release notes are valid and not placeholder
    release_body_from_pr(pull.get("body"))

    releases = [release for release in github.list_releases() if release.get("tag_name") != tag]
    baseline = highest_stable_release(releases)
    expected_baseline_tag = baseline[1].get("tag_name") if baseline else None
    if metadata.get("previous_stable_tag") != expected_baseline_tag:
        raise ReleaseError(
            "stale_candidate",
            f"release candidate was based on {metadata.get('previous_stable_tag')!r}, "
            f"but the latest published stable release is {expected_baseline_tag!r}",
        )

    merge_commit = github.get_commit(merge_sha)
    parents = [parent.get("sha") for parent in merge_commit.get("parents") or []]
    if candidate_head not in parents:
        raise ReleaseError(
            "not_a_merge_commit",
            "the release PR must be merged with a merge commit so its approved head remains a parent",
        )
    baseline_sha = str(metadata.get("master_baseline_sha") or "")
    if not baseline_sha or not _is_ancestor(github, baseline_sha, merge_sha):
        raise ReleaseError(
            "metadata_mismatch",
            "recorded master baseline is not an ancestor of the merged release commit",
        )
    source_sha = str(metadata.get("source_sha") or "")
    if not source_sha or not _is_ancestor(github, source_sha, merge_sha):
        raise ReleaseError("metadata_mismatch", "recorded source commit is not part of the merged release")

    merged_by = (pull.get("merged_by") or {}).get("login")
    if not merged_by:
        raise ReleaseError(
            "release_pr_not_merged",
            "the release PR has no recorded maintainer merge",
        )
    bot_logins = {login.lower() for login in options.bot_logins}
    if merged_by.lower() in bot_logins or merged_by.lower().endswith("[bot]"):
        raise ReleaseError(
            "release_pr_merged_by_bot",
            f"release PR was merged by automation identity {merged_by!r}; a maintainer must merge it",
        )

    mix_text = github.get_content_text("mix.exs", merge_sha)
    mix_version = extract_mix_version(mix_text)
    if mix_version != version.canonical:
        raise ReleaseError(
            "version_file_mismatch",
            f"mix.exs at the merge commit reports {mix_version!r}, expected {version.canonical!r}",
        )

    return metadata, version, tag


def _check_states(runs: list[dict[str, Any]], merge_sha: str) -> tuple[dict[str, str], list[str]]:
    stale: list[str] = []
    latest: dict[str, dict[str, Any]] = {}
    for run in runs:
        name = str(run.get("name") or "")
        if name not in REQUIRED_CHECKS:
            continue
        if run.get("head_sha") != merge_sha:
            stale.append(name)
            continue
        current = latest.get(name)
        if current is None or int(run.get("id") or 0) >= int(current.get("id") or 0):
            latest[name] = run

    states: dict[str, str] = {}
    for name in REQUIRED_CHECKS:
        run = latest.get(name)
        if run is None:
            states[name] = "missing"
            continue
        status = str(run.get("status") or "")
        conclusion = str(run.get("conclusion") or "")
        if status != "completed":
            states[name] = "pending"
        elif conclusion == "success":
            states[name] = "success"
        else:
            states[name] = conclusion or "unknown"
    return states, stale


def _validate_checks(
    github: Any,
    *,
    options: PublishOptions,
    merge_sha: str,
) -> None:
    deadline = time.monotonic() + max(0, options.checks_wait_seconds)
    poll = max(1, options.checks_poll_seconds)
    while True:
        runs = github.list_check_runs(merge_sha)
        states, stale = _check_states(runs, merge_sha)
        failures = {name: state for name, state in states.items() if state in FAILURE_CONCLUSIONS}
        if failures:
            raise ReleaseError(
                "checks_failed",
                "required release checks did not pass on the merge commit",
                details={"checks": states, "stale": stale},
            )
        if all(state == "success" for state in states.values()):
            return
        if time.monotonic() >= deadline:
            raise ReleaseError(
                "checks_incomplete",
                "required release checks were missing, pending, or stale on the merge commit",
                details={"checks": states, "stale": stale},
            )
        remaining = max(0.0, deadline - time.monotonic())
        time.sleep(min(poll, remaining) if remaining else 0)


def _publisher_inputs(options: PublishOptions, tag: str) -> dict[str, str]:
    return {
        "platforms": options.publisher_platforms,
        "docker_tags": tag,
        "publish_latest": "true",
    }


def _run_is_success(run: dict[str, Any]) -> bool:
    return str(run.get("status")) == "completed" and str(run.get("conclusion")) == "success"


def _run_is_pending(run: dict[str, Any]) -> bool:
    status = str(run.get("status") or "")
    return status != "completed" and status in PENDING_STATUSES


def _run_is_failure(run: dict[str, Any]) -> bool:
    return str(run.get("status")) == "completed" and str(run.get("conclusion")) in FAILURE_CONCLUSIONS


def _publish_runs(github: Any, options: PublishOptions, merge_sha: str) -> list[dict[str, Any]]:
    runs = github.list_workflow_runs(options.publisher_workflow, head_sha=merge_sha)
    return [
        run
        for run in runs
        if str(run.get("event") or "") == "workflow_dispatch"
        and str(run.get("head_sha") or merge_sha) == merge_sha
    ]


def _latest(runs: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not runs:
        return None
    return max(runs, key=lambda run: (str(run.get("created_at") or ""), int(run.get("id") or 0)))


def _require_current_target(github: Any, options: PublishOptions, merge_sha: str) -> None:
    branch = github.get_branch(options.target_branch)
    current_sha = ((branch or {}).get("commit") or {}).get("sha")
    if current_sha != merge_sha:
        raise ReleaseError(
            "stale_release_merge",
            f"target branch {options.target_branch!r} no longer points at release commit {merge_sha[:12]}",
            details={"current_target_sha": current_sha, "merge_sha": merge_sha},
        )


def _publisher_phase(
    github: Any,
    *,
    options: PublishOptions,
    tag: str,
    merge_sha: str,
) -> tuple[dict[str, Any] | None, bool, str]:
    """Return (successful run or None, dispatched, status).

    Status is ``success``, ``pending``, or ``not-started``.
    """
    dispatched = False
    deadline = time.monotonic() + max(0, options.publisher_wait_seconds)
    poll = max(1, options.publisher_poll_seconds)

    while True:
        runs = _publish_runs(github, options, merge_sha)

        # Managed releases use dispatch only; release events cannot start a build.
        pending_runs = [r for r in runs if _run_is_pending(r)]
        successful_runs = [r for r in runs if _run_is_success(r)]
        if successful_runs:
            for pending in pending_runs:
                dup_id = int(pending.get("id") or 0)
                try:
                    github.cancel_workflow_run(dup_id)
                    LOGGER.warning(
                        "Cancelled duplicate pending publisher run #%s because run #%s succeeded",
                        dup_id,
                        successful_runs[0].get("id"),
                    )
                except Exception as exc:
                    raise ReleaseError("duplicate_publisher", f"could not cancel duplicate run #{dup_id}") from exc
            return successful_runs[0], dispatched, "success"

        if len(pending_runs) > 1:
            pending_runs.sort(key=lambda r: (str(r.get("created_at") or ""), int(r.get("id") or 0)))
            for dup in pending_runs[1:]:
                dup_id = int(dup.get("id") or 0)
                try:
                    github.cancel_workflow_run(dup_id)
                    LOGGER.warning("Cancelled duplicate pending publisher run #%s", dup_id)
                except Exception as exc:
                    raise ReleaseError("duplicate_publisher", f"could not cancel duplicate run #{dup_id}") from exc

        # A cancelled newer duplicate is not a failure of the surviving run.
        latest = pending_runs[0] if pending_runs else _latest(runs)

        if latest is not None and _run_is_success(latest):
            return latest, dispatched, "success"
        if latest is not None and _run_is_pending(latest):
            if time.monotonic() >= deadline:
                return latest, dispatched, "pending"
            remaining = max(0.0, deadline - time.monotonic())
            time.sleep(min(poll, remaining) if remaining else 0)
            continue
        if latest is not None and _run_is_failure(latest):
            if dispatched:
                raise ReleaseError(
                    "publisher_failed",
                    "the stable publisher workflow failed; tag and release were left unchanged",
                    details={"run_id": latest.get("id"), "conclusion": latest.get("conclusion")},
                )
            # A rerun may retry a failed dispatch without moving the release tag.
            if options.dry_run:
                return None, False, "not-started"
            github.dispatch_workflow(
                options.publisher_workflow,
                ref=tag,
                inputs=_publisher_inputs(options, tag),
            )
            dispatched = True
            continue

        # No publisher run exists yet.
        if latest is None:
            if dispatched:
                if time.monotonic() >= deadline:
                    return None, dispatched, "not-started"
                remaining = max(0.0, deadline - time.monotonic())
                time.sleep(min(poll, remaining) if remaining else 0)
                continue
            if options.dry_run:
                return None, False, "not-started"
            current_runs = _publish_runs(github, options, merge_sha)
            if any(_run_is_pending(r) or _run_is_success(r) for r in current_runs):
                continue
            github.dispatch_workflow(
                options.publisher_workflow,
                ref=tag,
                inputs=_publisher_inputs(options, tag),
            )
            dispatched = True
            continue

        if time.monotonic() >= deadline:
            return None, dispatched, "not-started"
        remaining = max(0.0, deadline - time.monotonic())
        time.sleep(min(poll, remaining) if remaining else 0)


def _sync_master_to_dev(
    github: Any,
    *,
    options: PublishOptions,
    tag: str,
) -> dict[str, Any]:
    branch = github.get_branch(options.sync_branch)
    if not branch:
        raise ReleaseError("sync_branch_missing", f"synchronization branch {options.sync_branch!r} does not exist")

    comparison = github.compare(options.sync_branch, options.target_branch)
    if comparison.get("status") == "identical" or int(comparison.get("ahead_by") or 0) == 0:
        return {"status": "up_to_date"}

    try:
        merged = github.merge_into(
            base=options.sync_branch,
            head=options.target_branch,
            message=f"Merge {options.target_branch} into {options.sync_branch} after {tag}",
        )
        return {"status": "merged", "sha": merged.get("sha")}
    except GitHubConflict:
        owner = options.repository.split("/", 1)[0]
        pulls = github.list_pull_requests(
            state="open",
            head=f"{owner}:{options.target_branch}",
            base=options.sync_branch,
        )
        for pull in pulls:
            head = (pull.get("head") or {}).get("ref")
            base = (pull.get("base") or {}).get("ref")
            if head == options.target_branch and base == options.sync_branch:
                return {"status": "pr_exists", "number": int(pull.get("number") or 0)}
        body = "\n".join(
            [
                f"Merge the `{tag}` release commit from `{options.target_branch}` back into "
                f"`{options.sync_branch}`.",
                "",
                "The direct merge hit a conflict, so this PR keeps the long-lived development branch current.",
                "Resolve conflicts normally; do not rewrite the release tag.",
            ]
        )
        created = github.create_pull_request(
            title=f"Merge {options.target_branch} into {options.sync_branch} after {tag}",
            head=options.target_branch,
            base=options.sync_branch,
            body=body,
        )
        return {"status": "pr_created", "number": int(created.get("number") or 0)}


def publish(
    options: PublishOptions,
    github: Any,
    *,
    merge_sha: str,
    registry: Any = None,
    event_name: str | None = None,
) -> PublishResult:
    if event_name and event_name not in ("push", "workflow_dispatch"):
        return PublishResult(status="ignored", message=f"event {event_name!r} is not a release trigger")

    repo = github.get_repo()
    actual_repository = str(repo.get("full_name") or "")
    if actual_repository.lower() != options.repository.lower():
        raise ReleaseError(
            "repository_mismatch",
            f"GitHub reports {actual_repository!r}, expected {options.repository!r}",
        )

    pulls = github.get_commit_pulls(merge_sha)
    pull = _select_release_pull(pulls, options=options, merge_sha=merge_sha)
    if pull is None:
        return PublishResult(
            status="not_release_merge",
            message="this commit is not a merged release candidate; no tag or release was created",
            merge_sha=merge_sha,
        )

    _require_current_target(github, options, merge_sha)

    _metadata, version, tag = _validate_pull_metadata(
        github,
        pull,
        options=options,
        merge_sha=merge_sha,
    )
    _validate_checks(github, options=options, merge_sha=merge_sha)
    # CI may take long enough for another master merge to land.
    _require_current_target(github, options, merge_sha)
    publisher_config = github.get_content_text(f".github/workflows/{options.publisher_workflow}", merge_sha)
    if DISPATCH_MARKER not in publisher_config:
        raise ReleaseError(
            "publisher_guard_missing",
            "the release commit must include the managed-release event guard before publication",
        )

    if options.dry_run:
        return PublishResult(
            status="dry_run",
            message="dry run: validation passed; no tag, release, or publisher was created",
            version=version.canonical,
            tag=tag,
            merge_sha=merge_sha,
            pr_number=int(pull.get("number") or 0),
        )

    tag_existed = False
    existing_tag_sha = github.resolve_tag_commit(tag)
    if existing_tag_sha is not None:
        if existing_tag_sha != merge_sha:
            raise ReleaseError(
                "tag_collision",
                f"tag {tag} already points at {existing_tag_sha[:12]}, not the release commit {merge_sha[:12]}",
            )
        tag_existed = True
    else:
        github.create_tag_ref(tag, merge_sha)
        LOGGER.info("Created tag %s at %s", tag, merge_sha[:12])

    release = github.get_release_by_tag(tag)
    release_existed = release is not None
    if release is not None:
        if release.get("draft") or release.get("prerelease"):
            raise ReleaseError(
                "release_state_unexpected",
                f"release {tag} exists but is still a draft or prerelease; publish it manually before rerunning",
            )
        if DISPATCH_MARKER not in str(release.get("body") or ""):
            raise ReleaseError("release_state_unexpected", "existing release is not managed by explicit dispatch")
    else:
        body = release_body_from_pr(pull.get("body")) + "\n\n" + DISPATCH_MARKER
        release = github.create_release(
            tag=tag,
            target_commitish=merge_sha,
            name=tag,
            body=body,
            draft=False,
            prerelease=False,
        )
        LOGGER.info("Created GitHub release %s", tag)

    _require_current_target(github, options, merge_sha)
    publisher_run, dispatched, publisher_status = _publisher_phase(
        github,
        options=options,
        tag=tag,
        merge_sha=merge_sha,
    )
    if publisher_status == "pending":
        return PublishResult(
            status="publisher_pending",
            message="the stable publisher is still running; rerun this workflow to verify completion",
            version=version.canonical,
            tag=tag,
            merge_sha=merge_sha,
            pr_number=int(pull.get("number") or 0),
            tag_created=not tag_existed,
            release_created=not release_existed,
            publisher_event=(publisher_run or {}).get("event"),
            publisher_run_id=(publisher_run or {}).get("id"),
            publisher_dispatched=dispatched,
        )
    if publisher_status != "success":
        return PublishResult(
            status="publisher_not_started",
            message="the stable publisher did not start; tag and release were left unchanged",
            version=version.canonical,
            tag=tag,
            merge_sha=merge_sha,
            pr_number=int(pull.get("number") or 0),
            tag_created=not tag_existed,
            release_created=not release_existed,
            publisher_dispatched=dispatched,
        )

    registry_image = options.registry_image or f"ghcr.io/{options.repository.split('/', 1)[0].lower()}/pinchflat-ngx"
    digests = verify_stable_manifests(registry, registry_image, tag) if options.require_registry_verification else {}

    sync = _sync_master_to_dev(github, options=options, tag=tag)

    already_released = tag_existed and release_existed
    return PublishResult(
        status="already_released" if already_released else "released",
        message="release verified and already published" if already_released else "stable release published",
        version=version.canonical,
        tag=tag,
        merge_sha=merge_sha,
        pr_number=int(pull.get("number") or 0),
        tag_created=not tag_existed,
        release_created=not release_existed,
        publisher_event=(publisher_run or {}).get("event"),
        publisher_run_id=(publisher_run or {}).get("id"),
        publisher_dispatched=dispatched,
        registry_digests=digests,
        sync=sync,
    )
