# Pinchflat Improvements

Issues discovered while debugging Jellyfin artwork problems.

## Status Summary

- ✅ **Completed:** Issues 1-8
- 🔄 **Open:** Issues 9-10

## Issue 1: Source images not downloaded for early sources ✅ COMPLETED

**Problem:** Sources created before `download_source_images` was added to the media profile have empty `poster_filepath`, `fanart_filepath`, and `banner_filepath` in the `sources` table. The `source_metadata` table may have stale references to files that were never actually downloaded.

**Example:** Tsoding (source id 11, created 2025-06-04)

- `sources` table has empty artwork paths
- `source_metadata` references `/config/metadata/sources/11/*.jpg` but folder doesn't exist

**Expected behavior:** When `download_source_images: true` is set on a media profile, existing sources using that profile should have their artwork downloaded on next index.

**Suggested fix:** Add a migration or background job that:

1. Checks all sources using profiles with `download_source_images: true`
2. Downloads missing source images for sources that don't have them
3. Updates both `sources` and `source_metadata` tables

## Issue 2: Source images not downloaded for some new sources ✅ COMPLETED

**Problem:** Some recently added sources have no `source_metadata` entry at all, even though they use a profile with `download_source_images: true`.

**Example:** Jimmy_Broadbent (source id 97, created 2026-01-13)

- No entry in `source_metadata` table
- No metadata folder at `/config/metadata/sources/97/`
- No artwork files in show folder
- 1521 media items indexed, videos were downloaded (then culled due to 3-day retention)

**Expected behavior:** Source metadata and images should be downloaded when a source is first indexed, regardless of retention settings.

**Suggested fix:**

1. Investigate why `source_metadata` entry wasn't created during initial indexing
2. Ensure source image download happens before/independently of media downloads
3. Add error logging if source image download fails

## Issue 3: No way to re-trigger source image download ✅ COMPLETED

**Problem:** There's no UI option or API endpoint to re-download source images for an existing source. Users must delete and re-add the source.

**Suggested fix:** Add a "Refresh source metadata" button in the source settings that:

1. Re-fetches channel metadata from YouTube
2. Downloads/updates poster, fanart, and banner images
3. Updates the `source_metadata` and `sources` tables
4. Copies images to the show folder

## Database schema reference

```sql
-- sources table (relevant columns)
SELECT id, custom_name, poster_filepath, fanart_filepath, banner_filepath FROM sources;

-- source_metadata table
SELECT source_id, metadata_filepath, fanart_filepath, poster_filepath, banner_filepath FROM source_metadata;

-- Metadata files stored in
/config/metadata/sources/{source_id}/
  - metadata.json.gz
  - poster.jpg
  - fanart.jpg
  - banner.jpg

-- Show folder should have copies
/downloads/shows/{source_custom_name}/
  - poster.jpg
  - fanart.jpg
  - banner.jpg
  - tvshow.nfo
```

## Issue 4: SQLite "Database busy" errors blocking job processing ✅ COMPLETED

**Problem:** The Oban job queue can get stuck with "Database busy" errors, preventing all indexing and download jobs from processing. This occurs when:

1. Long-running operations hold database locks
2. The WAL (Write-Ahead Log) file grows very large (observed 252MB)
3. Multiple concurrent operations compete for write access

**Symptoms:**

- Logs show repeated `(Exqlite.Error) Database busy` errors
- `Oban.Stager` GenServer terminates repeatedly
- Jobs stay in `available` state but never execute
- `last_indexed_at` for sources becomes very stale (months old)

**Example log:**

```
[error] | GenServer {Oban.Registry, {Oban, Oban.Stager}} terminating
** (Exqlite.Error) Database busy
UPDATE "oban_jobs" AS o0 SET "state" = ? WHERE (o0."id" IN (?))
```

**Root cause:** SQLite's `busy_timeout` PRAGMA defaults to 0 in the application, meaning queries fail immediately instead of waiting for locks to be released.

**Suggested fixes:**

1. **Set busy_timeout PRAGMA** - Configure Exqlite/Ecto to use a reasonable busy_timeout (e.g., 5000ms) so queries wait for locks instead of failing immediately
2. **Configure WAL autocheckpoint** - Ensure WAL doesn't grow unbounded; set `wal_autocheckpoint` to a reasonable value
3. **Add connection pool limits** - Limit concurrent database writers to reduce lock contention
4. **Implement job queue cleanup** - Automatically prune old completed/cancelled jobs to keep the oban_jobs table smaller

**Workaround:** Restart Pinchflat container to clear stuck state and checkpoint WAL:

```bash
docker compose restart pinchflat
```

**Manual database maintenance:**

```bash
# Stop Pinchflat first
docker compose stop pinchflat

# Clean old jobs and optimize
sqlite3 /path/to/pinchflat.db "
  DELETE FROM oban_jobs WHERE state = 'completed' AND completed_at < datetime('now', '-7 days');
  DELETE FROM oban_jobs WHERE state = 'cancelled' AND scheduled_at < datetime('now', '-7 days');
  ANALYZE;
  VACUUM;
"

# Start Pinchflat
docker compose start pinchflat
```

## Issue 5: Orphaned deletion jobs for non-existent sources ✅ COMPLETED

**Problem:** When a source is deleted, a `SourceDeletionWorker` job is created. If this job fails repeatedly (e.g., due to database busy errors or files already deleted), it keeps retrying indefinitely even after the source no longer exists.

**Example:** Source ID 97 was deleted, but the deletion job kept retrying (14 attempts) even though there was nothing left to delete.

**Suggested fix:**

1. Add a check at the start of `SourceDeletionWorker` to verify the source still exists
2. If source doesn't exist, mark job as completed (or cancelled) instead of retrying
3. Consider adding idempotency - if files/records are already gone, succeed gracefully

## Issue 6: Sources with `last_indexed_at = NULL` never get indexed ✅ COMPLETED

**Problem:** Some sources show `last_indexed_at` as NULL in the database, indicating they were never successfully indexed. These sources have indexing jobs in the queue but the jobs may have failed silently or been stuck.

**Example sources with NULL `last_indexed_at`:**

- PietSmietTV (id 91)
- Rory Alexander (id 93)
- BigfryTV (id 94)
- Multiple sources added on 2026-03-06 (ids 101-118)

**Suggested fix:**

1. Add monitoring/alerting for sources that haven't been indexed within expected timeframe
2. Add a "Force re-index" button in the UI
3. Log more details when indexing jobs fail
4. Consider a health check that identifies sources with stale/null `last_indexed_at`

## Issue 7: SlowIndexing jobs don't show as "executing" in UI ✅ COMPLETED

**Problem:** When `MediaCollectionIndexingWorker` (SlowIndexing) jobs start running, they spawn yt-dlp processes but fail to update their job state from `available` to `executing` in the database. This causes:

1. No tasks visible in the frontend at `/#tab-active-tasks`
2. Jobs appear stuck in `available` state even though yt-dlp is actively running
3. Users have no visibility into what Pinchflat is currently doing

**Observed behavior:**

```bash
# Database shows no executing jobs
sqlite3 pinchflat.db "SELECT state, COUNT(*) FROM oban_jobs WHERE state = 'executing'"
# Returns: (empty)

# But yt-dlp processes are actively running
ps aux | grep yt-dlp
# Shows multiple yt-dlp processes for OutdoorBoys, USCSB, etc.
```

**Contrast with FastIndexing:** `FastIndexingWorker` jobs DO properly transition to `executing` state and show in the UI. Only `SlowIndexing` jobs have this issue.

**Root cause hypothesis:** The SlowIndexing worker spawns an external yt-dlp process but the database state update either:

1. Fails silently due to SQLite busy errors
2. Happens in a transaction that doesn't commit before the long-running process starts
3. Is not implemented for this worker type

**Impact:**

- Users think nothing is happening when indexing is actually in progress
- No way to see progress or estimate completion time
- Difficult to debug issues without visibility

**Suggested fix:**

1. Ensure job state is updated to `executing` BEFORE spawning the yt-dlp process
2. Use a database transaction with proper busy_timeout to ensure the state change persists
3. Add periodic heartbeat updates during long-running indexing operations
4. Consider adding progress tracking (e.g., "indexed 50/500 videos")

## Issue 8: Old download_cutoff_date causes unnecessary full channel scans ✅ COMPLETED

**Problem:** The `download_cutoff_date` field on sources doesn't automatically update over time. Sources created months ago still have their original cutoff date, causing yt-dlp to scan through thousands of old videos on every index.

**Example:** OutdoorBoys had `download_cutoff_date = 2025-11-08` even though it was March 2026, causing yt-dlp to check 4+ months of videos (~493 videos) on every indexing run.

**Impact:**

- Extremely slow indexing (hours instead of minutes)
- Unnecessary YouTube API calls (risk of rate limiting)
- High CPU usage from yt-dlp processing old video metadata

**Observed timing:** With 40-second sleep intervals between requests, indexing 493 videos takes ~5.5 hours minimum.

**Suggested fixes:**

1. **Auto-advance cutoff date** - After successful indexing, update `download_cutoff_date` to a recent date (e.g., 7 days before the oldest video that was actually downloaded)
2. **Use relative cutoff** - Instead of absolute dates, allow setting "download videos from last N days"
3. **Add --break-on-existing consistently** - Ensure all indexing jobs use this flag to stop early when hitting known videos
4. **UI warning** - Show a warning if cutoff date is very old

**Manual fix:**

```sql
-- Update all sources to have cutoff date of 7 days ago
UPDATE sources SET download_cutoff_date = date('now', '-7 days')
WHERE download_cutoff_date < date('now', '-7 days');
```

## Issue 9: Full channel indexing ignores retention period 🔄 OPEN

**Problem:** When a source has a short `retention_period_days` (e.g., 5-7 days), Pinchflat still performs a full channel index, scanning through potentially thousands of videos dating back to the original `download_cutoff_date`. This is extremely wasteful when only the most recent videos will ever be kept.

**Example scenario:**

- Source has `retention_period_days = 5`
- Source has `download_cutoff_date = 2025-11-08` (4+ months ago)
- yt-dlp scans through 500+ videos with 35-40 second sleep intervals
- Total indexing time: 5+ hours
- Only videos from the last ~8 days would ever be downloaded/retained

**The math:**

- With `--sleep-requests 40 --sleep-interval 35`, each video check takes ~35-40 seconds
- 500 videos × 35 seconds = ~4.8 hours minimum
- 99% of this work is wasted checking videos that will never be downloaded

**Expected behavior:** Indexing should be bounded by the retention period, not the cutoff date. If retention is 5 days, there's no point scanning videos older than `retention_period_days + buffer` (e.g., 5 + 3 = 8 days).

**Suggested fix:**

1. **Calculate effective scan window** - When starting an index, compute:

   ```
   effective_cutoff = max(download_cutoff_date, now - retention_period_days - buffer_days)
   ```

   where `buffer_days` accounts for upload delays and timezone differences (e.g., 3 days)

2. **Pass date filter to yt-dlp** - Use `--dateafter` flag to skip old videos entirely:

   ```bash
   yt-dlp --dateafter $(date -d '-8 days' +%Y%m%d) ...
   ```

3. **Use --break-on-existing more aggressively** - Stop indexing as soon as we hit a video we've already processed, since older videos won't be downloaded anyway

4. **Add UI indicator** - Show estimated scan time based on channel size and effective date range

**Impact of fix:**

- Indexing time reduced from hours to minutes
- Reduced YouTube API load (less rate limiting risk)
- Lower CPU/memory usage
- Faster queue throughput (more sources indexed per hour)

**Related to:** Issue 8 (old download_cutoff_date), but this is about using retention_period as an additional bound, not just updating the cutoff date.

## Issue 10: No visibility into active tasks or yt-dlp output in frontend 🔄 OPEN

**Problem:** The frontend provides no way to see what Pinchflat is currently doing. The "Active Tasks" tab (`/#tab-active-tasks`) is often empty even when yt-dlp processes are actively running. Users must SSH into the server and run `ps aux | grep yt-dlp` or query the database directly to understand system state.

**Current situation:**

- No live view of running yt-dlp processes
- No output logs from yt-dlp commands
- No visibility into Oban job queue state
- SlowIndexing jobs don't appear in Active Tasks (see Issue 7)
- Users have no idea if indexing is stuck, progressing, or completed

**What users have to do today:**

```bash
# Check if anything is running
docker exec pinchflat ps aux | grep yt-dlp

# Check job queue state
sqlite3 pinchflat.db "SELECT state, worker, COUNT(*) FROM oban_jobs GROUP BY state, worker"

# Check which sources are being indexed
sqlite3 pinchflat.db "SELECT id, args, attempt FROM oban_jobs WHERE state = 'executing'"
```

**Suggested improvements:**

1. **Active Tasks panel** - Show all currently running operations:
   - Source being indexed (with channel name, not just ID)
   - Number of videos scanned / estimated total
   - Time elapsed and estimated time remaining
   - Current yt-dlp command being executed

2. **Job Queue view** - Display Oban queue status:
   - Jobs by state (available, executing, scheduled, completed, failed)
   - Ability to cancel stuck jobs from UI
   - Retry failed jobs with one click
   - View job error messages

3. **Recent Activity log** - Scrollable log of recent operations:
   - Last N indexing completions with duration
   - Last N downloads with file sizes
   - Last N errors with stack traces
   - Filterable by source/worker type

4. **yt-dlp output streaming** - Real-time output from yt-dlp:
   - Show current video being processed
   - Display any warnings or errors
   - Progress bar for downloads
   - Rate limit warnings from YouTube

5. **System health indicators**:
   - Database size and WAL status
   - Queue depth and processing rate
   - Last successful index per source
   - Sources with stale `last_indexed_at`

**Implementation notes:**

- Could use Phoenix LiveView for real-time updates
- yt-dlp output could be captured and streamed via WebSocket
- Oban provides telemetry events that could feed the UI
- Consider a `/api/status` endpoint for programmatic access

**Impact:**

- Users can see what's happening without SSH access
- Easier debugging of stuck/slow operations
- Better understanding of system health
- Reduced support burden (users can self-diagnose)
