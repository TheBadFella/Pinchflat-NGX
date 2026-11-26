# Browser helpers (optional)

Files here are **optional operator tooling**. They are not installed into the Pinchflat-ngx container image and are not required to run the application.

## YouTube quick add (userscript)

**Path:** [`userscripts/youtube-quick-add-source.user.js`](userscripts/youtube-quick-add-source.user.js)

Adds controls on YouTube that open your instance’s **New Source** form with URL, name, and source type prefilled. Use this when the built-in [intake bookmarklet](https://github.com/TheBadFella/Pinchflat-NGX/wiki/Sharing-and-bookmarklets) (Browse → single video) is too limited but you still want the full source form.

**Adapted by TheBadFella; contributed originally by [@Asinin3](https://github.com/Asinin3) in [discussion #227](https://github.com/TheBadFella/Pinchflat-NGX/discussions/227).** The maintained copy in this repository may diverge slightly for configuration and documentation.

### Requirements

- [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/) in a desktop browser
- Your Pinchflat **External base URL** (Settings) must match how you reach the app in the browser

### Install (recommended)

1. Open **Settings → API & Access** on your Pinchflat-ngx instance.
2. Under **YouTube quick add userscript**, click **Install YouTube quick add** or copy the install URL.
3. In [Tampermonkey](https://www.tampermonkey.net/) or Violentmonkey, confirm installation when prompted. The hosted script already contains your **External base URL**.

The install URL shape is:

`https://your-pinchflat-host/browser/userscripts/youtube-quick-add-source.user.js`

That endpoint is public (no credentials in the script). Set **External base URL** correctly before sharing the link with other users on the same instance.

### Manual install

Edit `PINCHFLAT_BASE` in [`userscripts/youtube-quick-add-source.user.js`](userscripts/youtube-quick-add-source.user.js) only when you cannot use the hosted URL (for example, while developing the script itself).

The script opens `/sources/new` with query parameters. Pinchflat-ngx fills missing names and source types from the URL server-side, so Tampermonkey does not need to run on your Pinchflat tab.

### Security

The script does not store Pinchflat credentials. It only opens your instance in a new tab and sets form fields while you are signed in. It reads public YouTube page text and may call YouTube’s public `oembed` endpoint for playlist titles.

### Breakage

YouTube changes markup often. If buttons disappear, open an issue or submit a pull request with selector fixes. Tests are manual.

### Contributing

Pull requests that touch only `extras/browser/**` are welcome. Keep changes focused on DOM selectors, configuration, or comments. Credit the discussion author in the script header when preserving their logic.

**License:** Distributed with Pinchflat-ngx under the repository’s [AGPL-3.0](https://github.com/TheBadFella/Pinchflat-NGX/blob/master/LICENSE) unless a contributor requests a different license for their own additions.
