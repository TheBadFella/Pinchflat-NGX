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
