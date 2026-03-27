defmodule PinchflatWeb.Router do
  use PinchflatWeb, :router
  import PinchflatWeb.Plugs
  import Phoenix.LiveDashboard.Router

  # IMPORTANT: `strip_trailing_extension` in endpoint.ex removes
  # the extension from the path
  pipeline :browser do
    plug :basic_auth
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PinchflatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :allow_iframe_embed
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PinchflatWeb.ApiSpec
  end

  scope "/", PinchflatWeb do
    pipe_through [:maybe_basic_auth, :token_protected_route]

    # has to match before /sources/:id
    get "/sources/opml", Podcasts.PodcastController, :opml_feed
  end

  # Routes in here _may not be_ protected by basic auth. This is necessary for
  # media streaming to work for RSS podcast feeds.
  scope "/", PinchflatWeb do
    pipe_through :maybe_basic_auth

    get "/sources/:uuid/feed", Podcasts.PodcastController, :rss_feed
    get "/sources/:uuid/feed_image", Podcasts.PodcastController, :feed_image
    get "/media/:uuid/episode_image", Podcasts.PodcastController, :episode_image

    get "/media/:uuid/stream", MediaItems.MediaItemController, :stream
  end

  scope "/", PinchflatWeb do
    pipe_through :browser

    get "/", Pages.PageController, :home
    post "/sources/cookies/upload", Sources.SourceController, :upload_cookies
    post "/sources/cookies/save", Sources.SourceController, :save_cookies

    resources "/media_profiles", MediaProfiles.MediaProfileController
    resources "/search", Searches.SearchController, only: [:show], singleton: true

    resources "/settings", Settings.SettingController, only: [:show, :update], singleton: true
    get "/app_info", Settings.SettingController, :app_info
    get "/download_logs", Settings.SettingController, :download_logs

    resources "/sources", Sources.SourceController do
      post "/restore_automatic_downloads", Sources.SourceController, :restore_automatic_downloads
      post "/start_all", Sources.SourceController, :start_all
      post "/pause_all", Sources.SourceController, :pause_all
      post "/stop_all", Sources.SourceController, :stop_all
      post "/apply_selection", Sources.SourceController, :apply_selection
      post "/force_download_pending", Sources.SourceController, :force_download_pending
      post "/force_redownload", Sources.SourceController, :force_redownload
      post "/force_index", Sources.SourceController, :force_index
      post "/force_metadata_refresh", Sources.SourceController, :force_metadata_refresh
      post "/sync_files_on_disk", Sources.SourceController, :sync_files_on_disk

      resources "/media", MediaItems.MediaItemController, only: [:show, :edit, :update, :delete] do
        post "/force_download", MediaItems.MediaItemController, :force_download
      end
    end
  end

  # No auth or CSRF protection for the health check endpoint
  scope "/", PinchflatWeb do
    pipe_through :api

    get "/healthcheck", HealthController, :check, log: false
  end

  # No auth or CSRF protection for internal API endpoints
  scope "/api", PinchflatWeb do
    pipe_through :api

    # Media endpoints
    get "/media/recent_downloads", Api.MediaController, :recent_downloads
    get "/media", Api.MediaController, :index
    get "/media/:id", Api.MediaController, :show
    delete "/media/:id", Api.MediaController, :delete
    post "/media/:id/actions/download", Api.MediaController, :download

    # Media profile endpoints
    get "/media_profiles", Api.MediaProfileController, :index
    post "/media_profiles", Api.MediaProfileController, :create
    get "/media_profiles/:id", Api.MediaProfileController, :show
    put "/media_profiles/:id", Api.MediaProfileController, :update
    delete "/media_profiles/:id", Api.MediaProfileController, :delete

    # Search endpoint
    get "/search", Api.SearchController, :search

    # Source action endpoints
    post "/sources/:id/actions/download_pending", Api.SourceActionsController, :download_pending
    post "/sources/:id/actions/redownload", Api.SourceActionsController, :redownload
    post "/sources/:id/actions/index", Api.SourceActionsController, :index
    post "/sources/:id/actions/refresh_metadata", Api.SourceActionsController, :refresh_metadata
    post "/sources/:id/actions/sync_files", Api.SourceActionsController, :sync_files

    # Task endpoints
    get "/tasks", Api.TaskController, :index
    get "/tasks/:id", Api.TaskController, :show
    delete "/tasks/:id", Api.TaskController, :delete

    # Statistics endpoint
    get "/stats", Api.StatsController, :index

    # OpenAPI spec
    get "/spec", ApiSpecController, :spec
  end

  # Scalar API documentation UI
  scope "/api/docs", PinchflatWeb do
    pipe_through :browser

    get "/", ApiDocsController, :index
  end

  scope "/dev" do
    pipe_through :browser

    live_dashboard "/dashboard",
      metrics: PinchflatWeb.Telemetry,
      ecto_repos: [Pinchflat.Repo]
  end
end
