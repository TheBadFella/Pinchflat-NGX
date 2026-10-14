# Migration screenshot mapping

These are unchanged screenshot copies of real migration-testing captures, not mockups. They are embedded only in `docs/legacy-pinchflat-migration.md`. The backup page stays text-only.

Source tree: `C:\Users\Admin\Documents\Codex\2026-10-03\hell\work\branches\migration-guide\docs\assets\screenshots\` (branch `migration/migration-guide`). Original references: that tree's `docs/MIGRATION_GUIDE.md`, sections 6–8. Captures illustrate the PR #86 migration review; they are not screenshots of the current main checkout.

| Intended slot              | Published asset              | Original capture             | What it shows                                                                                                                                                                                                                         |
| -------------------------- | ---------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 01: Compose before/after   | No image; YAML examples only | No matching screenshot found | Keep the service and mounts; change the image. Placeholder removed.                                                                                                                                                                   |
| 02: Welcome                | `02-migration-welcome.jpg`   | `progress-desktop.jpg`       | Welcome, operations held, file check in progress. Continue is visible but disabled during this scan.                                                                                                                                  |
| 03: Summary / verification | `03-library-summary.jpg`     | `summary-desktop.jpg`        | Completed readability/size check; 80 of 82 files accessible. This is a problem example, not an all-clear.                                                                                                                             |
| 04: After continuing       | `04-sources-ready.png`       | `sources-table.png`          | Clean Sources page with channels and recorded downloads, without error rows or warning banners. This separate example does not show a confirmation flash or prove a migration transition. The Continue control is visible in slot 02. |
| Optional mobile welcome    | `05-welcome-mobile.jpg`      | `summary-mobile-initial.jpg` | Mobile welcome, held operations and finished file check; lower content is below the viewport.                                                                                                                                         |

Do not use `rescan-recovered-desktop.jpg` as proof of a recovered scan: it is byte-identical to `summary-desktop.jpg` and still shows two inaccessible files. It was intentionally not copied. The Sources page and migration-review captures use separate example libraries; their counts are not a before/after comparison. A clean screenshot illustrates the UI, not proof that every runtime check has passed.

No screenshots were edited or cropped. Migration-review desktop captures are 1920px wide, the Sources capture is 1920px wide, and mobile is 390px wide. The four SVG stand-ins were removed.

For manual publication, follow `docs/migration-wiki-upload-checklist.md`. Keep these original image bytes and their descriptive alt text.
