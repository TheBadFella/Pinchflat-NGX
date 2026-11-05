"""Command-line entry point used by the release workflows and local tests."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

from .errors import ReleaseError
from .github import GitHubClient
from .gitops import GitPushPublisher, GitRepo
from .prepare import PrepareOptions, PrepareResult, prepare
from .publish import PublishOptions, PublishResult, publish
from .registry import DockerRegistryClient
from .versioning import update_mix_version

LOGGER = logging.getLogger("release-automation")


def _load_event(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise ReleaseError("event_file_missing", f"could not read event payload: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ReleaseError("event_file_invalid", f"event payload is not valid JSON: {exc.msg}") from exc


def _event_name(event: dict[str, Any]) -> str | None:
    return os.environ.get("GITHUB_EVENT_NAME") or event.get("event_name")


def _event_repository(event: dict[str, Any]) -> str | None:
    repository = event.get("repository") or {}
    return repository.get("full_name")


def _event_sha(event: dict[str, Any]) -> str | None:
    return event.get("after") or event.get("sha")


def _event_ref(event: dict[str, Any]) -> str | None:
    return event.get("ref") or os.environ.get("GITHUB_REF")


def _input(event: dict[str, Any], name: str, default: str | None = None) -> str | None:
    inputs = event.get("inputs") or {}
    value = inputs.get(name)
    if value is None or value == "":
        return default
    return str(value)


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def _token() -> str:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise ReleaseError("missing_token", "GH_TOKEN or GITHUB_TOKEN is required")
    return token


def _escape_command(message: str) -> str:
    return str(message).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _write_json(path: str | None, payload: dict[str, Any]) -> None:
    if not path:
        return
    Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_github_output(path: str | None, values: dict[str, Any]) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8", newline="\n") as handle:
        for key, value in values.items():
            text = "" if value is None else str(value)
            handle.write(f"{key}={text.replace(chr(13), ' ').replace(chr(10), ' ')}\n")


def _append_summary(markdown: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(markdown.rstrip() + "\n")


def _prepare_summary(result: PrepareResult) -> str:
    lines = [f"### Release candidate: {result.status}", ""]
    if result.message:
        lines.append(result.message)
        lines.append("")
    for label, value in (
        ("Version", result.version),
        ("Tag", result.tag),
        ("Previous stable", result.previous_stable_tag),
        ("Candidate", result.candidate_head),
        ("Pull request", f"#{result.pr_number}" if result.pr_number else None),
    ):
        if value:
            lines.append(f"- {label}: `{value}`")
    return "\n".join(lines)


def _publish_summary(result: PublishResult) -> str:
    lines = [f"### Release: {result.status}", ""]
    if result.message:
        lines.append(result.message)
        lines.append("")
    for label, value in (
        ("Version", result.version),
        ("Tag", result.tag),
        ("Merge commit", result.merge_sha),
        ("Pull request", f"#{result.pr_number}" if result.pr_number else None),
        ("Publisher run", result.publisher_run_id),
        ("Publisher event", result.publisher_event),
        ("Sync", result.sync.get("status") if result.sync else None),
    ):
        if value:
            lines.append(f"- {label}: `{value}`")
    if result.registry_digests:
        lines.append("")
        lines.append("Verified container manifests:")
        for tag, digest in sorted(result.registry_digests.items()):
            lines.append(f"- `{tag}` -> `{digest}`")
    return "\n".join(lines)


def _finish(
    result: PrepareResult | PublishResult,
    *,
    output_json: str | None,
    github_output: str | None,
    summary: str,
) -> int:
    payload = result.to_dict()
    _write_json(output_json, payload)
    _write_github_output(
        github_output,
        {
            "status": payload.get("status"),
            "version": payload.get("version"),
            "tag": payload.get("tag"),
            "pr_number": payload.get("pr_number"),
            "candidate_head": payload.get("candidate_head"),
            "merge_sha": payload.get("merge_sha"),
            "publisher_run_id": payload.get("publisher_run_id"),
            "sync_status": (payload.get("sync") or {}).get("status"),
        },
    )
    _append_summary(summary)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def _fail(
    error: ReleaseError,
    *,
    output_json: str | None,
    github_output: str | None,
) -> int:
    payload = error.to_dict()
    _write_json(output_json, payload)
    _write_github_output(github_output, {"status": "error", "error_code": error.code, "message": error.message})
    _append_summary(f"### Release blocked\n\n`{error.code}`: {error.message}")
    print(f"::error title={_escape_command(error.code)}::{_escape_command(error.message)}")
    print(json.dumps(payload, indent=2, sort_keys=True), file=sys.stderr)
    return 1


def _cmd_prepare(args: argparse.Namespace) -> int:
    event = _load_event(args.event_file)
    event_name = _event_name(event)
    repository = args.repository or _event_repository(event) or os.environ.get("GITHUB_REPOSITORY")
    if not repository:
        raise ReleaseError("missing_repository", "repository must be provided or present in the event payload")

    source_ref = args.source_ref
    if not source_ref:
        dispatch_source = _input(event, "source_ref")
        if dispatch_source:
            source_ref = dispatch_source
        elif event_name == "push" and _event_ref(event) == "refs/heads/dev":
            source_ref = _event_sha(event) or "dev"
        else:
            source_ref = "dev"

    version_override = args.version_override or _input(event, "version_override")
    bootstrap_version = args.bootstrap_version or _input(event, "bootstrap_version")
    dry_run = bool(args.dry_run or _truthy(_input(event, "dry_run")))

    github = GitHubClient(repository, _token())
    git = GitRepo(Path.cwd())
    publisher = GitPushPublisher(git)
    result = prepare(
        PrepareOptions(
            repository=repository,
            target_branch=args.target_branch,
            candidate_branch=args.candidate_branch,
            source_ref=source_ref,
            master_ref=args.master_ref,
            version_override=version_override or None,
            bootstrap_version=bootstrap_version or None,
            tag_prefix=args.tag_prefix,
            fetch=not args.no_fetch,
            dry_run=dry_run,
            repository_url=args.repository_url,
        ),
        github,
        git,
        publisher,
        clock=args.clock,
    )
    return _finish(
        result,
        output_json=args.output_json,
        github_output=args.github_output,
        summary=_prepare_summary(result),
    )


def _cmd_publish(args: argparse.Namespace) -> int:
    event = _load_event(args.event_file)
    event_name = _event_name(event)
    if event_name and event_name not in ("push", "workflow_dispatch"):
        result = PublishResult(status="ignored", message=f"event {event_name!r} is not a release trigger")
        return _finish(
            result,
            output_json=args.output_json,
            github_output=args.github_output,
            summary=_publish_summary(result),
        )
    if event_name == "push":
        ref = _event_ref(event)
        if ref and ref != f"refs/heads/{args.target_branch}":
            result = PublishResult(
                status="ignored",
                message=f"push to {ref!r} is not a {args.target_branch} push",
            )
            return _finish(
                result,
                output_json=args.output_json,
                github_output=args.github_output,
                summary=_publish_summary(result),
            )

    repository = args.repository or _event_repository(event) or os.environ.get("GITHUB_REPOSITORY")
    if not repository:
        raise ReleaseError("missing_repository", "repository must be provided or present in the event payload")

    github = GitHubClient(repository, _token())
    merge_sha = args.sha or _input(event, "sha") or _event_sha(event)
    if not merge_sha and event_name == "workflow_dispatch":
        merge_sha = ((github.get_branch(args.target_branch) or {}).get("commit") or {}).get("sha")
    if not merge_sha:
        raise ReleaseError("missing_sha", "a merge commit SHA is required")

    dry_run = bool(args.dry_run or _truthy(_input(event, "dry_run")))
    try:
        checks_wait_seconds = int(_input(event, "checks_wait_seconds") or args.checks_wait_seconds)
        publisher_wait_seconds = int(_input(event, "publisher_wait_seconds") or args.publisher_wait_seconds)
    except ValueError as exc:
        raise ReleaseError("invalid_wait", "workflow wait inputs must be integers") from exc
    registry = None if args.skip_registry_verification or dry_run else DockerRegistryClient()
    result = publish(
        PublishOptions(
            repository=repository,
            target_branch=args.target_branch,
            candidate_branch=args.candidate_branch,
            sync_branch=args.sync_branch,
            tag_prefix=args.tag_prefix,
            checks_wait_seconds=checks_wait_seconds,
            checks_poll_seconds=args.checks_poll_seconds,
            publisher_wait_seconds=publisher_wait_seconds,
            publisher_poll_seconds=args.publisher_poll_seconds,
            publisher_workflow=args.publisher_workflow,
            publisher_platforms=args.publisher_platforms,
            registry_image=args.registry_image,
            require_registry_verification=not args.skip_registry_verification,
            bot_logins=tuple(
                login.strip()
                for login in (args.bot_logins or "github-actions[bot]").split(",")
                if login.strip()
            ),
            dry_run=dry_run,
        ),
        github,
        merge_sha=merge_sha,
        registry=registry,
        event_name=event_name,
    )
    status = _finish(
        result,
        output_json=args.output_json,
        github_output=args.github_output,
        summary=_publish_summary(result),
    )
    if result.status == "publisher_not_started":
        LOGGER.error("The stable publisher did not start; rerun the workflow after checking Actions.")
        return 1
    return status


def _cmd_set_version(args: argparse.Namespace) -> int:
    path = Path(args.file)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ReleaseError("file_missing", f"could not read {path}: {exc}") from exc
    updated = update_mix_version(text, args.version)
    path.write_text(updated, encoding="utf-8", newline="\n")
    print(f'Set {path} to version "{args.version}"')
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m release_automation")
    parser.add_argument("--verbose", action="store_true")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare", help="create or refresh the stable release candidate")
    prepare_parser.add_argument("--event-file")
    prepare_parser.add_argument("--repository")
    prepare_parser.add_argument("--source-ref", default="")
    prepare_parser.add_argument("--version-override", default="")
    prepare_parser.add_argument("--bootstrap-version", default="")
    prepare_parser.add_argument("--candidate-branch", default="release/stable-candidate")
    prepare_parser.add_argument("--target-branch", default="master")
    prepare_parser.add_argument("--master-ref", default="origin/master")
    prepare_parser.add_argument("--tag-prefix", default="")
    prepare_parser.add_argument("--repository-url")
    prepare_parser.add_argument("--clock")
    prepare_parser.add_argument("--dry-run", action="store_true")
    prepare_parser.add_argument("--no-fetch", action="store_true")
    prepare_parser.add_argument("--output-json")
    prepare_parser.add_argument("--github-output")
    prepare_parser.set_defaults(handler=_cmd_prepare)

    publish_parser = subparsers.add_parser("publish", help="validate and publish the merged release candidate")
    publish_parser.add_argument("--event-file")
    publish_parser.add_argument("--repository")
    publish_parser.add_argument("--sha", default="")
    publish_parser.add_argument("--target-branch", default="master")
    publish_parser.add_argument("--candidate-branch", default="release/stable-candidate")
    publish_parser.add_argument("--sync-branch", default="dev")
    publish_parser.add_argument("--tag-prefix", default="")
    publish_parser.add_argument("--checks-wait-seconds", type=int, default=2400)
    publish_parser.add_argument("--checks-poll-seconds", type=int, default=15)
    publish_parser.add_argument("--publisher-wait-seconds", type=int, default=3600)
    publish_parser.add_argument("--publisher-poll-seconds", type=int, default=20)
    publish_parser.add_argument("--publisher-workflow", default="docker_release.yml")
    publish_parser.add_argument("--publisher-platforms", default="linux/amd64,linux/arm64")
    publish_parser.add_argument("--registry-image")
    publish_parser.add_argument("--skip-registry-verification", action="store_true")
    publish_parser.add_argument("--bot-logins", default="github-actions[bot]")
    publish_parser.add_argument("--dry-run", action="store_true")
    publish_parser.add_argument("--output-json")
    publish_parser.add_argument("--github-output")
    publish_parser.set_defaults(handler=_cmd_publish)

    version_parser = subparsers.add_parser("set-version", help="update mix.exs using the calendar version rules")
    version_parser.add_argument("version")
    version_parser.add_argument("--file", default="mix.exs")
    version_parser.set_defaults(handler=_cmd_set_version)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
        stream=sys.stderr,
    )
    try:
        return int(args.handler(args))
    except ReleaseError as exc:
        return _fail(
            exc,
            output_json=getattr(args, "output_json", None),
            github_output=getattr(args, "github_output", None),
        )
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # pragma: no cover - defensive boundary
        LOGGER.exception("unexpected release automation failure")
        return _fail(
            ReleaseError("internal_error", f"unexpected failure: {exc}"),
            output_json=getattr(args, "output_json", None),
            github_output=getattr(args, "github_output", None),
        )


if __name__ == "__main__":
    raise SystemExit(main())
