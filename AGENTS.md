# Agent guidelines for Pinchflat-ngx

Guidelines for AI agents working on this Elixir/Phoenix codebase.

## Project Overview

Pinchflat-ngx (formerly PinchYT) is a self-hosted media management fork. Its internal Elixir
application and modules retain the Pinchflat name. It uses:

- **Backend**: Elixir 1.17+, Phoenix 1.8, Ecto with SQLite or PostgreSQL
- **Frontend**: Phoenix LiveView, Tailwind CSS, esbuild
- **Background Jobs**: Oban
- **Testing**: ExUnit with Mox for mocking

## Build/Lint/Test Commands

**Always use Docker for development and testing.** The project has permission issues when mixing Docker and local builds.

Compose files live in `docker/`. The root `compose.yaml` includes `docker/docker-compose.yml`, so `docker compose up` still works from the repo root. CI sets `COMPOSE_FILE: ./docker/docker-compose.ci.yml`.

## Git And PR Policy

- Create pull requests against this fork's `origin` remote unless the user explicitly says otherwise.
- Do not open pull requests against `upstream`.
- Use short, descriptive branch names that identify the work, such as `fix/media-cleanup-guidance`. Use lowercase words separated by hyphens; avoid issue/PR numbers, dates, agent names and vague placeholders in the branch name. Recheck the name when the scope changes.

### Documentation is part of every merged PR

- Assess documentation impact while implementing the change, including configuration, API/authentication, defaults, limits, errors, recovery and effects on existing files/jobs. Dependency and internal-only PRs still need this assessment; do not make artificial wiki edits when usage is unchanged.
- User/operator instructions live in the [wiki](https://github.com/TheBadFella/Pinchflat-NGX/wiki). Update the existing task guide and affected references, not a second manual in `docs/` or a page for each small implementation detail. Add a task guide only for a distinct workflow, then link it from the Features directory and navigation.
- Prepare affected wiki edits alongside the code PR. Include the guide links and documentation plan in its description, or a specific explanation of why no user-facing documentation changes are needed. A code PR cannot contain the separate wiki repository's commit; track and verify both explicitly.
- After **every PR merge**, review the final merged diff, publish the applicable wiki changes within the authorized publication task, and check that the published pages/anchors match the merged behavior. Do this before reporting the merge task complete; do not postpone it until release day. If wiki access fails, report the PR, affected pages and outstanding publication instead of claiming completion.
- Keep release state accurate. Describe merged-but-unreleased behavior in a clearly marked upcoming section with its PR/commit; retain instructions for the published version. Do not present `master` or a development image as a stable release. At release, reconcile guide version notices and the roadmap with the actual published tag.
- Verify steps and labels against code and available runtime evidence. Cover expected outcomes, limits, data/file/job effects and recovery; use dated examples for cutoff/retention rules. Keep environment-variable definitions in their reference page and link to them from tutorials.
- Preserve existing page URLs and section anchors when reorganizing guides, or leave compatible anchors/links. Check internal links and release-note deep links. Documentation-only changes need prose/link checks, not invented application test claims.
- The final merge handoff must say which documentation was published, with links, or why no update was necessary. Instructions are a required workflow, not proof of automated enforcement; never claim a bot or CI checked wiki accuracy unless that check actually exists and ran.

### PR descriptions and maintainer voice

- Before creating or editing a PR description, reread the final prose for clarity and voice, and check the published body after writing it.
- Write as the maintainer explaining a concrete change to another person: what was awkward or broken, what users can do now, and why this approach fits. Use a short natural paragraph for small PRs. Headings are optional; remove unused template sections, `N/A` filler and repeated "What's new/changed/fixed" scaffolding.
- First person is welcome when supported by the work (for example, "I moved the cutoff warning beside the download action so it is visible before confirmation"). Do not invent personal experiences, motivations, excitement, anecdotes or user feedback to manufacture a personal touch. Prefer plain words; avoid promotional openings, em dashes and canned summaries.
- Keep implementation details only when they help review correctness or a tradeoff. Summarize checks proportionately: relevant results, a CI/evidence link and material gaps. Preserve failures, exclusions and not-run distinctions without pasting a command diary or repeating the same test totals several times.
- Include documentation impact and credit external contributors/reporters where relevant. Preserve authorship/license requirements without asserting work is original when it is not. Rewrite the title/body around the final scope if the change evolves.
- For release descriptions, follow [the release-note guide](.github/RELEASE_NOTES.md): the agreed Immich/BentoPDF approach, named contributor thanks and direct usage-guide links. Do not substitute autogenerated PR/dependency lists for the maintainer's release notes.

**Database backup:** Use `pinchflat.db.backup-*` files for testing and development with real data. These contain production-like data for debugging issues.

```bash
# Run all checks (compile, format, credo, tests, sobelow, prettier)
docker compose run --rm phx mix check

# Run tests only
docker compose run --rm phx mix test

# Run a single test file
docker compose run --rm phx mix test test/pinchflat/media_test.exs

# Run a specific test by line number
docker compose run --rm phx mix test test/pinchflat/media_test.exs:42

# Run tests matching a pattern
docker compose run --rm phx mix test --only describe:"list_media_items"

# Format Elixir code
docker compose run --rm phx mix format

# Run Credo linter
docker compose run --rm phx mix credo

# Security analysis
docker compose run --rm phx mix sobelow --config

# Format JS/CSS/YAML/JSON
docker compose run --rm phx yarn run lint:fix

# Start the development server
docker compose up
```

## Code Style Guidelines

### Module Structure

Follow this order in modules:

1. `@moduledoc` - required for all public modules
2. `use`/`import`/`alias`/`require` statements
3. Module attributes (`@allowed_fields`, `@impl`, etc.)
4. Public functions with `@doc`
5. Private functions

```elixir
defmodule Pinchflat.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media.MediaItem

  @doc """
  Returns the list of media_items.
  """
  def list_media_items do
    Repo.all(MediaItem)
  end

  defp some_private_function do
    # ...
  end
end
```

### Imports and Aliases

- Use `alias` for frequently used modules
- Prefer explicit imports: `import Ecto.Query, warn: false`
- Group aliases alphabetically
- Use `alias __MODULE__` for self-reference in schemas

### Naming Conventions

- **Modules**: PascalCase matching file path (`Pinchflat.Media.MediaItem`)
- **Functions**: snake*case with verb prefixes (`get*`, `list*`, `create*`, `update*`, `delete*`)
- **Predicate functions**: end with `?` (`pending_download?/1`)
- **Private functions**: prefix with `do_` for wrapper pattern (`do_delete_media_files`)
- **Workers**: suffix with `Worker` (`MediaDownloadWorker`)
- **Fixtures**: suffix with `_fixture` (`media_item_fixture`)

### Formatting

- Line length: 120 characters max
- Use `mix format` - config in `.formatter.exs`
- Prettier for JS/CSS/YAML/JSON

### UI Theming Guardrails

- Follow Material Design 3 tokens and design foundations for UI work.
- For date-based rules, name the compared fields and show their actual dates when available. Distinguish publication date from download time; explain the consequence and available action instead of shorthand such as "this video is before the cutoff".
- Treat UI work ported from other forks, upstream, or generated patches as unfinished until it has been adapted to Pinchflat-ngx's current design system.
- Before adding or changing a screen, inspect nearby pages and shared components to match the existing layout density, surfaces, spacing, typography, buttons, tabs, badges, tables, and empty states.
- Use shared semantic theme classes from `assets/css/app.css` instead of page-local hardcoded palette combinations.
- Do not introduce raw palette classes like `text-red-*`, `bg-red-*`, `border-green-*`, or `zinc-*` in `lib/pinchflat_web`.
- Do not copy legacy theme classes such as `bg-white`, `dark:bg-boxdark`, `text-white`, `text-bodydark`, `bg-meta-*`, `border-strokedark`, or `bg-form-input` into `lib/pinchflat_web`; translate them to semantic theme surfaces, text, status, badge, input, and button classes.
- When a new UI state is needed, add a semantic class or token rather than styling a single screen inline.
- After UI ports or redesigns, scan `lib/pinchflat_web` for raw or legacy palette classes and fix neighboring pages that would visibly clash with the changed screen.
- Run `yarn run ui:check-theme` after UI changes that touch `lib/pinchflat_web`.
- Tailwind is configured in CSS, not `tailwind.config.js`. Keep Tailwind v4 theme tokens in `assets/css/theme/tokens.css`.
- Keep raw palette variables in `assets/css/theme/palette.css`. Keep semantic component classes in `assets/css/app.css`.
- The `@source` paths in `assets/css/app.css` are relative to `assets/css/app.css`. Be careful when editing them; wrong paths can make the UI compile successfully but drop most utilities.
- Trim custom Tailwind tokens to values the app actually uses instead of restoring large legacy compatibility blocks.

### UI Visual Review Checklist

Complete this review during UI work and before reporting the change as finished:

- Before coding, identify the shared component and variant that fit the control's context. Embedded field icons should use the field-action style; standalone outlined buttons can create unwanted nested borders inside an outlined field.
- Render the changed UI with synthetic data and inspect actual browser screenshots. Review empty, populated, selected, focused, hovered, disabled, expanded, and error states where applicable. Include long labels and values.
- Check at 320px, 390px, 768px, and 1440px, plus any widths requested by the user. Inspect borders, icon size, alignment, spacing, text clipping, dropdown placement, and neighboring controls. Passing geometry checks alone does not establish visual consistency.
- Verify keyboard access, visible focus, focus restoration after clearing or closing, and at least 44px touch targets on phone layouts. Hide selection actions when nothing is selected and clear actions when there is no value to clear.
- For shared component or CSS changes, inspect callers and render representative affected screens. Put reusable corrections in the shared component or semantic theme class.
- Fix visual defects found in this review before presenting the result. When showing before/after screenshots, use matching data and viewport sizes.
- Report the browser widths and states checked, relevant automated checks, and any missing visual verification. If browser review is unavailable, state that gap rather than claiming the UI is visually verified.

### Return Types

Document returns in `@doc`:

```elixir
@doc """
Creates a media_item.

Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
"""
def create_media_item(attrs) do
  # ...
end
```

### Error Handling

- Use `{:ok, result}` / `{:error, reason}` tuples
- Use `!` suffix for functions that raise (`get_media_item!/1`)
- Pattern match on error tuples explicitly
- Rescue specific exceptions when needed:

```elixir
def perform(%Oban.Job{args: %{"id" => id}}) do
  # ...
rescue
  Ecto.NoResultsError -> Logger.info("Record not found")
  Ecto.StaleEntryError -> Logger.info("Record stale")
end
```

### Oban Workers

```elixir
defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "show_in_dashboard"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id} = args}) do
    # Return :ok, {:ok, result}, {:error, reason}, or {:snooze, seconds}
  end
end
```

### Testing Patterns

Use `Pinchflat.DataCase` for database tests:

```elixir
defmodule Pinchflat.MediaTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media

  describe "list_media_items/0" do
    test "returns all media_items" do
      media_item = media_item_fixture()
      assert Media.list_media_items() == [media_item]
    end
  end
end
```

### Mocking with Mox

Mocks are defined in `test/test_helper.exs`:

- `YtDlpRunnerMock` - yt-dlp commands
- `HTTPClientMock` - HTTP requests
- `UserScriptRunnerMock` - user scripts
- `AppriseRunnerMock` - notifications

```elixir
test "calls user script" do
  expect(UserScriptRunnerMock, :run, fn :media_deleted, data ->
    assert data.id == media_item.id
    {:ok, "", 0}
  end)

  Media.delete_media_item(media_item, delete_files: true)
end
```

### Test Fixtures

Create fixtures in `test/support/fixtures/`:

```elixir
def media_item_fixture(attrs \\ %{}) do
  {:ok, media_item} =
    attrs
    |> Enum.into(%{
      media_id: Faker.String.base64(12),
      title: Faker.Commerce.product_name(),
      source_id: source_fixture().id
    })
    |> Pinchflat.Media.create_media_item()

  media_item
end
```

### Test Helpers

From `Pinchflat.TestingHelperMethods`:

- `now/0` - current UTC datetime
- `now_minus/2` - datetime in past (`now_minus(5, :days)`)
- `now_plus/2` - datetime in future
- `assert_changed/2` - verify state change

## Project Structure

```
lib/
  pinchflat/           # Business logic contexts
    media/             # Media context (MediaItem, queries)
    sources/           # Source context
    downloading/       # Download workers and helpers
    yt_dlp/            # yt-dlp integration
  pinchflat_web/       # Phoenix web layer
test/
  pinchflat/           # Context tests
  pinchflat_web/       # Controller/LiveView tests
  support/
    fixtures/          # Test data factories
    data_case.ex       # Database test setup
    conn_case.ex       # HTTP test setup
```

## API Documentation

Pinchflat provides a REST API with OpenAPI 3.0 specification and Scalar for interactive documentation.

### OpenAPI Specification

**Location:** `lib/pinchflat_web/api_spec.ex`

Uses `open_api_spex` (~> 3.21) to generate OpenAPI 3.0 specification programmatically:

```elixir
defmodule PinchflatWeb.ApiSpec do
  alias OpenApiSpex.{Info, OpenApi, Server}

  def spec do
    %OpenApi{
      info: %Info{
        title: "Pinchflat API",
        version: "1.0.0"
      },
      servers: [%Server{url: "/"}],
      paths: # ... endpoint definitions
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
```

**Access Points:**

- Interactive docs: http://localhost:4000/api/docs (Scalar UI)
- OpenAPI JSON: http://localhost:4000/api/spec

### API Schemas

**Location:** `lib/pinchflat_web/schemas.ex`

Define reusable schemas using `OpenApiSpex.schema/1`:

```elixir
defmodule PinchflatWeb.Schemas.Source do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Source",
    description: "A YouTube channel or playlist source",
    type: :object,
    properties: %{
      id: %Schema{type: :integer, description: "Source ID"},
      custom_name: %Schema{type: :string, description: "Custom name"}
    },
    required: [:id, :custom_name],
    example: %{
      "id" => 1,
      "custom_name" => "My Channel"
    }
  })
end
```

**Available Schemas:**

- `HealthResponse` - Health check response
- `MediaProfile` - Media download configuration
- `Source` - YouTube channel/playlist source
- `MediaItem` - Downloaded media item
- `RecentDownloadsResponse` - List of recent downloads
- `SourcesListResponse` - List of sources
- `CreateSourceRequest` - Create source request body
- `UpdateSourceRequest` - Update source request body

### Scalar API Documentation

**Location:** `lib/pinchflat_web/controllers/api_docs_controller.ex`

Serves Scalar UI loaded from CDN:

```elixir
def index(conn, _params) do
  html(conn, """
  <!DOCTYPE html>
  <html>
    <head>
      <title>Pinchflat API Documentation</title>
    </head>
    <body>
      <script
        id="api-reference"
        data-url="/api/spec"
        data-theme="default"></script>
      <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
    </body>
  </html>
  """)
end
```

**Note:** Scalar is loaded via CDN, not bundled with the app.

### API Endpoints

**Public Endpoints** (`:api` pipeline - no management authentication):

- `GET /healthcheck` - Health check
- `GET /api/spec` - OpenAPI specification JSON

**Management API** (`:management_api` and `:api` pipelines):

- `GET /api/media/recent_downloads` - Recent downloads (limit: 1-500), subject to management API authentication.
- General management API reads and writes require configured Basic Auth credentials when Basic Auth or OIDC is enabled. OIDC browser cookies and scoped share tokens do not authorize these calls. OIDC installations need both `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD` for API clients.
- `/api/share/intake` has separate profile-bound Bearer-token authorization. Migration review holds management API writes. Keep the [API access guide](https://github.com/TheBadFella/Pinchflat-NGX/wiki/API-access) and OpenAPI definitions aligned when changing these contracts.

**Dual-Format Endpoints** (HTML or JSON based on Accept header):

- `GET /sources` - List all sources
- `POST /sources` - Create source
- `GET /sources/{id}` - Get source details
- `PUT /sources/{id}` - Update source
- `DELETE /sources/{id}` - Delete source

**Podcast/Streaming Endpoints:**

- `GET /sources/opml` - OPML feed for podcast clients
- `GET /sources/{uuid}/feed` - RSS feed for source
- `GET /sources/{uuid}/feed_image` - Source feed image
- `GET /media/{uuid}/episode_image` - Episode thumbnail
- `GET /media/{uuid}/stream` - Stream media file (Range support)

### Adding New API Endpoints

1. **Define operation in `api_spec.ex`:**

```elixir
"/api/media/recent_downloads" => %PathItem{
  get: %Operation{
    tags: ["Media"],
    summary: "Get recent downloads",
    operationId: "MediaController.recent_downloads",
    parameters: [
      Operation.parameter(:limit, :query, :integer, "Max items")
    ],
    responses: %{
      200 => Operation.response("Success", "application/json", RecentDownloadsResponse)
    }
  }
}
```

2. **Implement controller with OpenApiSpex plug:**

```elixir
defmodule PinchflatWeb.Api.MediaController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Operation

  @spec recent_downloads(Conn.t(), map()) :: Conn.t()
  def recent_downloads(conn, %{"limit" => limit}) do
    # Implementation
    json(conn, %{data: media_items})
  end
end
```

3. **Add route to `router.ex`:**

```elixir
scope "/api", PinchflatWeb do
  pipe_through :api

  get "/media/recent_downloads", Api.MediaController, :recent_downloads
end
```

4. **Create schemas in `schemas.ex` if needed**

5. **Add tests in `test/pinchflat_web/controllers/`**

### Testing API Documentation

```elixir
test "renders Scalar UI" do
  conn = get(build_conn(), "/api/docs")
  assert html_response(conn, 200) =~ "@scalar/api-reference"
end

test "returns OpenAPI spec" do
  conn = get(build_conn(), "/api/spec")
  assert %{"openapi" => "3.0.0"} = json_response(conn, 200)
end
```

## Pre-commit Hooks

Lefthook runs on commit (configured in `lefthook.yml`):

- `prettier` - JS/CSS/YAML/JSON formatting (runs in Docker)
- `mix format` - Elixir formatting (runs in Docker)
- `typos` - spell checking (runs on host)
- `actionlint` - GitHub Actions validation (runs on host)
- `mix check` - Full CI validation (runs in Docker)

**Note:** `prettier` and `mix format` run inside Docker to avoid permission issues. `typos` and `actionlint` run on the host machine.

**Important:** Read the current `lefthook.yml` before preparing the hook environment. Its Compose `run` commands create one-off containers; do not assume the hooks use `exec` or require an already-running phx container. Use isolated application/database/media state and preserve pre-existing services.

**NEVER skip hooks with `--no-verify`.** Repair the actual environment or check failure, then rerun the normal hooks.

## Verify completed asynchronous workflows

For changes to intake, indexing or background downloads, define success from the user's completed result: persisted source/media state and the expected output path. HTTP acceptance and an enqueued job prove only acceptance. Trace each affected real entry point and the workers it schedules; do not supply test-only metadata that those callers omit.

Add a regression that starts at the affected API or UI boundary, executes the relevant workers with fixture-backed external responses, and asserts the final name and destination. Exercise settings that can accidentally control unrelated behavior, such as artwork disabled, plus retries and user edits during work. Mock external services at the runner/HTTP boundary, not the application workflow being checked.

Before claiming deployment verification, smoke-test the packaged image through the changed entry points in isolated state. Report acceptance, completed processing and filesystem outcomes separately; identify fixture-backed checks and live-provider checks accurately. Scope checks to the change rather than requiring a whole-product audit.
