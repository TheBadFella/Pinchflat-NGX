# Bulk source cutoff validation

Branch: `feat/bulk-source-cutoff`, prepared for publication against master after PR #140 (`a2702c9`). Earlier validation used merged PR #142 (`6f1488e`); publication checks cover the combined result. The PR records final commits and CI. No release or deployment is included.

## Behavior

The Sources view reuses its current-page selection for download cutoff editing. Enter a date, or leave it blank to remove the cutoff, then preview before confirming. Selection remains limited to the existing page; this does not add an all-library selection mode.

Preview validates the complete selection and existing source settings, including the rule that an indexing cutoff cannot be later than the proposed download cutoff. It lists existing source cutoffs and counts downloaded items before the proposed date, items eligible for scheduled removal, and items protected from culling. The media counts come from one aggregate query, so concurrent media changes cannot make the displayed counts disagree with each other.

A signed preview expires after fifteen minutes and binds the date, source IDs and source-settings fingerprint. Confirmation reloads the selection, locks source rows on PostgreSQL and rejects stale or unavailable sources. Updates commit together. Extra client-supplied dates or source IDs cannot replace the signed values.

Confirmation changes source dates only. It does not immediately delete files, enqueue work, change indexing cutoffs, resume paused sources or change monitoring. Normal download eligibility and scheduled retention subsequently use the new date. Retention can remove unprotected downloaded media before the cutoff; media uploaded exactly on the date stays eligible. Moving the date earlier or clearing it can make older indexed media eligible for download.

The selection loader is shared with Pause selected; its existing invalid-selection, rollback and file/job-preservation checks remain covered.

## Verification

Evidence: `D:/Archives/PinchYT/2026-10-18/cutoff-validation`.

- Seven initial regression checks failed before implementation. The expanded affected source, controller, pause and retention set passed 29 tests on SQLite and PostgreSQL.
- Full Docker checks passed on both adapters: 2,309 test definitions, zero failures. SQLite excluded 36 normal adapter/schema tests (2,273 executed); PostgreSQL excluded 47 (2,262 executed). Compiler, formatter, Credo, security, dependency and JavaScript checks passed. Logs: `gate-sqlite.log`, `gate-postgres.log`.
- The final preview layout change replaced a sentence with labeled counts. The affected 29-test set, formatting and asset build passed afterward in `preview-final.log`; the final production image and browser checks include that layout.
- A normal retention-worker test confirmed that a confirmed cutoff removes the older unprotected file only when retention runs, preserving protected media and media uploaded exactly at midnight on the cutoff date. Passed on both adapters.
- Packaged SQLite browser checks passed for keyboard selection and confirmation, a read-only preview with independently expected counts, cancel preserving every date, exactly two selected sources changing, other sources unchanged, monitoring/download switches preserved, and three fixture files remaining byte-for-byte intact.
- Missing-CSRF requests returned 403 for both new endpoints; unauthenticated confirmation returned 401. Controller checks reject unsigned/expired tokens, ignore forged extra parameters and reject changed source settings.
- Geometry checks passed in table/grid at 320, 360, 390, 414, 768 and 1440 pixels, and on preview at 320, 390, 768 and 1440. No document overflow; relevant inputs/buttons have at least 44px targets. A reviewed phone screenshot is retained.
- Theme scan, asset builds and production SQLite image build passed. Final image: `sha256:fa2b6b425a5015d72431b4f2215a36c28574d21d18fd3b71785d6e852d25e87f`.

Unsuccessful attempts remain in the evidence. Initial harness issues included a missing input value, signing an expired fixture token without an endpoint, and browser steps that did not wait for LiveView connection/layout state after navigation. The full gate also found a single-clause `with` lint issue in the shared selection helper, corrected before the final gates. The packaged fixture initially allowed background index jobs to run after container recreation; all fixture queues were then paused and those jobs cancelled before the final browser evidence. Their failed lookups of synthetic channel IDs are not live-provider validation.

PostgreSQL packaged UI, ARM, live YouTube downloads and screen-reader behavior were not exercised by this change. No schema change or isolated migration-schema suite was needed. The current task's isolated services are stopped after saving logs; dependency caches and reproducible fixture state remain for publication checks.

## Cleanup alongside this work

The cleanup inventory and restore mappings are in `D:/Archives/PinchYT/2026-10-18/README.md`. Thirteen verified completed worktrees were removed, along with 23 obsolete test containers, 80 unused test/dependency volumes, 30 old test/development image tags and three empty test networks. Build-cache pruning reported 4.03 GB reclaimed from cache unused for more than 24 hours.

Five validation folders, three older investigations, twelve root PR drafts/patches and four generated cache directories were archived intact. Automatic approval review rejected deletion of the generated directories, so they were moved rather than deleted. The original checkout's tracked edits, dirty/deferred worktrees, wiki and active PR #140 review environment are preserved. No branches or committed history were deleted.
