defmodule PinchflatWeb.MediaItems.MediaItemHTML do
  use PinchflatWeb, :html

  alias PinchflatWeb.Helpers.MediaCleanupHelpers

  embed_templates "media_item_html/*"

  @doc """
  Renders a media item form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def media_item_form(assigns)

  def media_file_exists?(media_item) do
    !!media_item.media_filepath and File.exists?(media_item.media_filepath)
  end

  @doc """
  Labels the last observed remote visibility without implying deletion when the
  remote state was never established.
  """
  def watch_visibility_label(nil), do: "not observed yet"
  def watch_visibility_label("public"), do: "public"
  def watch_visibility_label("unlisted"), do: "unlisted"
  def watch_visibility_label("private"), do: "private"
  def watch_visibility_label("unavailable"), do: "unavailable or removed"
  def watch_visibility_label("unknown"), do: "unknown"
  def watch_visibility_label(other), do: to_string(other)

  @doc """
  Labels the confirmation state as distinct from a media download failure.
  """
  def watch_change_label("confirmed"), do: "confirmed change"
  def watch_change_label("suspected"), do: "suspected change"
  def watch_change_label(_state), do: "no change confirmed"

  @doc """
  Returns a clear explanation of why automatic replacement is blocked.
  """
  def watch_hold_explanation(%{confirmed_state: "confirmed", suspected_kind: "duration"} = watch)
      when not is_nil(watch.baseline_upstream_duration_seconds) and
             not is_nil(watch.current_upstream_duration_seconds) do
    "Upstream video duration changed from #{watch.baseline_upstream_duration_seconds}s to #{watch.current_upstream_duration_seconds}s. Automatic replacement is blocked so the modified video does not overwrite your original file."
  end

  def watch_hold_explanation(%{confirmed_state: "confirmed", suspected_kind: "duration"}) do
    "Upstream video duration changed. Automatic replacement is blocked so the modified video does not overwrite your original file."
  end

  def watch_hold_explanation(%{confirmed_state: "confirmed", suspected_kind: "restored"} = watch) do
    "Video visibility was restored to #{watch_visibility_label(watch.current_visibility)}. Automatic replacement is blocked to protect the original file."
  end

  def watch_hold_explanation(%{confirmed_state: "confirmed", suspected_kind: "unlisted"}) do
    "Video visibility was changed to unlisted. Automatic replacement is blocked to protect the original file."
  end

  def watch_hold_explanation(%{confirmed_state: "confirmed", suspected_kind: "unavailable"}) do
    "Video is unavailable or set to private upstream. Automatic replacement is blocked to protect the original file."
  end

  def watch_hold_explanation(%{confirmed_state: "confirmed"} = watch) when is_binary(watch.suspected_kind) do
    "A change (#{watch.suspected_kind}) to this video has been confirmed. Automatic replacement is blocked to protect the original file."
  end

  def watch_hold_explanation(%{confirmed_state: "suspected"} = watch) when is_binary(watch.suspected_kind) do
    "A potential change (#{watch.suspected_kind}) was detected and is awaiting confirmation. Automatic replacement is blocked."
  end

  def watch_hold_explanation(_watch) do
    "Automatic replacement is blocked to protect the original."
  end

  @doc """
  Formats duration delta between current and baseline.
  """
  def watch_duration_delta(nil, _baseline), do: nil
  def watch_duration_delta(_current, nil), do: nil
  def watch_duration_delta(current, baseline) when current == baseline, do: nil
  def watch_duration_delta(current, baseline) when current > baseline, do: "+#{current - baseline}s"
  def watch_duration_delta(current, baseline) when current < baseline, do: "-#{baseline - current}s"

  @doc """
  Returns a human-readable label for a watch transition event kind.
  """
  def watch_event_label("duration"), do: "Duration edited"
  def watch_event_label("restored"), do: "Visibility restored to public"
  def watch_event_label("unlisted"), do: "Made unlisted"
  def watch_event_label("visibility"), do: "Visibility changed"
  def watch_event_label("unavailable"), do: "Video unavailable or private"
  def watch_event_label(kind), do: "Event: #{kind}"

  @doc """
  Summarizes the transition values of a watch event.
  """
  def watch_event_summary(%{kind: "duration"} = event), do: "#{event.old_value}s → #{event.new_value}s"
  def watch_event_summary(%{kind: "restored"} = event), do: "#{event.old_value} → #{event.new_value}"

  def watch_event_summary(%{old_value: old_val, new_value: new_val}) when not is_nil(old_val) and not is_nil(new_val),
    do: "#{old_val} → #{new_val}"

  def watch_event_summary(%{new_value: new_val}) when not is_nil(new_val), do: "#{new_val}"
  def watch_event_summary(_event), do: ""

  @doc """
  Returns theme badge classes for an alert delivery state.
  """
  def watch_delivery_badge_class("sent"), do: "bg-theme-success/20 text-theme-success border border-theme-success/30"
  def watch_delivery_badge_class("pending"), do: "bg-theme-warning/20 text-theme-warning border border-theme-warning/30"
  def watch_delivery_badge_class("failed"), do: "bg-theme-danger/20 text-theme-danger border border-theme-danger/30"
  def watch_delivery_badge_class("skipped"), do: "bg-theme-surface-accent text-theme-on-surface-muted"
  def watch_delivery_badge_class(_state), do: "bg-theme-surface-accent text-theme-on-surface"

  def watch_archive_summary({:ok, %{bytes: bytes, manifest_path: path}}) do
    %{bytes: bytes, manifest_path: path}
  end

  def watch_archive_summary(%{bytes: bytes, manifest_path: path}) do
    %{bytes: bytes, manifest_path: path}
  end

  def watch_archive_summary(_summary), do: nil

  def watch_archive_download_label("thumbnail"), do: "Download thumbnail"
  def watch_archive_download_label("metadata"), do: "Download metadata"
  def watch_archive_download_label("nfo"), do: "Download NFO file"
  def watch_archive_download_label("internal-thumbnail"), do: "Download cached thumbnail"
  def watch_archive_download_label("internal-metadata"), do: "Download cached metadata"
  def watch_archive_download_label("subtitle-" <> language), do: "Download subtitles (#{language})"
  def watch_archive_download_label(_role), do: "Download associated file"

  def media_type(media_item) do
    case Path.extname(media_item.media_filepath) do
      ext when ext in [".mp4", ".webm", ".mkv"] -> :video
      ext when ext in [".mp3", ".m4a", ".opus"] -> :audio
      _ -> :unknown
    end
  end

  @doc """
  Formats a DateTime according to the user's timezone defined in Compose/system environment,
  falling back to UTC.
  """
  def format_watch_timestamp(datetime, format \\ "%Y-%m-%d %H:%M:%S")
  def format_watch_timestamp(nil, _format), do: "-"

  def format_watch_timestamp(%DateTime{} = dt, format) do
    tz = Application.get_env(:pinchflat, :timezone) || "UTC"

    shifted =
      case DateTime.shift_zone(dt, tz) do
        {:ok, shifted} -> shifted
        _ -> dt
      end

    Calendar.strftime(shifted, format)
  end

  def format_watch_timestamp(%NaiveDateTime{} = ndt, format) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_watch_timestamp(format)
  end
end
