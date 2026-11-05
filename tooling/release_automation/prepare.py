"""Prepare or refresh the managed stable release candidate."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .errors import ReleaseError
from .notes import (
    MANAGED_BY,
    SCHEMA_VERSION,
    collect_changes,
    parse_metadata,
    render_generated_changes,
    render_pr_body,
)
from .versioning import (
    Version,
    calculate_next_version,
    duplicate_release_versions,
    highest_stable_release,
    normalize_clock,
    update_mix_version,
)

LOGGER = logging.getLogger(__name__)


@dataclass
class PrepareOptions:
    repository: str
    target_branch: str = "master"
    candidate_branch: str = "release/stable-candidate"
    source_ref: str = "dev"
    master_ref: str = "origin/master"
    version_override: str | None = None
    bootstrap_version: str | None = None
    tag_prefix: str = ""
    fetch: bool = True
    dry_run: bool = False
    repository_url: str | None = None


@dataclass
class PrepareResult:
    status: str
    message: str = ""
    version: str | None = None
    tag: str | None = None
    candidate_branch: str | None = None
    candidate_head: str | None = None
    source_sha: str | None = None
    master_sha: str | None = None
    pr_number: int | None = None
    previous_stable_tag: str | None = None
    changed: bool = False
    push_performed: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "message": self.message,
            "version": self.version,
            "tag": self.tag,
            "candidate_branch": self.candidate_branch,
            "candidate_head": self.candidate_head,
            "source_sha": self.source_sha,
            "master_sha": self.master_sha,
            "pr_number": self.pr_number,
            "previous_stable_tag": self.previous_stable_tag,
            "changed": self.changed,
            "push_performed": self.push_performed,
        }


def _repository_url(options: PrepareOptions, repo: dict[str, Any]) -> str:
    if options.repository_url:
        return options.repository_url.rstrip("/")
    html_url = repo.get("html_url")
    if html_url:
        return str(html_url).rstrip("/")
    return f"https://github.com/{options.repository}"


def _managed_pulls(
    pulls: list[dict[str, Any]],
    *,
    repository: str,
    candidate_branch: str,
    target_branch: str,
) -> list[dict[str, Any]]:
    managed = []
    for pull in pulls:
        head = pull.get("head") or {}
        base = pull.get("base") or {}
        head_repo = (head.get("repo") or {}).get("full_name")
        if head.get("ref") != candidate_branch:
            continue
        if base.get("ref") != target_branch:
            continue
        if head_repo and str(head_repo).lower() != repository.lower():
            continue
        managed.append(pull)
    return sorted(managed, key=lambda pull: int(pull.get("number") or 0))


def _close_duplicate_pulls(github: Any, pulls: list[dict[str, Any]], keep_number: int) -> None:
    for pull in pulls:
        number = int(pull.get("number") or 0)
        if number == keep_number:
            continue
        github.add_issue_comment(
            number,
            "Closing a duplicate release candidate PR. The release automation keeps exactly one "
            f"open PR for `{pull.get('head', {}).get('ref', 'the candidate branch')}`.",
        )
        github.update_pull_request(number, state="closed")
        LOGGER.info("Closed duplicate release candidate PR #%s", number)


def _combine_comparisons(github: Any, base: str, refs: list[str]) -> list[dict[str, Any]]:
    commits: list[dict[str, Any]] = []
    seen: set[str] = set()
    for head in refs:
        comparison = github.compare(base, head)
        for commit in comparison.get("commits") or []:
            sha = commit.get("sha")
            if sha and sha in seen:
                continue
            if sha:
                seen.add(sha)
            commits.append(commit)
    return commits


def prepare(
    options: PrepareOptions,
    github: Any,
    git: Any,
    publisher: Any,
    *,
    clock: datetime | str | None = None,
) -> PrepareResult:
    local_now = normalize_clock(clock)
    now_iso = local_now.isoformat()

    repo = github.get_repo()
    actual_repository = str(repo.get("full_name") or "")
    if actual_repository.lower() != options.repository.lower():
        raise ReleaseError(
            "repository_mismatch",
            f"GitHub reports {actual_repository!r}, expected {options.repository!r}",
        )

    releases = github.list_releases()
    duplicates = duplicate_release_versions(releases)
    if duplicates:
        versions = ", ".join(sorted(duplicates))
        raise ReleaseError("duplicate_release_version", f"multiple published stable releases share {versions}")

    baseline_pair = highest_stable_release(releases)
    baseline_version: Version | None = None
    baseline_tag: str | None = None
    baseline_sha: str | None = None
    if baseline_pair is not None:
        baseline_version, baseline_release = baseline_pair
        baseline_tag = str(baseline_release.get("tag_name"))
        baseline_sha = github.resolve_tag_commit(baseline_tag)
        if not baseline_sha:
            raise ReleaseError(
                "baseline_tag_missing",
                f"published baseline {baseline_tag} has no resolvable tag ref",
            )

    version = calculate_next_version(
        local_now,
        baseline_version,
        override=options.version_override,
        bootstrap=options.bootstrap_version,
    )
    tag = version.tag(options.tag_prefix)

    existing_tag_sha = github.resolve_tag_commit(tag)
    if existing_tag_sha is not None:
        raise ReleaseError(
            "tag_collision",
            f"tag {tag} already points at {existing_tag_sha[:12]}; refusing to reuse or move it",
            details={"tag": tag, "commit": existing_tag_sha},
        )

    if options.fetch:
        git.fetch()
    git.ensure_clean()
    master_sha = git.resolve(options.master_ref)
    try:
        source_sha = git.resolve(options.source_ref)
    except ReleaseError:
        # A manual dispatch can name a remote branch that was not checked out.
        source_sha = git.resolve(f"{git.remote}/{options.source_ref}")

    comparison_base = baseline_sha or master_sha
    comparison_heads = [source_sha]
    if source_sha != master_sha and not git.is_ancestor(master_sha, source_sha):
        # A hotfix that landed on master but not yet on the source branch still
        # belongs to this release.
        comparison_heads.append(master_sha)

    commits = _combine_comparisons(github, comparison_base, comparison_heads)
    changes = collect_changes({"commits": commits}, head_label=options.source_ref)

    if baseline_version is not None and not changes:
        return PrepareResult(
            status="no_changes",
            message="no releasable changes were found; leaving the candidate untouched",
            version=version.canonical,
            tag=tag,
            candidate_branch=options.candidate_branch,
            source_sha=source_sha,
            master_sha=master_sha,
            previous_stable_tag=baseline_tag,
        )

    if baseline_version is None and not changes:
        changes = [
            {
                "sha": source_sha,
                "subject": "Initial stable release",
                "pr": None,
                "author": None,
            }
        ]

    if options.dry_run:
        return PrepareResult(
            status="dry_run",
            message="dry run: candidate was not created or updated",
            version=version.canonical,
            tag=tag,
            candidate_branch=options.candidate_branch,
            source_sha=source_sha,
            master_sha=master_sha,
            previous_stable_tag=baseline_tag,
        )

    owner = options.repository.split("/", 1)[0]
    open_pulls = github.list_pull_requests(
        state="open",
        head=f"{owner}:{options.candidate_branch}",
        base=options.target_branch,
    )
    pulls = _managed_pulls(
        open_pulls,
        repository=options.repository,
        candidate_branch=options.candidate_branch,
        target_branch=options.target_branch,
    )
    existing = pulls[0] if pulls else None
    if len(pulls) > 1 and existing is not None:
        _close_duplicate_pulls(github, pulls[1:], int(existing.get("number") or 0))

    existing_metadata: dict[str, Any] | None = None
    if existing is not None:
        try:
            existing_metadata = parse_metadata(existing.get("body"))
        except ReleaseError as exc:
            raise ReleaseError(
                "unmanaged_candidate_pr",
                f"an open PR already uses {options.candidate_branch} but its release metadata is invalid: {exc.message}",
            ) from exc

    branch = github.get_branch(options.candidate_branch)
    expected_old = ((branch or {}).get("commit") or {}).get("sha")

    if existing is not None and existing_metadata is not None and expected_old:
        pull_head = (existing.get("head") or {}).get("sha")
        same_candidate = (
            existing_metadata.get("source_sha") == source_sha
            and existing_metadata.get("master_baseline_sha") == master_sha
            and existing_metadata.get("proposed_version") == version.canonical
            and existing_metadata.get("tag_name") == tag
            and existing_metadata.get("previous_stable_tag") == baseline_tag
            and existing_metadata.get("candidate_head_sha") == expected_old
            and pull_head == expected_old
            and existing_metadata.get("release_branch") == options.candidate_branch
            and existing_metadata.get("target_branch") == options.target_branch
        )
        if same_candidate:
            return PrepareResult(
                status="noop",
                message="candidate, version, and baseline are unchanged",
                version=version.canonical,
                tag=tag,
                candidate_branch=options.candidate_branch,
                candidate_head=expected_old,
                source_sha=source_sha,
                master_sha=master_sha,
                pr_number=int(existing.get("number") or 0),
                previous_stable_tag=baseline_tag,
            )

    original_ref = git.current_ref()
    push_performed = False
    try:
        if expected_old:
            # Advance the existing candidate branch monotonically. Never reset to master
            # or discard previous candidate ancestry.
            git.create_reset_branch(options.candidate_branch, expected_old)
            if master_sha != expected_old and not git.is_ancestor(master_sha, git.head_sha()):
                git.merge(
                    master_sha,
                    message=f"Merge {options.target_branch} into {options.candidate_branch} for release candidate",
                )
            if source_sha != expected_old and not git.is_ancestor(source_sha, git.head_sha()):
                git.merge(
                    source_sha,
                    message=f"Merge {options.source_ref} into {options.candidate_branch} for release candidate",
                )
        else:
            # First candidate creation starts from master and merges source
            git.create_reset_branch(options.candidate_branch, master_sha)
            if source_sha != master_sha:
                git.merge(
                    source_sha,
                    message=f"Merge {options.source_ref} into {options.target_branch} for release candidate",
                )

        mix_text = git.read_text("mix.exs")
        updated_mix = update_mix_version(mix_text, version)
        if updated_mix != mix_text:
            git.write_text("mix.exs", updated_mix)
            git.commit_all(f"release: prepare {version.canonical}")

        candidate_head = git.head_sha()
    except Exception:
        git.checkout(original_ref)
        raise
    else:
        git.checkout(original_ref)

    changed = (
        existing_metadata is None
        or existing_metadata.get("candidate_head_sha") != candidate_head
        or existing_metadata.get("source_sha") != source_sha
        or existing_metadata.get("master_baseline_sha") != master_sha
        or existing_metadata.get("proposed_version") != version.canonical
        or existing_metadata.get("previous_stable_tag") != baseline_tag
    )

    previous_acceptance = (existing_metadata or {}).get("acceptance") or {}
    if changed and existing_metadata is not None:
        acceptance_status = "invalidated"
        invalidated_at = now_iso
    elif existing_metadata is None:
        acceptance_status = "pending"
        invalidated_at = None
    else:
        acceptance_status = str(previous_acceptance.get("status") or "pending")
        invalidated_at = previous_acceptance.get("invalidated_at")

    metadata = {
        "schema_version": SCHEMA_VERSION,
        "managed_by": MANAGED_BY,
        "repository": options.repository,
        "source_sha": source_sha,
        "master_baseline_sha": master_sha,
        "candidate_head_sha": candidate_head,
        "proposed_version": version.canonical,
        "tag_name": tag,
        "previous_stable_tag": baseline_tag,
        "previous_stable_sha": baseline_sha,
        "release_branch": options.candidate_branch,
        "target_branch": options.target_branch,
        "generated_at": now_iso,
        "acceptance": {
            "status": acceptance_status,
            "head_sha": candidate_head,
            "previous_head_sha": (existing_metadata or {}).get("candidate_head_sha"),
            "invalidated_at": invalidated_at,
        },
    }

    generated = render_generated_changes(
        changes,
        base_label=baseline_tag or f"{options.target_branch}@{master_sha[:12]}",
        head_label=f"{options.source_ref}@{source_sha[:12]}",
    )
    body = render_pr_body(
        tag=tag,
        generated_changes=generated,
        metadata=metadata,
        existing_body=(existing or {}).get("body"),
    )

    # Validate the complete notes before changing the remote candidate branch.
    if candidate_head != expected_old:
        publisher.publish(options.candidate_branch, candidate_head, expected_old)
        push_performed = True

    if existing is not None:
        updated = github.update_pull_request(
            int(existing.get("number") or 0),
            title=f"Release {tag}",
            body=body,
        )
        pr_number = int((updated or existing).get("number") or existing.get("number") or 0)
        status = "refreshed"
    else:
        created = github.create_pull_request(
            title=f"Release {tag}",
            head=options.candidate_branch,
            base=options.target_branch,
            body=body,
        )
        pr_number = int(created.get("number") or 0)
        status = "prepared"

    LOGGER.info("Release candidate %s is ready in PR #%s at %s", tag, pr_number, candidate_head[:12])
    return PrepareResult(
        status=status,
        message="release candidate prepared" if status == "prepared" else "release candidate refreshed",
        version=version.canonical,
        tag=tag,
        candidate_branch=options.candidate_branch,
        candidate_head=candidate_head,
        source_sha=source_sha,
        master_sha=master_sha,
        pr_number=pr_number,
        previous_stable_tag=baseline_tag,
        changed=changed,
        push_performed=push_performed,
    )
