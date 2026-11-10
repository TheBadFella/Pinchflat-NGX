# Retention browser regression

This checks the real source form and source listings, including Alpine updates,
profile switching, zero and positive overrides, clearing with the keyboard, a blank
save that remains inherited, and layout at 320, 390, 768 and 1440 CSS pixels. It
checks that retention summaries and mobile delete actions stay visible. It never
clicks a delete action.

The application runs in a disposable Docker container with synthetic SQLite data
and manual Oban testing mode. No live YouTube downloads are used. The fixture
refuses a non-test environment or a database that already contains sources. The
browser test also verifies the fixture source name before editing it.

Build the repository's normal test image:

```bash
docker compose -f docker/docker-compose.ci.yml build phx
```

Start a fresh container with no host database or media mounts:

```bash
docker run --rm --name pinchflat-retention-ui \
  -p 127.0.0.1:4002:4002 -e MIX_ENV=test -e RETENTION_UI_FIXTURE=1 \
  --entrypoint sh pinchyt-phx -lc \
  'mix ecto.create --quiet && mix ecto.migrate --quiet && mix assets.build && mix run --no-start test/support/retention_ui_fixture.exs'
```

Wait for `RETENTION_UI_READY`. In another terminal, copy its fixture manifest and
run the test through an installed Chrome DevTools AXI CLI (tested with 0.1.44):

```bash
docker cp pinchflat-retention-ui:/tmp/pinchflat-retention-ui.json /tmp/retention-ui.json
export RETENTION_UI_BASE_URL=http://127.0.0.1:4002
export RETENTION_UI_FIXTURES=/tmp/retention-ui.json
export CHROME_DEVTOOLS_AXI_SESSION=retention-regression
chrome-devtools-axi run < test/browser/source_retention.mjs
chrome-devtools-axi stop
docker stop pinchflat-retention-ui
```

The browser CLI must be configured with a working Chrome/MCP installation. If a
local wrapper supplies it, set `RETENTION_UI_BROWSER_CLI` to that executable and
use the wrapper for both `run` and `stop`. Set `RETENTION_UI_ARTIFACTS` to an
evidence directory to save screenshots. Use the same named browser session for
the entire run and cleanup. Stop that session and the named container after a
failed assertion too. Fixtures and browser profiles must not be shared between
parallel test runs.

This is an explicit browser check alongside ExUnit. It is not silently run by
`mix test` or the existing CI jobs, and it does not prove PostgreSQL behavior,
packaged release behavior or live-provider downloads.

## Library UI regression

This checks the refreshed library UI at 320, 390, 768 and 1440 CSS pixels: no
horizontal page scroll, real thumbnails loading and staying visible after
sorting reuses row nodes, the Alpine placeholder for a missing thumbnail file and
for an item with no thumbnail, the conditional Action column, every link and
button in source rows meeting 44x44 CSS pixels on phone widths, and the row
menu's keyboard flow (Enter opens it, Tab reaches Start/Pause/Stop/Delete, Escape
returns focus).
It cancels the Pause confirmation and asserts nothing submitted. It never
activates Delete.

The fixture writes synthetic sources, media items and a real JPEG thumbnail to a
disposable test container. It refuses a non-test environment or a database that
already contains sources. Use `LIBRARY_UI_FIXTURE=empty` for a single source with
nothing indexed in the last 24 hours to check the P3 empty state.

Build the repository's normal test image, then start a fresh container:

```bash
docker compose -f docker/docker-compose.ci.yml build phx
docker run --rm --name pinchflat-library-ui \
  -p 127.0.0.1:4004:4004 -e MIX_ENV=test -e LIBRARY_UI_FIXTURE=1 \
  -e TEST_DATABASE_PATH=/tmp/pinchflat-library-ui.db \
  -v "$PWD:/app" -v pinchflat_library_ui_deps:/app/deps \
  -v pinchflat_library_ui_build:/app/_build \
  --entrypoint sh pinchyt-phx -lc \
  'mix ecto.create --quiet && mix ecto.migrate --quiet && mix assets.build && mix run --no-start test/support/library_ui_fixture.exs'
```

Wait for `LIBRARY_UI_READY`, copy its manifest and run the test with an installed
Chrome DevTools AXI CLI:

```bash
docker cp pinchflat-library-ui:/tmp/pinchflat-library-ui.json /tmp/library-ui.json
export LIBRARY_UI_BASE_URL=http://127.0.0.1:4004
export LIBRARY_UI_FIXTURES=/tmp/library-ui.json
export CHROME_DEVTOOLS_AXI_SESSION=library-ui-regression
export LIBRARY_UI_BROWSER_CLI=/home/badfellawsl/.local/bin/browser-axi
browser-axi run < test/browser/library_ui.mjs
browser-axi stop
docker stop pinchflat-library-ui
```

For the empty state, repeat with `-e LIBRARY_UI_FIXTURE=empty` and a fresh
database path. Set `LIBRARY_UI_ARTIFACTS` to save screenshots named
`<page>-<state>-<width>.png`. Use one named browser session for the run and stop
it and the container after a failed assertion too. This is an explicit browser
check; it is not run by `mix test` or CI and does not prove PostgreSQL or packaged
release behavior.

## Source actions and Paste URL regression

This checks the source play/pause/stop controls and the Browse YouTube Paste URL
placement. It asserts icon-box centres within 2 CSS pixels of the button content
box, alignment with the neighbouring edit/delete controls, 44x44 targets under
touch emulation, no horizontal overflow, and that opening Paste URL from its new
search-row location preserves the query/profile and restores focus on close. It
paints both screens at 320, 390, 768 and 1440 CSS pixels.

The fixture refuses a non-test environment or a database that already contains
sources or profiles, and it refuses to inspect an unrelated library by checking its own
fixture names first. It uses manual Oban testing mode and no live downloads.

Start a fresh container with the source mounted for the test fixture (the image
excludes `/test`):

```bash
docker run --rm --name pinchflat-source-actions-ui \
  -p 127.0.0.1:4003:4003 -e MIX_ENV=test -e SOURCE_ACTIONS_UI_FIXTURE=1 \
  -e TEST_DATABASE_PATH=/tmp/pinchflat-source-actions-ui.db \
  -v "$PWD:/app" -v pinchflat_source_actions_deps:/app/deps -v pinchflat_source_actions_build:/app/_build \
  --entrypoint sh pinchyt-phx -lc \
  'mix ecto.create --quiet && mix ecto.migrate --quiet && mix assets.build && mix run --no-start test/support/source_actions_ui_fixture.exs'
```

Wait for `SOURCE_ACTIONS_UI_READY`, then copy the manifest and run the test with
an installed Chrome DevTools AXI CLI:

```bash
docker cp pinchflat-source-actions-ui:/tmp/pinchflat-source-actions-ui.json /tmp/source-actions-ui.json
export SOURCE_ACTIONS_UI_BASE_URL=http://127.0.0.1:4003
export SOURCE_ACTIONS_UI_FIXTURES=/tmp/source-actions-ui.json
export CHROME_DEVTOOLS_AXI_SESSION=source-actions-regression
export SOURCE_ACTIONS_UI_BROWSER_CLI=/home/badfellawsl/.local/bin/browser-axi
browser-axi run < test/browser/source_actions_browse.mjs
browser-axi stop
docker stop pinchflat-source-actions-ui
```

Set `SOURCE_ACTIONS_UI_ARTIFACTS` to save screenshots and
`SOURCE_ACTIONS_UI_BROWSER_CLI` to use a local wrapper. Use one named browser
session for the run and stop it and the container after a failed assertion too.
This is an explicit browser check; it is not run by `mix test` or CI and does not
prove PostgreSQL or packaged release behavior.
