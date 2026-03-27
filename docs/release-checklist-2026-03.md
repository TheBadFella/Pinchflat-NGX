# Release Checklist - 2026-03

This checklist tracks follow-up work for the playlist selection fix release, plus the download performance investigation.

## Section 1: Playlist Selection And Auto-Download Regression Guardrails

- [x] Re-test normal playlist creation with `Delay Automatic Download` off.
- [x] Confirm normal playlists redirect to the source page, not the `Selection` tab.
- [x] Confirm normal playlists begin downloading automatically after indexing.
- [x] Re-test playlist creation with `Delay Automatic Download` on.
- [x] Confirm delayed playlists redirect to the `Selection` tab.
- [x] Confirm delayed playlists do not auto-download before selection is applied.
- [x] Confirm only manual playlists expose the `Selection` tab in the source view.
- [x] Add or verify regression coverage for all of the above in controller/context tests.

## Section 2: Existing Source Recovery

- [x] Decide whether existing playlist sources created before the fix need automatic remediation.
- [x] Add an edit-flow control to switch a playlist from manual selection mode back to normal auto-download mode.
- [x] Define what happens to existing `prevent_download` items when switching back to auto-download mode.
- [x] Add a source-level status badge or summary showing `Automatic Downloads` vs `Manual Selection`.
- [x] Add a user-visible explanation when a media item is not downloading because `prevent_download` is true.

## Section 2A: Sources List UX

- [x] Add a visible source-mode identifier on the sources list page for:
  - `Automatic Downloads`
  - `Delayed Downloads`
- [x] Place the identifier near the source name so the mode is visible at a glance in the list view.
- [x] Add row-level source controls beside the source name:
  - `Start All`
  - `Pause All`
  - `Stop All`
- [x] Define the exact behavior for those controls:
  - whether `Start All` enables downloads, re-enqueues pending items, or both
  - whether `Pause All` disables future enqueues only or also pauses active jobs
  - whether `Stop All` cancels active jobs, dequeues pending jobs, or both
- [x] Make sure the controls are safe for long-running playlist sources and reflect current source state clearly.
- [x] Add tests for source-list actions and permissions.
- [x] Validate the list layout still works on smaller screens after adding badges and inline controls.

## Section 3: Download Speed Investigation

- [ ] Capture actual runtime values for:
  - `YT_DLP_DOWNLOAD_WORKER_CONCURRENCY`
  - `YT_DLP_INDEX_WORKER_CONCURRENCY`
  - `YT_DLP_REMOTE_METADATA_WORKER_CONCURRENCY`
  - `download_throughput_limit`
  - `extractor_sleep_interval_seconds`
- [ ] Measure download speed in the job UI during a real multi-item playlist run.
- [ ] Determine whether the bottleneck is:
  - queue starvation
  - yt-dlp precheck overhead
  - extractor sleep settings
  - throughput caps
  - remote throttling
  - disk I/O
- [x] Check whether slow indexing still does redundant pending-download sweeps for large sources.
- [x] Decide whether the broad post-index enqueue pass can be narrowed safely.
- [x] Review whether cookies or metadata fetch behavior is adding unnecessary round trips.

## Section 4: MeTube Comparison

- [x] Inspect MeTube's yt-dlp invocation strategy.
- [x] Compare MeTube concurrency and queue behavior to Pinchflat.
- [x] Compare whether MeTube skips any prechecks that Pinchflat performs before download.
- [x] Compare cookie usage, archive usage, and metadata fetch flow.
- [x] Compare ffmpeg/post-processing defaults.
- [x] Document any concrete differences that could explain faster effective throughput.
- [x] Identify changes that are safe to port without regressing correctness or observability.

## Section 5: Logging And Diagnostics

- [x] Add structured logs when a source is created showing:
  - `collection_type`
  - `selection_mode`
  - `download_media`
  - `enabled`
- [x] Add structured logs when indexing finishes and pending downloads are enqueued.
- [x] Log why a media item was skipped:
  - source downloads disabled
  - item prevented
  - item not pending
  - format/profile mismatch
- [x] Add a simple operator playbook for inspecting source and media download state in Docker.

## Section 6: Release Validation

- [x] Run focused tests for touched source/controller/downloading files.
- [ ] Run full `docker compose run --rm phx mix test`.
- [ ] Run `docker compose run --rm phx mix check`.
- [ ] Validate the preview/dev stack starts cleanly and stays up.
- [ ] Smoke test source creation for channel, playlist, and single video URLs.
- [ ] Confirm no regressions in Pending, Active Tasks, Downloaded, Job Queue, and Excluded tabs.

## Section 7: Per-Source Folder Selection

- [x] Add a per-source folder field that stores a relative subpath under the media root.
- [x] Validate the folder input so it cannot escape the media root or use unsafe absolute paths.
- [x] Apply the source folder before the existing output template so current naming rules still work.
- [x] Show the folder field in the source create/edit form with clear help text.
- [x] Add an existing-folder picker on the source form for choosing folders already under the media root.
- [x] Add a source-form helper action that inserts the media profile output template for editing.
- [x] Add tests covering output path resolution with and without a per-source folder.
- [ ] Confirm source metadata and series-directory logic still work with per-source folders.

## Notes

- The immediate bug fixed here was that normal playlists were incorrectly exposed to the selection workflow in the UI.
- The next area to investigate is download performance, especially relative to MeTube.
