# Shared button and control updates

This change is extracted from the local `feat/global-latest-tab` integration onto `origin/master` at `565b1d4`. The Latest tab, media queries, date picker, timezone logic and status badges are excluded. The original working tree is preserved.

## Changed behavior

Standard actions use a 44px minimum height. Compact desktop actions retain their smaller size and expand to at least 44px for phone layouts and coarse pointers. Button components render navigation as links without nested buttons; disabled navigation renders a disabled button with no destination. POST links retain their method and CSRF attributes.

The change also normalizes Settings labels and inputs, filter targets, icon action names, back links, source/profile form wrapping, dropdown rows, pagination buttons and monitoring validation messages. Toggle thumbs remain centered within their 44px click targets.

## Verification and provenance

The standalone branch has its own Docker Compose project, dependency/build volumes, synthetic SQLite database and preview on loopback port 4124. Full checks run again through the pre-commit hooks and remote validation before merge. Results are recorded in the PR body for the exact pushed commit.

- Component regression tests cover disabled navigation, POST link rendering and standalone label associations.
- Existing history/source tests cover native pagination selectors and disabled first/last-page boundaries.
- Standalone Chrome Settings checks at 1920px and 320px found no document overflow or nested button markup. Visible mobile controls measured at least 44px in both dimensions. Test Now remains an intentional compact desktop action.
- Theme checks and the asset build passed on the extracted source.
- An initial full run failed on a random media-profile fixture name collision. The following full run passed 2,025 tests, with 30 excluded; its formatting failure was corrected before the commit hooks.
- A component-only run overlapped the full suite and failed during shared temporary-directory cleanup after its three tests passed. Repeating it sequentially passed with exit 0. Final validation uses one suite at a time.
- Three existing Markdown tables were reformatted without content changes so the required full Prettier gate can pass.

The earlier browser audit of 37 screen/state URLs and seven Settings filters was performed on the combined Latest branch. It is supporting evidence for unchanged shared controls, not fresh standalone coverage. Prototype images and invalid 404 captures are excluded from this PR.

## Limits

No new production image or deployment is included. Physical touch hardware, all themes, Firefox/Safari, prefix deployment and every conditional screen state were not rechecked on this extracted branch. PostgreSQL validation is reported separately in the remote workflow results. The ordinary suite excludes adapter-specific and schema migration tests; the remote schema job explicitly selects its migration tests.
