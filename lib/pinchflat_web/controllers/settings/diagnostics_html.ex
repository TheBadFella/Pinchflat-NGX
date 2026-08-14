defmodule PinchflatWeb.Settings.DiagnosticsHTML do
  use PinchflatWeb, :html

  alias Pinchflat.Settings
  alias Pinchflat.Diagnostics.QueueDiagnostics

  embed_templates "diagnostics_html/*"

  def queue_stats do
    QueueDiagnostics.get_all_queue_stats()
  end

  def retryable_jobs do
    QueueDiagnostics.get_retryable_jobs(20)
  end

  def discarded_jobs do
    QueueDiagnostics.get_discarded_jobs(20)
  end

  def stuck_jobs do
    QueueDiagnostics.get_stuck_jobs(30)
  end

  def system_stats do
    QueueDiagnostics.get_system_stats()
  end

  def diagnostic_info_string do
    """
    - App Version: #{Application.spec(:pinchflat)[:vsn]}
    - yt-dlp Version: #{Settings.get!(:yt_dlp_version)}
    - yt-dlp Update Behavior: #{Pinchflat.YtDlp.UpdateManager.humanize_policy(Settings.get!(:yt_dlp_update_policy))}
    - Apprise Version: #{Settings.get!(:apprise_version)}
    - System Architecture: #{to_string(:erlang.system_info(:system_architecture))}
    - Timezone: #{Application.get_env(:pinchflat, :timezone)}
    """
  end

  def format_worker_name(worker) do
    worker
    |> String.split(".")
    |> Enum.at(-1)
    |> format_worker_short_name()
  end

  defp format_worker_short_name("FastIndexingWorker"), do: "Fast Indexing"
  defp format_worker_short_name("MediaDownloadWorker"), do: "Download"
  defp format_worker_short_name("MediaCollectionIndexingWorker"), do: "Indexing"
  defp format_worker_short_name("MediaQualityUpgradeWorker"), do: "Quality Upgrade"
  defp format_worker_short_name("SourceMetadataStorageWorker"), do: "Metadata"
  defp format_worker_short_name(other), do: other

  def format_queue_name(queue) do
    queue
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def format_datetime(nil), do: "-"

  def format_datetime(datetime) do
    # Oban stores these timestamps in UTC; convert to the configured timezone
    # (TIMEZONE / TZ env var) before rendering so the page reads in local time.
    # The 12h/24h clock follows the `time_format` setting.
    tz = Application.get_env(:pinchflat, :timezone) || "Etc/UTC"

    datetime
    |> to_utc_datetime()
    |> shift_timezone(tz)
    |> Calendar.strftime(datetime_format())
  end

  defp shift_timezone(dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> shifted
      _ -> dt
    end
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp datetime_format do
    case Settings.get!(:time_format) do
      "12h" -> "%Y-%m-%d %I:%M:%S %p"
      _ -> "%Y-%m-%d %H:%M:%S"
    end
  end

  def extract_last_error(errors) when is_list(errors) and errors != [] do
    errors
    |> List.last()
    |> Map.get("error", "Unknown error")
    |> String.slice(0, 200)
  end

  def extract_last_error(_), do: "No error details"

  def queue_health_class(stats) do
    cond do
      stats.paused -> "theme-status-card-warning bg-theme-warning/10"
      stats.retryable > 0 -> "theme-status-card-error bg-theme-error/10"
      stats.running >= stats.limit and stats.available > 0 -> "theme-status-card-info bg-theme-primary/10"
      true -> "theme-status-card-success bg-theme-success/10"
    end
  end

  def queue_status_class(stats) do
    cond do
      stats.paused -> "theme-badge-warning"
      stats.retryable > 0 -> "theme-danger-panel"
      true -> "bg-theme-surface-4 text-theme-on-surface-muted"
    end
  end

  def queue_status_text(stats) do
    cond do
      stats.paused -> "Paused"
      stats.retryable > 0 -> "Has Failures"
      stats.running >= stats.limit -> "At Capacity"
      stats.running > 0 -> "Active"
      true -> "Idle"
    end
  end
end
