# Selective Download Tasks

## Placement Decision

The selection UI should show up as a new tab on the source detail page.

Current source tabs live in `lib/pinchflat_web/controllers/sources/source_html/show.html.heex`:

- `Source`
- `Pending`
- `Active Tasks`
- `Downloaded`
- `Job Queue`
- `Excluded`

Recommended new tab:

- `Selection`

Recommended behavior:

- Show the `Selection` tab only for playlist sources, or only when the source is in manual-selection mode.
- When a user creates a playlist source with delayed automatic downloading enabled, redirect them to:
  - `/sources/:id?tab=selection`
- The selection tab should list indexed playlist items ordered by `playlist_index`, with:
  - checkboxes
  - select all / clear all
  - optional range input later
  - action buttons like `Save Selection` and `Download Selected`

## Section 1: Download Speed in Progress UI

### Backend

- [x] Add `progress_speed_bytes_per_second` to the `tasks` table with a new migration.
- [x] Add `progress_speed_bytes_per_second` to `Pinchflat.Tasks.Task` in `lib/pinchflat/tasks/task.ex`.
- [x] Allow the field in `Pinchflat.Tasks.Task.changeset/2`.
- [x] Include the field in `Pinchflat.Tasks.task_progress_payload/1`.
- [x] Include the field in `Pinchflat.Pages.JobTableLive.progress_fields/0`.
- [x] Include the field in `PinchflatWeb.Sources.MediaItemTableLive.progress_fields/0`.

### yt-dlp parsing

- [x] Parse the speed token in `Pinchflat.YtDlp.CommandRunner.parse_progress_line/1` in `lib/pinchflat/yt_dlp/command_runner.ex`.
- [x] Persist speed updates through `Tasks.update_task_progress/2`.

### UI

- [x] Show speed in the active jobs dashboard in `lib/pinchflat_web/controllers/pages/page_html/job_table_live.ex`.
- [x] Show speed in the source media table in `lib/pinchflat_web/controllers/sources/source_html/media_item_table_live.ex`.
- [x] Format speed as human-readable bytes per second, for example `3.2 MiB/s`.

### Tests

- [x] Extend `test/pinchflat/downloading/media_download_worker_test.exs` to assert speed persistence.
- [x] Extend `test/pinchflat/tasks_test.exs` to assert speed round-tripping through task updates.
- [x] Extend LiveView/UI tests that cover progress display.

## Section 2: Retry Logic and Error Reset Behavior

### Desired behavior

- [x] When a pending download is manually re-triggered, clear old `last_error` immediately.
- [x] If the new attempt fails with the same normalized error, keep that error visible.
- [x] If the new attempt fails with a different error, replace `last_error` with the new message.
- [x] If the retry succeeds, keep `last_error` cleared.

### Worker changes

- [x] Capture the prior `last_error` before starting the download in `lib/pinchflat/downloading/media_download_worker.ex`.
- [x] Clear `last_error` before starting a new attempt.
- [x] Let the new attempt repopulate `last_error` naturally if it fails again.
- [x] Keep the logic in the worker path so it applies consistently to all retry entry points.

### Error normalization

- [x] Add a small helper to normalize errors before comparison:
  - trim whitespace
  - collapse repeated whitespace
  - strip common `ERROR:` prefixes
- [x] Use normalized compare rather than raw string compare.

### UI and progress copy

- [x] Add a progress status such as `Retrying download` or `Retry requested` while the new attempt is underway.

### Tests

- [x] Add worker tests for:
  - old error cleared on retry start
  - same error repeated
  - different error replacing previous error
  - success clearing previous error

## Section 3: Selective Playlist Download Data Model

### Source-level mode

- [x] Add a source-level field to indicate manual playlist selection mode, recommended:
  - `selection_mode`
  - values: `:all`, `:manual`
- [x] Add the migration for the new source field.
- [x] Add the field to `Pinchflat.Sources.Source` in `lib/pinchflat/sources/source.ex`.
- [x] Add it to allowed source changes and validations.

### Why this is needed

- [x] Ensure future playlist items default to non-downloading behavior when the source is in manual mode.
- [x] Avoid relying only on one-time create flow state.

## Section 4: Source Creation Flow for Delayed Automatic Download

### Form changes

- [x] Add a create-time toggle to `lib/pinchflat_web/controllers/sources/source_html/source_form.html.heex`:
  - `Delay Automatic Download`
- [x] Make it clear in help text that this is intended for playlists where the user wants to pick specific items first.
- [x] Keep this as create-flow behavior, not a normal edit field unless we decide to support toggling it later.

### Controller changes

- [x] Update `PinchflatWeb.Sources.SourceController.create/2` to accept the delayed-download toggle.
- [x] When the new source resolves to a playlist and delayed-download is enabled:
  - create it in manual selection mode
  - create it with `download_media: false`
  - still index it
  - redirect to `/sources/:id?tab=selection`
- [x] Preserve normal create flow for:
  - channels
  - single videos
  - playlists where delayed-download is not selected

### Source context changes

- [x] Update `Pinchflat.Sources.create_source/2` and related post-commit handling so manual playlist creation does not auto-enqueue downloads before selection is applied.

## Section 5: Selection Tab UI

### New tab

- [x] Add a new `Selection` tab to `lib/pinchflat_web/controllers/sources/source_html/show.html.heex`.
- [x] Update allowed tab handling in `PinchflatWeb.Sources.SourceController.show/2` so `selection` is valid.
- [x] Hide the tab when it does not apply.

### Selection interface

- [x] Build a selection UI that shows playlist items:
  - ordered by `playlist_index`
  - with checkboxes
  - with current selected/unselected state
- [x] Add bulk actions:
  - `Select All`
  - `Clear All`
- [x] Add action buttons:
  - `Save Selection`
  - `Download Selected`

### Optional enhancement

- [x] Add typed index/range support, for example `1-10,15,20-25`.

## Section 6: Applying Playlist Selection

### Persistence behavior

- [x] Save selected items by setting `prevent_download: false`.
- [x] Save unselected items by setting `prevent_download: true`.
- [x] Use bulk updates where possible for performance.

### Download kickoff

- [x] When the user confirms selection:
  - optionally set `download_media: true`
  - enqueue downloads only for selected pending items
- [x] Make sure unselected items remain indexed but not downloaded.

### Future indexing behavior

- [x] During future indexing, if the source is in manual mode and a new playlist item is discovered, create it with `prevent_download: true`.
- [x] Ensure automatic pending sweeps do not bypass manual selection mode.

### Tests

- [x] Add tests covering:
  - selected items download
  - unselected items stay pending-but-prevented
  - future new playlist entries default to prevented in manual mode

## Section 7: Download Performance Improvements

### Runtime/config review

- [ ] Verify actual runtime values for:
  - `YT_DLP_WORKER_CONCURRENCY`
  - `download_throughput_limit`
  - `extractor_sleep_interval_seconds`
- [x] Document recommended deployment defaults for faster downloads.

### Queue concurrency split

- [x] Split yt-dlp queue concurrency so downloads can be tuned separately from indexing.
- [x] Add separate env vars, recommended:
  - `YT_DLP_DOWNLOAD_WORKER_CONCURRENCY`
  - `YT_DLP_INDEX_WORKER_CONCURRENCY`
- [x] Update `config/runtime.exs` to apply them per queue.

### Reduce duplicate work

- [x] Review whether `get_downloadable_status` precheck can be skipped for some downloads.
- [x] If safe, avoid the extra precheck round-trip for non-livestream items that already use cookies.
- [ ] Review source-wide pending sweeps after indexing and reduce redundant enqueue scans where possible.

### Diagnostics

- [ ] Use the new speed display to confirm whether slowness is:
  - network throughput
  - remote-side throttling
  - queue starvation
  - precheck/index overhead

### Recommended defaults

- `YT_DLP_DOWNLOAD_WORKER_CONCURRENCY=6`
- `YT_DLP_INDEX_WORKER_CONCURRENCY=2`
- `YT_DLP_REMOTE_METADATA_WORKER_CONCURRENCY=2`
- `download_throughput_limit=nil` unless you intentionally want to rate-limit downloads
- `extractor_sleep_interval_seconds=0` unless you are explicitly trying to reduce request pressure

These are deployment recommendations, not verified live values from the current runtime.

## Section 8: Download Cutoff Date Behavior

### Desired behavior

- [x] New sources should not auto-populate `download_cutoff_date`.
- [x] A source should download all eligible media by default unless the user explicitly sets:
  - a manual cutoff date
  - a preset cutoff date
- [x] Indexing should not silently advance or backfill `download_cutoff_date`.

### Current code to change

- [x] Remove the automatic cutoff-date advancement in `update_source_after_indexing/1` in `lib/pinchflat/slow_indexing/slow_indexing_helpers.ex`.
- [x] Keep `last_indexed_at` updates, but stop writing a synthetic cutoff date during indexing.
- [x] Review any create flow defaults to ensure the source form leaves `download_cutoff_date` blank unless the user sets it.

### Validation

- [x] Create a new source and confirm `download_cutoff_date` remains `nil`.
- [x] Confirm a new source downloads all eligible items by default.
- [x] Confirm preset selection still works when the user explicitly chooses one.
- [x] Confirm manually entered cutoff dates are still respected.

## Section 9: Final Validation

### Manual checks

- [x] Create a normal playlist source and confirm it still auto-downloads as before.
- [x] Create a playlist source with delayed automatic downloading and confirm it redirects to the `Selection` tab.
- [x] Select a subset of items and confirm only those download.
- [x] Confirm unselected items remain visible but excluded from downloading.
- [x] Re-trigger a failed pending item and confirm stale errors are cleared correctly.
- [x] Confirm speed is visible in both job progress areas.

### Regression checks

- [x] Confirm channel and single-video source creation are unchanged.
- [x] Confirm existing pending/downloaded/excluded tabs still work.
- [x] Confirm background indexing does not break manual playlist mode.

## Recommended Order

- [ ] Complete Section 1 first: speed in progress UI
- [ ] Complete Section 2 next: retry/error reset behavior
- [x] Complete Section 7 next: performance tuning
- [x] Complete Sections 3 through 6 after that: selective playlist downloads
- [x] Complete Section 8 next: cutoff date behavior
- [x] Complete Section 9 last: validation and regression checks

## Test Status

- [x] `mix format`
- [x] Focused regression suite for touched files
- [x] Full `mix test`

## Verified Remaining Work

This section lists only the items that still appear to be missing after comparing this document against the current codebase.

### Performance Validation And Tuning

- [x] Verify the actual runtime values for `YT_DLP_WORKER_CONCURRENCY`, `download_throughput_limit`, and `extractor_sleep_interval_seconds`.

Pertains to:

- Confirming the real environment settings the app is running with, not just the code defaults.
- Determining whether slow downloads or indexing are caused by deployment configuration rather than application logic.
- `download_throughput_limit` may cap transfer speed.
- `extractor_sleep_interval_seconds` may intentionally add delay between yt-dlp requests.
- `YT_DLP_WORKER_CONCURRENCY` is still used as the fallback for the newer split queue settings.

- [x] Review the source-wide pending download sweep that still runs after indexing and reduce redundant enqueue scans if a narrower safe path exists.

Pertains to:

- `Pinchflat.SlowIndexing.SlowIndexingHelpers` still calls `DownloadingHelpers.enqueue_pending_download_tasks(source)` after indexing completes.
- That broad pass is correct, but it may do unnecessary work for large sources when only some items changed.
- The remaining work is to determine whether this can be narrowed without regressing download correctness or manual selection behavior.

- [x] Use the new download speed display in real runtime conditions to determine whether slowness is caused by network throughput, remote throttling, queue starvation, or precheck/index overhead.

Pertains to:

- Operational diagnosis rather than missing UI or backend implementation.
- The speed field is already stored and rendered, but the follow-up analysis has not been captured as complete.
- This work should inform whether any additional queue tuning or yt-dlp request changes are actually needed.
