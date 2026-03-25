# PinchYT

> [!IMPORTANT]
> Personal Fork Disclaimer: This fork is maintained for personal use and to continue development while the upstream project remains the canonical source.

PinchYT is a fork of Pinchflat.

For installation, configuration, and the base feature set, use the actual upstream Pinchflat docs:

- Upstream project: <https://github.com/kieraneglin/pinchflat>
- Upstream README: <https://github.com/kieraneglin/pinchflat/blob/master/README.md>
- Upstream wiki: <https://github.com/kieraneglin/pinchflat/wiki>

## What PinchYT Adds

- **Single Video Support:** Individual YouTube video URLs can be used as sources (upstream focuses on channels/playlists).
- **Cookie Management:** Internal UI for uploading, pasting, and inspecting the shared `cookies.txt` file.
- **Collapsible Sidebar:** Optimized desktop layout with a collapsible sidebar for increased focus.
- **Material 3 AMOLED Theme:** Comprehensive theme pass featuring AMOLED-black and Material 3 design principles.
- **Enhanced Form Controls:** Custom single-select dropdowns and animated perimeter borders for a premium feel.
- **Selective Playlist Download:** Choose which items to download after indexing with the new Selection tab.
- **Download Speed:** Real-time download speed is now visible in both the job dashboard and media tables.
- **Smarter Retries:** Improved retry logic that clears stale errors and provides accurate task status updates.
- **Nightly yt-dlp Builds:** Automatically uses nightly builds to ensure immediate compatibility with YouTube changes.
- **Quality-of-Life Tweaks:** General UI improvements and maintenance fixes beyond the upstream implementation.

For local development in this repo, use Docker:

```bash
docker compose run --rm phx mix test
docker compose run --rm phx mix check
docker compose up
```
