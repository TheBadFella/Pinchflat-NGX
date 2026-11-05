from __future__ import annotations

import sys
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling"))
sys.path.insert(0, str(ROOT / "test" / "tooling"))

from release_automation.errors import ReleaseError
from release_automation.versioning import (
    Version,
    calculate_next_version,
    duplicate_release_versions,
    extract_mix_version,
    highest_stable_release,
    normalize_clock,
    parse_tag,
    parse_version,
    update_mix_version,
)


class VersionCalculationTests(unittest.TestCase):
    def test_same_month_increments_patch(self):
        result = calculate_next_version("2026-11-05T12:00:00Z", Version(2026, 11, 0))
        self.assertEqual(result, Version(2026, 11, 1))

    def test_new_month_resets_patch(self):
        result = calculate_next_version("2026-12-01T12:00:00Z", Version(2026, 11, 0))
        self.assertEqual(result, Version(2026, 12, 0))

    def test_new_year_resets_patch(self):
        result = calculate_next_version("2027-01-02T12:00:00Z", Version(2026, 12, 4))
        self.assertEqual(result, Version(2027, 1, 0))

    def test_timezone_boundary_stays_in_previous_regina_month(self):
        # 03:00 UTC on 1 November is still 31 October in America/Regina.
        result = calculate_next_version("2026-11-01T03:00:00Z", Version(2026, 10, 5))
        self.assertEqual(result, Version(2026, 10, 6))

    def test_timezone_boundary_rolls_into_new_regina_month(self):
        # 07:00 UTC on 1 November is 01:00 on 1 November in America/Regina.
        result = calculate_next_version("2026-11-01T07:00:00Z", Version(2026, 10, 5))
        self.assertEqual(result, Version(2026, 11, 0))

    def test_naive_clock_is_treated_as_utc(self):
        result = calculate_next_version(datetime(2026, 11, 1, 3, 0), Version(2026, 10, 5))
        self.assertEqual(result, Version(2026, 10, 6))

    def test_normalize_clock_uses_regina_offset(self):
        normalized = normalize_clock("2026-11-01T03:00:00Z")
        self.assertEqual(normalized.utcoffset().total_seconds(), -6 * 3600)

    def test_clock_before_latest_release_month_fails(self):
        with self.assertRaises(ReleaseError) as raised:
            calculate_next_version("2026-10-31T12:00:00Z", Version(2026, 11, 0))
        self.assertEqual(raised.exception.code, "clock_before_latest_release")

    def test_future_baseline_fails_even_when_override_is_newer(self):
        with self.assertRaises(ReleaseError) as raised:
            calculate_next_version("2026-11-05T12:00:00Z", Version(2027, 1, 0))
        self.assertEqual(raised.exception.code, "clock_before_latest_release")

    def test_override_must_be_strictly_newer(self):
        for override in ("2026.11.0", "2026.10.9"):
            with self.subTest(override=override):
                with self.assertRaises(ReleaseError) as raised:
                    calculate_next_version(
                        "2026-11-05T12:00:00Z",
                        Version(2026, 11, 0),
                        override=override,
                    )
                self.assertEqual(raised.exception.code, "override_not_newer")

    def test_override_accepts_newer_version(self):
        result = calculate_next_version(
            "2026-11-05T12:00:00Z",
            Version(2026, 11, 0),
            override="2026.12.3",
        )
        self.assertEqual(result, Version(2026, 12, 3))

    def test_override_rejects_non_canonical_spelling(self):
        for override in ("2026.011.1", "2026.11.01", "2026.13.0", "2026.11", "v2026.11.1"):
            with self.subTest(override=override):
                with self.assertRaises(ReleaseError) as raised:
                    calculate_next_version(
                        "2026-11-05T12:00:00Z",
                        Version(2026, 11, 0),
                        override=override,
                    )
                self.assertEqual(raised.exception.code, "invalid_version")

    def test_missing_baseline_requires_bootstrap(self):
        with self.assertRaises(ReleaseError) as raised:
            calculate_next_version("2026-11-05T12:00:00Z", None)
        self.assertEqual(raised.exception.code, "missing_baseline")

        with self.assertRaises(ReleaseError) as raised:
            calculate_next_version("2026-11-05T12:00:00Z", None, override="2026.11.1")
        self.assertEqual(raised.exception.code, "missing_baseline")

    def test_bootstrap_creates_first_version(self):
        result = calculate_next_version("2026-11-05T12:00:00Z", None, bootstrap="2026.11.0")
        self.assertEqual(result, Version(2026, 11, 0))


class VersionAndTagParsingTests(unittest.TestCase):
    def test_parse_version_accepts_canonical_spelling_only(self):
        self.assertEqual(parse_version("2026.11.0"), Version(2026, 11, 0))
        for value in ("2026.011.0", "2026.11.00", "2026.0.1", "2026.13.1", "2026.11.-1"):
            with self.subTest(value=value):
                with self.assertRaises(ReleaseError):
                    parse_version(value)

    def test_parse_tag_accepts_legacy_and_prefixed_tags(self):
        self.assertEqual(parse_tag("2026.11.0"), Version(2026, 11, 0))
        self.assertEqual(parse_tag("v2026.11.1"), Version(2026, 11, 1))
        self.assertIsNone(parse_tag("nightly"))
        self.assertIsNone(parse_tag("v1.2.3"))

    def test_tag_rendering_respects_prefix(self):
        self.assertEqual(Version(2026, 11, 0).tag(), "v2026.11.0")
        self.assertEqual(Version(2026, 11, 0).tag(""), "2026.11.0")

    def test_highest_stable_release_ignores_drafts_prereleases_and_unrelated_tags(self):
        releases = [
            {"tag_name": "2026.10.2", "draft": False, "prerelease": False},
            {"tag_name": "2026.12.0", "draft": True, "prerelease": False},
            {"tag_name": "v2027.1.0", "draft": False, "prerelease": True},
            {"tag_name": "nightly", "draft": False, "prerelease": False},
            {"tag_name": "v2026.11.0", "draft": False, "prerelease": False},
        ]
        version, release = highest_stable_release(releases)
        self.assertEqual(version, Version(2026, 11, 0))
        self.assertEqual(release["tag_name"], "v2026.11.0")

    def test_duplicate_release_versions_are_reported(self):
        releases = [
            {"tag_name": "2026.11.0", "draft": False, "prerelease": False},
            {"tag_name": "v2026.11.0", "draft": False, "prerelease": False},
        ]
        self.assertEqual(duplicate_release_versions(releases), {"2026.11.0": 2})


class MixVersionTests(unittest.TestCase):
    SAMPLE = """defmodule Pinchflat.MixProject do
  use Mix.Project

  def project do
    [
      app: :pinchflat,
      version: "2026.10.0",
      elixir: "~> 1.17"
    ]
  end
end
"""

    def test_extract_and_update_version(self):
        self.assertEqual(extract_mix_version(self.SAMPLE), "2026.10.0")
        updated = update_mix_version(self.SAMPLE, "2026.11.1")
        self.assertIn('version: "2026.11.1"', updated)
        self.assertEqual(extract_mix_version(updated), "2026.11.1")

    def test_update_is_compatible_with_version_bump_script_format(self):
        updated = update_mix_version(self.SAMPLE, Version(2026, 11, 0))
        self.assertIn('version: "2026.11.0"', updated)
        self.assertEqual(updated.count("2026.11.0"), 1)

    def test_missing_version_entry_fails(self):
        with self.assertRaises(ReleaseError) as raised:
            update_mix_version("defmodule X do\nend\n", "2026.11.0")
        self.assertEqual(raised.exception.code, "mix_version_missing")


if __name__ == "__main__":
    unittest.main()
