# Download failure guidance and roadmap reconciliation

Base: `ba97f9dfbd4b452d599d26d99258362bbab2caa5` (PR #135).
Implementation branch: `fix/download-failure-guidance`.
The original checkout and its existing edits are preserved.

## Behavior

The source and global history views use one shared presentation component. Recognized storage, authentication, availability, rate-limit, bot-check and network failures get an explanation and recovery advice. Unknown messages, including an HTTP 403 without a more specific cause or a generic post-processing timeout, retain an explicit unknown-cause fallback.

Raw errors remain escaped text inside a native, keyboard-operable Technical details disclosure. Recovery links use the existing Settings and Diagnostics pages. No automatic repair or new configuration is introduced.

Queue guidance comes from the active download job already loaded by each view: running, queued, retryable or scheduled. A scheduled time uses the app's timezone and clock preference. Without an active job, the component distinguishes an item-level download block from an empty queue. Global history now selects `prevent_download`, matching the source view. A scheduled time is not a guaranteed start time; queues can be paused.

Worker classification, retry scheduling, manual/forced download policy and confirmation dialogs are unchanged. Render tests verify that displaying the guidance adds no work.

Browser review exposed adjacent card-layout defects: action buttons and badges could squeeze titles into a one-character column on narrow screens, and the progress component had a fixed minimum width larger than its card. Card headers now give titles and actions separate rows, and progress widths are bounded by their container.

## Roadmap reconciliation

The companion wiki checkout is `D:/Git/PinchYT-failure-validation/wiki`, based on wiki commit `a6d4b63ad5d849d36380087bdacf1ba3b040fb89`. Its `Roadmap.md` is the edited user-facing page; the repository's `docs/roadmap.md` remains a redirect.

- Global Latest is released in 2026.10.16 via #129.
- Browse and reviewed URL intake (#131), scoped sharing (#132), media-server refresh (#133), hardening (#134) and reliability corrections (#135) are merged into master, but absent from the latest published 2026.10.16 release.
- Current-schema SQLite transfer is corrected in #135. Transfer tables for hypothetical future features are not implemented work.
- This failure-guidance follow-up is local, not merged or released.
- CSV import, WebSub and announcements remain deferred proposals, with explicit conditions for reconsideration. Historical local owner ledgers are snapshots, not current completion records.

Evidence was checked against current routes, contexts, transfer schema and GitHub PR/release state on 18 October 2026. The older `outputs/testing-stack/remaining-local-pr-work.md` ledger still labels Latest unimplemented and transfer deferred; current code and merged PRs supersede those claims.

## Verification

Raw commands, successful and failed logs, synthetic fixture data and browser evidence are retained in `D:/Git/PinchYT-failure-validation`. The owned Docker project is `pinchflat-failure-guidance-20261018`; it has no production storage mounted.

The initial two regression tests failed because neither view had the guidance. Final verification completed on 18 October 2026:

- Docker `mix check --no-fix --no-retry` passed on SQLite with its test database on an owned Docker volume: 2,278 test definitions, zero failures, 36 excluded. Theme checks and asset build passed in the same run (`complete-check.log`). The exclusions are the normal `migration_schema` and `postgres_only` selections, not successful tests.
- The final affected-view suite passed on PostgreSQL: 52 tests, zero failures (`resumed-postgres.log`). It includes progress arriving before job state and live transitions from retryable to discarded. The full PostgreSQL suite and dedicated schema suite were not rerun for this presentation change.
- Both real LiveViews passed browser checks at 320, 360, 390, 414, 768 and 1440 pixels: readable card titles, bounded card/progress widths, no page overflow, controls at least 44 by 44 pixels, keyboard disclosure open/close, escaped raw errors, and working Settings/Cookies and Diagnostics navigation. No browser page errors were recorded (`browser.json`, `resumed-browser-final.log`). Phone card and desktop screenshots were also visually inspected.
- `git diff --check` passed in the implementation worktree.

The browser harness initially waited for the first connected LiveView on the page, which could be an unrelated component. The source table could then connect after the disclosure was opened, resetting its initial markup. A focused keyboard probe passed; waiting for the failure table's own LiveView connection resolved the full run. The failed harness logs are retained; no application workaround was added.

Intermediate checks found formatting and encoding mistakes in the edits; corrected them, including independent ASCII/Unicode bot-challenge cases and a generic-timeout fallback. Some full SQLite runs on the Windows bind mount hit `Exqlite.Error: Database busy` while setting up an existing legacy-migration scan fixture. This also occurred before this change. The failed logs remain available; no application retry-policy workaround was added.

Runtime verification uses the actual LiveViews and built assets with a separate synthetic SQLite library and manual job execution mode. It tests presentation, navigation and queue-state display, not live YouTube downloads. Physical devices, screen readers and a full PostgreSQL check are outside the verification performed for this presentation change.

This is the validation snapshot before publication. The follow-up is implemented and locally verified; code and the companion wiki reconciliation are prepared for publication. The PR records the final merge and CI results. This change does not publish a release or container image or deploy the app. The temporary UI started during continuation has been stopped; the PostgreSQL fixture service that was already running was left intact.
