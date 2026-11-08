"""Release PR body rendering, metadata validation, and release note extraction.

Everything the maintainer writes is treated as literal text. Nothing in this
module builds a shell command, so notes containing ``$(...)`` or backticks are
published exactly as typed.
"""

from __future__ import annotations

import json
import re
from typing import Any, Iterable

from .errors import ReleaseError

GENERATED_START = "<!-- GENERATED-CHANGES-START -->"
GENERATED_END = "<!-- GENERATED-CHANGES-END -->"
NOTES_START = "<!-- RELEASE-NOTES-START -->"
NOTES_END = "<!-- RELEASE-NOTES-END -->"
FOOTER_START = "<!-- RELEASE-FOOTER-START -->"
FOOTER_END = "<!-- RELEASE-FOOTER-END -->"
CHECKLIST_START = "<!-- INTERNAL-CHECKLIST-START -->"
CHECKLIST_END = "<!-- INTERNAL-CHECKLIST-END -->"
METADATA_START = "<!-- RELEASE-METADATA-START -->"
METADATA_END = "<!-- RELEASE-METADATA-END -->"

MANAGED_BY = "pinchflat-release-automation"
DISPATCH_MARKER = "<!-- pinchflat-release-automation:publisher=dispatch -->"
SCHEMA_VERSION = 1

DEFAULT_NOTES = (
    "_Add the maintainer release notes here. This text is preserved when the "
    "candidate is refreshed._"
)
DEFAULT_CHECKLIST = "\n".join(
    [
        "- [ ] Required checks passed on the candidate head (SQLite, PostgreSQL, schema migrations).",
        "- [ ] Release notes reviewed with direct wiki guide links and contributor thanks.",
        "- [ ] Version baseline and tag availability checked.",
        "- [ ] Wiki version notices and upgrade guidance prepared for publication.",
    ]
)

RELEASE_HEADING = re.compile(r"^##\s+Release\s+(?:candidate\s+)?v?[0-9]{4}\.[0-9]{1,2}\.[0-9]+\s*$", re.MULTILINE)
PR_NUMBER = re.compile(r"\(#([0-9]+)\)")
AUTOMATION_SUBJECT = re.compile(
    r"^(?:"
    r"release:\s*prepare\b"
    r"|Merge .* into master for release candidate\b"
    r"|Merge master into dev\b"
    r"|Merge pull request #"
    r"|Merge branch "
    r")"
)


def _marker_offsets(text: str, marker: str) -> list[int]:
    return [match.start() for match in re.finditer(re.escape(marker), text)]


def extract_block(text: str | None, start_marker: str, end_marker: str, *, required: bool = False) -> str | None:
    """Return one marker-delimited block, rejecting duplicates and stray markers."""
    if not text:
        if required:
            raise ReleaseError("marker_missing", f"missing {start_marker} block")
        return None
    starts = _marker_offsets(text, start_marker)
    ends = _marker_offsets(text, end_marker)
    if not starts and not ends:
        if required:
            raise ReleaseError("marker_missing", f"missing {start_marker} block")
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] > ends[0]:
        raise ReleaseError(
            "marker_duplicate",
            f"expected exactly one ordered {start_marker} / {end_marker} block",
        )
    return text[starts[0] + len(start_marker) : ends[0]]


def replace_block(text: str, start_marker: str, end_marker: str, content: str) -> str:
    starts = _marker_offsets(text, start_marker)
    ends = _marker_offsets(text, end_marker)
    if len(starts) != 1 or len(ends) != 1 or starts[0] > ends[0]:
        raise ReleaseError(
            "marker_duplicate",
            f"expected exactly one ordered {start_marker} / {end_marker} block",
        )
    body = f"{start_marker}\n{content.strip()}\n{end_marker}" if content.strip() else f"{start_marker}\n{end_marker}"
    return text[: starts[0]] + body + text[ends[0] + len(end_marker) :]


def remove_block(text: str, start_marker: str, end_marker: str) -> str:
    if start_marker not in text and end_marker not in text:
        return text
    starts = _marker_offsets(text, start_marker)
    ends = _marker_offsets(text, end_marker)
    if len(starts) != 1 or len(ends) != 1 or starts[0] > ends[0]:
        raise ReleaseError(
            "marker_duplicate",
            f"expected exactly one ordered {start_marker} / {end_marker} block",
        )
    return text[: starts[0]] + text[ends[0] + len(end_marker) :]


def render_metadata(metadata: dict[str, Any]) -> str:
    payload = json.dumps(metadata, indent=2, sort_keys=True)
    return f"{METADATA_START}\n```json\n{payload}\n```\n{METADATA_END}"


def parse_metadata(body: str | None) -> dict[str, Any]:
    """Parse exactly one machine-readable metadata block from a PR body."""
    block = extract_block(body, METADATA_START, METADATA_END, required=True)
    assert block is not None
    content = block.strip()
    if content.startswith("```"):
        lines = content.splitlines()
        if lines and lines[0].strip().startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        content = "\n".join(lines).strip()
    try:
        data = json.loads(content)
    except json.JSONDecodeError as exc:
        raise ReleaseError("metadata_invalid_json", f"release metadata is not valid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ReleaseError("metadata_invalid", "release metadata must be a JSON object")
    if data.get("managed_by") != MANAGED_BY:
        raise ReleaseError("metadata_unmanaged", "release PR was not created by the release automation")
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ReleaseError(
            "metadata_schema",
            f"unsupported release metadata schema {data.get('schema_version')!r}",
        )
    return data


def _fallback_notes(existing_body: str) -> str:
    """Preserve maintainer prose when an older body predates the notes markers."""
    text = existing_body
    for start, end in (
        (METADATA_START, METADATA_END),
        (CHECKLIST_START, CHECKLIST_END),
        (GENERATED_START, GENERATED_END),
        (FOOTER_START, FOOTER_END),
    ):
        text = remove_block(text, start, end)
    for marker in (NOTES_START, NOTES_END):
        text = text.replace(marker, "")
    text = RELEASE_HEADING.sub("", text)
    return _collapse_blank_lines(text).strip()


def _collapse_blank_lines(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text.replace("\r\n", "\n"))


def _with_release_footer(text: str, metadata: dict[str, Any]) -> str:
    # Regenerate only our bounded footer; retain a correctly formatted human footer.
    text = remove_block(text, FOOTER_START, FOOTER_END).replace("\r\n", "\n").strip()
    repository = metadata["repository"]
    tag = metadata["tag_name"]
    previous = metadata.get("previous_stable_tag")
    image = f"ghcr.io/{repository.split('/', 1)[0].lower()}/pinchflat-ngx"
    base_url = f"https://github.com/{repository}"
    comparison = f"{previous}...{tag}" if previous else tag
    history_url = f"{base_url}/compare/{comparison}" if previous else f"{base_url}/commits/{tag}"
    changelog = f"Full changelog: [{comparison}]({history_url})."
    rows = [
        ("Database", "Versioned image", "Moving tag"),
        ("SQLite", f"`{image}:{tag}`", "`latest`"),
        ("PostgreSQL", f"`{image}:{tag}-postgres`", "`latest-postgres`"),
    ]
    if re.search(r"(?m)^## Container images\s*$|^\[?Full changelog", text):
        table = [
            tuple(cell.strip() for cell in line.strip().strip("|").split("|"))
            for line in text.splitlines() if line.lstrip().startswith("|")
        ]
        has_separator = any(
            len(row) == 3 and all(re.fullmatch(r":?-{3,}:?", cell) for cell in row)
            for row in table
        )
        if (
            len(re.findall(r"(?m)^## Container images\s*$", text)) != 1
            or not all(row in table for row in rows)
            or not has_separator
            or re.findall(r"(?m)^Full changelog:.*$", text) != [changelog]
        ):
            raise ReleaseError(
                "release_footer_invalid",
                "use the current SQLite/PostgreSQL image table and version-range Full changelog link, "
                "or leave these to the generated footer",
            )
        return text
    table_lines = ["| " + " | ".join(row) + " |" for row in rows]
    table_lines.insert(1, "| --- | --- | --- |")
    footer = "\n".join([
        "## Container images", "",
        "Use the versioned tags below or their moving aliases.", "",
        *table_lines, "", changelog,
    ])
    return f"{text}\n\n{FOOTER_START}\n{footer}\n{FOOTER_END}"


def render_generated_changes(
    changes: Iterable[dict[str, Any]],
    *,
    base_label: str,
    head_label: str,
    maintainer: str = "",
    limit: int = 100,
) -> str:
    all_items = list(changes)
    items = all_items[:limit]
    lines = ["### Included changes", ""]
    if not items:
        lines.append("_No releasable changes were detected._")
    for change in items:
        subject = str(change.get("subject") or "").strip()
        if not subject:
            continue
        line = f"- {subject}"
        number = change.get("pr")
        author = change.get("author")
        if number:
            line += f" (#{number})"
        if author and author.casefold() != maintainer.casefold():
            line += f". Thanks @{author}."
        lines.append(line)
    if len(all_items) > limit:
        lines.append(f"_...and {len(all_items) - limit} more commits._")
    lines.extend(["", f"_Compared `{base_label}` to `{head_label}`._"])
    return "\n".join(lines)


def render_pr_body(
    *,
    tag: str,
    generated_changes: str,
    metadata: dict[str, Any],
    existing_body: str | None = None,
) -> str:
    notes = None
    checklist = None
    if existing_body:
        notes = extract_block(existing_body, NOTES_START, NOTES_END)
        checklist = extract_block(existing_body, CHECKLIST_START, CHECKLIST_END)
        if notes is None:
            notes = _fallback_notes(existing_body)
    if notes is None:
        notes = DEFAULT_NOTES
    notes = _with_release_footer(notes, metadata)
    if checklist is None:
        checklist = DEFAULT_CHECKLIST
    elif (metadata.get("acceptance") or {}).get("status") == "invalidated":
        # Approval belongs to the previous candidate, while prose survives refresh.
        checklist = re.sub(r"(?m)^(\s*-\s*\[)[xX](\])", r"\1 \2", checklist)

    return "\n".join(
        [
            f"## Release {tag}",
            "",
            GENERATED_START,
            generated_changes.strip(),
            GENERATED_END,
            "",
            "## Release notes",
            "",
            NOTES_START,
            notes.strip(),
            NOTES_END,
            "",
            CHECKLIST_START,
            checklist.strip(),
            CHECKLIST_END,
            "",
            render_metadata(metadata),
            "",
        ]
    )


def release_body_from_pr(body: str | None) -> str:
    """Build the public release body, excluding internal checklists and metadata.

    Public content is every maintainer-visible part of the PR body except the
    internal checklist and machine-readable metadata blocks. Marker comments are
    removed, generated changes are kept, and the duplicated release heading is
    dropped because the GitHub release title already carries the version.
    """
    if not body:
        raise ReleaseError("release_notes_empty", "release PR body is empty")

    maintainer_notes = extract_block(body, NOTES_START, NOTES_END)
    if maintainer_notes is not None:
        notes_stripped = remove_block(maintainer_notes, FOOTER_START, FOOTER_END).strip()
        if not notes_stripped or DEFAULT_NOTES.strip() in notes_stripped:
            raise ReleaseError(
                "release_notes_placeholder",
                "release PR contains placeholder release notes; maintainer notes must be written before release",
            )
    else:
        fallback = _fallback_notes(body)
        if not fallback or fallback == DEFAULT_NOTES.strip():
            raise ReleaseError(
                "release_notes_placeholder",
                "release PR does not contain maintainer notes",
            )

    text = body
    text = remove_block(text, CHECKLIST_START, CHECKLIST_END)
    text = remove_block(text, METADATA_START, METADATA_END)
    for marker in (GENERATED_START, GENERATED_END, NOTES_START, NOTES_END):
        text = text.replace(marker, "")
    text = text.replace(DEFAULT_NOTES, "")
    text = RELEASE_HEADING.sub("", text)
    text = re.sub(r"(?m)^##\s+Release notes\s*$", "", text)
    text = _with_release_footer(text, parse_metadata(body))
    for marker in (FOOTER_START, FOOTER_END):
        text = text.replace(marker, "")
    text = _collapse_blank_lines(text).strip()
    if not text:
        raise ReleaseError("release_notes_empty", "release PR does not contain publishable notes")
    return text


def is_checklist_complete(body: str | None) -> bool:
    """Return True if all checklist items in the body are checked (- [x] or - [X])."""
    if not body:
        return False
    checklist = extract_block(body, CHECKLIST_START, CHECKLIST_END)
    if not checklist:
        return False
    if re.search(r"(?m)^\s*-\s*\[\s*\]", checklist):
        return False
    return bool(re.search(r"(?m)^\s*-\s*\[[xX]\]", checklist))


def validate_release_metadata(
    metadata: dict[str, Any],
    *,
    repository: str,
    proposed_version: str,
    tag_name: str,
    candidate_head_sha: str,
    target_branch: str,
    candidate_branch: str,
) -> None:
    expected = {
        "repository": repository,
        "proposed_version": proposed_version,
        "tag_name": tag_name,
        "candidate_head_sha": candidate_head_sha,
        "target_branch": target_branch,
        "release_branch": candidate_branch,
    }
    for key, value in expected.items():
        actual = metadata.get(key)
        if actual != value:
            raise ReleaseError(
                "metadata_mismatch",
                f"release metadata {key} is {actual!r}, expected {value!r}",
            )
    for key in ("source_sha", "master_baseline_sha", "previous_stable_tag"):
        if key not in metadata:
            raise ReleaseError("metadata_incomplete", f"release metadata is missing {key}")


def collect_changes(comparison: dict[str, Any], *, head_label: str) -> list[dict[str, Any]]:
    """Turn a GitHub compare payload into bounded, deduplicated release bullets."""
    changes: list[dict[str, Any]] = []
    seen: set[str] = set()
    for commit in comparison.get("commits") or []:
        sha = commit.get("sha") or ""
        if sha and sha in seen:
            continue
        if sha:
            seen.add(sha)
        message = (commit.get("commit") or {}).get("message") or ""
        subject = message.splitlines()[0].strip() if message else ""
        if not subject or AUTOMATION_SUBJECT.match(subject):
            continue
        author = None
        author_object = commit.get("author") or {}
        if isinstance(author_object, dict):
            author = author_object.get("login")
        if author and author.endswith("[bot]"):
            author = None
        number = None
        match = PR_NUMBER.search(subject)
        if match:
            number = int(match.group(1))
            subject = PR_NUMBER.sub("", subject).strip()
        changes.append(
            {
                "sha": sha,
                "subject": subject,
                "pr": number,
                "author": author,
                "head": head_label,
            }
        )
    return changes
