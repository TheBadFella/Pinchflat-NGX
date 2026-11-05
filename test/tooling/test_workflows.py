from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling"))
sys.path.insert(0, str(ROOT / "test" / "tooling"))

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is available on the runner
    yaml = None

WORKFLOW_DIR = ROOT / ".github" / "workflows"
CANDIDATE = WORKFLOW_DIR / "release_candidate.yml"
PUBLISH = WORKFLOW_DIR / "release_publish.yml"
USES = re.compile(r"^\s*uses:\s*([^\s#]+)")
SHA_PIN = re.compile(r"^[^@]+@[0-9a-f]{40}$")


def load_workflow(path: Path):
    if yaml is None:
        raise unittest.SkipTest("PyYAML is not available")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def triggers(workflow):
    # PyYAML resolves the YAML 1.1 boolean key `on` to True.
    return workflow.get("on") or workflow.get(True)


class WorkflowStructureTests(unittest.TestCase):
    def test_release_candidate_trigger_and_permissions(self):
        workflow = load_workflow(CANDIDATE)
        trigger = triggers(workflow)
        self.assertIn("push", trigger)
        self.assertEqual(trigger["push"]["branches"], ["dev"])
        self.assertIn("workflow_dispatch", trigger)
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], False)
        job = workflow["jobs"]["prepare"]
        self.assertEqual(job["permissions"]["contents"], "write")
        self.assertEqual(job["permissions"]["pull-requests"], "write")
        self.assertEqual(job["timeout-minutes"], 15)

    def test_release_publish_trigger_and_permissions(self):
        workflow = load_workflow(PUBLISH)
        trigger = triggers(workflow)
        self.assertEqual(trigger["push"]["branches"], ["master"])
        dispatch = trigger["workflow_dispatch"]["inputs"]
        self.assertNotIn("publisher_mode", dispatch)
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertEqual(workflow["concurrency"]["cancel-in-progress"], False)
        job = workflow["jobs"]["publish"]
        self.assertEqual(job["permissions"]["contents"], "write")
        self.assertEqual(job["permissions"]["pull-requests"], "write")
        self.assertEqual(job["permissions"]["checks"], "read")
        self.assertEqual(job["permissions"]["actions"], "write")
        self.assertGreaterEqual(job["timeout-minutes"], 120)

    def test_workflows_have_default_off_activation_gate(self):
        candidate = load_workflow(CANDIDATE)
        publish = load_workflow(PUBLISH)
        self.assertIn("vars.RELEASE_CANDIDATE_ENABLED == 'true'", candidate["jobs"]["prepare"]["if"])
        self.assertIn("vars.RELEASE_PUBLISH_ENABLED == 'true'", publish["jobs"]["publish"]["if"])
        self.assertNotIn("RELEASE_PUBLISH_ENABLED", candidate["jobs"]["prepare"]["if"])
        self.assertNotIn("RELEASE_CANDIDATE_ENABLED", publish["jobs"]["publish"]["if"])
        self.assertIn("confirm_active", triggers(candidate)["workflow_dispatch"]["inputs"])
        self.assertIn("confirm_active", triggers(publish)["workflow_dispatch"]["inputs"])

    def test_managed_release_event_skips_publisher_build(self):
        from release_automation.notes import DISPATCH_MARKER
        workflow = load_workflow(WORKFLOW_DIR / "docker_release.yml")
        condition = workflow["jobs"]["prepare"]["if"]
        self.assertIn("github.event_name != 'release'", condition)
        self.assertIn(DISPATCH_MARKER, condition)
        self.assertIn("!contains(github.event.release.body", condition)

    def test_release_workflows_do_not_duplicate_the_publisher(self):
        candidate_text = CANDIDATE.read_text(encoding="utf-8")
        publish_text = PUBLISH.read_text(encoding="utf-8")
        for text in (candidate_text, publish_text):
            self.assertNotIn("docker/build-push-action", text)
        self.assertIn("release_automation publish", publish_text)
        self.assertIn("docker_release.yml", publish_text + RUNBOOK_TEXT)

    def test_all_actions_are_pinned_to_full_commit_shas(self):
        for path in (CANDIDATE, PUBLISH):
            for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                match = USES.match(line)
                if not match:
                    continue
                reference = match.group(1)
                with self.subTest(path=path.name, line=line_number, reference=reference):
                    self.assertRegex(reference, SHA_PIN)
                    self.assertIn("# v", line)

    def test_workflow_run_blocks_do_not_interpolate_event_or_inputs(self):
        for path in (CANDIDATE, PUBLISH):
            text = path.read_text(encoding="utf-8")
            self.assertIn("PYTHONPATH: tooling", text)
            workflow = load_workflow(path)
            for job in workflow["jobs"].values():
                for step in job.get("steps") or []:
                    run = step.get("run")
                    if not run:
                        continue
                    for forbidden in ("${{ github.event", "${{ inputs.", "${{ steps.", "${{ secrets."):
                        with self.subTest(path=path.name, step=step.get("name"), forbidden=forbidden):
                            self.assertNotIn(forbidden, run)
                    self.assertIn('--event-file "$GITHUB_EVENT_PATH"', run)

    def test_existing_stable_publisher_remains_the_only_publisher(self):
        workflow = load_workflow(WORKFLOW_DIR / "docker_release.yml")
        trigger = triggers(workflow)
        self.assertIn("release", trigger)
        self.assertEqual(trigger["release"]["types"], ["published"])
        dispatch = trigger["workflow_dispatch"]["inputs"]
        self.assertIn("platforms", dispatch)
        self.assertIn("docker_tags", dispatch)
        self.assertIn("publish_latest", dispatch)


class DocumentationTests(unittest.TestCase):
    def test_runbook_covers_activation_and_recovery(self):
        text = (ROOT / "docs" / "release-runbook.md").read_text(encoding="utf-8")
        lowered = text.lower()
        for expected in (
            "GitHub App",
            "RELEASE_AUTOMATION_TOKEN",
            "contents: write",
            "pull-requests: write",
            "actions: write",
            "packages: read",
            "merge commit",
            "branch protection",
            "bootstrap_version",
            "Failure and resume",
            "Rollback and rollforward",
            "-m unittest discover -s test/tooling",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected.lower(), lowered)

    def test_release_note_style_guide_is_linked_by_agents(self):
        style = (ROOT / ".github" / "RELEASE_NOTES.md").read_text(encoding="utf-8")
        for expected in ("Contributor thanks", "wiki", "Included changes", "Do not include"):
            with self.subTest(expected=expected):
                self.assertIn(expected, style)
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn(".github/RELEASE_NOTES.md", agents)


class CliTests(unittest.TestCase):
    def test_manual_publish_defaults_to_current_master_not_dispatch_ref(self):
        from release_automation.__main__ import main
        from test_publish import PublishHarness

        with tempfile.TemporaryDirectory() as temporary:
            harness = PublishHarness(Path(temporary))
            merge_sha = harness.merge()
            event = Path(temporary) / "dispatch.json"
            event.write_text('{"inputs": {}, "ref": "dev"}', encoding="utf-8")
            with patch.dict(os.environ, {
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REPOSITORY": harness.options.repository,
                "GITHUB_SHA": "f" * 40,
                "GH_TOKEN": "fixture-only",
            }), patch("release_automation.__main__.GitHubClient", return_value=harness.github), redirect_stdout(StringIO()) as output:
                code = main(["publish", "--event-file", str(event), "--dry-run"])
            self.assertEqual(code, 0, output.getvalue())
            self.assertIn(merge_sha, output.getvalue())
            self.assertEqual(harness.github.tags_created, [])
            self.assertEqual(harness.github.releases_created, [])
            self.assertEqual(harness.github.dispatches, [])

    def test_module_help_is_available(self):
        completed = subprocess.run(
            [sys.executable, "-m", "release_automation", "--help"],
            text=True,
            capture_output=True,
            cwd=ROOT,
            env={**os.environ, "PYTHONPATH": str(ROOT / "tooling")},
            shell=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("prepare", completed.stdout)
        self.assertIn("publish", completed.stdout)

    def test_set_version_cli_updates_mix_exs(self):
        with tempfile.TemporaryDirectory() as temporary:
            mix = Path(temporary) / "mix.exs"
            mix.write_text('def project do\n  [\n    version: "2026.10.0"\n  ]\nend\n', encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "release_automation",
                    "set-version",
                    "2026.12.0",
                    "--file",
                    str(mix),
                ],
                text=True,
                capture_output=True,
                cwd=ROOT,
                env={**os.environ, "PYTHONPATH": str(ROOT / "tooling")},
                shell=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn('version: "2026.12.0"', mix.read_text(encoding="utf-8"))

    def test_version_bump_script_still_accepts_calendar_versions(self):
        script = (ROOT / "tooling" / "version_bump.sh").read_text(encoding="utf-8")
        self.assertIn("YEAR.MONTH.PATCH", script)
        self.assertIn("mix check", script)


RUNBOOK_TEXT = (ROOT / "docs" / "release-runbook.md").read_text(encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
