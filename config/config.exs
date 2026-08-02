# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pinchflat,
  ecto_repos: [Pinchflat.Repo],
  generators: [timestamp_type: :utc_datetime],
  env: config_env(),
  # Specifying backend data here makes mocking and local testing SUPER easy
  yt_dlp_executable: System.find_executable("yt-dlp"),
  apprise_executable: System.find_executable("apprise"),
  yt_dlp_runner: Pinchflat.YtDlp.CommandRunner,
  apprise_runner: Pinchflat.Lifecycle.Notifications.CommandRunner,
  media_directory: "/downloads",
  # The user may or may not store metadata for their needs, but the app will always store its copy
  metadata_directory: "/config/metadata",
  extras_directory: "/config/extras",
  tmpfile_directory: Path.join([System.tmp_dir!(), "pinchflat", "data"]),
  # Setting BASIC_AUTH_USERNAME and BASIC_AUTH_PASSWORD implies you want to use basic auth.
  # If either is unset, basic auth will not be used.
  basic_auth_username: "",
  basic_auth_password: "",
  expose_feed_endpoints: false,
  file_watcher_poll_interval: 1000,
  timezone: "UTC",
  base_route_path: "/"

config :pinchflat, Pinchflat.Repo,
  journal_mode: :wal,
  # Explicit (matches exqlite's default): NORMAL is safe under WAL — only a
  # transaction can be lost on OS/power loss, never corruption — and avoids a
  # per-write fsync. Pinned here so a future driver-default change can't regress it.
  synchronous: :normal,
  # BEGIN IMMEDIATE for every transaction. The default DEFERRED mode starts as a
  # read transaction and upgrades to a write on the first write statement — under
  # WAL that upgrade fails instantly with SQLITE_BUSY (busy_timeout never runs)
  # whenever another connection committed since the read snapshot was taken, which
  # is constant under an active queue (Oban's stager does exactly this
  # select-then-update shape every second). IMMEDIATE takes the write lock at
  # BEGIN, so contending writers queue on busy_timeout instead of erroring.
  default_transaction_mode: :immediate,
  # Explicit (matches ecto_sqlite3's defaults — negative = KiB, so ~64 MB page
  # cache per connection): keeps the reconcile working set off the disk
  # and pins us against a future driver-default change.
  cache_size: -64_000,
  temp_store: :memory,
  # Generous so slow writes on weak hardware (or a database VACUUM) surface as
  # brief waits instead of "database is locked" errors
  busy_timeout: 30_000,
  # Must exceed busy_timeout: Ecto's default per-query timeout is 15s, which
  # would kill a write while it's still legitimately queued on the busy handler
  timeout: 45_000,
  # Small pools starved the LiveView/other jobs while a reconcile held connections.
  # WAL lets extra readers run without blocking, so a larger pool is cheap.
  # Overridable at runtime via DATABASE_POOL_SIZE.
  pool_size: 10

# Configures the endpoint
config :pinchflat, PinchflatWeb.Endpoint,
  url: [host: "localhost", port: 8945],
  # NOTE: this must be updated if ever deployed traditionally (ie: not self-hosted)
  check_origin: false,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: PinchflatWeb.ErrorHTML, json: PinchflatWeb.ErrorJSON],
    # Error pages use a dedicated standalone layout (no `layout:` — inner layout
    # stays disabled). The app/root layouts need assigns (flash) and database
    # access that the error-rendering conn doesn't have.
    root_layout: {PinchflatWeb.Layouts, :error}
  ],
  pubsub_server: Pinchflat.PubSub,
  live_view: [signing_salt: "/t5878kO"]

config :pinchflat, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  repo: Pinchflat.Repo

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :pinchflat, Pinchflat.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.27.4",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.2.2",
  default: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger. Timestamps are rendered in the app's configured
# timezone by Pinchflat.LoggerFormatter (utc_log: true so it receives UTC and
# converts) rather than the BEAM's OS-derived local time, which didn't honour TZ.
config :logger, :default_formatter,
  format: {Pinchflat.LoggerFormatter, :format},
  metadata: [:request_id],
  utc_log: true

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :pinchflat, Pinchflat.PromEx,
  disabled: true,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  metrics_server: :disabled

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
