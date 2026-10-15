# Roadmap

GitHub issues are still the place to open requests. This page lists work **not** included in **[Release 2026.10.15](releases/2026.10.15.md)**.

Each item is a short title and two lines of context.

---

## Planned (deferred)

Larger or dependency-heavy work stays here until we open a dedicated feature PR. Issues stay open where they exist.

### Global “Latest” tab ([#99](https://github.com/TheBadFella/Pinchflat-NGX/issues/99))

One Home (or top-level) view of recently **indexed** media across all sources, newest first, so you do not open each source to see what is new.
Reuses existing history-table patterns where possible; default sort by indexed time (`inserted_at`).

### In-app YouTube browser

Browse and search YouTube inside Pinchflat-ngx with library-aware status, guarded downloads, and bounded provider use.
Large surface area (routes, LiveView, workers, packaging); not part of the 2026.10.15 tag.

### Paste-a-link quick download

Add a video from a pasted YouTube URL with strict parsing and preview before intake.
Depends on the in-app browser stack and shared intake policy.

### Subscription import from CSV

Import YouTube subscriptions from a Takeout-style CSV with preview, deduplication, and a durable background importer.
Bounded parsing and cancel/retry behavior; deferred past 2026.10.15.

### Share links and bookmarklet

Authenticated share tokens and a bookmarklet for sending URLs into your library from another browser tab.
Scoped tokens, rate limits, and preview-only flows; separate from core migration work.

### Media server library refresh

Optional Plex, Jellyfin, or Emby refresh after downloads complete, with coalesced jobs and safe server configuration.
Does not replace your media server; only nudges it when new files land.

### Proxy, sharing, and browser hardening

Trusted-proxy options, cookie/session hardening, token expiry, and clearer browser search feedback.
Follows share intake and media-server refresh in the original merge order.

### Channel event notifications (WebSub)

Optional upload/title/removal notifications per channel via a bounded WebSub sidecar and settings UI.
Default off; live YouTube webhook trials are not part of the initial ship criteria.

### Expanded SQLite → PostgreSQL transfer tables

Broader table coverage and sequence preservation when moving an existing NGX library from SQLite to PostgreSQL beyond the first-cut transfer.
Additive to **#87**; pairs with channel-event schema only if that feature is enabled later.

### Dynamic announcements banner

Optional fetched announcement feed, dismissible banner, and `/announcements` page with safe HTTPS fetching and local cache.
Requires choosing a production feed endpoint before default-on behavior makes sense.

---

## Shipped in 2026.10.15

See [Release 2026.10.15](releases/2026.10.15.md) for the full list: migration (**#86**, **#87**, **#85**, **#109**, **#107**), infra (**#105–#109**, **#96**, **#102**), interface polish (selects, branding, long names, small-screen Sources, toggles), source diagnostics, safer media streaming, download space protection, client fallback chains, and cookie health warnings.
