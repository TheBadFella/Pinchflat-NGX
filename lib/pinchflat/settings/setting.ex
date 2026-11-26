defmodule Pinchflat.Settings.Setting do
  @moduledoc """
  The Setting schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Settings.CodecPreferences
  alias Pinchflat.Sources.Source
  alias Pinchflat.YtDlp.UpdateManager

  @allowed_fields [
    :onboarding,
    :pro_enabled,
    :yt_dlp_version,
    :yt_dlp_update_policy,
    :yt_dlp_pinned_version,
    :yt_dlp_nightly_baseline,
    :apprise_version,
    :apprise_server,
    :notification_include_video_titles,
    :external_base_url,
    :video_codec_preference,
    :audio_codec_preference,
    :youtube_api_key,
    :extractor_sleep_interval_seconds,
    :download_throughput_limit,
    :restrict_filenames,
    :ignore_unavailable_media,
    :database_maintenance_enabled,
    :default_cookie_behaviour,
    :time_format,
    :yt_dlp_download_worker_concurrency,
    :yt_dlp_index_worker_concurrency,
    :yt_dlp_remote_metadata_worker_concurrency,
    :channel_discovery_enabled,
    :channel_discovery_mentions_enabled,
    :channel_discovery_featured_enabled,
    :postgres_backup_retention_count,
    :download_space_protection_enabled,
    :download_space_protection_threshold_bytes,
    :download_space_protection_blocked,
    :download_space_protection_blocked_reason,
    :download_space_protection_blocked_location,
    :download_space_protection_free_bytes,
    :download_space_protection_blocked_at,
    :download_space_protection_alerted_at,
    :cookie_health_monitoring_enabled,
    :cookie_health_check_interval_hours,
    :cookie_health_canary_url,
    :cookie_health_status,
    :cookie_health_last_checked_at,
    :cookie_health_last_authenticated_at,
    :cookie_health_last_error,
    :cookie_health_cookie_digest,
    :cookie_health_alert_sent_for_digest,
    :plex_enabled,
    :plex_url,
    :plex_token,
    :plex_library_section_id,
    :jellyfin_enabled,
    :jellyfin_url,
    :jellyfin_api_key,
    :jellyfin_library_id,
    :emby_enabled,
    :emby_url,
    :emby_api_key,
    :emby_confirm_full_scan,
    :default_media_profile_id
  ]

  @time_formats ~w(24h 12h)
  @cookie_behaviours ~w(disabled when_needed all_operations)

  # Codec preferences are intentionally excluded: a blank value is meaningful
  # (no application override for that stream) and is stored as an empty string.
  @required_fields [
    :onboarding,
    :pro_enabled,
    :extractor_sleep_interval_seconds
  ]

  schema "settings" do
    field :onboarding, :boolean, default: true
    field :pro_enabled, :boolean, default: false
    field :yt_dlp_version, :string
    field :yt_dlp_update_policy, :string, default: "stable"
    field :yt_dlp_pinned_version, :string
    field :yt_dlp_nightly_baseline, :string
    field :apprise_version, :string
    field :apprise_server, :string
    field :notification_include_video_titles, :boolean, default: false
    field :external_base_url, :string
    field :youtube_api_key, :string
    field :route_token, :string
    field :extractor_sleep_interval_seconds, :integer, default: 0
    # This is a string because it accepts values like "100K" or "4.2M"
    field :download_throughput_limit, :string
    field :restrict_filenames, :boolean, default: false
    field :ignore_unavailable_media, :boolean, default: false
    field :database_maintenance_enabled, :boolean, default: false

    # The cookie behaviour pre-selected when adding a new source:
    # "disabled" | "when_needed" | "all_operations"
    field :default_cookie_behaviour, :string, default: "disabled"

    # Clock used when rendering timestamps in the UI: "24h" | "12h"
    field :time_format, :string, default: "24h"

    # Oban worker limits for yt-dlp-backed queues. Nil means "use env vars".
    field :yt_dlp_download_worker_concurrency, :integer
    field :yt_dlp_index_worker_concurrency, :integer
    field :yt_dlp_remote_metadata_worker_concurrency, :integer

    # Channel discovery is opt-in at both the feature and generator level.
    field :channel_discovery_enabled, :boolean, default: false
    field :channel_discovery_mentions_enabled, :boolean, default: false
    field :channel_discovery_featured_enabled, :boolean, default: false
    field :postgres_backup_retention_count, :integer, default: 7

    field :download_space_protection_enabled, :boolean, default: false
    field :download_space_protection_threshold_bytes, :integer, default: 10_737_418_240
    field :download_space_protection_blocked, :boolean, default: false
    field :download_space_protection_blocked_reason, :string
    field :download_space_protection_blocked_location, :string
    field :download_space_protection_free_bytes, :integer
    field :download_space_protection_blocked_at, :utc_datetime
    field :download_space_protection_alerted_at, :utc_datetime

    field :cookie_health_monitoring_enabled, :boolean, default: false
    field :cookie_health_check_interval_hours, :integer, default: 6
    field :cookie_health_canary_url, :string
    field :cookie_health_status, :string, default: "not_configured"
    field :cookie_health_last_checked_at, :utc_datetime
    field :cookie_health_last_authenticated_at, :utc_datetime
    field :cookie_health_last_error, :string
    field :cookie_health_cookie_digest, :string
    field :cookie_health_alert_sent_for_digest, :string

    field :video_codec_preference, :string
    field :audio_codec_preference, :string

    field :plex_enabled, :boolean, default: false
    field :plex_url, :string
    field :plex_token, :string, redact: true
    field :plex_library_section_id, :string, default: "all"

    field :jellyfin_enabled, :boolean, default: false
    field :jellyfin_url, :string
    field :jellyfin_api_key, :string, redact: true
    field :jellyfin_library_id, :string

    field :emby_enabled, :boolean, default: false
    field :emby_url, :string
    field :emby_api_key, :string, redact: true
    field :emby_confirm_full_scan, :boolean, default: false

    belongs_to :default_media_profile, Pinchflat.Profiles.MediaProfile
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @allowed_fields)
    |> normalize_codec_preferences(attrs)
    |> validate_required(@required_fields)
    |> validate_number(:extractor_sleep_interval_seconds, greater_than_or_equal_to: 0)
    |> validate_inclusion(:yt_dlp_update_policy, UpdateManager.policies())
    |> validate_pinned_version()
    |> validate_inclusion(:default_cookie_behaviour, @cookie_behaviours)
    |> validate_inclusion(:time_format, @time_formats)
    |> validate_number(:yt_dlp_download_worker_concurrency, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
    |> validate_number(:yt_dlp_index_worker_concurrency, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
    |> validate_number(:yt_dlp_remote_metadata_worker_concurrency,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    |> validate_number(:postgres_backup_retention_count, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:download_space_protection_threshold_bytes, greater_than_or_equal_to: 1)
    |> validate_number(:cookie_health_check_interval_hours, greater_than_or_equal_to: 1, less_than_or_equal_to: 168)
    |> validate_canary_url()
    |> validate_media_server_settings()
    |> validate_codec_preferences(attrs)
    |> foreign_key_constraint(:default_media_profile_id)
  end

  @doc """
  The allowed cookie behaviours (matching Source.cookie_behaviour).
  """
  def cookie_behaviours, do: @cookie_behaviours

  @doc """
  The allowed time formats.
  """
  def time_formats, do: @time_formats

  defp validate_pinned_version(changeset) do
    if get_field(changeset, :yt_dlp_update_policy) == "pinned" do
      validate_required(changeset, [:yt_dlp_pinned_version])
    else
      changeset
    end
  end

  defp validate_canary_url(changeset) do
    case get_change(changeset, :cookie_health_canary_url) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :cookie_health_canary_url, nil)

      url when is_binary(url) ->
        trimmed = String.trim(url)

        if Source.youtube_video_url?(trimmed) do
          put_change(changeset, :cookie_health_canary_url, trimmed)
        else
          add_error(
            changeset,
            :cookie_health_canary_url,
            "must be a valid YouTube video or shorts URL"
          )
        end
    end
  end

  defp validate_media_server_settings(changeset) do
    changeset
    |> validate_server_config(:plex_enabled, :plex_url, :plex_token)
    |> validate_server_config(:jellyfin_enabled, :jellyfin_url, :jellyfin_api_key)
    |> validate_server_config(:emby_enabled, :emby_url, :emby_api_key)
  end

  defp validate_server_config(changeset, enabled_field, url_field, credential_field) do
    if get_field(changeset, enabled_field) do
      changeset
      |> validate_required([url_field, credential_field])
      |> validate_http_url(url_field)
    else
      changeset
    end
  end

  defp validate_http_url(changeset, field) do
    case Pinchflat.MediaServers.validate_server_url(get_field(changeset, field)) do
      {:ok, url} -> put_change(changeset, field, url)
      {:error, _} -> add_error(changeset, field, "must be an HTTP or HTTPS URL without credentials, query or fragment")
    end
  end

  # The DB columns are NOT NULL and a blank list is meaningful, so normalize a
  # blank submission to "" instead of letting Ecto turn it into nil. Unchanged
  # preferences are left alone so unrelated saves never rewrite them.
  # Submitted tokens are canonicalized to match select options (e.g. "H264" -> "avc", "aac" -> "m4a").
  defp normalize_codec_preferences(changeset, attrs) do
    Enum.reduce([:video_codec_preference, :audio_codec_preference], changeset, fn field, acc ->
      case submitted_value(acc, attrs, field) do
        :unchanged ->
          acc

        value ->
          kind = if field == :video_codec_preference, do: :video, else: :audio

          canonical =
            value
            |> CodecPreferences.parse()
            |> CodecPreferences.canonical_tokens(kind)
            |> CodecPreferences.format()

          put_change(acc, field, canonical)
      end
    end)
  end

  # Ecto's `cast` turns a blank text input into nil, which the NOT NULL columns
  # reject. Read the raw submitted value so a cleared list is stored as "" -
  # the meaning the rest of the app relies on.
  defp submitted_value(changeset, attrs, field) do
    case attr_value(attrs, field) do
      nil ->
        if is_nil(get_change(changeset, field)), do: :unchanged, else: ""

      value ->
        value |> to_string() |> String.trim()
    end
  end

  defp attr_value(attrs, field) when is_list(attrs), do: attrs |> Map.new() |> attr_value(field)
  defp attr_value(attrs, field) when is_map(attrs), do: Map.get(attrs, field) || Map.get(attrs, to_string(field))

  defp validate_codec_preferences(changeset, attrs) do
    changeset
    |> validate_codec_preference(:video_codec_preference, :video, attrs)
    |> validate_codec_preference(:audio_codec_preference, :audio, attrs)
  end

  defp validate_codec_preference(changeset, field, kind, attrs) do
    case submitted_value(changeset, attrs, field) do
      :unchanged ->
        changeset

      value ->
        case CodecPreferences.validate(kind, value) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, field, message)
        end
    end
  end
end
