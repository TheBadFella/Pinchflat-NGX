# Download Performance Investigation

This document tracks the current working theory for why Pinchflat can feel slower than MeTube during playlist-heavy runs, and what remains to be measured in a live environment.

## Current Pinchflat Findings

### Queue model

Pinchflat splits yt-dlp-related work across separate Oban queues in [runtime.exs](/D:/Git/PinchYT/config/runtime.exs):

- `media_fetching`
- `fast_indexing`
- `media_collection_indexing`
- `remote_metadata`

Those queue counts come from:

- `YT_DLP_WORKER_CONCURRENCY`
- `YT_DLP_DOWNLOAD_WORKER_CONCURRENCY`
- `YT_DLP_INDEX_WORKER_CONCURRENCY`
- `YT_DLP_REMOTE_METADATA_WORKER_CONCURRENCY`

If the split values are unset, they fall back to the shared worker count. In preview, the split env vars appeared unset, so the likely effective default there is `5/5/5`.

### Rate limiting and sleep

Pinchflat adds rate and sleep options in [command_runner.ex](/D:/Git/PinchYT/lib/pinchflat/yt_dlp/command_runner.ex):

- `download_throughput_limit` maps to yt-dlp `limit_rate`
- `extractor_sleep_interval_seconds` maps to yt-dlp sleep settings

Schema defaults in [setting.ex](/D:/Git/PinchYT/lib/pinchflat/settings/setting.ex) are:

- `download_throughput_limit = nil`
- `extractor_sleep_interval_seconds = 0`

So unless the deployment settings were changed, Pinchflat is not rate-limiting or adding extractor sleep by default.

### Download start path

Pinchflat may do extra work before the actual transfer begins.

In [media_downloader.ex](/D:/Git/PinchYT/lib/pinchflat/downloading/media_downloader.ex), normal downloads go through:

1. `get_downloadable_status`
2. optional cookie retry logic
3. only then the final yt-dlp download

The progress UI even reflects this with `Prechecking media` before `Waiting for transfer to start`.

In [media_download_worker.ex](/D:/Git/PinchYT/lib/pinchflat/downloading/media_download_worker.ex), that precheck now gets skipped for all non-livestream items. Livestreams still keep the precheck so active or not-yet-ready streams do not immediately fall into the full download path.

This reduces one yt-dlp round trip for the common case and is the first direct throughput optimization in this investigation.

### Post-index enqueue behavior

Pinchflat already opportunistically enqueues downloads item-by-item during slow indexing, but it still performs a broad pending-media sweep after indexing completes in [slow_indexing_helpers.ex](/D:/Git/PinchYT/lib/pinchflat/slow_indexing/slow_indexing_helpers.ex) via [downloading_helpers.ex](/D:/Git/PinchYT/lib/pinchflat/downloading/downloading_helpers.ex).

That broad sweep is useful for correctness, but on large sources it is still extra coordination work that MeTube largely avoids.

#### Decision on narrowing the broad sweep

At the moment, it is not safe to remove or narrowly scope that sweep without adding a more targeted reconciliation mechanism.

Reasons:

- slow indexing uses a file follower and explicitly tolerates partially written lines and missed records during the streaming phase
- downloads may fail to enqueue during the per-item path
- source state may change during long indexing runs, so the code reloads source state repeatedly before deciding what to enqueue
- manual-selection mode and `prevent_download` behavior still rely on a final authoritative pass over "what is pending now"

So the current decision is:

- keep the broad post-index enqueue pass for correctness
- treat it as a known throughput tradeoff
- revisit only if a targeted "enqueue newly created ids plus recovery for known failures" path is introduced

### Cookie and metadata round trips

Pinchflat does add some extra app-level network work outside the core media transfer:

- source metadata is fetched in a separate worker via two calls in [source_metadata_storage_worker.ex](/D:/Git/PinchYT/lib/pinchflat/metadata/source_metadata_storage_worker.ex):
  - one call to determine the series directory from source details
  - one call to fetch source metadata and images
- media thumbnails for internal storage are fetched in a separate yt-dlp thumbnail call in [metadata_file_helpers.ex](/D:/Git/PinchYT/lib/pinchflat/metadata/metadata_file_helpers.ex)
- `cookie_behaviour: :when_needed` uses cookies for indexing and error recovery, but not for normal downloading or metadata in [sources.ex](/D:/Git/PinchYT/lib/pinchflat/sources/sources.ex)

That means:

- cookie behavior is not the main cause of extra download-start latency in the common case
- metadata/image fetching does add extra round trips, but mostly in adjacent metadata paths rather than the core transfer path
- the biggest already-addressed per-download overhead was the separate precheck for non-livestream items

## MeTube Findings

Reference repo: [alexta69/metube](https://github.com/alexta69/metube)

From the MeTube README:

- it supports a simpler download scheduler with `sequential`, `concurrent`, and `limited` modes
- its default limited mode is controlled by `MAX_CONCURRENT_DOWNLOADS`
- `TEMP_DIR` is explicitly called out as a performance lever, with SSD or RAM-backed storage recommended

Source: [MeTube README](https://github.com/alexta69/metube)

### Likely performance differences

Compared to Pinchflat, MeTube appears to optimize for a more direct path from "queued item" to "start yt-dlp transfer":

- fewer source/media-state checks around each item
- a simpler concurrency model centered on download slots
- no equivalent Pinchflat-style precheck stage exposed before most downloads
- fewer app-level orchestration steps between indexing/queueing and transfer

### Cookies, archive, metadata flow, and ffmpeg defaults

Compared against Pinchflat:

- MeTube uses a single global `YTDL_OPTIONS` / `YTDL_OPTIONS_FILE` model for cookies and extra yt-dlp behavior, documented in the [MeTube README](https://github.com/alexta69/metube/blob/master/README.md). Pinchflat uses per-source cookie behavior and only applies cookies to some operations depending on mode.
- MeTube does not appear to have a Pinchflat-style indexing download archive mechanism. In Pinchflat, slow indexing uses `--break-on-existing` plus a generated download archive for channels in [slow_indexing_helpers.ex](/D:/Git/PinchYT/lib/pinchflat/slow_indexing/slow_indexing_helpers.ex). That is good for correctness/efficiency during channel indexing, but it is extra app-side logic MeTube does not seem to carry.
- MeTube does not have an equivalent source-metadata subsystem like Pinchflat's `SourceMetadataStorageWorker`; its main path is more tightly centered on the requested download itself.
- Pinchflat defaults to remuxing video downloads into `mp4` in [quality_option_builder.ex](/D:/Git/PinchYT/lib/pinchflat/downloading/quality_option_builder.ex). MeTube's formatting/postprocessing is driven more directly by selected format plus yt-dlp/postprocessor options in [dl_formats.py](https://raw.githubusercontent.com/alexta69/metube/master/app/dl_formats.py). From that code, audio extraction and thumbnail/embed postprocessors are added for audio flows, but there is no obvious app-level forced video remux equivalent in the default "any/mp4" path.

Inference:

- MeTube likely has fewer post-download transformations by default for many video downloads
- Pinchflat may spend more time in ffmpeg remux/postprocessing depending on the selected profile
- MeTube's simpler global cookie model also removes some app-level decision overhead, though that is probably a smaller factor than prechecks and queue orchestration

This does not automatically mean raw network throughput is higher. It more likely means MeTube reaches sustained transfer sooner and spends less time in app-side setup per item.

## Current Working Theory

The most likely reasons MeTube feels faster are:

1. lower time-to-first-byte because it starts downloads more directly
2. less pre-transfer overhead from prechecks and state orchestration
3. a simpler concurrency model focused on download execution
4. explicit operator guidance around temporary storage placement

The most likely Pinchflat-side contributors are:

1. `get_downloadable_status` precheck latency
2. post-index pending-download sweeps for large sources
3. queue contention between indexing, metadata, and downloading if deployment tuning is not set well

## Safe Next Steps

- capture the real runtime values for concurrency and settings in the target deployment
- measure how long items spend in `Prechecking media` before transfer begins
- verify whether the deployment is using slow temp storage for yt-dlp intermediates
- compare production behavior after the widened non-livestream precheck skip
- review whether the broad post-index pending sweep can be narrowed further for large sources

## Not Yet Confirmed

The following still need direct verification before changing behavior:

- actual live values for throughput and sleep settings in production
- whether remote throttling or cookies are the main source-specific factor
- MeTube's exact cookie, archive, and metadata-fetch flow compared to Pinchflat
- whether ffmpeg/post-processing defaults materially differ for the formats being compared
