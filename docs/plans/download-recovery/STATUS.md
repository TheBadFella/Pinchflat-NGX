# Packaged download recovery verification

Base: `75593d3`, after PR #137. Branch: `fix/preserve-media-on-replacement`.

## Defect and change

Real yt-dlp removes an existing final file when `--force-overwrites` starts. With optional staging disabled, a forced replacement or quality upgrade could therefore make the original unplayable before the new transfer finished. The packaged SQLite and PostgreSQL checks both reproduced a streaming 404 during replacement.

Replacements of an existing regular media file now use the existing download-staging implementation. A configured staging root takes priority; otherwise the app uses `.pinchflat-replacements` under its media directory. The completed download is transferred before its final path is persisted. The original remains available while the external download runs or fails. Initial downloads retain their existing behavior.

This requires room for the replacement alongside the existing file. Staging errors leave the original intact. The existing cleanup policy also applies to the fallback root: old inactive attempt directories are removed at startup after one day, while active media IDs are preserved.

## Runtime evidence

Release images were built with `docker/selfhosted.Dockerfile`, separately for SQLite and PostgreSQL. Four isolated services used new configuration/media volumes and localhost ports 45970 through 45973. No production paths or accounts were used.

- Fresh setup through the UI, single-video source creation, real YouTube indexing/download, browser playback, Range/HEAD requests and restart persistence passed on both adapters.
- Real forced replacements were throttled to 10 KiB/s. After partial files appeared, duplicate requests were rejected, the existing stream remained readable, and the container was killed with SIGKILL and recreated. The same job recovered on attempt two on both adapters.
- The PostgreSQL replacement retained the same SHA256. SQLite selected YouTube format 18 rather than 133+140, so byte equality across downloads was not expected. Its final streamed bytes matched disk, ffprobe reported valid H.264/AAC and a roughly 19-second duration, and browser playback passed. The earlier overly strict hash assertion remains in the evidence.
- Separate controlled-process instances exercised network and storage error text, guidance in both views, retry, playback, failed-replacement preservation, duplicate prevention, hard-kill recovery and restart persistence on both adapters. These use a synthetic external downloader and do not prove real network outages or a physically full filesystem.
- In all four services, only owned inactive attempt directories were aged to 25 hours for the cleanup check. Restart removed those directories without changing completed media hashes. This simulates elapsed time; it is not a 25-hour soak test.

## Automated evidence

The replacement regression failed twice before the code change because the simulated yt-dlp overwrite removed the original. Focused downloader, staging, worker and startup checks passed after the fix. A cleanup regression also checks active-attempt preservation and refusal to delete outside the selected root.

The full Docker check results and later publication evidence are retained in `D:/Git/PinchYT-recovery-validation`. Early failures included a fixture using an unsanitized random ID, an existing worker mock that returned an artifact outside staging, and a test image without PostgreSQL 18 backup tools. The fixtures and isolated test image were corrected without weakening the application checks. Final adapter results are recorded in the PR.

The original checkout is preserved. The test work does not publish a release, container image or production deployment. Physical devices, accounts/cookies, long-running subscriptions and true filesystem exhaustion remain outside this verification.
