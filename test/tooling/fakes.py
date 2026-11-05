"""Stateful GitHub/git/registry fakes used by the offline release tests."""

from __future__ import annotations

import hashlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from release_automation.errors import GitHubConflict, ReleaseError
from release_automation.registry import ManifestInfo

DEFAULT_REPOSITORY = "TheBadFella/Pinchflat-NGX"
REQUIRED_CHECK_NAMES = (
    "Build, Lint, and Test (sqlite)",
    "Build, Lint, and Test (postgres)",
    "PostgreSQL schema migration tests",
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class FakeGitHub:
    def __init__(self, repository: str = DEFAULT_REPOSITORY):
        self.repository = repository
        self.branches: dict[str, str] = {}
        self.commits: dict[str, dict[str, Any]] = {}
        self.pulls: dict[int, dict[str, Any]] = {}
        self.releases: list[dict[str, Any]] = []
        self.tags: dict[str, str] = {}
        self.check_runs: dict[str, list[dict[str, Any]]] = {}
        self.workflow_runs: list[dict[str, Any]] = []
        self.comments: list[dict[str, Any]] = []
        self.merge_conflicts: set[tuple[str, str]] = set()
        self.simulate_release_event = True
        self.release_event_behavior = "success"
        self.dispatch_behavior = "success"
        self.dispatches: list[dict[str, Any]] = []
        self.tags_created: list[str] = []
        self.releases_created: list[dict[str, Any]] = []
        self.pulls_created: list[dict[str, Any]] = []
        self.pulls_updated: list[dict[str, Any]] = []
        self._next_pull = 100
        self._next_run = 5000
        self._next_commit = 0
        self._sequence = 0
        self._file_cache: dict[str, dict[str, str]] = {}

    # ------------------------------------------------------------- fixtures
    def add_commit(
        self,
        sha: str,
        message: str,
        parents: Iterable[str] = (),
        *,
        files: dict[str, str] | None = None,
        author: str | None = None,
    ) -> dict[str, Any]:
        self._sequence += 1
        commit = {
            "sha": sha,
            "message": message,
            "parents": list(parents),
            "files": dict(files or {}),
            "author": author,
            "sequence": self._sequence,
        }
        self.commits[sha] = commit
        self._file_cache.pop(sha, None)
        return commit

    def set_branch(self, name: str, sha: str) -> None:
        self.branches[name] = sha

    def seed_release(
        self,
        tag: str,
        sha: str,
        *,
        name: str | None = None,
        published_at: str = "2026-10-20T00:00:00Z",
    ) -> dict[str, Any]:
        self.tags[tag] = sha
        release = {
            "tag_name": tag,
            "target_commitish": sha,
            "name": name or tag,
            "body": "",
            "draft": False,
            "prerelease": False,
            "published_at": published_at,
            "created_at": published_at,
        }
        self.releases.append(release)
        return release

    # ------------------------------------------------------------ refs/read
    def _resolve(self, ref: str) -> str:
        if ref in self.branches:
            return self.branches[ref]
        if ref in self.commits:
            return ref
        if ref in self.tags:
            return self.tags[ref]
        for sha in self.commits:
            if sha.startswith(ref):
                return sha
        raise ReleaseError("ref_not_found", f"fake GitHub cannot resolve {ref!r}")

    def _reachable(self, sha: str) -> dict[str, dict[str, Any]]:
        seen: dict[str, dict[str, Any]] = {}
        stack = [sha]
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            commit = self.commits.get(current)
            if commit is None:
                raise ReleaseError("commit_not_found", f"fake GitHub has no commit {current!r}")
            seen[current] = commit
            stack.extend(commit["parents"])
        return seen

    def _files(self, sha: str) -> dict[str, str]:
        if sha in self._file_cache:
            return self._file_cache[sha]
        commit = self.commits[sha]
        files: dict[str, str] = {}
        for parent in commit["parents"]:
            files.update(self._files(parent))
        files.update(commit.get("files") or {})
        self._file_cache[sha] = files
        return files

    def get_repo(self) -> dict[str, Any]:
        return {
            "full_name": self.repository,
            "html_url": f"https://github.com/{self.repository}",
            "default_branch": "master",
        }

    def get_branch(self, name: str) -> dict[str, Any] | None:
        sha = self.branches.get(name)
        if not sha:
            return None
        return {"name": name, "commit": {"sha": sha}}

    def get_commit(self, sha: str) -> dict[str, Any]:
        commit = self.commits.get(sha)
        if commit is None:
            raise ReleaseError("commit_not_found", f"fake GitHub has no commit {sha!r}")
        return {
            "sha": sha,
            "commit": {"message": commit["message"]},
            "parents": [{"sha": parent} for parent in commit["parents"]],
            "files": self._files(sha),
        }

    def compare(self, base: str, head: str) -> dict[str, Any]:
        base_sha = self._resolve(base)
        head_sha = self._resolve(head)
        base_reachable = self._reachable(base_sha)
        head_reachable = self._reachable(head_sha)
        ahead = [
            commit
            for sha, commit in head_reachable.items()
            if sha not in base_reachable
        ]
        behind = [
            commit
            for sha, commit in base_reachable.items()
            if sha not in head_reachable
        ]
        ahead.sort(key=lambda commit: commit["sequence"])
        behind.sort(key=lambda commit: commit["sequence"])
        if base_sha == head_sha:
            status = "identical"
        elif base_sha in head_reachable:
            status = "ahead"
        elif head_sha in base_reachable:
            status = "behind"
        else:
            status = "diverged"
        return {
            "status": status,
            "ahead_by": len(ahead),
            "behind_by": len(behind),
            "commits": [
                {
                    "sha": commit["sha"],
                    "commit": {"message": commit["message"]},
                    "author": {"login": commit.get("author")},
                }
                for commit in ahead
            ],
        }

    def get_content_text(self, path: str, ref: str) -> str:
        sha = self._resolve(ref)
        files = self._files(sha)
        if path not in files:
            raise ReleaseError("file_missing", f"fake GitHub has no {path} at {sha}")
        return files[path]

    def list_releases(self) -> list[dict[str, Any]]:
        return [dict(release) for release in self.releases]

    def get_release_by_tag(self, tag: str) -> dict[str, Any] | None:
        for release in self.releases:
            if release.get("tag_name") == tag:
                return dict(release)
        return None

    def get_tag_ref(self, tag: str) -> dict[str, Any] | None:
        sha = self.tags.get(tag)
        if not sha:
            return None
        return {"ref": f"refs/tags/{tag}", "object": {"sha": sha, "type": "commit"}}

    def resolve_tag_commit(self, tag: str) -> str | None:
        return self.tags.get(tag)

    # --------------------------------------------------------------- pulls
    def list_pull_requests(
        self,
        *,
        state: str = "open",
        head: str | None = None,
        base: str | None = None,
    ) -> list[dict[str, Any]]:
        head_ref = head.split(":", 1)[1] if head and ":" in head else head
        results = []
        for pull in self.pulls.values():
            if state != "all" and pull.get("state") != state:
                continue
            if head_ref is not None and (pull.get("head") or {}).get("ref") != head_ref:
                continue
            if base is not None and (pull.get("base") or {}).get("ref") != base:
                continue
            results.append(dict(pull))
        return sorted(results, key=lambda pull: pull["number"])

    def get_pull_request(self, number: int) -> dict[str, Any]:
        return dict(self.pulls[number])

    def create_pull_request(self, *, title: str, head: str, base: str, body: str, draft: bool = False) -> dict[str, Any]:
        self._next_pull += 1
        number = self._next_pull
        head_sha = self.branches.get(head)
        pull = {
            "number": number,
            "title": title,
            "body": body,
            "state": "open",
            "draft": draft,
            "merged": False,
            "merged_at": None,
            "merge_commit_sha": None,
            "merged_by": None,
            "head": {
                "ref": head,
                "sha": head_sha,
                "repo": {"full_name": self.repository},
            },
            "base": {"ref": base, "sha": self.branches.get(base)},
        }
        self.pulls[number] = pull
        self.pulls_created.append(dict(pull))
        return dict(pull)

    def update_pull_request(self, number: int, **fields: Any) -> dict[str, Any]:
        pull = self.pulls[number]
        pull.update(fields)
        self.pulls_updated.append({"number": number, **fields})
        return dict(pull)

    def add_issue_comment(self, number: int, body: str) -> None:
        self.comments.append({"number": number, "body": body})

    def get_commit_pulls(self, sha: str) -> list[dict[str, Any]]:
        results = []
        for pull in self.pulls.values():
            if pull.get("merge_commit_sha") == sha:
                results.append(dict(pull))
            elif (pull.get("head") or {}).get("sha") == sha:
                results.append(dict(pull))
        return results

    def merge_pull(self, number: int, *, merged_by: str = "maintainer", merge_sha: str | None = None) -> str:
        pull = self.pulls[number]
        head_ref = pull["head"]["ref"]
        base_ref = pull["base"]["ref"]
        head_sha = self.branches[head_ref]
        base_sha = self.branches[base_ref]
        self._next_commit += 1
        if merge_sha is None:
            merge_sha = f"merge{self._next_commit:038d}"
        self.add_commit(
            merge_sha,
            f"Merge pull request #{number} from {head_ref}",
            [base_sha, head_sha],
        )
        self.branches[base_ref] = merge_sha
        pull.update(
            {
                "state": "closed",
                "merged": True,
                "merged_at": _now_iso(),
                "merge_commit_sha": merge_sha,
                "merged_by": {"login": merged_by},
                "head": {
                    "ref": head_ref,
                    "sha": head_sha,
                    "repo": {"full_name": self.repository},
                },
                "base": {"ref": base_ref, "sha": base_sha},
            }
        )
        return merge_sha

    # --------------------------------------------------------------- checks
    def set_checks(self, sha: str, specs: Iterable[dict[str, Any]] | None = None) -> None:
        if specs is None:
            specs = [
                {"name": name, "status": "completed", "conclusion": "success"}
                for name in REQUIRED_CHECK_NAMES
            ]
        runs = []
        for spec in specs:
            self._next_run += 1
            run = {
                "id": self._next_run,
                "name": spec.get("name"),
                "status": spec.get("status", "completed"),
                "conclusion": spec.get("conclusion"),
                "head_sha": spec.get("head_sha", sha),
            }
            runs.append(run)
        self.check_runs[sha] = runs

    def list_check_runs(self, sha: str) -> list[dict[str, Any]]:
        return [dict(run) for run in self.check_runs.get(sha, [])]

    # ------------------------------------------------------------ workflows
    def _add_workflow_run(
        self,
        *,
        event: str,
        head_sha: str,
        behavior: str,
    ) -> dict[str, Any]:
        self._next_run += 1
        if behavior == "pending":
            status, conclusion = "in_progress", None
        elif behavior in ("failure", "cancelled"):
            status, conclusion = "completed", behavior
        else:
            status, conclusion = "completed", "success"
        run = {
            "id": self._next_run,
            "name": "Docker Release",
            "event": event,
            "status": status,
            "conclusion": conclusion,
            "head_sha": head_sha,
            "created_at": _now_iso(),
        }
        self.workflow_runs.append(run)
        return run

    def create_publisher_run(self, *, event: str, head_sha: str, behavior: str = "success") -> dict[str, Any]:
        return self._add_workflow_run(event=event, head_sha=head_sha, behavior=behavior)

    def list_workflow_runs(
        self,
        workflow: str,
        *,
        head_sha: str | None = None,
        event: str | None = None,
    ) -> list[dict[str, Any]]:
        results = []
        for run in self.workflow_runs:
            if head_sha is not None and run.get("head_sha") != head_sha:
                continue
            if event is not None and run.get("event") != event:
                continue
            results.append(dict(run))
        return results

    def dispatch_workflow(self, workflow: str, *, ref: str, inputs: dict[str, str]) -> None:
        self.dispatches.append({"workflow": workflow, "ref": ref, "inputs": dict(inputs)})
        head_sha = self._resolve(ref) if ref in self.branches or ref in self.tags or ref in self.commits else ref
        self._add_workflow_run(event="workflow_dispatch", head_sha=head_sha, behavior=self.dispatch_behavior)

    def cancel_workflow_run(self, run_id: int) -> None:
        for run in self.workflow_runs:
            if run.get("id") == run_id:
                run["status"] = "completed"
                run["conclusion"] = "cancelled"
                return

    # -------------------------------------------------------------- writes
    def create_tag_ref(self, tag: str, sha: str) -> dict[str, Any]:
        if tag in self.tags:
            raise ReleaseError("tag_exists", f"tag {tag} already exists")
        self.tags[tag] = sha
        self.tags_created.append(tag)
        return {"ref": f"refs/tags/{tag}", "object": {"sha": sha, "type": "commit"}}

    def create_release(
        self,
        *,
        tag: str,
        target_commitish: str,
        name: str,
        body: str,
        draft: bool = False,
        prerelease: bool = False,
    ) -> dict[str, Any]:
        if self.get_release_by_tag(tag) is not None:
            raise ReleaseError("release_exists", f"release {tag} already exists")
        now = _now_iso()
        release = {
            "tag_name": tag,
            "target_commitish": target_commitish,
            "name": name,
            "body": body,
            "draft": draft,
            "prerelease": prerelease,
            "created_at": now,
            "published_at": None if draft else now,
        }
        self.releases.append(release)
        self.releases_created.append(dict(release))
        if self.simulate_release_event and not draft and "<!-- pinchflat-release-automation:publisher=dispatch -->" not in body:
            self._add_workflow_run(
                event="release",
                head_sha=target_commitish,
                behavior=self.release_event_behavior,
            )
        return dict(release)

    def merge_into(self, *, base: str, head: str, message: str) -> dict[str, Any]:
        base_sha = self._resolve(base)
        head_sha = self._resolve(head)
        if (base, head) in self.merge_conflicts or (head_sha, base_sha) in self.merge_conflicts:
            raise GitHubConflict("fake merge conflict", status=409)
        if base_sha == head_sha or head_sha in self._reachable(base_sha):
            return {"merged": True, "sha": base_sha}
        self._next_commit += 1
        merge_sha = f"sync{self._next_commit:038d}"
        self.add_commit(merge_sha, message, [base_sha, head_sha])
        self.branches[base] = merge_sha
        return {"merged": True, "sha": merge_sha}


class FakePublisher:
    def __init__(self, github: FakeGitHub):
        self.github = github
        self.pushes: list[dict[str, Any]] = []
        self.fail_next = False

    def publish(self, branch: str, sha: str, expected_old: str | None) -> None:
        if self.fail_next:
            self.fail_next = False
            raise ReleaseError("push_rejected", "fake lease rejection")
        current = self.github.branches.get(branch)
        if expected_old and current != expected_old:
            raise ReleaseError("push_rejected", "fake stale lease rejection")
        if expected_old is None and current is not None:
            raise ReleaseError("push_rejected", "fake new-branch lease rejection")
        self.github.branches[branch] = sha
        self.pushes.append({"branch": branch, "sha": sha, "expected_old": expected_old})


class FakeRegistry:
    def __init__(
        self,
        missing: Iterable[str] = (),
        *,
        platforms: tuple[str, ...] = ("linux/amd64", "linux/arm64"),
        custom_digests: dict[str, str] | None = None,
        custom_platforms: dict[str, tuple[str, ...]] | None = None,
    ):
        self.missing = set(missing)
        self.platforms = platforms
        self.custom_digests = dict(custom_digests or {})
        self.custom_platforms = dict(custom_platforms or {})
        self.calls: list[tuple[str, str]] = []

    def inspect(self, image: str, tag: str) -> ManifestInfo:
        self.calls.append((image, tag))
        if tag in self.missing:
            raise ReleaseError("registry_tag_missing", f"missing fake tag {tag}")
        if tag in self.custom_digests:
            digest = self.custom_digests[tag]
        else:
            suffix = "postgres" if "postgres" in tag else "sqlite"
            digest = "sha256:" + hashlib.sha256(f"{image}:{suffix}".encode("utf-8")).hexdigest()

        plats = self.custom_platforms.get(tag, self.platforms)
        return ManifestInfo(digest=digest, platforms=plats)


class GitFixture:
    def __init__(self, path: Path, master_sha: str, dev_sha: str):
        self.path = path
        self.master_sha = master_sha
        self.dev_sha = dev_sha

    @classmethod
    def create(cls, path: Path, *, version: str = "2026.10.0") -> "GitFixture":
        path.mkdir(parents=True, exist_ok=True)
        fixture = cls(path, "", "")
        fixture.run(["init", "--quiet", "--initial-branch=master"])
        fixture.run(["config", "user.name", "Release Test"])
        fixture.run(["config", "user.email", "release-test@example.invalid"])
        fixture.write("mix.exs", _mix_exs(version))
        fixture.write("README.md", "# Fixture\n")
        fixture.run(["add", "-A"])
        fixture.run(["commit", "--quiet", "-m", "chore: initial"])
        fixture.master_sha = fixture.rev("HEAD")
        fixture.run(["checkout", "--quiet", "-b", "dev"])
        fixture.write("lib/dev_change.txt", "one\n")
        fixture.run(["add", "-A"])
        fixture.run(["commit", "--quiet", "-m", "feat: add dev change (#201)"])
        fixture.dev_sha = fixture.rev("HEAD")
        fixture.run(["checkout", "--quiet", "master"])
        return fixture

    def run(self, args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            ["git", *args],
            cwd=self.path,
            text=True,
            capture_output=True,
            shell=False,
        )
        if check and completed.returncode != 0:
            raise AssertionError(
                f"git {' '.join(args)} failed: {completed.stderr or completed.stdout}"
            )
        return completed

    def rev(self, ref: str) -> str:
        return self.run(["rev-parse", ref]).stdout.strip()

    def write(self, name: str, content: str) -> None:
        target = self.path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")

    def add_commit(self, branch: str, *, files: dict[str, str], message: str) -> str:
        self.run(["checkout", "--quiet", branch])
        for name, content in files.items():
            self.write(name, content)
        self.run(["add", "-A"])
        self.run(["commit", "--quiet", "-m", message])
        return self.rev("HEAD")

    def history(self, sha: str) -> list[dict[str, Any]]:
        shas = self.run(["rev-list", "--reverse", "--topo-order", sha]).stdout.split()
        history = []
        for item in shas:
            parents = self.run(["show", "-s", "--format=%P", item]).stdout.strip().split()
            message = self.run(["show", "-s", "--format=%s", item]).stdout.strip()
            mix_exs = self.run(["show", f"{item}:mix.exs"]).stdout
            history.append(
                {
                    "sha": item,
                    "parents": parents,
                    "message": message,
                    "mix_exs": mix_exs,
                }
            )
        return history

    def parent_count(self, sha: str) -> int:
        return len(self.run(["show", "-s", "--format=%P", sha]).stdout.split())


def register_history(github: FakeGitHub, fixture: GitFixture, sha: str) -> None:
    for item in fixture.history(sha):
        if item["sha"] in github.commits:
            continue
        github.add_commit(
            item["sha"],
            item["message"],
            item["parents"],
            files={
                "mix.exs": item["mix_exs"],
                ".github/workflows/docker_release.yml": (Path(__file__).resolve().parents[2] / ".github/workflows/docker_release.yml").read_text(encoding="utf-8"),
            },
        )


def _mix_exs(version: str) -> str:
    return "\n".join(
        [
            "defmodule Pinchflat.MixProject do",
            "  use Mix.Project",
            "",
            "  def project do",
            "    [",
            "      app: :pinchflat,",
            f'      version: "{version}",',
            '      elixir: "~> 1.17"',
            "    ]",
            "  end",
            "end",
            "",
        ]
    )
