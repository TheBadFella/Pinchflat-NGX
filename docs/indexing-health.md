# Indexing controls and health

Fast Indexing disables the full-scan frequency picker because the backend uses a
30-day full-refresh interval while checking recent uploads every ten minutes.
Disabling Fast Indexing restores an editable full-scan frequency. Saving does not
resume intentionally paused queues. Single-video sources have no recurring indexing.

The System Health view distinguishes full scans from fast checks. Fast-check
success uses retained completed indexing jobs linked to the source; successful
checks with no new videos still count. Full scans use their successful timestamp
and completed full-index jobs. Download or metadata jobs do not prove indexing.

- Healthy: success is within the configured check interval plus grace.
- Overdue: observed success is older than that interval plus half an interval of
  grace, with a minimum grace of ten minutes.
- Failed check: a retryable/discarded indexing attempt is newer than the observed success.
- Unknown: retained success or queue status is unavailable. Pruning old history
  can produce this state; it does not mean migration damaged the library.
- Active or scheduled/pending: indexing is executing or queued; this is not a
  claim of completed success. An overdue success is still overdue when merely queued.
- Paused/held: the relevant indexing queue is intentionally paused or migration
  review is pending. Disabled and manual sources are classified separately.

The summary and review list share one classification. The list shows up to ten
overdue, failed or unknown sources and separates fast-check cadence from full
refresh cadence. Opening or refreshing health does not change sources, queues,
settings or files, and does not contact YouTube. A Force Full Scan is an explicit
existing action, not an automatic response to a warning.

Media-profile presets update native checkbox states and emit normal input/change
events. Disabled custom selectors reject selection even when their menu was open
before the controlling setting changed.
