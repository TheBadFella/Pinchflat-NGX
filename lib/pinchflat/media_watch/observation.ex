defmodule Pinchflat.MediaWatch.Observation do
  @moduledoc """
  A normalized remote observation for a watched media item.

  Adapters reduce backend-specific responses to this struct so scheduling,
  comparison and notification do not depend on yt-dlp or the YouTube API.
  `:unknown` means the observation could not establish remote state; it is
  never treated as deletion or as zero duration.
  """

  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @duration_tolerance_seconds 2

  @type availability :: :public | :unlisted | :private | :unavailable | :unknown

  @type t :: %__MODULE__{
          backend: atom(),
          observed_at: DateTime.t(),
          availability: availability(),
          duration_seconds: non_neg_integer() | nil,
          livestream: boolean(),
          reason: term()
        }

  defstruct [:backend, :observed_at, :availability, :duration_seconds, :livestream, :reason]

  @doc "Builds an explicit unknown observation that must not change confidence."
  def unknown(backend, reason, observed_at \\ nil) do
    %__MODULE__{
      backend: backend,
      observed_at: observed_at || utc_now(),
      availability: :unknown,
      duration_seconds: nil,
      livestream: false,
      reason: reason
    }
  end

  @doc "Normalizes a yt-dlp metadata response."
  def from_yt_dlp(%YtDlpMedia{} = media, observed_at \\ nil) do
    %__MODULE__{
      backend: :yt_dlp,
      observed_at: observed_at || utc_now(),
      availability: normalize_yt_dlp_availability(media.availability),
      duration_seconds: media.duration_seconds,
      livestream: media.livestream == true,
      reason: nil
    }
  end

  @doc "Normalizes a YouTube Data API videos.list item."
  def from_youtube_api(item, observed_at \\ nil)

  def from_youtube_api(item, observed_at) when is_map(item) do
    details = Map.get(item, "contentDetails") || %{}
    status = Map.get(item, "status") || %{}
    snippet = Map.get(item, "snippet") || %{}

    %__MODULE__{
      backend: :youtube_api,
      observed_at: observed_at || utc_now(),
      availability: normalize_privacy_status(Map.get(status, "privacyStatus")),
      duration_seconds: parse_iso8601_duration(Map.get(details, "duration")),
      livestream: Map.get(snippet, "liveBroadcastContent") in ["live", "upcoming"],
      reason: nil
    }
  end

  def from_youtube_api(_other, observed_at), do: unknown(:youtube_api, :invalid_item, observed_at)

  @doc """
  Classifies the observation against a watch's immutable baseline and current
  state. Returns :unknown, :unchanged, or `{kind, old_value, new_value}` where
  kind is :duration, :visibility, :unavailable or :restored.
  """
  def classify(_watch, %__MODULE__{availability: :unknown} = observation) do
    {:unknown, observation.reason}
  end

  def classify(_watch, %__MODULE__{livestream: true}), do: :unchanged

  def classify(watch, %__MODULE__{} = observation) do
    current_visibility = watch.current_visibility || watch.baseline_visibility
    current_duration = Map.get(watch, :confirmed_upstream_duration_seconds) || watch.baseline_upstream_duration_seconds

    cond do
      current_visibility == nil and observation.availability in [:public, :unlisted] and
          is_nil(observation.duration_seconds) ->
        {:unknown, :missing_duration}

      current_visibility == nil ->
        :unchanged

      observation.availability in [:unavailable, :private] and
          current_visibility != to_string(observation.availability) ->
        {:unavailable, current_visibility, to_string(observation.availability)}

      observation.availability == :unlisted and current_visibility != "unlisted" ->
        {:visibility, current_visibility, "unlisted"}

      observation.availability == :public and current_visibility in ["unlisted", "unavailable", "private"] ->
        {:restored, current_visibility, "public"}

      observation.availability in [:public, :unlisted] and is_nil(observation.duration_seconds) ->
        {:unknown, :missing_duration}

      duration_changed?(current_duration, observation.duration_seconds) ->
        {:duration, current_duration, observation.duration_seconds}

      true ->
        :unchanged
    end
  end

  @doc "Returns true only for known durations more than two seconds apart."
  def duration_changed?(baseline, observed)
      when is_integer(baseline) and is_integer(observed) do
    abs(baseline - observed) > @duration_tolerance_seconds
  end

  def duration_changed?(_baseline, _observed), do: false

  @doc "Returns the stable event kind name for a classified change."
  def event_kind({kind, _old, _new}) when kind in [:duration, :visibility, :unavailable], do: to_string(kind)
  def event_kind({:restored, _old, _new}), do: "restored"
  def event_kind(_other), do: nil

  @doc "Returns the value to persist as the current visibility."
  def current_visibility(%__MODULE__{availability: :unknown}), do: nil
  def current_visibility(%__MODULE__{availability: availability}), do: to_string(availability)

  @doc "Returns the event fingerprint for a classified change."
  def fingerprint(kind, old_value, new_value), do: "#{kind}:#{old_value}->#{new_value}"

  defp normalize_yt_dlp_availability(:public), do: :public
  defp normalize_yt_dlp_availability(:unlisted), do: :unlisted
  defp normalize_yt_dlp_availability(:private), do: :private

  defp normalize_yt_dlp_availability(value) when value in [:subscriber_only, :premium_only, :needs_auth],
    do: :unavailable

  defp normalize_yt_dlp_availability(_value), do: :unknown

  defp normalize_privacy_status("public"), do: :public
  defp normalize_privacy_status("unlisted"), do: :unlisted
  defp normalize_privacy_status("private"), do: :private
  defp normalize_privacy_status(_value), do: :unknown

  @doc false
  def parse_iso8601_duration(nil), do: nil

  def parse_iso8601_duration("P" <> rest) do
    if Regex.match?(~r/\d/, rest) do
      parse_iso8601_components(rest)
    else
      nil
    end
  end

  def parse_iso8601_duration(_value), do: nil

  defp parse_iso8601_components(rest) do
    {days_part, time_part} =
      case String.split(rest, "T", parts: 2) do
        [days] -> {days, ""}
        [days, time] -> {days, time}
      end

    days = parse_unit(days_part, "D")
    hours = parse_unit(time_part, "H")
    minutes = parse_unit(time_part, "M")
    seconds = parse_unit(time_part, "S")

    days * 86_400 + hours * 3_600 + minutes * 60 + seconds
  end

  defp parse_unit(part, suffix) do
    case Regex.run(~r/(\d+)#{suffix}/, part) do
      [_, value] -> String.to_integer(value)
      _ -> 0
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
