# PinchYT

> [!IMPORTANT]
> Personal Fork Disclaimer: This fork is maintained for personal use and to continue development while the upstream project remains the canonical source.

> [!NOTE]
> PinchYT keeps the core Pinchflat model, then layers on a more Material-style interface, stronger source controls, and a few workflow improvements for day-to-day downloading.

For installation, configuration, and the base feature set, use the actual upstream Pinchflat docs:

- Upstream project: <https://github.com/kieraneglin/pinchflat>
- Upstream README: <https://github.com/kieraneglin/pinchflat/blob/master/README.md>
- Upstream wiki: <https://github.com/kieraneglin/pinchflat/wiki>

## What PinchYT Adds over Pinchflat (As a Fork)

### Sources

- **Single Video Sources:** Add one-off YouTube video URLs directly as sources, not just channels and playlists.
- **Selective Playlist Downloads:** Delay playlist downloads, review indexed items, and choose exactly what to fetch from the Selection flow.
- **Stronger Source Controls:** Manage sources faster with clearer automatic vs delayed indicators plus inline and dropdown start, pause, and stop actions.
- **Faster Source Actions:** New inline notification links and direct source delete controls make routine source management quicker.
- **Per-Source Folder Routing:** Send each source into its own folder with a picker for existing folders and template-aware output routing.

### Interface

- **Material 3 AMOLED Theme:** A darker, more opinionated visual layer with Material-inspired spacing, surfaces, controls, and hierarchy.
- **Native Tailwind v4 Pipeline:** Shared theme tokens and the native Tailwind v4 asset pipeline make the refreshed UI more consistent and maintainable.
- **Cleaner Form UX:** Better toggles, custom selects, clearer source/profile editing states, and improved source creation guidance.
- **Collapsible Sidebar:** Desktop navigation can collapse for a denser, more focused layout.
- **Broader Mobile Polish:** Source, job, and history views have improved responsive layouts for smaller screens.
- **Settings Search:** Filter the Settings page to jump to notifications, extractor, cookies, and yt-dlp options faster.

### Downloads

- **Cookie Management UI:** Upload, paste, and inspect the shared `cookies.txt` file directly from the app.
- **YouTube API Key Testing:** Validate your API key from the settings page before relying on it for indexing.
- **Ignore Unavailable Media:** Automatically skip and mark members-only, private, or removed videos instead of endlessly retrying them.
- **Media Status Clarity:** The Other tab now shows distinct statuses — Unavailable, Removed, Ignored, or Filtered Out — so you always know why an item isn't downloading.
- **Download Speed Visibility:** See live download speed in the jobs dashboard and media tables.
- **Smarter Retry Behavior:** Retry flows clear stale errors properly and keep task state more accurate.
- **Control yt-dlp Updates:** Track stable, nightly, nightly-frozen, nightly-until-stable, or pinned versions instead of always auto-updating.
- **yt-dlp Base Config:** Edit extra yt-dlp options from Settings (the same flags you would put in a yt-dlp config file).
- **Failed Downloads Tab:** Review failed items on Home and retry one or all from history and source tables.
- **Cookie-Aware Retries:** Forced retries still apply cookies even when livestream prechecks are skipped.

### Operations

- **Queue Diagnostics Page:** Inspect running, retryable, and discarded Oban jobs, reset or cancel individual jobs, and clear discarded queues from a single page.
- **Worker Concurrency:** Cap yt-dlp download, index, and metadata workers from Settings. Compose `YT_DLP_*_WORKER_CONCURRENCY` env vars still override the UI when set.
- **Release Indicator:** The sidebar shows whether PinchYT is on the latest GitHub release and which yt-dlp update policy is selected.
- **Extra Diagnostics:** More structured logging around source creation, indexing, enqueueing, and skipped downloads. Integrity check and related tools wrap correctly on small screens.
- **Compose Layout:** Docker Compose files live in `docker/`. A root `compose.yaml` keeps `docker compose up` working from the repo root.
- **FFmpeg:** Container images install FFmpeg from [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds) `latest` (master builds, currently FFmpeg 9.x). That feed does not publish a separate `n9.0` tarball yet.
- **Ongoing Fork Tweaks:** Small workflow, UI, and reliability improvements that are useful in self-hosted daily use.
