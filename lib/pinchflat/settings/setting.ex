defmodule Pinchflat.Settings.Setting do
  @moduledoc """
  The Setting schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
    :time_format
  ]

  @time_formats ~w(24h 12h)
  @cookie_behaviours ~w(disabled when_needed all_operations)

  @required_fields [
    :onboarding,
    :pro_enabled,
    :video_codec_preference,
    :audio_codec_preference,
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

    field :video_codec_preference, :string
    field :audio_codec_preference, :string
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
    |> validate_number(:extractor_sleep_interval_seconds, greater_than_or_equal_to: 0)
    |> validate_inclusion(:yt_dlp_update_policy, UpdateManager.policies())
    |> validate_pinned_version()
    |> validate_inclusion(:default_cookie_behaviour, @cookie_behaviours)
    |> validate_inclusion(:time_format, @time_formats)
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
end
