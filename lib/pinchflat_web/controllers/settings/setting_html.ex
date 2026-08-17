defmodule PinchflatWeb.Settings.SettingHTML do
  use PinchflatWeb, :html

  embed_templates "setting_html/*"

  @doc """
  Renders a setting form.
  """
  attr :conn, Plug.Conn, required: true
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :concurrency_fields, :map, required: true

  def setting_form(assigns)

  def apprise_server_help do
    url = "https://github.com/caronc/apprise/wiki/URLBasics"

    ~s(Server endpoint for Apprise notifications when new media is found. See <a href="#{url}" class="#{help_link_classes()}" target="_blank">Apprise docs</a> for more information)
  end

  def external_base_url_help do
    "Public Pinchflat URL used to build clickable links in notifications. Include the scheme, for example https://pinchflat.example.com"
  end

  def youtube_api_help do
    url = "https://github.com/kieraneglin/pinchflat/wiki/Generating-a-YouTube-API-key"

    ~s(API key for YouTube Data API v3. Greatly improves the accuracy of Fast Indexing. See <a href="#{url}" class="#{help_link_classes()}" target="_blank">here</a> for details on generating an API key)
  end

  def yt_dlp_update_policy_help do
    ~s(Controls how the bundled yt-dlp is kept up to date. Use "Nightly until stable" to temporarily ride nightly when YouTube breaks something, then auto-return to stable once the fix ships)
  end

  def yt_dlp_pinned_version_help do
    url = "https://github.com/yt-dlp/yt-dlp/releases"

    ~s(The exact yt-dlp version to install and hold, e.g. "2025.12.08". See the <a href="#{url}" class="#{help_link_classes()}" target="_blank">GH releases page</a> for valid versions, or use the check button to validate your entry)
  end

  def concurrency_help(%{locked: true, env_key: key, value: value}, _unlocked_help) do
    ~s(Currently #{value}, set by Docker Compose as <span class="font-mono">#{key}</span>. Remove that variable from your compose file if you want to control this in the UI.)
  end

  def concurrency_help(%{locked: false}, unlocked_help), do: unlocked_help

  defp download_workers_help do
    "How many videos can download at once. Each 1080p job opens two network streams, so start at 1–2 if you see timeouts or 'Network is unreachable'. Takes effect immediately."
  end

  defp indexing_workers_help do
    "How many sources can be indexed at once. Lower this if YouTube starts rate-limiting. Takes effect immediately."
  end

  defp metadata_workers_help do
    "How many thumbnail/NFO/subtitle metadata jobs can run at once. Takes effect immediately."
  end

  defp help_link_classes do
    "underline decoration-theme-on-surface-muted/70 decoration-1 hover:text-theme-on-surface hover:decoration-theme-on-surface"
  end
end
