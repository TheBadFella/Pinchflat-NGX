# YouTube browser shortcuts and New Source prefill

Tracks [discussion #227](https://github.com/TheBadFella/Pinchflat-NGX/discussions/227) (community userscript) and the planned in-app follow-up.

## Roadmap text (publish to wiki `Roadmap.md`)

Insert after **Subscription import extensions** and before **Deferred proposals**.

### Optional YouTube userscript (repository helper)

**Status:** optional operator tooling; not part of the application image.

Pinchflat-ngx already supports deep links to the full **New Source** form via `GET /sources/new` query parameters (`original_url`, `custom_name`, `source_type`). The bookmarklet on **Settings → API & Access** targets **Browse** for single-video review only.

An optional [userscript](https://github.com/TheBadFella/Pinchflat-NGX/tree/master/extras/browser/userscripts) adds buttons on YouTube (channels, playlists, videos, thumbnails) and opens the signed-in **New Source** page with those fields prefilled. Install via Tampermonkey or Violentmonkey; see [Sharing and bookmarklets](Sharing-and-bookmarklets#youtube-quick-add-userscript-optional).

The script relies on YouTube page markup and may break when YouTube changes layout. Improvements are welcome as pull requests against `extras/browser/userscripts/`. Adapted by TheBadFella; contributed originally by [@Asinin3](https://github.com/Asinin3) in [discussion #227](https://github.com/TheBadFella/Pinchflat-NGX/discussions/227).

### New Source metadata prefill (implemented, unreleased)

**Status:** merged to application code; publish wiki/roadmap on release.

Today, query parameters on `/sources/new` prefill the form when an external shortcut supplies them. A follow-up would resolve `original_url` on the server when the parameter is present but name or type are omitted: use the same URL metadata path as source creation to suggest `custom_name`, detected `source_type`, and (where appropriate) reduce dependence on client-side form scripting across origins.

That would make a minimal bookmarklet or pasted link sufficient for many channel and playlist cases without Tampermonkey cross-tab state. Scoped intake, share tokens, and Browse behavior stay unchanged.

**Publication checklist**

- [ ] Add the two sections above to [Roadmap](https://github.com/TheBadFella/Pinchflat-NGX/wiki/Roadmap).
- [ ] Add [Sharing and bookmarklets](Sharing-and-bookmarklets#youtube-quick-add-userscript-optional) install section and link from [Pinchflat-ngx Features](Pinchflat-ngx-Features) under Operations and access.
- [ ] After merge: thank Asinin3 on discussion #227 and link the wiki + repository path (do not claim the feature is in a stable release until published).

## Official support model

| Piece                                  | Purpose                                                                                    |
| -------------------------------------- | ------------------------------------------------------------------------------------------ |
| `extras/browser/userscripts/*.user.js` | Versioned script in-repo; raw GitHub URL for Tampermonkey “Install from URL”.              |
| `extras/browser/README.md`             | Scope, configuration, breakage expectations, how to contribute.                            |
| Wiki (Sharing guide)                   | Install steps, `PINCHFLAT_BASE` / `@match`, security note (no credentials in script).      |
| Roadmap                                | Distinguish optional userscript (shipped separately from the container) vs in-app prefill. |
| Credit                                 | Header `@author` and wiki “Originally by … discussion #227”.                               |
| Community PRs                          | Yes for userscript DOM selectors and docs; no CI gate beyond optional review (not Elixir). |
| Settings UI                            | Optional later: link to raw script + “New Source bookmarklet” using query params only.     |

Do **not** load the userscript from the Phoenix app or Docker image. It is not tested on every release unless maintainers run a manual smoke check.

## In-app prefill (medium term) — design sketch

1. On `SourceController.new/2`, when `original_url` is present and `custom_name` / `source_type` are absent, call existing source URL resolution (same as create validation) with a short timeout and no side effects.
2. On success, merge into `prefill_source_attrs/1`; on failure, render the form unchanged with an optional flash-less inline hint.
3. Add ExUnit coverage with mocked URL metadata (no live YouTube).
4. Optionally add a second bookmarklet generator beside the Browse bookmarklet: `/sources/new?original_url=` + current page URL (channel/playlist pages benefit once server prefill lands).

No browser extension or Web Store release unless requirements grow beyond DOM injection.

## Wiki text (append to `Sharing-and-bookmarklets.md`)

```markdown
<a id="youtube-quick-add-userscript-optional"></a>

## YouTube quick add userscript (optional)

This is optional browser tooling shipped in the application repository, not inside the Docker image. Use it when you want the full **New Source** form from YouTube instead of the intake bookmarklet, which opens **Browse** for a single video.

**Adapted by TheBadFella; contributed originally by [@Asinin3](https://github.com/Asinin3) in [discussion #227](https://github.com/TheBadFella/Pinchflat-NGX/discussions/227).**

1. Install [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/).
2. Copy the maintained script from [`extras/browser/userscripts/youtube-quick-add-source.user.js`](https://github.com/TheBadFella/Pinchflat-NGX/blob/master/extras/browser/userscripts/youtube-quick-add-source.user.js) into a new userscript, or install from your fork’s raw URL after merge.
3. Set `PINCHFLAT_BASE` to your **External base URL** (Settings → the same host you use in the browser, including a path prefix if you use one).
4. If you deploy under a subpath, add a `@match` line for your `.../sources/new` URL as described in the script header.
5. Open YouTube, use the inline **+** controls or thumbnail button, and complete **New Source** in your signed-in Pinchflat tab.

The script does not contain credentials. YouTube layout changes may require script updates; pull requests against `extras/browser/` are welcome.

For a single video with profile review, keep using the bookmarklet on this same page. For channels and playlists with retention, profiles and folder options, prefer this userscript or paste the URL on **New Source**.

**Upcoming (in-app):** opening **New Source** with only `original_url` may prefill name and source type without Tampermonkey; see [Roadmap](Roadmap#new-source-metadata-prefill-planned-in-app).
```

Add a Features table row: “Add a YouTube channel/playlist from the browser (full New Source form)” → Sharing guide anchor above.
