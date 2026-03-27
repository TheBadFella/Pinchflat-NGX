# Agent Guidelines for Pinchflat

Guidelines for AI agents working on this Elixir/Phoenix codebase.

## Project Overview

Pinchflat is a self-hosted media management app using:

- **Backend**: Elixir 1.17+, Phoenix 1.7, Ecto with SQLite
- **Frontend**: Phoenix LiveView, Tailwind CSS, esbuild
- **Background Jobs**: Oban
- **Testing**: ExUnit with Mox for mocking

## Build/Lint/Test Commands

**Always use Docker for development and testing.** The project has permission issues when mixing Docker and local builds.

## Git And PR Policy

- Create pull requests against this fork's `origin` remote unless the user explicitly says otherwise.
- Do not open pull requests against `upstream`.

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
- Use shared semantic theme classes from `assets/css/app.css` instead of page-local hardcoded palette combinations.
- Do not introduce raw palette classes like `text-red-*`, `bg-red-*`, `border-green-*`, or `zinc-*` in `lib/pinchflat_web`.
- When a new UI state is needed, add a semantic class or token rather than styling a single screen inline.
- Run `yarn run ui:check-theme` after UI changes that touch `lib/pinchflat_web`.

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

**Public Endpoints** (`:api` pipeline - no auth, no CSRF):

- `GET /api/spec` - OpenAPI specification JSON
- `GET /api/media/recent_downloads` - Recent downloads (limit: 1-500)

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
- `mix check` - Full CI validation (runs in Docker, requires running container)

**Note:** `prettier` and `mix format` run inside Docker to avoid permission issues. `typos` and `actionlint` run on the host machine.

**Important:** The `mix check` hook uses `docker compose exec` which requires the phx container to be running. Before committing, ensure the container is started with `docker compose up -d phx`.

**NEVER skip hooks with `--no-verify`.** If a hook fails due to the container not running, start it first.
