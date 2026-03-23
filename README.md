# PinchYT

> [!IMPORTANT]
> Personal Fork Disclaimer: This fork is maintained for personal use and to continue development while the upstream project remains the canonical source.

PinchYT is a fork of Pinchflat.

For installation, configuration, and the base feature set, use the actual upstream Pinchflat docs:

- Upstream project: <https://github.com/kieraneglin/pinchflat>
- Upstream README: <https://github.com/kieraneglin/pinchflat/blob/master/README.md>
- Upstream wiki: <https://github.com/kieraneglin/pinchflat/wiki>

## What PinchYT Adds

- Single video sources and downloads. Upstream Pinchflat focused on channels and playlists; this fork also accepts individual YouTube video URLs as sources.
- Cookie file management in the UI. You can upload, paste, and inspect the shared `cookies.txt` file directly from the source form.
- Collapsible desktop sidebar for a cleaner PC layout.
- Uses `yt-dlp nightly` builds so download fixes can land faster when YouTube changes.
- A few quality-of-life UI and maintenance changes on top of upstream.

For local development in this repo, use Docker:

```bash
docker compose run --rm phx mix test
docker compose run --rm phx mix check
docker compose up
```
