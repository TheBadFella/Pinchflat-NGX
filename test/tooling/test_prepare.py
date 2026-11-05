from __future__ import annotations

import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling"))
sys.path.insert(0, str(ROOT / "test" / "tooling"))

from release_automation.errors import MergeConflict, ReleaseError
from release_automation.gitops import GitRepo
from release_automation.notes import DEFAULT_NOTES, parse_metadata
from release_automation.prepare import PrepareOptions, prepare

from fakes import FakeGitHub, FakePublisher, GitFixture, register_history

CLOCK = "2026-11-05T12:00:00Z"
BASELINE = "2026.11.0"


class PrepareHarness:
    def __init__(self, root: Path):
        self.fixture = GitFixture.create(root / "repo", version=BASELINE)
        self.github = FakeGitHub()
        register_history(self.github, self.fixture, self.fixture.master_sha)
        register_history(self.github, self.fixture, self.fixture.dev_sha)
        self.github.set_branch("master", self.fixture.master_sha)
        self.github.set_branch("dev", self.fixture.dev_sha)
        self.github.seed_release(BASELINE, self.fixture.master_sha)
        self.publisher = FakePublisher(self.github)
        self.git = GitRepo(self.fixture.path)
        self.options = PrepareOptions(
            repository="TheBadFella/Pinchflat-NGX",
            source_ref=self.fixture.dev_sha,
            master_ref="master",
            fetch=False,
        )

    def run(self, **overrides):
        options = replace(self.options, **overrides)
        result = prepare(options, self.github, self.git, self.publisher, clock=CLOCK)
        if result.candidate_head:
            register_history(self.github, self.fixture, result.candidate_head)
        return result

    def add_branch_commit(self, branch: str, *, files: dict[str, str], message: str) -> str:
        sha = self.fixture.add_commit(branch, files=files, message=message)
        self.github.set_branch(branch, sha)
        register_history(self.github, self.fixture, sha)
        return sha


class PrepareTests(unittest.TestCase):
    def test_invalid_handwritten_footer_does_not_publish_refreshed_candidate(self):
        from release_automation.notes import NOTES_START, NOTES_END, replace_block
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            first = harness.run()
            pull = harness.github.pulls[first.pr_number]
            pull["body"] = replace_block(
                pull["body"], NOTES_START, NOTES_END,
                "Human notes.\n\n## Container images\n\nStale image references.\n\nFull changelog: old",
            )
            source = harness.add_branch_commit("dev", files={"new.txt": "change"}, message="fix: new change")
            with self.assertRaises(ReleaseError) as raised:
                harness.run(source_ref=source)
            self.assertEqual(raised.exception.code, "release_footer_invalid")
            self.assertEqual(len(harness.publisher.pushes), 1)
            self.assertEqual(harness.github.branches["release/stable-candidate"], first.candidate_head)

    def test_prepare_creates_one_candidate_and_one_pr(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            result = harness.run()

            self.assertEqual(result.status, "prepared")
            self.assertEqual(result.version, "2026.11.1")
            self.assertEqual(result.tag, "2026.11.1")
            self.assertEqual(result.previous_stable_tag, BASELINE)
            self.assertEqual(len(harness.publisher.pushes), 1)
            self.assertEqual(len(harness.github.pulls_created), 1)
            self.assertEqual(harness.github.branches["release/stable-candidate"], result.candidate_head)

            pull = harness.github.pulls[result.pr_number]
            metadata = parse_metadata(pull["body"])
            self.assertEqual(metadata["proposed_version"], "2026.11.1")
            self.assertEqual(metadata["candidate_head_sha"], result.candidate_head)
            self.assertEqual(metadata["acceptance"]["status"], "pending")
            self.assertIn("feat: add dev change (#201)", pull["body"])

            mix_exs = harness.fixture.run(
                ["show", f"{result.candidate_head}:mix.exs"]
            ).stdout
            self.assertIn('version: "2026.11.1"', mix_exs)
            self.assertEqual(harness.fixture.rev("HEAD"), harness.fixture.master_sha)

    def test_repeated_identical_prepare_is_a_noop(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            first = harness.run()
            pushes_before = len(harness.publisher.pushes)
            second = harness.run()

            self.assertEqual(second.status, "noop")
            self.assertEqual(second.candidate_head, first.candidate_head)
            self.assertEqual(len(harness.publisher.pushes), pushes_before)
            self.assertEqual(len(harness.github.pulls_created), 1)
            self.assertEqual(len(harness.github.list_pull_requests(state="open")), 1)

    def test_refresh_preserves_notes_and_invalidates_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            first = harness.run()
            pull = harness.github.pulls[first.pr_number]
            notes = "Hand-written release notes with a [guide](https://example.invalid/guide)."
            harness.github.update_pull_request(
                first.pr_number,
                body=pull["body"].replace(DEFAULT_NOTES, notes),
            )

            new_dev = harness.add_branch_commit(
                "dev",
                files={"lib/second.txt": "two\n"},
                message="fix: refresh candidate (#202)",
            )
            second = harness.run(source_ref=new_dev)

            self.assertEqual(second.status, "refreshed")
            self.assertNotEqual(second.candidate_head, first.candidate_head)
            self.assertEqual(len(harness.publisher.pushes), 2)
            self.assertEqual(len(harness.github.pulls_created), 1)
            updated = harness.github.pulls[first.pr_number]
            self.assertIn(notes, updated["body"])
            self.assertIn("fix: refresh candidate (#202)", updated["body"])
            metadata = parse_metadata(updated["body"])
            self.assertEqual(metadata["acceptance"]["status"], "invalidated")
            self.assertEqual(metadata["acceptance"]["previous_head_sha"], first.candidate_head)
            self.assertEqual(metadata["acceptance"]["head_sha"], second.candidate_head)

    def test_master_hotfix_is_included_in_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            hotfix = harness.add_branch_commit(
                "master",
                files={"lib/hotfix.txt": "safe\n"},
                message="fix: master hotfix (#203)",
            )

            result = harness.run()

            self.assertEqual(result.status, "prepared")
            self.assertIn("fix: master hotfix (#203)", harness.github.pulls[result.pr_number]["body"])
            hotfix_file = harness.fixture.run(
                ["show", f"{result.candidate_head}:lib/hotfix.txt"]
            ).stdout
            self.assertEqual(hotfix_file, "safe\n")
            self.assertEqual(harness.fixture.parent_count(result.candidate_head), 1)

    def test_merge_conflict_aborts_without_push(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            harness.add_branch_commit(
                "master",
                files={"lib/dev_change.txt": "master version\n"},
                message="fix: master edits shared file (#204)",
            )
            harness.add_branch_commit(
                "dev",
                files={"lib/dev_change.txt": "dev version\n"},
                message="fix: dev edits shared file (#205)",
            )

            with self.assertRaises(MergeConflict):
                harness.run()

            self.assertEqual(harness.publisher.pushes, [])
            self.assertIsNone(harness.github.branches.get("release/stable-candidate"))
            self.assertEqual(harness.github.pulls_created, [])
            self.assertEqual(harness.fixture.rev("HEAD"), harness.fixture.rev("dev"))
            status = harness.fixture.run(["status", "--porcelain"]).stdout.strip()
            self.assertEqual(status, "")

    def test_tag_collision_stops_before_any_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            harness.github.tags["2026.11.1"] = "f" * 40

            with self.assertRaises(ReleaseError) as raised:
                harness.run()

            self.assertEqual(raised.exception.code, "tag_collision")
            self.assertEqual(harness.publisher.pushes, [])
            self.assertEqual(harness.github.pulls_created, [])

    def test_untracked_runner_files_are_not_committed(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            harness.fixture.write("tooling/__pycache__/release_automation.pyc", "runner artifact\n")
            result = harness.run()

            tree = harness.fixture.run(
                ["ls-tree", "-r", "--name-only", result.candidate_head]
            ).stdout
            self.assertNotIn("__pycache__", tree)
            self.assertIn("mix.exs", tree)

    def test_no_releasable_changes_creates_no_empty_pr(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            result = harness.run(source_ref=harness.fixture.master_sha)

            self.assertEqual(result.status, "no_changes")
            self.assertEqual(harness.publisher.pushes, [])
            self.assertEqual(harness.github.pulls_created, [])
            self.assertNotIn("release/stable-candidate", harness.github.branches)

    def test_unmanaged_candidate_pr_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            harness.github.branches["release/stable-candidate"] = harness.fixture.dev_sha
            harness.github.pulls[1] = {
                "number": 1,
                "title": "Manual release attempt",
                "body": "No automation metadata here.",
                "state": "open",
                "head": {
                    "ref": "release/stable-candidate",
                    "sha": harness.fixture.dev_sha,
                    "repo": {"full_name": harness.github.repository},
                },
                "base": {"ref": "master"},
                "merged": False,
            }

            with self.assertRaises(ReleaseError) as raised:
                harness.run()

            self.assertEqual(raised.exception.code, "unmanaged_candidate_pr")
            self.assertEqual(harness.publisher.pushes, [])

    def test_duplicate_open_candidate_prs_are_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            first = harness.run()
            original = harness.github.pulls[first.pr_number]
            duplicate = dict(original)
            duplicate["number"] = 999
            harness.github.pulls[999] = duplicate

            second = harness.run()

            self.assertEqual(second.status, "noop")
            self.assertEqual(harness.github.pulls[999]["state"], "closed")
            self.assertEqual(harness.github.pulls[first.pr_number]["state"], "open")
            self.assertEqual(len(harness.github.list_pull_requests(state="open")), 1)

    def test_stale_candidate_lease_rejects_refresh_without_force(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            first = harness.run()
            new_dev = harness.add_branch_commit(
                "dev",
                files={"lib/second.txt": "two\n"},
                message="fix: refresh candidate (#206)",
            )
            harness.publisher.fail_next = True

            with self.assertRaises(ReleaseError) as raised:
                harness.run(source_ref=new_dev)

            self.assertEqual(raised.exception.code, "push_rejected")
            self.assertEqual(harness.github.branches["release/stable-candidate"], first.candidate_head)
            self.assertEqual(len(harness.publisher.pushes), 1)

    def test_concurrent_new_branch_push_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            original_publish = harness.publisher.publish

            def race_publish(branch, sha, expected_old):
                # Another run created the managed branch after this run observed
                # that it did not exist.
                harness.github.branches[branch] = "f" * 40
                return original_publish(branch, sha, expected_old)

            harness.publisher.publish = race_publish

            with self.assertRaises(ReleaseError) as raised:
                harness.run()

            self.assertEqual(raised.exception.code, "push_rejected")
            self.assertEqual(harness.github.pulls_created, [])

    def test_missing_baseline_requires_explicit_bootstrap(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            harness.github.releases.clear()
            harness.github.tags.clear()

            with self.assertRaises(ReleaseError) as raised:
                harness.run()
            self.assertEqual(raised.exception.code, "missing_baseline")

            bootstrapped = harness.run(bootstrap_version="2026.11.0")
            self.assertEqual(bootstrapped.status, "prepared")
            self.assertEqual(bootstrapped.version, "2026.11.0")
            self.assertEqual(len(harness.github.pulls_created), 1)

    def test_duplicate_release_versions_stop(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            harness.github.seed_release("2026.11.0", harness.fixture.master_sha)

            with self.assertRaises(ReleaseError) as raised:
                harness.run()
            self.assertEqual(raised.exception.code, "duplicate_release_version")

    def test_explicit_override_is_used(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            result = harness.run(version_override="2026.12.0")
            self.assertEqual(result.version, "2026.12.0")
            self.assertEqual(result.tag, "2026.12.0")

    def test_candidate_refresh_preserves_ancestry_without_force_push(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            result1 = harness.run()
            self.assertEqual(result1.status, "prepared")

            # Dev advances with another commit
            new_dev = harness.add_branch_commit(
                "dev",
                files={"lib/second.txt": "two\n"},
                message="feat: second change (#202)",
            )

            result2 = harness.run(source_ref=new_dev)
            self.assertEqual(result2.status, "refreshed")
            self.assertNotEqual(result1.candidate_head, result2.candidate_head)

            # Assert result1 candidate head is an ancestor of result2 candidate head
            is_ancestor = harness.fixture.run(
                ["merge-base", "--is-ancestor", result1.candidate_head, result2.candidate_head],
                check=False,
            )
            self.assertEqual(is_ancestor.returncode, 0, "previous candidate head must be preserved as an ancestor")

    def test_clean_runner_without_git_ident_can_merge(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = PrepareHarness(Path(temporary))
            # Unset git user.name and user.email to simulate a clean CI runner
            harness.fixture.run(["config", "--unset", "user.name"])
            harness.fixture.run(["config", "--unset", "user.email"])

            result = harness.run()
            self.assertEqual(result.status, "prepared")


if __name__ == "__main__":
    unittest.main()
