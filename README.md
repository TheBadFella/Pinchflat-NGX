<p align="center">
  <img src="docs/assets/logo.svg" alt="Pinchflat-ngx logo" width="460">
</p>

<p align="center">
  <a href="https://github.com/TheBadFella/pinchflat-ngx/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/TheBadFella/pinchflat-ngx?style=for-the-badge&color=D0BCFF&labelColor=211F26"></a>
  <a href="https://github.com/TheBadFella/pinchflat-ngx/actions/workflows/lint_and_test.yml"><img alt="Build status" src="https://img.shields.io/github/actions/workflow/status/TheBadFella/pinchflat-ngx/lint_and_test.yml?style=for-the-badge&label=checks&labelColor=211F26"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-AGPL--3.0-EFB8C8?style=for-the-badge&labelColor=211F26"></a>
  <img alt="Platforms" src="https://img.shields.io/badge/linux-amd64%20%7C%20arm64-CCC2DC?style=for-the-badge&labelColor=211F26">
</p>

<p align="center">
  An enhanced, self-hosted YouTube media manager built on Pinchflat.<br>
  Engineered with a Material 3 AMOLED interface, SQLite &amp; PostgreSQL 18 support,<br>
  OIDC single sign-on, and local disk staging for seamless network storage downloads.
</p>

<p align="center">
  <img src="docs/assets/screenshot.png" alt="Pinchflat-ngx web interface" width="100%">
</p>

<p align="center">
  <a href="#what-pinchflat-ngx-adds"><strong>Overview</strong></a> &bull;
  <a href="#why-pinchflat-ngx"><strong>Comparison</strong></a> &bull;
  <a href="#screenshots"><strong>Screenshots</strong></a> &bull;
  <a href="#get-started"><strong>Get Started</strong></a> &bull;
  <a href="#postgresql-image"><strong>PostgreSQL</strong></a> &bull;
  <a href="#optional-local-download-staging"><strong>NAS Staging</strong></a> &bull;
  <a href="#single-sign-on"><strong>OIDC SSO</strong></a> &bull;
  <a href="#documentation"><strong>Documentation</strong></a>
</p>

---

## What Pinchflat-ngx adds

### Why Pinchflat-ngx?

| Feature                  | Upstream Pinchflat         | Pinchflat-ngx                                          |
| :----------------------- | :------------------------- | :----------------------------------------------------- |
| **Database**             | SQLite only                | SQLite & PostgreSQL 18                                 |
| **User Interface**       | Legacy theme               | Material 3 AMOLED Dark Mode                            |
| **Authentication**       | HTTP Basic Auth only       | Basic Auth + OAuth2 / OIDC (Authentik, Authelia, etc.) |
| **Download Pipeline**    | Direct write only          | Local Disk Staging (NAS / NFS-friendly)                |
| **YouTube Reliability**  | Stock yt-dlp               | PO-token Provider (bgutil) integration                 |
| **Queue Operations**     | Basic worker pool          | Live Diagnostics, Granular Worker Tuning               |
| **Single Video Sources** | No (Channel/Playlist only) | Yes (One-off direct video downloads)                   |

<table>
  <tr>
    <td width="33%" valign="top">
      <h3>📚 Sources</h3>
      More ways to add media, decide what downloads, and control where files land.
    </td>
    <td width="33%" valign="top">
      <h3>✨ Interface</h3>
      A focused Material 3 AMOLED experience across desktop and mobile.
    </td>
    <td width="33%" valign="top">
      <h3>⬇️ Downloads</h3>
      Better visibility, safer retries, and settings for real-world YouTube access.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h3>🛠️ Operations</h3>
      Queue controls, diagnostics, structured logs, and adjustable workers.
    </td>
    <td width="33%" valign="top">
      <h3>🔐 Access</h3>
      Optional OAuth2/OpenID Connect login without breaking podcast clients.
    </td>
    <td width="33%" valign="top">
      <h3>📦 Delivery</h3>
      Versioned, multi-platform container images published through GHCR.
    </td>
  </tr>
</table>

### Sources

- **Single video sources:** Add one-off YouTube video URLs directly instead of treating everything as a channel or
  playlist.
- **Selective playlist downloads:** Index a playlist, review its items, and choose exactly what to fetch from the
  Selection flow.
- **Stronger source controls:** See automatic and delayed sources at a glance, with inline and menu actions to start,
  pause, or stop them.
- **Faster source actions:** Jump to a source from notifications and delete sources directly from their management views.
- **Per-source folder routing:** Send each source to its own folder with a picker for existing directories and
  template-aware output paths.

### Interface

- **Material 3 AMOLED theme:** Dark, consistent surfaces with shared semantic colors, spacing, controls, and hierarchy.
- **Native Tailwind v4 pipeline:** Theme tokens and the native Tailwind v4 asset pipeline keep the interface consistent
  and maintainable.
- **Cleaner forms:** Refined toggles, custom selects, clearer editing states, and better guidance when creating sources
  and profiles.
- **Collapsible sidebar:** Collapse desktop navigation when you want a denser workspace.
- **Mobile polish:** Source, job, history, profile, and settings views adapt cleanly to smaller screens.
- **Settings search:** Filter Settings to find notifications, extractor options, cookies, and yt-dlp controls quickly.
- **Interface gallery:** Explore the [Screenshots](#screenshots) gallery below for full captures of the interface.

### Downloads

- **Cookie management:** Upload, paste, and inspect the shared `cookies.txt` file from Settings.
- **YouTube API-key testing:** Validate a key before relying on it for indexing.
- **Unavailable-media handling:** Skip and label members-only, private, or removed videos instead of retrying forever.
- **Clear media states:** The Other tab distinguishes Unavailable, Removed, Ignored, and Filtered Out items.
- **Live speed visibility:** See current download speed in the jobs dashboard and media tables.
- **Safer retries:** Retry flows clear stale errors and keep job and media state aligned.
- **Controlled yt-dlp updates:** Choose stable, nightly, frozen nightly, nightly-until-stable, or a pinned version.
- **yt-dlp base configuration:** Maintain additional yt-dlp options in Settings using familiar config-file syntax.
- **Failed-download workflow:** Review failed items on Home and retry one or many from history and source tables.
- **Cookie-aware forced retries:** Forced retries continue to apply cookies when livestream prechecks are skipped.

### Operations

- **Queue diagnostics:** Inspect running, retryable, and discarded Oban jobs; reset or cancel individual jobs; and clear
  discarded queues.
- **Worker concurrency:** Set separate limits for downloads, indexing, and metadata in Settings. Environment variables
  can override those saved values.
- **Release status:** See whether Pinchflat-ngx is current and which yt-dlp update policy is active.
- **Operational diagnostics:** Use structured source, indexing, enqueue, and skipped-download logs alongside responsive
  integrity and maintenance tools.
- **Repository-friendly Compose layout:** Development Compose files live in `docker/`, while the root `compose.yaml`
  keeps `docker compose up` working for contributors.
- **Current FFmpeg builds:** Images install FFmpeg from
  [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds) `latest`.
- **Ongoing fork improvements:** Smaller workflow, interface, and reliability changes continue to land as they prove
  useful in daily self-hosted use.

### Single sign-on

Pinchflat-ngx can protect the web interface with OAuth2/OpenID Connect. It supports provider discovery, PKCE, state and nonce
validation, configurable scopes, and fixed callback URLs for reverse-proxy deployments.

OIDC replaces Basic Auth for browser routes when enabled. Feed endpoints retain Basic Auth and route-token support for
podcast clients; API endpoints and `/healthcheck` remain unauthenticated by design.

**[Set up OIDC &rarr;](https://github.com/TheBadFella/pinchflat-ngx/wiki/OIDC-Single-Sign-On)**

---

## Screenshots

Explore captures of the Material 3 AMOLED interface across key views:

|                           [Poster Grid](docs/assets/screenshots/sources-grid.png)                            |                        [Source Details](docs/assets/screenshots/source-details.png)                         |
| :----------------------------------------------------------------------------------------------------------: | :---------------------------------------------------------------------------------------------------------: |
| [![Sources Poster Grid](docs/assets/screenshots/sources-grid.png)](docs/assets/screenshots/sources-grid.png) | [![Source Details](docs/assets/screenshots/source-details.png)](docs/assets/screenshots/source-details.png) |

|                        [Sources Table](docs/assets/screenshots/sources-table.png)                        |                       [System Diagnostics](docs/assets/screenshots/diagnostics.png)                       |
| :------------------------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------------------------------------: |
| [![Sources Table](docs/assets/screenshots/sources-table.png)](docs/assets/screenshots/sources-table.png) | [![System Diagnostics](docs/assets/screenshots/diagnostics.png)](docs/assets/screenshots/diagnostics.png) |

|                 [Dashboard & History](docs/assets/screenshots/dashboard.png)                 |                          [Channel Discovery](docs/assets/screenshots/channel-discovery.png)                          |
| :------------------------------------------------------------------------------------------: | :------------------------------------------------------------------------------------------------------------------: |
| [![Dashboard](docs/assets/screenshots/dashboard.png)](docs/assets/screenshots/dashboard.png) | [![Channel Discovery](docs/assets/screenshots/channel-discovery.png)](docs/assets/screenshots/channel-discovery.png) |

---

## Get started

| 1 &middot; Deploy                                                                               | 2 &middot; Configure                                                                                | 3 &middot; Build your library                                                  |
| :---------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------- |
| Run the multi-platform image from GHCR.                                                         | Set your timezone and choose Basic Auth or OIDC.                                                    | Create a media profile, then add a channel, playlist, or video.                |
| **[Installation guide &rarr;](https://github.com/TheBadFella/pinchflat-ngx/wiki/Installation)** | **[Configuration &rarr;](https://github.com/TheBadFella/pinchflat-ngx/wiki/Environment-Variables)** | **[Pinchflat concepts &rarr;](https://github.com/kieraneglin/pinchflat/wiki)** |

```yaml
services:
  pinchflat-ngx:
    image: ghcr.io/thebadfella/pinchflat-ngx:latest
    environment:
      TZ: America/Regina
    ports:
      - '8945:8945'
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    restart: unless-stopped
```

Save this as `compose.yaml`, replace the timezone if needed, and run `docker compose up -d`. Open
<http://localhost:8945> when the container is healthy.

### PostgreSQL image

The `latest` image continues to use SQLite. To start a new installation with PostgreSQL, use the
`latest-postgres` image and set `DATABASE_URL`:

```yaml
services:
  pinchflat-ngx:
    image: ghcr.io/thebadfella/pinchflat-ngx:latest-postgres
    environment:
      DATABASE_ADAPTER: postgres
      DATABASE_URL: ecto://pinchflat-ngx:change-me@postgres/pinchflat-ngx
      TZ: America/Regina
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - '8945:8945'
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    restart: unless-stopped

  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_DB: pinchflat-ngx
      POSTGRES_PASSWORD: change-me
      POSTGRES_USER: pinchflat-ngx
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U pinchflat-ngx -d pinchflat-ngx']
      interval: 5s
      timeout: 5s
      retries: 10
    volumes:
      - postgres-data:/var/lib/postgresql
    restart: unless-stopped

volumes:
  postgres-data:
```

The PostgreSQL image creates and migrates its own schema, but it does not copy data from an existing SQLite database.
This PostgreSQL 18 example is intended for a fresh installation. PostgreSQL 16 or earlier volumes are not
compatible with the PostgreSQL 18 server as-is; use an explicit PostgreSQL upgrade or `pg_dump`/`pg_restore`
procedure before reusing existing PostgreSQL data. Keep using `latest` for an existing SQLite installation until
you have migrated its data separately.

> [!TIP]
> The PostgreSQL image supports in-app `pg_dump` backups and retention policies via **Settings > PostgreSQL Backups**. See the [Backups and restore guide](https://github.com/TheBadFella/pinchflat-ngx/wiki/Backups-and-Restore) for backup operations and restore commands.

### Optional PO-token provider

The default compose above keeps the provider disabled. If YouTube presents SABR or authentication problems, add the
following service and environment variable to your compose file:

```yaml
services:
  pinchflat-ngx:
    environment:
      TZ: America/Regina
      POT_PROVIDER_URL: http://pot-provider:4416

  pot-provider:
    image: brainicism/bgutil-ytdlp-pot-provider:2.0.0
    profiles: [pot-provider]
    restart: unless-stopped
    # No ports mapping: the unauthenticated provider stays on the Compose network.
```

Start the opt-in service with `docker compose --profile pot-provider up -d`. Pinchflat-ngx images include the matching bgutil
yt-dlp plugin, and Diagnostics reports the provider's bounded `/ping` health check. See the
[official bgutil provider documentation](https://github.com/Brainicism/bgutil-ytdlp-pot-provider) and
[yt-dlp's PO-token guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide) for background and limitations.

### Optional local download staging

Set `DOWNLOAD_STAGING_PATH` to an absolute path inside the container when downloads should complete on a local disk
before their finished artifacts are transferred to `/downloads`. The default is disabled, so existing deployments keep
their current direct-to-library behavior. Each download receives its own directory, and the database is updated only
after the complete artifact set reaches the media root.

For a local staging disk, add a bind mount such as:

```yaml
services:
  pinchflat-ngx:
    environment:
      DOWNLOAD_STAGING_PATH: /staging
    volumes:
      - ./download-staging:/staging
```

For a NAS library with local temporary storage, mount the local staging disk separately from the NAS destination:

```yaml
services:
  pinchflat-ngx:
    environment:
      DOWNLOAD_STAGING_PATH: /staging
    volumes:
      - /fast-local-disk/pinchflat-ngx-staging:/staging
      - /mnt/nas/media:/downloads
```

Staging and the media directory may be on different filesystems. Pinchflat-ngx uses a temporary destination name and an
atomic rename after copying in that case. Staging paths must be absolute, writable, and different from the media root.

---

## Documentation

| Start here                                                                                       | Run it safely                                                                                      | Understand the fork                                                                                |
| :----------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------- |
| [Installation](https://github.com/TheBadFella/pinchflat-ngx/wiki/Installation)                   | [Backups and restore](https://github.com/TheBadFella/pinchflat-ngx/wiki/Backups-and-Restore)       | [Pinchflat-ngx features](https://github.com/TheBadFella/pinchflat-ngx/wiki/Pinchflat-ngx-Features) |
| [Environment variables](https://github.com/TheBadFella/pinchflat-ngx/wiki/Environment-Variables) | [Upgrading and rollback](https://github.com/TheBadFella/pinchflat-ngx/wiki/Upgrading-and-Rollback) | [Upstream Pinchflat wiki](https://github.com/kieraneglin/pinchflat/wiki)                           |
| [OIDC single sign-on](https://github.com/TheBadFella/pinchflat-ngx/wiki/OIDC-Single-Sign-On)     | [Diagnostics](https://github.com/TheBadFella/pinchflat-ngx/wiki/Diagnostics)                       | API documentation at `/api/docs` on your instance                                                  |

The Pinchflat-ngx wiki documents behavior added or changed by this fork. Shared concepts such as naming templates, media
profiles, podcast feeds, SponsorBlock, retention, and custom scripts remain documented by upstream.

---

## Support and development

- [Report a bug](https://github.com/TheBadFella/pinchflat-ngx/issues/new?template=bug_report.md)
- [Request a feature](https://github.com/TheBadFella/pinchflat-ngx/issues/new?template=feature_request.md)
- [Browse releases](https://github.com/TheBadFella/pinchflat-ngx/releases)
- Read [AGENTS.md](AGENTS.md) for development commands and repository conventions

Pinchflat-ngx is distributed under the terms in [LICENSE](LICENSE).
