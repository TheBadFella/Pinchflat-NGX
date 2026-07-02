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
    :ignore_unavailable_media
  ]

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
  end

  defp validate_pinned_version(changeset) do
    if get_field(changeset, :yt_dlp_update_policy) == "pinned" do
      validate_required(changeset, [:yt_dlp_pinned_version])
    else
      changeset
    end
  end
end
