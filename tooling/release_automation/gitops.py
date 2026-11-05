"""Small, explicit wrapper around the local git CLI.

Only branch construction and fast-forward publication live here. Tags and
releases are created through the GitHub API so the release workflow has one
source of truth for immutable references.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Sequence

from .errors import MergeConflict, ReleaseError


class GitError(ReleaseError):
    def __init__(self, code: str, message: str, *, stderr: str = ""):
        super().__init__(code, message, details={"stderr": stderr[-2000:]} if stderr else None)
        self.stderr = stderr


class GitRepo:
    def __init__(
        self,
        path: str | Path,
        *,
        remote: str = "origin",
        author_name: str = "BadFella",
        author_email: str = "19318225+TheBadFella@users.noreply.github.com",
    ):
        self.path = Path(path).resolve()
        self.remote = remote
        self.author_name = author_name
        self.author_email = author_email

    def _run(self, args: Sequence[str], *, check: bool = True, timeout: int = 300) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.setdefault("GIT_TERMINAL_PROMPT", "0")
        env.setdefault("GIT_ASKPASS", "echo")
        command = ["git", *args]
        completed = subprocess.run(
            command,
            cwd=self.path,
            text=True,
            capture_output=True,
            timeout=timeout,
            env=env,
            shell=False,
        )
        if check and completed.returncode != 0:
            raise GitError(
                "git_failed",
                f"git {' '.join(args)} failed with exit code {completed.returncode}",
                stderr=completed.stderr or completed.stdout,
            )
        return completed

    def ensure_clean(self) -> None:
        status = self._run(["status", "--porcelain", "--untracked-files=no"]).stdout.strip()
        if status:
            raise ReleaseError(
                "worktree_dirty",
                "the release worktree has modified tracked files; refusing to build a candidate",
                details={"status": status[:4000]},
            )

    def fetch(self) -> None:
        self._run(["fetch", "--prune", "--tags", self.remote, "+refs/heads/*:refs/remotes/" + self.remote + "/*"])

    def resolve(self, ref: str) -> str:
        if not ref:
            raise ReleaseError("missing_ref", "a git ref is required")
        completed = self._run(["rev-parse", "--verify", f"{ref}^{{commit}}"], check=False)
        if completed.returncode != 0:
            raise ReleaseError("ref_not_found", f"git ref {ref!r} could not be resolved")
        return completed.stdout.strip()

    def branch_exists(self, name: str) -> bool:
        completed = self._run(["show-ref", "--verify", "--quiet", f"refs/heads/{name}"], check=False)
        return completed.returncode == 0

    def current_ref(self) -> str:
        completed = self._run(["symbolic-ref", "--quiet", "--short", "HEAD"], check=False)
        if completed.returncode == 0 and completed.stdout.strip():
            return completed.stdout.strip()
        return self.head_sha()

    def head_sha(self) -> str:
        return self.resolve("HEAD")

    def checkout(self, ref: str) -> None:
        self._run(["checkout", "--quiet", ref])

    def create_reset_branch(self, name: str, sha: str) -> None:
        self._run(["checkout", "--quiet", "-B", name, sha])

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        completed = self._run(["merge-base", "--is-ancestor", ancestor, descendant], check=False)
        if completed.returncode == 0:
            return True
        if completed.returncode == 1:
            return False
        raise GitError(
            "git_failed",
            f"git merge-base --is-ancestor failed with exit code {completed.returncode}",
            stderr=completed.stderr,
        )

    def merge(self, commit: str, *, message: str) -> None:
        completed = self._run(
            [
                "-c",
                f"user.name={self.author_name}",
                "-c",
                f"user.email={self.author_email}",
                "merge",
                "--no-ff",
                "--no-edit",
                "-m",
                message,
                commit,
            ],
            check=False,
        )
        if completed.returncode != 0:
            self.abort_merge()
            raise MergeConflict(
                f"could not merge {commit} into the release candidate",
                details={"stderr": (completed.stderr or completed.stdout)[-2000:]},
            )

    def abort_merge(self) -> None:
        self._run(["merge", "--abort"], check=False)

    def read_text(self, path: str) -> str:
        file_path = self.path / path
        try:
            return file_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ReleaseError("file_missing", f"could not read {path}: {exc}") from exc

    def write_text(self, path: str, content: str) -> None:
        file_path = self.path / path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(content, encoding="utf-8", newline="\n")

    def commit_all(self, message: str) -> str | None:
        # Only tracked changes belong in the candidate commit. Running the
        # Python engine creates __pycache__, and the workflow worktree may hold
        # other untracked runner artifacts.
        self._run(["add", "--update"])
        diff = self._run(["diff", "--cached", "--quiet"], check=False)
        if diff.returncode == 0:
            return None
        self._run(
            [
                "-c",
                f"user.name={self.author_name}",
                "-c",
                f"user.email={self.author_email}",
                "commit",
                "--quiet",
                "-m",
                message,
            ]
        )
        return self.head_sha()

    def push_branch(self, branch: str, *, expected_old: str | None = None) -> None:
        refspec = f"refs/heads/{branch}:refs/heads/{branch}"
        # Standard fast-forward push. Never force-push or reset shared candidate history.
        completed = self._run(["push", self.remote, refspec], check=False)
        if completed.returncode != 0:
            raise ReleaseError(
                "push_rejected",
                f"pushing {branch} was rejected; the candidate changed or is not a fast-forward",
                details={"stderr": (completed.stderr or completed.stdout)[-2000:]},
            )

    def tag_exists(self, tag: str) -> bool:
        completed = self._run(["show-ref", "--verify", "--quiet", f"refs/tags/{tag}"], check=False)
        return completed.returncode == 0

    def show_file(self, ref: str, path: str) -> str:
        completed = self._run(["show", f"{ref}:{path}"], check=False)
        if completed.returncode != 0:
            raise ReleaseError("file_missing", f"{path} does not exist at {ref}")
        return completed.stdout


class GitPushPublisher:
    """Publish a candidate branch using the local git remote."""

    def __init__(self, git: GitRepo):
        self.git = git
        self.pushes: list[dict[str, str | None]] = []

    def publish(self, branch: str, sha: str, expected_old: str | None) -> None:
        self.git.push_branch(branch, expected_old=expected_old)
        self.pushes.append({"branch": branch, "sha": sha, "expected_old": expected_old})
