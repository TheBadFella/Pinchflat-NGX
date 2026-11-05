from __future__ import annotations

import sys
import json
import tempfile
import unittest
from unittest.mock import patch
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling"))
sys.path.insert(0, str(ROOT / "test" / "tooling"))

from release_automation.errors import ReleaseError
from release_automation.notes import (
    CHECKLIST_START,
    DEFAULT_NOTES,
    METADATA_START,
    METADATA_END,
    NOTES_END,
    NOTES_START,
    parse_metadata,
    render_metadata,
    replace_block,
)
from release_automation.publish import PublishOptions, publish
from test_prepare import PrepareHarness

from fakes import FakeRegistry, REQUIRED_CHECK_NAMES


class PublishHarness:
    def __init__(self, root: Path):
        self.prepare = PrepareHarness(root)
        self.prepared = self.prepare.run()
        self.github = self.prepare.github
        self.pr_number = self.prepared.pr_number
        self.options = PublishOptions(
            repository="TheBadFella/Pinchflat-NGX",
            checks_wait_seconds=0,
            checks_poll_seconds=1,
            publisher_wait_seconds=0,
            publisher_poll_seconds=1,
            registry_image="ghcr.io/thebadfella/pinchflat-ngx",
        )
        self.set_notes("Valid maintainer release notes.\n\nSee [guide](https://example.invalid).", approve=True)

    @property
    def pull(self):
        return self.github.pulls[self.pr_number]

    def set_notes(self, notes: str, *, approve: bool = True) -> None:
        body = replace_block(self.pull["body"], NOTES_START, NOTES_END, notes)
        if approve:
            body = body.replace("- [ ]", "- [x]")
        else:
            body = body.replace("- [x]", "- [ ]")
        self.github.update_pull_request(self.pr_number, body=body)

    def approve(self) -> None:
        body = self.pull["body"].replace("- [ ]", "- [x]")
        self.github.update_pull_request(self.pr_number, body=body)

    def merge(self, *, merged_by: str = "maintainer", merge_sha: str | None = None) -> str:
        merge_sha = self.github.merge_pull(
            self.pr_number,
            merged_by=merged_by,
            merge_sha=merge_sha,
        )
        self.github.set_checks(merge_sha)
        return merge_sha

    def publish(self, sha: str, *, registry=None, **overrides):
        options = replace(self.options, **overrides)
        return publish(
            options,
            self.github,
            merge_sha=sha,
            registry=registry or FakeRegistry(),
            event_name="push",
        )


class PublishTests(unittest.TestCase):
    def test_master_advancing_during_check_validation_blocks_tagging(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            original = harness.github.list_check_runs
            def advance_master(sha):
                harness.github.set_branch("master", "f" * 40)
                return original(sha)
            with patch.object(harness.github, "list_check_runs", side_effect=advance_master):
                with self.assertRaises(ReleaseError) as raised:
                    harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "stale_release_merge")
            self.assertEqual(harness.github.tags_created, [])
            self.assertEqual(harness.github.dispatches, [])

    def test_approved_metadata_cannot_bypass_unchecked_current_checklist(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            harness.set_notes("Reviewed notes", approve=False)
            metadata = parse_metadata(harness.pull["body"])
            metadata["acceptance"]["status"] = "approved"
            body = harness.pull["body"]
            harness.pull["body"] = replace_block(body, METADATA_START, METADATA_END, json.dumps(metadata))
            merge_sha = harness.merge()
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "acceptance_pending")
            self.assertEqual(harness.github.tags_created, [])

    def test_old_publisher_without_event_guard_cannot_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.commits[merge_sha]["files"][".github/workflows/docker_release.yml"] = "name: old publisher"
            harness.github._file_cache.clear()
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "publisher_guard_missing")
            self.assertEqual(harness.github.tags_created, [])
            self.assertEqual(harness.github.dispatches, [])

    def test_valid_release_creates_exactly_one_tag_release_and_publisher_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            notes = "This release fixes the library view.\n\nSee the [upgrade guide](https://example.invalid/guide)."
            harness.set_notes(notes)
            merge_sha = harness.merge()

            result = harness.publish(merge_sha)

            self.assertEqual(result.status, "released")
            self.assertEqual(result.tag, "2026.11.1")
            self.assertEqual(harness.github.tags_created, ["2026.11.1"])
            self.assertEqual(len(harness.github.releases_created), 1)
            self.assertEqual(len(harness.github.dispatches), 1)
            self.assertEqual(result.publisher_event, "workflow_dispatch")
            self.assertEqual(len(harness.github.workflow_runs), 1)
            self.assertEqual(result.sync["status"], "merged")
            self.assertEqual(set(result.registry_digests), {"2026.11.1", "2026.11.1-postgres", "latest", "latest-postgres"})

            release = harness.github.get_release_by_tag("2026.11.1")
            self.assertIn(notes, release["body"])
            self.assertIn("feat: add dev change", release["body"])
            self.assertNotIn(METADATA_START, release["body"])
            self.assertNotIn(CHECKLIST_START, release["body"])
            self.assertIn("| SQLite | `ghcr.io/thebadfella/pinchflat-ngx:2026.11.1` | `latest` |", release["body"])
            self.assertIn("| PostgreSQL | `ghcr.io/thebadfella/pinchflat-ngx:2026.11.1-postgres` | `latest-postgres` |", release["body"])
            self.assertIn("Full changelog: [2026.11.0...2026.11.1](https://github.com/TheBadFella/Pinchflat-NGX/compare/2026.11.0...2026.11.1).", release["body"])
            self.assertEqual(harness.github.tags["2026.11.1"], merge_sha)

    def test_release_notes_shell_injection_is_literal(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            payload = "$(touch /tmp/pwned); `id`; \"quoted\"; rm -rf /"
            harness.set_notes(payload)
            merge_sha = harness.merge()

            harness.publish(merge_sha)

            release = harness.github.get_release_by_tag("2026.11.1")
            self.assertIn(payload, release["body"])
            self.assertNotIn("\\$(", release["body"])

    def test_missing_checks_block_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.set_checks(merge_sha, [])

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)

            self.assertEqual(raised.exception.code, "checks_incomplete")
            self.assertEqual(harness.github.tags_created, [])
            self.assertEqual(harness.github.releases_created, [])

    def test_failed_checks_block_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.set_checks(
                merge_sha,
                [
                    {"name": REQUIRED_CHECK_NAMES[0], "status": "completed", "conclusion": "failure"},
                    {"name": REQUIRED_CHECK_NAMES[1], "status": "completed", "conclusion": "success"},
                    {"name": REQUIRED_CHECK_NAMES[2], "status": "completed", "conclusion": "success"},
                ],
            )
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "checks_failed")
            self.assertEqual(harness.github.tags_created, [])

    def test_skipped_and_cancelled_checks_block_release(self):
        for conclusion in ("skipped", "cancelled", "timed_out", "neutral"):
            with self.subTest(conclusion=conclusion), tempfile.TemporaryDirectory() as temporary:
                harness = PublishHarness(Path(temporary))
                merge_sha = harness.merge()
                harness.github.set_checks(
                    merge_sha,
                    [
                        {"name": name, "status": "completed", "conclusion": conclusion}
                        for name in REQUIRED_CHECK_NAMES
                    ],
                )
                with self.assertRaises(ReleaseError) as raised:
                    harness.publish(merge_sha)
                self.assertEqual(raised.exception.code, "checks_failed")
                self.assertEqual(harness.github.tags_created, [])

    def test_pending_checks_block_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.set_checks(
                merge_sha,
                [
                    {"name": name, "status": "queued", "conclusion": None}
                    for name in REQUIRED_CHECK_NAMES
                ],
            )
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "checks_incomplete")
            self.assertEqual(harness.github.tags_created, [])

    def test_stale_checks_block_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.set_checks(
                merge_sha,
                [
                    {
                        "name": name,
                        "status": "completed",
                        "conclusion": "success",
                        "head_sha": "f" * 40,
                    }
                    for name in REQUIRED_CHECK_NAMES
                ],
            )
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "checks_incomplete")
            self.assertIn(REQUIRED_CHECK_NAMES[0], raised.exception.details["stale"])
            self.assertEqual(harness.github.tags_created, [])

    def test_unrelated_merged_pr_is_not_released(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            master_sha = harness.github.branches["master"]
            feature_sha = harness.github.add_commit("feature1", "feat: unrelated", [master_sha])
            harness.github.set_branch("feature1", feature_sha)
            pull = harness.github.create_pull_request(
                title="Unrelated feature",
                head="feature1",
                base="master",
                body="Not a release candidate.",
            )
            merge_sha = harness.github.merge_pull(pull["number"])

            result = harness.publish(merge_sha)

            self.assertEqual(result.status, "not_release_merge")
            self.assertEqual(harness.github.tags_created, [])
            self.assertEqual(harness.github.releases_created, [])

    def test_spoofed_metadata_candidate_head_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            body = harness.pull["body"].replace(harness.prepared.candidate_head, "f" * 40)
            harness.github.update_pull_request(harness.pr_number, body=body)

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)

            self.assertIn(raised.exception.code, ("metadata_mismatch", "acceptance_invalidated"))
            self.assertEqual(harness.github.tags_created, [])

    def test_spoofed_metadata_block_in_notes_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            fake_metadata = parse_metadata(harness.pull["body"])
            fake_metadata["tag_name"] = "v9999.1.0"
            harness.set_notes(f"Maintainer notes.\n\n{render_metadata(fake_metadata)}")
            merge_sha = harness.merge()

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)

            self.assertEqual(raised.exception.code, "marker_duplicate")
            self.assertEqual(harness.github.tags_created, [])

    def test_unrelated_repository_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha, repository="Someone/Else")
            self.assertEqual(raised.exception.code, "repository_mismatch")

    def test_bot_merged_release_pr_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge(merged_by="github-actions[bot]")
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "release_pr_merged_by_bot")
            self.assertEqual(harness.github.tags_created, [])

    def test_tag_collision_blocks_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.tags["2026.11.1"] = "f" * 40

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)

            self.assertEqual(raised.exception.code, "tag_collision")
            self.assertEqual(harness.github.tags["2026.11.1"], "f" * 40)
            self.assertEqual(harness.github.releases_created, [])

    def test_stale_candidate_after_newer_release_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.seed_release("2026.12.0", harness.github.branches["master"])

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)

            self.assertEqual(raised.exception.code, "stale_candidate")
            self.assertEqual(harness.github.tags_created, [])

    def test_squash_merge_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            master_sha = harness.github.branches["master"]
            squash_sha = "a" * 40
            harness.github.add_commit(squash_sha, "squashed release", [master_sha])
            harness.github.set_branch("master", squash_sha)
            harness.github.pulls[harness.pr_number].update(
                {
                    "state": "closed",
                    "merged": True,
                    "merged_at": "2026-11-05T12:00:00Z",
                    "merge_commit_sha": squash_sha,
                    "merged_by": {"login": "maintainer"},
                }
            )
            harness.github.set_checks(squash_sha)

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(squash_sha)

            self.assertEqual(raised.exception.code, "not_a_merge_commit")
            self.assertEqual(harness.github.tags_created, [])

    def test_dispatch_mode_routes_exact_publisher_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            harness.github.simulate_release_event = False
            merge_sha = harness.merge()

            result = harness.publish(merge_sha)

            self.assertEqual(result.status, "released")
            self.assertEqual(
                harness.github.dispatches,
                [
                    {
                        "workflow": "docker_release.yml",
                        "ref": "2026.11.1",
                        "inputs": {
                            "platforms": "linux/amd64,linux/arm64",
                            "docker_tags": "2026.11.1",
                            "publish_latest": "true",
                        },
                    }
                ],
            )
            self.assertEqual(result.publisher_event, "workflow_dispatch")
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)

    def test_managed_release_uses_only_explicit_dispatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            result = harness.publish(merge_sha)
            self.assertEqual(result.publisher_event, "workflow_dispatch")
            self.assertEqual(len(harness.github.dispatches), 1)

    def test_publisher_failure_retries_without_moving_tag(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            harness.github.release_event_behavior = "failure"
            harness.github.dispatch_behavior = "success"
            merge_sha = harness.merge()
            harness.github.create_publisher_run(event="workflow_dispatch", head_sha=merge_sha, behavior="failure")

            result = harness.publish(merge_sha)

            self.assertEqual(result.status, "released")
            self.assertEqual(result.publisher_dispatched, True)
            self.assertEqual(len(harness.github.dispatches), 1)
            self.assertEqual(harness.github.tags["2026.11.1"], merge_sha)
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)
            self.assertEqual(result.sync["status"], "merged")

    def test_failed_dispatch_can_be_retried_on_rerun(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            harness.github.release_event_behavior = "failure"
            harness.github.dispatch_behavior = "failure"
            merge_sha = harness.merge()

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "publisher_failed")
            self.assertEqual(harness.github.tags["2026.11.1"], merge_sha)
            self.assertEqual(len(harness.github.releases_created), 1)

            harness.github.dispatch_behavior = "success"
            result = harness.publish(merge_sha)

            self.assertEqual(result.status, "already_released")
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)
            self.assertEqual(harness.github.tags["2026.11.1"], merge_sha)
            self.assertEqual(result.sync["status"], "merged")

    def test_publisher_pending_returns_without_sync_then_completes(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            harness.github.dispatch_behavior = "pending"
            merge_sha = harness.merge()

            pending = harness.publish(merge_sha)
            self.assertEqual(pending.status, "publisher_pending")
            self.assertEqual(pending.sync, {})
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)
            self.assertEqual(len(harness.github.dispatches), 1)

            for run in harness.github.workflow_runs:
                if run["event"] == "workflow_dispatch":
                    run["status"] = "completed"
                    run["conclusion"] = "success"
            completed = harness.publish(merge_sha)

            self.assertEqual(completed.status, "already_released")
            self.assertEqual(completed.sync["status"], "merged")
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)

    def test_rerun_after_success_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            first = harness.publish(merge_sha)
            second = harness.publish(merge_sha)

            self.assertEqual(first.status, "released")
            self.assertEqual(second.status, "already_released")
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)
            self.assertEqual(len(harness.github.dispatches), 1)
            self.assertEqual(second.sync["status"], "up_to_date")
            self.assertEqual(len(harness.github.pulls_created), 1)

    def test_sync_conflict_creates_one_pr(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.github.merge_conflicts.add(("dev", "master"))

            first = harness.publish(merge_sha)
            second = harness.publish(merge_sha)

            self.assertEqual(first.sync["status"], "pr_created")
            self.assertEqual(second.sync["status"], "pr_exists")
            self.assertEqual(len(harness.github.pulls_created), 2)
            sync_pull = harness.github.pulls[first.sync["number"]]
            self.assertEqual(sync_pull["head"]["ref"], "master")
            self.assertEqual(sync_pull["base"]["ref"], "dev")

    def test_registry_verification_failure_blocks_sync_until_rerun(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha, registry=FakeRegistry(missing={"latest"}))
            self.assertEqual(raised.exception.code, "registry_tag_missing")
            self.assertEqual(harness.github.tags["2026.11.1"], merge_sha)
            self.assertEqual(len(harness.github.releases_created), 1)
            self.assertEqual(harness.github.branches["dev"], harness.prepare.fixture.dev_sha)

            result = harness.publish(merge_sha)
            self.assertEqual(result.status, "already_released")
            self.assertEqual(result.sync["status"], "merged")
            self.assertEqual(len(harness.github.tags_created), 1)
            self.assertEqual(len(harness.github.releases_created), 1)

    def test_non_push_event_is_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            result = publish(
                harness.options,
                harness.github,
                merge_sha=merge_sha,
                registry=FakeRegistry(),
                event_name="release",
            )
            self.assertEqual(result.status, "ignored")
            self.assertEqual(harness.github.tags_created, [])

    def test_two_pending_dispatches_track_survivor_without_third_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            run1 = harness.github.create_publisher_run(event="workflow_dispatch", head_sha=merge_sha, behavior="pending")
            run2 = harness.github.create_publisher_run(event="workflow_dispatch", head_sha=merge_sha, behavior="pending")
            result = harness.publish(merge_sha)
            self.assertEqual(result.status, "publisher_pending")
            self.assertEqual(result.publisher_run_id, run1["id"])
            self.assertEqual(run2["conclusion"], "cancelled")
            self.assertEqual(harness.github.dispatches, [])
            self.assertEqual(len(harness.github.workflow_runs), 2)

    def test_delayed_release_event_is_ignored_after_dispatch_succeeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            harness.publish(merge_sha)
            harness.github.create_publisher_run(event="release", head_sha=merge_sha, behavior="pending")
            result = harness.publish(merge_sha)
            self.assertEqual(result.status, "already_released")
            self.assertEqual(result.publisher_event, "workflow_dispatch")
            self.assertEqual(len(harness.github.dispatches), 1)

    def test_candidate_refresh_requires_new_checklist_before_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            source = harness.prepare.add_branch_commit("dev", files={"new.txt": "new"}, message="fix: new change")
            harness.prepare.run(source_ref=source)
            self.assertEqual(parse_metadata(harness.pull["body"])["acceptance"]["status"], "invalidated")
            self.assertIn("Valid maintainer release notes", harness.pull["body"])
            merge_sha = harness.merge()
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "acceptance_pending")
            self.assertEqual(harness.github.tags_created, [])
            harness.approve()
            self.assertEqual(harness.publish(merge_sha).status, "released")

    def test_stale_release_merge_after_master_advanced_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()

            # Master advances to a new commit after the merge
            newer_master = "f" * 40
            harness.github.branches["master"] = newer_master

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "stale_release_merge")

    def test_mismatched_latest_and_version_digests_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()

            bad_registry = FakeRegistry(custom_digests={"latest": "sha256:" + "0" * 64})
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha, registry=bad_registry)
            self.assertEqual(raised.exception.code, "registry_digest_mismatch")

    def test_missing_manifest_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()

            # Registry missing linux/arm64
            bad_registry = FakeRegistry(platforms=("linux/amd64",))
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha, registry=bad_registry)
            self.assertEqual(raised.exception.code, "registry_architecture_missing")

    def test_placeholder_release_notes_reject_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            harness.set_notes(DEFAULT_NOTES, approve=True)
            merge_sha = harness.merge()
            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "release_notes_placeholder")

    def test_unapproved_acceptance_rejects_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            # Put notes without checking the checklist
            harness.set_notes("Valid notes", approve=False)
            merge_sha = harness.merge()

            with self.assertRaises(ReleaseError) as raised:
                harness.publish(merge_sha)
            self.assertEqual(raised.exception.code, "acceptance_pending")


if __name__ == "__main__":
    unittest.main()
