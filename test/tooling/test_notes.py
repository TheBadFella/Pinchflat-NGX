from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling"))
sys.path.insert(0, str(ROOT / "test" / "tooling"))

from release_automation.errors import ReleaseError
from release_automation.notes import (
    CHECKLIST_START,
    DEFAULT_NOTES,
    FOOTER_START,
    FOOTER_END,
    GENERATED_START,
    METADATA_START,
    NOTES_START,
    collect_changes,
    extract_block,
    is_checklist_complete,
    parse_metadata,
    release_body_from_pr,
    render_generated_changes,
    render_metadata,
    render_pr_body,
    replace_block,
)


def metadata(**overrides):
    base = {
        "schema_version": 1,
        "managed_by": "pinchflat-release-automation",
        "repository": "TheBadFella/Pinchflat-NGX",
        "source_sha": "a" * 40,
        "master_baseline_sha": "b" * 40,
        "candidate_head_sha": "c" * 40,
        "proposed_version": "2026.11.1",
        "tag_name": "v2026.11.1",
        "previous_stable_tag": "2026.11.0",
        "previous_stable_sha": "d" * 40,
        "release_branch": "release/stable-candidate",
        "target_branch": "master",
        "generated_at": "2026-11-05T12:00:00-06:00",
        "acceptance": {
            "status": "pending",
            "head_sha": "c" * 40,
            "previous_head_sha": None,
            "invalidated_at": None,
        },
    }
    base.update(overrides)
    return base


class NotesTests(unittest.TestCase):
    def test_candidate_and_published_notes_have_standard_image_table_and_changelog(self):
        body = render_pr_body(
            tag="2026.11.2", generated_changes="- fix: regression",
            metadata=metadata(tag_name="2026.11.2", proposed_version="2026.11.2", previous_stable_tag="2026.11.1"),
        ).replace(DEFAULT_NOTES, "Maintainer notes with thanks to @reporter.")
        for text in (body, release_body_from_pr(body)):
            self.assertIn("## Container images", text)
            self.assertIn("| Database | Versioned image | Moving tag |", text)
            self.assertIn("| SQLite | `ghcr.io/thebadfella/pinchflat-ngx:2026.11.2` | `latest` |", text)
            self.assertIn("| PostgreSQL | `ghcr.io/thebadfella/pinchflat-ngx:2026.11.2-postgres` | `latest-postgres` |", text)
            self.assertIn("Full changelog: [2026.11.1...2026.11.2](https://github.com/TheBadFella/Pinchflat-NGX/compare/2026.11.1...2026.11.2).", text)
        self.assertNotIn(FOOTER_START, release_body_from_pr(body))
        self.assertNotIn(FOOTER_END, release_body_from_pr(body))

    def test_refresh_updates_footer_versions_without_duplicating_or_changing_prose(self):
        first = render_pr_body(tag="2026.11.1", generated_changes="- old", metadata=metadata(tag_name="2026.11.1"))
        first = first.replace(DEFAULT_NOTES, "Maintainer prose `$(literal)` and @contributor credit.")
        refreshed = render_pr_body(
            tag="2026.12.0", generated_changes="- new", existing_body=first,
            metadata=metadata(tag_name="2026.12.0", proposed_version="2026.12.0", previous_stable_tag="2026.11.1"),
        )
        self.assertIn("Maintainer prose `$(literal)` and @contributor credit.", refreshed)
        self.assertEqual(refreshed.count("## Container images"), 1)
        self.assertEqual(refreshed.count("Full changelog:"), 1)
        self.assertNotIn("pinchflat-ngx:2026.11.1`", refreshed)
        self.assertIn("[2026.11.1...2026.12.0]", refreshed)

    def test_pasting_complete_formatted_notes_preserves_footer_without_duplicates(self):
        body = render_pr_body(tag="2026.11.1", generated_changes="- fix", metadata=metadata(tag_name="2026.11.1"))
        footer = extract_block(body, FOOTER_START, FOOTER_END)
        self.assertIsNotNone(footer)
        footer = footer.replace("|", " | ")
        notes = "Human introduction and @reporter credit.\n\n" + footer + "\n\nHuman image guidance."
        body = replace_block(body, NOTES_START, "<!-- RELEASE-NOTES-END -->", notes)
        released = release_body_from_pr(body.replace("\n", "\r\n"))
        self.assertEqual(released.count("## Container images"), 1)
        self.assertEqual(released.count("Full changelog:"), 1)
        self.assertIn("Human image guidance.", released)
        self.assertIn(footer.strip(), released)

    def test_malformed_or_stale_handwritten_footer_blocks_publication(self):
        body = render_pr_body(tag="2026.11.1", generated_changes="- fix", metadata=metadata(tag_name="2026.11.1"))
        footer = extract_block(body, FOOTER_START, FOOTER_END)
        for bad_footer in (
            footer.replace("2026.11.0...2026.11.1", "2026.10.20...2026.11.0"),
            footer.replace("2026.11.1-postgres", "2026.11.0-postgres"),
            "Versioned images: `image:tag`\n\n[Full changelog](https://example.invalid)",
        ):
            with self.subTest(footer=bad_footer):
                edited = replace_block(body, NOTES_START, "<!-- RELEASE-NOTES-END -->", "Human notes.\n\n" + bad_footer)
                with self.assertRaises(ReleaseError) as raised:
                    release_body_from_pr(edited)
                self.assertEqual(raised.exception.code, "release_footer_invalid")

    def test_first_release_footer_links_commit_history_without_inventing_baseline(self):
        body = render_pr_body(
            tag="2026.11.0", generated_changes="- initial",
            metadata=metadata(tag_name="2026.11.0", proposed_version="2026.11.0", previous_stable_tag=None),
        )
        self.assertIn("Full changelog: [2026.11.0](https://github.com/TheBadFella/Pinchflat-NGX/commits/2026.11.0).", body)
        self.assertNotIn("None", extract_block(body, FOOTER_START, FOOTER_END))

    def test_handwritten_footer_does_not_make_placeholder_notes_publishable(self):
        body = render_pr_body(tag="2026.11.1", generated_changes="- fix", metadata=metadata(tag_name="2026.11.1"))
        body = body.replace(FOOTER_START, "").replace(FOOTER_END, "")
        with self.assertRaises(ReleaseError) as raised:
            release_body_from_pr(body)
        self.assertEqual(raised.exception.code, "release_notes_placeholder")

    def test_metadata_round_trip(self):
        body = render_pr_body(
            tag="v2026.11.1",
            generated_changes="### Included changes\n\n- feat: add widgets (#12)",
            metadata=metadata(),
        )
        parsed = parse_metadata(body)
        self.assertEqual(parsed["proposed_version"], "2026.11.1")
        self.assertEqual(parsed["candidate_head_sha"], "c" * 40)

    def test_refresh_preserves_maintainer_notes_and_replaces_generated_changes(self):
        first = render_pr_body(
            tag="v2026.11.1",
            generated_changes="- old change",
            metadata=metadata(),
        )
        first = first.replace(
            DEFAULT_NOTES,
            "This release fixes the library view.\n\nRead the [upgrade guide](https://example.invalid/guide).",
        )
        refreshed = render_pr_body(
            tag="v2026.11.1",
            generated_changes="- new change",
            metadata=metadata(candidate_head_sha="e" * 40),
            existing_body=first,
        )
        self.assertIn("This release fixes the library view.", refreshed)
        self.assertIn("[upgrade guide](https://example.invalid/guide)", refreshed)
        self.assertIn("- new change", refreshed)
        self.assertNotIn("- old change", refreshed)
        self.assertEqual(parse_metadata(refreshed)["candidate_head_sha"], "e" * 40)

    def test_refresh_recovers_notes_when_markers_are_missing(self):
        old_body = "\n".join(
            [
                "## Release v2026.11.1",
                "",
                "Hand-written notes survive an older template.",
                "",
                render_metadata(metadata()),
            ]
        )
        refreshed = render_pr_body(
            tag="v2026.11.1",
            generated_changes="- new change",
            metadata=metadata(),
            existing_body=old_body,
        )
        self.assertIn("Hand-written notes survive an older template.", refreshed)
        self.assertEqual(refreshed.count("Hand-written notes survive an older template."), 1)

    def test_duplicate_metadata_blocks_are_rejected(self):
        body = "\n".join(
            [
                render_metadata(metadata()),
                "",
                render_metadata(metadata()),
            ]
        )
        with self.assertRaises(ReleaseError) as raised:
            parse_metadata(body)
        self.assertEqual(raised.exception.code, "marker_duplicate")

    def test_spoofed_metadata_in_notes_is_rejected(self):
        body = render_pr_body(
            tag="v2026.11.1",
            generated_changes="- change",
            metadata=metadata(),
        )
        body = body.replace(DEFAULT_NOTES, render_metadata(metadata(tag_name="v9999.1.0")))
        with self.assertRaises(ReleaseError) as raised:
            parse_metadata(body)
        self.assertEqual(raised.exception.code, "marker_duplicate")

    def test_unmanaged_body_is_rejected(self):
        with self.assertRaises(ReleaseError) as raised:
            parse_metadata(render_metadata(metadata(managed_by="someone-else")))
        self.assertEqual(raised.exception.code, "metadata_unmanaged")

    def test_release_body_excludes_internal_checklist_and_metadata(self):
        body = render_pr_body(
            tag="v2026.11.1",
            generated_changes="### Included changes\n\n- fix: prevent crash (#7). Thanks @contributor.",
            metadata=metadata(),
        )
        body = body.replace(DEFAULT_NOTES, "Main notes for users.\n\nSee the [guide](https://example.invalid).")
        released = release_body_from_pr(body)
        self.assertIn("Main notes for users.", released)
        self.assertIn("fix: prevent crash", released)
        self.assertIn("[guide](https://example.invalid)", released)
        self.assertNotIn(METADATA_START, released)
        self.assertNotIn(CHECKLIST_START, released)
        self.assertNotIn("Required checks passed", released)
        self.assertNotIn("## Release notes", released)

    def test_shell_injection_is_literal_text(self):
        payload = "$(touch /tmp/pwned); `id`; \"quoted\"; rm -rf /"
        body = render_pr_body(
            tag="v2026.11.1",
            generated_changes="- change",
            metadata=metadata(),
        )
        body = body.replace(DEFAULT_NOTES, payload)
        released = release_body_from_pr(body)
        self.assertIn(payload, released)
        self.assertNotIn("\\$(", released)

    def test_generated_changes_are_bounded_and_skip_automation_commits(self):
        commits = [
            {
                "sha": f"{index:040d}",
                "commit": {"message": f"feat: change {index} (#{index})"},
                "author": {"login": "contributor"},
            }
            for index in range(150)
        ]
        commits.append(
            {
                "sha": "f" * 40,
                "commit": {"message": "release: prepare 2026.11.0"},
                "author": {"login": "release-bot"},
            }
        )
        commits.append(
            {
                "sha": "e" * 40,
                "commit": {"message": "Merge dev into master for release candidate"},
                "author": {"login": "release-bot"},
            }
        )
        changes = collect_changes({"commits": commits}, head_label="dev")
        self.assertEqual(len(changes), 150)
        rendered = render_generated_changes(changes, base_label="2026.10.0", head_label="dev")
        self.assertEqual(rendered.count("\n- "), 100)
        self.assertNotIn("release: prepare", rendered)
        self.assertIn("Thanks @contributor", rendered)
        self.assertIn("Compared `2026.10.0` to `dev`", rendered)

    def test_extract_block_rejects_stray_end_marker(self):
        with self.assertRaises(ReleaseError):
            extract_block(f"{NOTES_START}\nnotes\n", NOTES_START, "<!-- RELEASE-NOTES-END -->")
        with self.assertRaises(ReleaseError):
            extract_block(f"notes\n{GENERATED_START}", GENERATED_START, "<!-- GENERATED-CHANGES-END -->")

    def test_placeholder_release_notes_are_rejected(self):
        body = render_pr_body(
            tag="v2026.11.1",
            generated_changes="### Included changes\n\n- fix: change (#1)",
            metadata=metadata(),
        )
        with self.assertRaises(ReleaseError) as raised:
            release_body_from_pr(body)
        self.assertEqual(raised.exception.code, "release_notes_placeholder")

    def test_is_checklist_complete(self):
        body = render_pr_body(
            tag="v2026.11.1",
            generated_changes="- change",
            metadata=metadata(),
        )
        self.assertFalse(is_checklist_complete(body))
        checked_body = body.replace("- [ ]", "- [x]")
        self.assertTrue(is_checklist_complete(checked_body))


if __name__ == "__main__":
    unittest.main()
