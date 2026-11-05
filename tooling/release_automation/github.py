"""Minimal GitHub REST client built on urllib.

The client is deliberately small: it exposes only the operations the release
engine needs and passes every request body as JSON. No release note, branch,
tag, or metadata value is ever interpolated into a shell command.
"""

from __future__ import annotations

import base64
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from .errors import GitHubConflict, ReleaseError


class GitHubAPIError(ReleaseError):
    def __init__(self, status: int, message: str, *, path: str):
        super().__init__("github_api_error", message, details={"status": status, "path": path})
        self.status = status


class GitHubClient:
    def __init__(
        self,
        repository: str,
        token: str,
        *,
        api_url: str = "https://api.github.com",
        timeout: int = 30,
        user_agent: str = "pinchflat-release-automation",
    ):
        if "/" not in repository:
            raise ReleaseError("invalid_repository", "repository must be owner/name")
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.timeout = timeout
        self.user_agent = user_agent

    # ------------------------------------------------------------------ HTTP
    def _request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
        allow_404: bool = False,
        expected: tuple[int, ...] = (200, 201, 204),
    ) -> Any:
        url = f"{self.api_url}{path}"
        if params:
            cleaned = {key: value for key, value in params.items() if value is not None}
            if cleaned:
                url = f"{url}?{urllib.parse.urlencode(cleaned, doseq=True)}"
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": self.user_agent,
        }
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"

        last_error: Exception | None = None
        for attempt in range(3):
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    status = response.status
                    raw = response.read()
                    if status not in expected:
                        raise GitHubAPIError(status, f"unexpected GitHub status {status}", path=path)
                    if not raw:
                        return None
                    try:
                        return json.loads(raw.decode("utf-8"))
                    except json.JSONDecodeError:
                        return raw.decode("utf-8", errors="replace")
            except urllib.error.HTTPError as exc:
                raw = exc.read().decode("utf-8", errors="replace")
                if exc.code == 404 and allow_404:
                    return None
                if exc.code in (502, 503, 504) and attempt < 2:
                    last_error = exc
                    time.sleep(1 + attempt)
                    continue
                message = _github_error_message(raw) or f"GitHub returned HTTP {exc.code}"
                raise GitHubAPIError(exc.code, message, path=path) from exc
            except urllib.error.URLError as exc:
                last_error = exc
                if attempt < 2:
                    time.sleep(1 + attempt)
                    continue
                raise ReleaseError("github_unreachable", f"could not reach GitHub: {exc.reason}") from exc
        raise ReleaseError("github_unreachable", f"could not reach GitHub: {last_error}")

    def _paginated(self, path: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        page = 1
        while page <= 100:
            query = dict(params or {})
            query.update({"per_page": 100, "page": page})
            batch = self._request("GET", path, params=query)
            if not isinstance(batch, list):
                raise ReleaseError("github_response", f"expected a list from {path}")
            results.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        return results

    # --------------------------------------------------------------- readers
    def get_repo(self) -> dict[str, Any]:
        data = self._request("GET", f"/repos/{self.repository}")
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid repository response")
        return data

    def get_branch(self, name: str) -> dict[str, Any] | None:
        data = self._request(
            "GET",
            f"/repos/{self.repository}/branches/{urllib.parse.quote(name, safe='')}",
            allow_404=True,
        )
        return data if isinstance(data, dict) else None

    def get_commit(self, sha: str) -> dict[str, Any]:
        data = self._request(
            "GET",
            f"/repos/{self.repository}/commits/{urllib.parse.quote(sha, safe='')}",
        )
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid commit response")
        return data

    def compare(self, base: str, head: str) -> dict[str, Any]:
        base_ref = urllib.parse.quote(base, safe="")
        head_ref = urllib.parse.quote(head, safe="")
        data = self._request("GET", f"/repos/{self.repository}/compare/{base_ref}...{head_ref}")
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid compare response")
        return data

    def list_releases(self) -> list[dict[str, Any]]:
        return self._paginated(f"/repos/{self.repository}/releases")

    def get_release_by_tag(self, tag: str) -> dict[str, Any] | None:
        data = self._request(
            "GET",
            f"/repos/{self.repository}/releases/tags/{urllib.parse.quote(tag, safe='')}",
            allow_404=True,
        )
        return data if isinstance(data, dict) else None

    def get_tag_ref(self, tag: str) -> dict[str, Any] | None:
        data = self._request(
            "GET",
            f"/repos/{self.repository}/git/ref/tags/{urllib.parse.quote(tag, safe='')}",
            allow_404=True,
        )
        return data if isinstance(data, dict) else None

    def resolve_tag_commit(self, tag: str) -> str | None:
        ref = self.get_tag_ref(tag)
        if not ref:
            return None
        target = ref.get("object") or {}
        sha = target.get("sha")
        if not sha:
            return None
        if target.get("type") == "tag":
            annotated = self._request(
                "GET",
                f"/repos/{self.repository}/git/tags/{urllib.parse.quote(sha, safe='')}",
            )
            if isinstance(annotated, dict):
                return (annotated.get("object") or {}).get("sha") or sha
        return sha

    def get_content_text(self, path: str, ref: str) -> str:
        data = self._request(
            "GET",
            f"/repos/{self.repository}/contents/{urllib.parse.quote(path, safe='/')}",
            params={"ref": ref},
        )
        if not isinstance(data, dict):
            raise ReleaseError("github_response", f"unexpected content response for {path}")
        if data.get("encoding") != "base64" or not data.get("content"):
            raise ReleaseError("github_response", f"{path} is too large or not readable through the contents API")
        try:
            return base64.b64decode(data["content"]).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise ReleaseError("github_response", f"could not decode {path}") from exc

    def list_pull_requests(
        self,
        *,
        state: str = "open",
        head: str | None = None,
        base: str | None = None,
    ) -> list[dict[str, Any]]:
        return self._paginated(
            f"/repos/{self.repository}/pulls",
            {"state": state, "head": head, "base": base},
        )

    def get_pull_request(self, number: int) -> dict[str, Any]:
        data = self._request("GET", f"/repos/{self.repository}/pulls/{number}")
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid pull request response")
        return data

    def get_commit_pulls(self, sha: str) -> list[dict[str, Any]]:
        data = self._request(
            "GET",
            f"/repos/{self.repository}/commits/{urllib.parse.quote(sha, safe='')}/pulls",
        )
        if not isinstance(data, list):
            raise ReleaseError("github_response", "invalid commit pull list")
        return data

    def list_check_runs(self, sha: str) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        page = 1
        while page <= 50:
            data = self._request(
                "GET",
                f"/repos/{self.repository}/commits/{urllib.parse.quote(sha, safe='')}/check-runs",
                params={"per_page": 100, "page": page, "filter": "latest"},
            )
            if not isinstance(data, dict):
                raise ReleaseError("github_response", "invalid check run response")
            batch = data.get("check_runs") or []
            results.extend(batch)
            if len(results) >= int(data.get("total_count") or 0) or len(batch) < 100:
                break
            page += 1
        return results

    def list_workflow_runs(
        self,
        workflow: str,
        *,
        head_sha: str | None = None,
        event: str | None = None,
    ) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        page = 1
        while page <= 20:
            data = self._request(
                "GET",
                f"/repos/{self.repository}/actions/workflows/{urllib.parse.quote(workflow, safe='')}/runs",
                params={"per_page": 100, "page": page, "head_sha": head_sha, "event": event},
            )
            if not isinstance(data, dict):
                raise ReleaseError("github_response", "invalid workflow run response")
            batch = data.get("workflow_runs") or []
            results.extend(batch)
            if len(results) >= int(data.get("total_count") or 0) or len(batch) < 100:
                break
            page += 1
        return results

    # --------------------------------------------------------------- writers
    def create_pull_request(
        self,
        *,
        title: str,
        head: str,
        base: str,
        body: str,
        draft: bool = False,
    ) -> dict[str, Any]:
        data = self._request(
            "POST",
            f"/repos/{self.repository}/pulls",
            body={"title": title, "head": head, "base": base, "body": body, "draft": draft},
        )
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid created pull request")
        return data

    def update_pull_request(self, number: int, **fields: Any) -> dict[str, Any]:
        data = self._request(
            "PATCH",
            f"/repos/{self.repository}/pulls/{number}",
            body={key: value for key, value in fields.items() if value is not None},
        )
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid updated pull request")
        return data

    def add_issue_comment(self, number: int, body: str) -> None:
        self._request(
            "POST",
            f"/repos/{self.repository}/issues/{number}/comments",
            body={"body": body},
        )

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
        data = self._request(
            "POST",
            f"/repos/{self.repository}/releases",
            body={
                "tag_name": tag,
                "target_commitish": target_commitish,
                "name": name,
                "body": body,
                "draft": draft,
                "prerelease": prerelease,
            },
        )
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid created release")
        return data

    def create_tag_ref(self, tag: str, sha: str) -> dict[str, Any]:
        data = self._request(
            "POST",
            f"/repos/{self.repository}/git/refs",
            body={"ref": f"refs/tags/{tag}", "sha": sha},
        )
        if not isinstance(data, dict):
            raise ReleaseError("github_response", "invalid created tag ref")
        return data

    def dispatch_workflow(self, workflow: str, *, ref: str, inputs: dict[str, str]) -> None:
        self._request(
            "POST",
            f"/repos/{self.repository}/actions/workflows/{urllib.parse.quote(workflow, safe='')}/dispatches",
            body={"ref": ref, "inputs": inputs},
            expected=(204,),
        )

    def cancel_workflow_run(self, run_id: int) -> None:
        self._request(
            "POST",
            f"/repos/{self.repository}/actions/runs/{run_id}/cancel",
            expected=(202,),
        )

    def merge_into(self, *, base: str, head: str, message: str) -> dict[str, Any]:
        try:
            data = self._request(
                "POST",
                f"/repos/{self.repository}/merges",
                body={"base": base, "head": head, "commit_message": message},
                expected=(200, 201, 204),
            )
        except GitHubAPIError as exc:
            if exc.status in (405, 409, 422):
                raise GitHubConflict(
                    f"GitHub could not merge {head} into {base}",
                    status=exc.status,
                    details={"api_message": exc.message},
                ) from exc
            raise
        if data is None:
            return {"merged": True, "sha": None}
        if isinstance(data, dict):
            return {"merged": True, "sha": data.get("sha")}
        return {"merged": True, "sha": None}


def _github_error_message(raw: str) -> str | None:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return raw.strip()[:500] or None
    if isinstance(payload, dict):
        message = payload.get("message")
        errors = payload.get("errors")
        if errors:
            return f"{message}: {json.dumps(errors, ensure_ascii=False)[:1000]}"
        if message:
            return str(message)
    return None
