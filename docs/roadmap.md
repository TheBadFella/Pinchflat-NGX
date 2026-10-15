# Roadmap

Use [GitHub issues](https://github.com/TheBadFella/Pinchflat-NGX/issues) for bugs and smaller requests. This page tracks larger features that are not in the current release train yet.

Shipped versions and release notes: [GitHub Releases](https://github.com/TheBadFella/Pinchflat-NGX/releases).

Tracking for the next planning window: [Roadmap 31Oct 2026](https://github.com/TheBadFella/Pinchflat-NGX/milestone/2) milestone.

## Upcoming Features

### Global Latest Tab ([#99](https://github.com/TheBadFella/Pinchflat-NGX/issues/99))

- Top-level view of recently **indexed** media across all sources, sorted newest first.
- Goal: stop opening every source just to see what is new.
- Likely reuse of existing history-table UI; default sort on indexed time (`inserted_at`), not download time alone.
- Targeted for the release after **2026.10.15** (see the issue for discussion on sort and filters).

### In-App YouTube Browser

- Search and browse YouTube inside Pinchflat-ngx with clear status for items already in your library.
- Guarded download actions and limits on provider/API use so browsing does not hammer yt-dlp or your network.
- Touches routes, LiveView, workers, and packaging; one of the larger UI efforts on the list.

### Paste-a-Link Quick Download

- Paste a YouTube URL, parse it strictly, preview title/channel/thumbnail, then add or download on confirm.
- Shares intake rules with the in-app browser work (duplicates, policy, errors).
- Depends on the browser stack above for a consistent “add from URL” path.

### Subscription Import From CSV

- Import subscriptions from a Google Takeout-style CSV.
- Preview rows, dedupe against existing sources, run import in the background with cancel and retry.
- Bounded parsing so a bad export cannot wedge the app.

### Share Links and Bookmarklet

- Scoped share tokens so you can send a URL into your library from another browser tab.
- Bookmarklet or share URL flow with rate limits and preview before anything is queued.
- Settings live outside the main settings form (same pattern as API access).

### Media Server Library Refresh

- Optional Plex, Jellyfin, or Emby library refresh after downloads finish.
- Coalesced jobs so ten new episodes do not fire ten separate scans.
- Server URL and credentials stay in settings; Pinchflat-ngx only nudges the server, it does not replace it.

### Proxy, Sharing, and Browser Hardening

- Trusted reverse-proxy options, tighter cookie/session handling, token expiry, clearer errors in browser search.
- Follows share intake and media-server refresh in the original feature order from the merge backlog.

### Channel Event Notifications (WebSub)

- Optional per-channel upload, title, and removal notifications via a bounded WebSub sidecar.
- Settings to enable channels individually; default off.
- Initial ship does not depend on live YouTube webhook experiments in production.

### Expanded SQLite to PostgreSQL Transfer Tables

- **Not** the migration shipped in **[#87](https://github.com/TheBadFella/Pinchflat-NGX/pull/87)** / **2026.10.15**. That release already copies the core library tables and resets PostgreSQL ID sequences for those tables.
- This item is follow-on work: extra tables, future schema (for example channel-event storage), and harder edge cases beyond the first-cut transfer.
- Additive only; pairs with WebSub or other features if their tables are added later.

### Dynamic Announcements Banner

- Optional fetched announcement feed, dismissible banner, and `/announcements` page.
- HTTPS fetch with a local cache; no phone-home until a production feed URL is chosen.
- Default off until maintainers pick a feed endpoint and retention rules.
