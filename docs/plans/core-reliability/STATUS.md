# Core reliability improvements

Base: `72f203b` (18 October 2026). Local worktree: `D:/Git/PinchYT-core-reliability`.
Existing edits in `D:/Git/PinchYT` are preserved. The user authorized a pull request and merge on 18 October 2026.

All five corrections are implemented and locally verified:

1. Protect general API operations using existing Basic Auth credentials, including under OIDC.
2. Transfer the actual current SQLite schema and preserve sharing, typed data and allocation history.
3. Report download/retry outcomes accurately without weakening forced-download distinctions.
4. Include existing JavaScript checks in routine CI and verify isolated startup and recovery.
5. Improve the existing bulk source import without adding a second import subsystem.

Validation uses the owned Docker project `pinchflat-core-reliability-20261018`.
Compose configuration and raw evidence are in `D:/Git/PinchYT-core-validation`.
All databases and synthetic media belong to that project; no production storage is mounted.

## Evidence

- API regression before the fix: four tests, three failures. Protected library reads returned 200.
- Current-schema SQLite validation failed before the transfer correction. The corrected validator accepts a database created by actual migrations.
- Retry regressions reproduced a false duplicate-success message and loss of the previous task when replacement enqueueing failed. Replacement is now transactional.
- A final regression reproduced API profile creation during PostgreSQL review (201 instead of 423). Both legacy and PostgreSQL review now hold API writes; management authentication runs before that check.

| Final check                                                             | Result                                                                                                                                                      | Raw evidence                                   |
| ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| Docker SQLite `mix check --no-fix --no-retry`                           | Passed: 2,265 definitions, 2,229 executed, zero failures, 36 excluded                                                                                       | `complete-sqlite.log`                          |
| Docker PostgreSQL full check                                            | Passed: 2,265 definitions, 2,218 executed, zero failures, 47 excluded                                                                                       | `complete-postgres.log`                        |
| Separate PostgreSQL schema process                                      | Passed: 25 tests                                                                                                                                            | `schema-postgres.log`                          |
| SQLite late database-rejection fault                                    | Passed: one schema-tagged test; 15 ordinary cases excluded from this selection                                                                              | `schema-sqlite.log`                            |
| Existing sidebar, Browse, date-picker and responsive-dialog Node suites | Passed in both final full checks                                                                                                                            | `complete-*.log`                               |
| Theme and workflow validation                                           | Passed: Docker `yarn run ui:check-theme`, containerized actionlint, `git diff --check`                                                                      | `actionlint-final.log`, tool output            |
| Linux amd64 production image builds                                     | Passed for both adapters; running image IDs match final builds                                                                                              | `image-complete-*.log`                         |
| Native SQLite to PostgreSQL transfer                                    | Passed: every selected table validated, typed subtitles, credential revocation, retired IDs, source hash, replay refusal and pending review                 | `native-transfer.json`, `native-transfer3.log` |
| Packaged browser journey                                                | Fresh onboarding, source indexing, controlled failure, explicit retry, playback, exact full/Range bytes and HEAD passed                                     | `browser-journey.json`, `browser-journey2.log` |
| Final packaged UI and restart checks                                    | Passed: retained media bytes, specific import errors, keyboard confirmation, cancellation, duplicate handling and usable PostgreSQL profile/import page     | `browser-followup.json`, `browser-final.log`   |
| Final responsive preview                                                | Passed at 320/360/390/414/768/1440px; no document overflow, confirmation target 44px                                                                        | `browser-followup.json`, `final-import-*.png`  |
| Abrupt interruption and repeat request                                  | Passed on final image: killed during an executing download, same job completed on its second attempt after startup, no duplicate work, media hash unchanged | `interruption.json`, `interruption-final.log`  |
| Actual transferred library under review                                 | Final PostgreSQL image read the retained library; anonymous writes returned 401, authenticated writes returned 423, profile rows remained unchanged         | `runtime-review.json`                          |

Excluded adapter tests are not counted as passes. Separate schema checks cover the schema-tagged cases; unchanged schema modules were not needlessly rerun after presentation/access changes.

Downloads in these runtime journeys use a synthetic yt-dlp executable and a locally generated MP4. The application, forms, workers, queues, storage, HTTP streaming and playback are real. This proves the application path at the external-process boundary, not current YouTube access.

## Corrections during validation

- The PostgreSQL development container initially lacked `pg_dump`. Installed PostgreSQL 18 client tools in that owned container, then passed the full gate.
- Schema tests intentionally commit fixture state. Reusing their database caused fixture-name collisions in a later full suite. Final PostgreSQL full checks use the separate `core_full_final` database. The original failure logs remain available.
- Native probe drafts used the wrong share-authentication function and revoked-status name; corrected the probes and verified a fresh transfer target. These were harness failures, not application defects.
- The Chrome connector was unavailable. Browser proof uses a separately launched headless Chromium. A first probe dismissed a confirmation dialog; a fresh journey accepted the actual confirmation and verified the resulting work. A later probe initially requested a page before startup completed; the final probe waits for readiness and still requires the actual UI journey.

## Scope and remaining limits

API clients must provide the existing Basic Auth credentials when browser authentication is configured. OIDC-only installations reject general API calls until those credentials are set. Public health/spec routes, podcast access rules and scoped sharing remain separate.

Bulk source import remains a bounded text import. It previews before mutation, processes one source at a time, shows outcomes, and cancels after the current source. Already-added sources remain. Closing the page does not provide durable import resume. CSV intake, bulk source editing, WebSub and announcements remain deferred.

The checks below were captured before publication. Pull request and merge checks are recorded in GitHub. Public wiki edits, releases, image publication and production deployment are outside this batch. The original working checkout was not edited.

Live YouTube/account access, an external OIDC provider, ARM runtime, physical mobile devices and screen-reader usability were not tested. Automatic GitHub triggers are implemented and actionlint-validated locally. Remote results belong to the corresponding GitHub Actions run.

Operator-facing wording is prepared in [OPERATOR-NOTES.md](OPERATOR-NOTES.md). Final source hashes and image identities are saved with the raw evidence. Owned containers are stopped after capture; named fixture volumes are retained for reproduction.
