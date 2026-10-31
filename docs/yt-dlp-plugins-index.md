# yt-dlp plugin index for Pinchflat-ngx

A practical, opinionated list of community yt-dlp plugins for a self-hosted media
library. This is not an official yt-dlp list. Star counts are a rough popularity
signal from the GitHub `yt-dlp-plugins` topic on 2026-10-31; they do not guarantee
quality, maintenance, or compatibility with your yt-dlp version.

## How to install and use a plugin

1. Open **Settings → yt-dlp → Plugins**.
2. Upload a `.zip`, `.whl`, or `.egg`, or paste a direct archive URL. GitHub
   release assets work.
3. Open **Config** on the plugin row. The modal shows the package README and
   stores a per-plugin yt-dlp config file.
4. Postprocessor plugins usually need an explicit activation line in that config,
   for example `--use-postprocessor FixupMtime`. Extractor plugins load
   automatically.
5. Test on one source before enabling it everywhere. Plugins load for indexing
   and downloads.

Plugins are arbitrary Python code. Install only code you trust. Extractor
plugins take priority over built-in extractors and can break downloads.

### Dependency and platform limits

A zip-only install copies the plugin package. It does not install Python
dependencies from `requirements.txt` or `pyproject.toml`. The default image does
not include `pip` in the yt-dlp runtime and does not include `rsgain`, `mp3gain`,
`vorbisgain`, or `metaflac`. Plugins that import `requests`, `pyotp`,
`stashapp-tools`, `yt-dlp-danmaku`, or `nodriver` fail at import until those
packages are added to the image. Windows-only plugins cannot load in the Linux
container. The status table at the end records what was verified in the default
image.

## Tier 1: start here

### bgutil-ytdlp-pot-provider

- **Area:** PO tokens and YouTube bot checks.
- **Community signal:** ~885 stars, the most-used plugin in the topic.
- **What it does:** runs a provider service that generates proof-of-origin
  tokens. It can help with “Sign in to confirm you’re not a bot” responses.
- **Use in Pinchflat-ngx:** prefer the built-in `POT_PROVIDER_URL` support. The
  image bundles the matching plugin and adds the extractor argument for you.
  Do not install a second copy unless you are deliberately testing another
  version.
- **Manual config:** `--extractor-args "youtubepot-bgutilhttp:base_url=http://pot-provider:4416"`
  when the provider runs at a non-default address.
- **Verified:** the plugin registers `bgutil:http-2.0.2 (external)`; the script
  providers show as unavailable. Token generation requires a running provider.
- **Caution:** the provider server is unauthenticated. Keep it on the Compose
  network. A PO token does not guarantee access; cookies may still be required.

### yt-dlp-FixupMtime

- **Area:** library file timestamps.
- **Community signal:** ~35 stars.
- **What it does:** sets the modification time of downloaded files from a
  metadata field.
- **Activation:** `--use-postprocessor FixupMtime:mtime_key=upload_date`.
- **Tested:** loaded as a postprocessor in the Pinchflat-ngx dev instance.

### yt-dlp-dearrow

- **Area:** YouTube titles.
- **Community signal:** listed on the official yt-dlp plugin wiki.
- **What it does:** replaces the title with the first DeArrow community title
  when one exists. The original title remains available as
  `%(original_title)s`.
- **Activation:** `--use-postprocessor DeArrow:when=pre_process`.
- **Tested:** loaded as a postprocessor.

### yt-dlp-ReturnYoutubeDislike

- **Area:** YouTube metadata.
- **Community signal:** ~18 stars.
- **What it does:** adds the Return YouTube Dislike count to video metadata.
- **Activation:** `--use-postprocessor ReturnYoutubeDislike:when=pre_process`.
- **Caution:** the public API is rate-limited.
- **Tested:** loaded as a postprocessor.

### yt-dlp-replaygain

- **Area:** music libraries.
- **Community signal:** ~13 stars.
- **What it does:** applies track and album ReplayGain tags to audio. It uses
  `rsgain`, `mp3gain`, `vorbisgain`, or `metaflac`, in that order.
- **Activation:** `--use-postprocessor ReplayGain:when=after_move` for single
  tracks, or `--use-postprocessor ReplayGain:when=playlist` for albums.
- **Default image:** the plugin loads and the activation name is accepted, but
  none of the gain tools are installed. It will not apply tags until one is
  added to the container.

### srt_fix

- **Area:** subtitles.
- **Community signal:** ~98 stars.
- **What it does:** removes duplicate lines from YouTube auto-generated
  subtitles converted to SRT.
- **Activation:** `--use-postprocessor srt_fix`.
- **Tested:** loaded as a postprocessor. It does not embed subtitles.

## Tier 2: YouTube reliability and bot checks

These are higher risk than the postprocessors above because they change how
YouTube is extracted. Try one at a time.

### yt-dlp-YTAgeGateBypass

- **Area:** age-gated YouTube videos.
- **Community signal:** ~74 stars, listed on the official wiki.
- **What it does:** routes around YouTube age gates through a third-party proxy.
- **Activation:** loads automatically as an extractor override. You can disable
  the proxy with `--extractor-args youtube:no-video-proxy`.
- **Verified:** loaded as an extractor override (`AGB (YoutubeIE)`). A real
  age-gated download was not tested.
- **Caution:** it overrides the built-in YouTube extractor. If YouTube changes,
  this plugin can break normal downloads until it is updated or removed.

### yt-dlp-getpot-wpc

- **Area:** PO tokens.
- **Community signal:** ~77 stars.
- **What it does:** experimental PO token provider that uses a browser to mint
  tokens.
- **Use in Pinchflat-ngx:** not a good fit for a headless container unless you
  already run a browser that the plugin can drive. Prefer bgutil.
- **Default image:** installs, but import fails because `nodriver` is missing.
- **Caution:** experimental; check the repo before relying on it.

### yt-dlp-apple-webkit-jsi

- **Area:** YouTube N/Sig challenges.
- **Community signal:** ~161 stars.
- **What it does:** solves YouTube JavaScript challenges with Apple WebKit.
- **Requirement:** an Apple operating system (iOS/iPadOS or macOS).
- **Verified:** registered as `apple-webkit-jsi-0.1.1 (external, unavailable)` on
  Linux. It cannot solve challenges there.
- **Tested:** loaded; not functionally verified on Apple hardware.

### yt-dlp-remote-cipher

- **Area:** YouTube JavaScript challenges.
- **Community signal:** ~7 stars.
- **What it does:** delegates challenge solving to a separate `yt-cipher`
  server.
- **Use in Pinchflat-ngx:** requires running and maintaining that server. Use
  only if you already have one.
- **Verified:** registered `remotecipher-0.0.1 (external)` with a test base URL.
  A real cipher server was not available for an end-to-end test.
- **Caution:** low activity; test against your yt-dlp version.

## Tier 3: site-specific and niche

### yt-dlp-rajiko

- **Area:** radiko.jp (Japanese radio).
- **Community signal:** ~113 stars.
- **What it does:** improved radiko.jp extractor with area-free support.
- **Activation:** loads automatically for radiko URLs.
- **Verified:** loaded `RadikoLiveIE`, `RadikoPersonIE`, `RadikoPodcast*`,
  `RadikoSearchIE`, and related extractors. A real radiko download was not
  tested.
- **Use when:** you archive Japanese radio.

### yt-dlp-hianime

- **Area:** HiAnime.
- **Community signal:** ~45 stars.
- **What it does:** HiAnime extractor plugin.
- **Activation:** loads automatically for that site.
- **Default image:** installs, but import fails because `requests` is missing.
- **Use when:** you archive that site and can add the Python dependency. Site
  extractors are fragile and need updates when the site changes.

### yt-dlp-stash

- **Area:** Stash metadata.
- **Community signal:** ~28 stars.
- **What it does:** postprocessor that adds metadata for a Stash library.
- **Default image:** installs, but import fails because `stashapi` is missing.
  It also needs a reachable Stash server and API key.
- **Use when:** Stash is your media manager and you can add the Python
  dependency. Check the repo for the exact `--use-postprocessor` activation.

### yt-dlp-SpotifyCanvas

- **Area:** Spotify Canvas videos.
- **Community signal:** ~12 stars.
- **What it does:** downloads Spotify Canvas videos.
- **Default image:** installs, but import fails because `pyotp` is missing.
- **Use when:** you archive Spotify-related media and can add the Python
  dependency. Check the repo for the activation and available URL support.

### yt-dlp-YTCustomChapters

- **Area:** YouTube chapters.
- **Community signal:** ~9 stars.
- **What it does:** uses custom YouTube chapter lists.
- **Activation:** `--extractor-args "youtube:chapters_file=/path/to/chapters.txt"`.
- **Verified:** loaded as an extractor override (`CustomChapters (YoutubeIE)`).
  The file-reading path was not exercised.
- **Use when:** you maintain your own chapter data.

### yt-dlp-danmaku

- **Area:** Bilibili danmaku subtitles.
- **Community signal:** ~30 stars.
- **What it does:** converts Bilibili danmaku into ASS subtitles.
- **Activation:** `--use-postprocessor danmaku`. Options are documented in its
  README, for example `danmaku:text_opacity=0.1;display_region_ratio=0.5`.
- **Default image:** installs, but import fails because the sibling
  `yt_dlp_danmaku` package is missing. A pip install includes that package; a
  single re-packaged `yt_dlp_plugins` zip does not.
- **Recommendation:** use it only if you can install its Python dependency.

## Avoid or use with care

- **yt-dlp-ChromeCookieUnlock:** Windows-only. It imports `ctypes.windll` and
  fails on the Linux container. Use the Pinchflat-ngx cookies upload page
  instead.
- **DRM/decryption plugins** (`yt-dlp-mp4decrypt`, widevine helpers): they need
  keys and raise legal/terms-of-service questions. They are outside the scope
  of this index.
- **ytdlp-plugins** (the plugin manager): unnecessary here; Pinchflat-ngx
  already manages the plugin directory and the yt-dlp invocation.
- **yt-dont-lock-p:** applies a system wake lock. Useful on a desktop; not
  useful for a server.
- **Adult-site plugins:** intentionally omitted.
- **Stacking extractor overrides:** do not run several plugins that override
  `YoutubeIE` at once. Keep one and remove it if downloads regress.

## Suggested starter sets

- **Minimal:** FixupMtime, plus srt_fix if you download auto-subs.
- **Metadata-focused:** ReturnYoutubeDislike and DeArrow.
- **Music:** FixupMtime. Use ReplayGain only if you add a gain tool to the
  container.
- **Bot checks:** bgutil through `POT_PROVIDER_URL` first. Try getpot-wpc only
  if you can run a browser and add `nodriver`.
- **Site-specific:** rajiko works with a zip-only install. Use hianime,
  SpotifyCanvas, or stash only if you can add their Python dependencies.

## How to evaluate a plugin before keeping it

1. Check that it has a release zip with `yt_dlp_plugins/` at the archive root,
   or that it is installable with pip.
2. Read the README for the supported yt-dlp version and the activation flag.
3. Check the last release or commit date.
4. Install it alone, index one source, download one item.
5. Search the logs for `[yt-dlp plugins]` after the test.
6. Remove it if the source stops indexing or YouTube downloads regress.

## Verified in the default Pinchflat-ngx image

Each plugin was installed through `PluginDirectory.install_archive/2`, then
loaded with `yt-dlp --plugin-dirs ... --verbose`. Postprocessor rows also had
their documented activation line saved through the Config path and were run with
`--config-locations`; the check confirms the postprocessor name is registered,
not that a full download completed.

| Plugin                 | Install | Load / activation                                            | Notes                                     |
| ---------------------- | ------- | ------------------------------------------------------------ | ----------------------------------------- |
| FixupMtime             | Pass    | `FixupMtimePP`; activation accepted                          | Pure Python                               |
| DeArrow                | Pass    | `DeArrowPP`; activation accepted                             | Needs network/API                         |
| ReturnYoutubeDislike   | Pass    | `ReturnYoutubeDislikePP`; activation accepted                | API is rate-limited                       |
| srt_fix                | Pass    | `srt_fixPP`; activation accepted                             | Uses ffmpeg                               |
| ReplayGain             | Pass    | `ReplayGainPP`; activation accepted                          | No gain tool in the image                 |
| YTAgeGateBypass        | Pass    | `AGB (YoutubeIE)` extractor override                         | Age-gate path not tested                  |
| YTCustomChapters       | Pass    | `CustomChapters (YoutubeIE)` extractor override              | File path not tested                      |
| rajiko                 | Pass    | `Radiko*IE` extractors                                       | Site download not tested                  |
| bgutil 2.0.2           | Pass    | `bgutil:http-2.0.2 (external)`; script providers unavailable | Needs a provider server                   |
| apple-webkit-jsi 0.1.1 | Pass    | `apple-webkit-jsi-0.1.1 (external, unavailable)`             | Needs Apple hardware                      |
| remote-cipher 0.0.1    | Pass    | `remotecipher-0.0.1 (external)`                              | Needs a cipher server                     |
| ChromeCookieUnlock     | Pass    | Import fails: `ctypes.windll`                                | Windows-only                              |
| danmaku                | Pass    | Import fails: `yt_dlp_danmaku` missing                       | Needs pip dependency                      |
| getpot-wpc             | Pass    | Import fails: `nodriver` missing                             | Needs browser dependency                  |
| hianime                | Pass    | Import fails: `requests` missing                             | Needs Python dependency                   |
| SpotifyCanvas          | Pass    | Import fails: `pyotp` missing                                | Needs Python dependency                   |
| stash                  | Pass    | Import fails: `stashapi` missing                             | Needs `stashapp-tools` and a Stash server |

The remaining plugins were not exercised end-to-end: provider plugins need their
external servers, site extractors need live sites, and the postprocessors need a
real download. The table distinguishes registration from full functional proof.

## Sources

- [yt-dlp Plugins wiki](https://github.com/yt-dlp/yt-dlp/wiki/Plugins)
- [GitHub topic: yt-dlp-plugins](https://github.com/topics/yt-dlp-plugins)
- Each plugin’s repository README, linked in its section
