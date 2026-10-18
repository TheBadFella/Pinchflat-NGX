# Bulk source pause

This records the implementation, validation and priority decisions for bulk source pause.

## Why this is next

The critique replaced a feature-count queue with this order: protect management APIs, preserve the current database during transfer, make download/retry feedback truthful, close inexpensive verification gaps including packaged recovery, then improve bulk source management through the existing workflow. Consequence, demonstrated user need, evidence, implementation size and ongoing maintenance determine priority. Existing implementation effort alone does not justify shipping a feature.

The reliability batch (#135), failure guidance (#137), replacement-file preservation (#139) and single-source Pause/Stop cancellation (#141) are merged. Packaged recovery checks found the replacement defect; testing Pause during replacement found its prerequisite cancellation defect. Those findings justified the order before adding multi-selection.

The latest user instruction in the recovered chat authorized publishing/merging the single-source fix and then implementing Pause selected. PR #141 merged as `4e4cf2ee125d9db942fea08c115ab5f6d1ce202f`; its post-merge run `39163823965` passed SQLite, PostgreSQL and dedicated schema jobs. This was verified again during continuation.

The exact interruption left only `bulk_source_pause_test.exs` on `feat/pause-selected-sources`, based on that merge. The first run could not use stale dependencies. Continuation uses separate owned dependency volumes without updating application dependencies or the lockfile.

## Implemented locally

- Individual selection in mobile cards, desktop table and poster grid; selection is shared between layouts.
- Select page and Clear selection with a live selected count. Paging and sorting clear selection; background refresh drops sources no longer on the page.
- Confirmed Pause selected through the authenticated browser POST/CSRF flow. Monitoring and files remain intact; idle selected sources also have future downloads paused.
- Up to 100 valid source IDs, deduplicated. Missing, malformed, oversized, deleted-source and deleted-profile selections are rejected before changes.
- Source updates commit together. If one fails, all updates roll back before any cancellation. Successful updates reuse the existing cancellation helper, including replacement downloads.
- The new browser-only endpoint stays out of the generated API specification.

## Scope and next decision

The validated feature is prepared for publication from `feat/pause-selected-sources`. The original checkout and other tasks are preserved. The PR records the final commit and CI results. No release or deployment is included.

Finish this feature's review/publication before expanding the control set. Bulk cutoff editing is the next candidate from issue #99 feedback, to be scoped separately against the existing cutoff semantics. CSV import should extend the existing import flow if justified. WebSub needs measured benefit beyond polling; dynamic announcements remain deferred. Do not resurrect the old P18/P19-first queue: those features have since merged.

## Evidence

Evidence is retained in `D:/Git/PinchYT-bulk-source-validation`, including compose definitions, scripts and unsuccessful runs. The app and both database suites run in isolated Docker services. The browser drives a packaged SQLite app with twelve synthetic sources; no real channel indexing/download was requested for this UI change.

- Initial feature regression: three failures before implementation, then three passes.
- Expanded focused source/control checks: 32 tests, zero failures on each adapter, including file/job preservation, stale selection, duplicate IDs, rollback and layout/page selection behavior.
- Packaged browser: keyboard Space selection, grid/table state, cancel sending no POST, acceptance pausing exactly the selected sources, monitoring preserved, unselected sources unchanged, Select page submitting ten current-page IDs and Clear selection working.
- Packaged boundary checks: missing CSRF token returns 403; unauthenticated POST returns 401.
- Geometry checks at 320, 360, 390, 414, 768 and 1440 pixels: table and grid document width stays within viewport, and bulk buttons/checkbox labels provide at least 44px targets. Screenshots are retained.
- Theme script passed in a PowerShell Docker container (host Yarn was unavailable). No new semantic theme tokens were required.
- Existing table tests initially failed because an added column moved their cell positions. The checkbox now sits in the existing name cell; the original columns remain intact.
- One SQLite run hit the existing asynchronous cookie-probe cleanup assertion. Its file passed in isolation, including with the failed full run's seed. This is recorded as a failure, not counted as coverage. A separate added-test timestamp precision mistake was corrected before the final gates.

Final gate results, source hashes and runtime image identity are recorded alongside this handoff after completion. PostgreSQL packaged browser behavior, live YouTube downloads, ARM and screen-reader behavior were not tested by this change.

## Final results (2026-10-18)

- `gate-sqlite.log`: Docker `mix check --no-fix` passed; 2,301 test definitions, zero failures, 36 excluded (2,265 executed). Compiler, formatter, Credo, security, dependency and JavaScript checks passed.
- `gate-postgres.log`: the same gate passed; 2,301 definitions, zero failures, 47 excluded (2,254 executed).
- Adapter exclusions are configured in `test/test_helper.exs`: PostgreSQL excludes SQLite-only cases; SQLite excludes PostgreSQL-only cases; both routine suites exclude isolated migration-schema tests. This change did not alter exclusions or run the dedicated schema suite.
- The focused 32-test set passed before each final gate. `browser-report.json`, `page-selection.log` and screenshots record packaged UI results. Unauthenticated POST returned 401 in a separate browser context.
- `build-runtime-final.log`: production SQLite build passed. Local image identity: `sha256:90ea04d9126689a224b183351ae41fc76acb660abbc74c2ad4dab59d8e76cf90`.
- `source-hashes.json` fingerprints all changed implementation and test files. Browser verification used that implementation; only test additions/fixture corrections and this handoff followed the image build.
- `theme.log`: theme scan passed in Docker using the repository PowerShell script. `git diff --check` passed.
- The isolated app and test database are stopped after verification; fixture volumes and evidence remain. No release or deployment occurred.

The standalone development asset build initially lacked Alpine in the test harness. After installing the locked asset dependencies into an owned Docker volume, `assets.log` records a passing Tailwind/esbuild build. The production image had already built its assets successfully. No dependency or lockfile changes were made.
