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
- **Per-Source Folder Routing:** Send each source into its own folder with a picker for existing folders and template-aware output routing.

### Interface

- **Material 3 AMOLED Theme:** A darker, more opinionated visual layer with Material-inspired spacing, surfaces, controls, and hierarchy.
- **Cleaner Form UX:** Better toggles, custom selects, clearer source/profile editing states, and improved source creation guidance.
- **Collapsible Sidebar:** Desktop navigation can collapse for a denser, more focused layout.

### Downloads

- **Cookie Management UI:** Upload, paste, and inspect the shared `cookies.txt` file directly from the app.
- **Download Speed Visibility:** See live download speed in the jobs dashboard and media tables.
- **Smarter Retry Behavior:** Retry flows clear stale errors properly and keep task state more accurate.
- **Nightly yt-dlp Builds:** Track newer yt-dlp builds for faster compatibility with upstream extractor changes.

### Operations

- **Extra Diagnostics:** More structured logging around source creation, indexing, enqueueing, and skipped downloads.
- **Ongoing Fork Tweaks:** Small workflow, UI, and reliability improvements that are useful in self-hosted daily use.
