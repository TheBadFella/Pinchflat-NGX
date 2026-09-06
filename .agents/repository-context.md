# PinchYT engineering context

Maintain the PinchYT media fork and its Material Design theme.

Stack observed on 2026-09-06: Elixir/Phoenix LiveView + Ecto/SQLite + Oban. Recheck manifests and scoped instructions when the implementation changes.

## Read for the affected area

- `mix.exs`
- `compose.yaml`
- `docker/docker-compose.yml`
- `test/test_helper.exs`
- `test/pinchflat/media_test.exs`
- `assets/css/app.css`
- `assets/css/theme/tokens.css`
- `package.json`

## Contracts to preserve

- Use Docker for development/testing as required by AGENTS; inspect binds and isolate media/database paths first.
- Preserve Oban uniqueness/retries, retention safety and fixture-based yt-dlp/HTTP behavior.
- Use semantic Material Design classes and current Tailwind CSS theme paths. Pinchflat remains the internal module name; PinchYT is the fork/product name.

## Verification recipes

These commands were found in project instructions, manifests, tests or CI and reviewed for task fit. Their inclusion does not mean they ran or passed during the skill audit. Inspect test fixtures and environment prerequisites before execution. Run only checks relevant to the change; keep any stricter repository release gate.

| Working directory | Command | Purpose / condition |
|---|---|---|
| root in isolated development stack | `docker compose run --rm phx mix test` | ExUnit |
| root in isolated development stack | `docker compose run --rm phx mix check` | Repository full check alias; may format |
| root in isolated development stack | `docker compose run --rm phx yarn run ui:check-theme` | Theme checks for LiveView changes |

## Observable proof

Use synthetic fixture DB/media by default, inspect backup sensitivity before any real-data testing, and preserve priv/repo/ui_smoke_seed.exs because it predates this audit. Test a queued worker and its resulting state; do not contact production download services.

## Communication

Keep public PinchYT naming separate from Pinchflat code modules. Do not rewrite class names, yt-dlp flags, file templates or API identifiers.
