defmodule Pinchflat.Downloading.SpaceProtection do
  @moduledoc """
  Provides preflight storage space checks and protection for media downloads.

  When enabled, prevents download jobs from executing if available disk space
  on the media destination or active staging filesystem falls below the configured
  threshold. Blocked jobs are snoozed via Oban (default 60s) without consuming
  retries. A single deduplicated alert is dispatched via Apprise per blocked episode.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Pinchflat.Database
  alias Pinchflat.Diagnostics.DiskSpaceChecker
  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Settings.Setting
  alias Pinchflat.Tasks

  @default_threshold_bytes 10_737_418_240
  @hysteresis_recovery_bytes 1_073_741_824
  @snooze_interval_seconds 60

  @doc "Returns the default minimum threshold in bytes (10 GiB)."
  def default_threshold_bytes, do: @default_threshold_bytes

  @doc "Returns the recovery threshold in bytes (configured threshold + 1 GiB hysteresis)."
  def recovery_threshold_bytes(threshold_bytes) when is_integer(threshold_bytes) do
    threshold_bytes + @hysteresis_recovery_bytes
  end

  @doc """
  Performs preflight disk space validation before starting a download.

  Returns :ok | {:snooze, non_neg_integer()}
  """
  def preflight(job_id) do
    setting = Settings.record()

    if setting.download_space_protection_enabled do
      do_preflight(setting, job_id)
    else
      :ok
    end
  end

  defp do_preflight(%Setting{download_space_protection_blocked: true} = setting, job_id) do
    maybe_retry_alert(setting)
    maybe_update_task_status(job_id, "Waiting for storage space")
    {:snooze, @snooze_interval_seconds}
  end

  defp do_preflight(%Setting{download_space_protection_threshold_bytes: threshold}, job_id) do
    case evaluate_storage(threshold) do
      :ok ->
        :ok

      {:error, reason, location, free_bytes} ->
        block_and_alert(reason, location, free_bytes, threshold)
        maybe_update_task_status(job_id, "Waiting for storage space")
        {:snooze, @snooze_interval_seconds}
    end
  end

  @doc """
  Evaluates free space on destination and active staging filesystems against required bytes.

  Returns :ok | {:error, reason, location, free_bytes}
  """
  def evaluate_storage(required_bytes) when is_integer(required_bytes) and required_bytes > 0 do
    dest_path = Application.get_env(:pinchflat, :media_directory, "/downloads")

    case check_location_capacity(dest_path, required_bytes) do
      :ok ->
        evaluate_staging_storage(required_bytes)

      {:error, reason, free_bytes} ->
        {:error, reason, "destination", free_bytes}
    end
  end

  defp evaluate_staging_storage(required_bytes) do
    case DownloadStaging.configured_directory() do
      nil ->
        :ok

      staging_path when is_binary(staging_path) ->
        case check_location_capacity(staging_path, required_bytes) do
          :ok ->
            :ok

          {:error, reason, free_bytes} ->
            {:error, reason, "staging", free_bytes}
        end
    end
  end

  defp check_location_capacity(path, required_bytes) do
    case resolve_storage_target(path) do
      {:ok, existing_path} ->
        query_path_capacity(existing_path, required_bytes)

      {:error, _} ->
        {:error, :missing_storage, nil}
    end
  end

  defp resolve_storage_target(nil), do: {:error, :missing_path}
  defp resolve_storage_target(""), do: {:error, :missing_path}

  defp resolve_storage_target(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        check_directory_accessible(expanded)

      File.exists?(expanded) ->
        {:error, :not_a_directory}

      true ->
        parent = Path.dirname(expanded)

        if parent != expanded and File.dir?(parent) do
          check_directory_accessible(parent)
        else
          {:error, :missing_storage}
        end
    end
  end

  defp query_path_capacity(path, required_bytes) do
    case checker().available_bytes(path) do
      {:ok, available_bytes} when available_bytes < required_bytes ->
        {:error, :low_space, available_bytes}

      {:ok, _available_bytes} ->
        :ok

      :error ->
        {:error, :unknown_capacity, nil}
    end
  end

  @doc """
  Locates the closest existing directory ancestor for a given path without creating directories.
  """
  def find_existing_ancestor(nil), do: {:error, :missing_path}
  def find_existing_ancestor(""), do: {:error, :missing_path}

  def find_existing_ancestor(path) when is_binary(path) do
    expanded = Path.expand(path)
    do_find_existing_ancestor(expanded)
  end

  defp do_find_existing_ancestor(path) do
    cond do
      File.dir?(path) ->
        check_directory_accessible(path)

      File.exists?(path) ->
        {:error, :not_a_directory}

      true ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, :missing_path}
        else
          do_find_existing_ancestor(parent)
        end
    end
  end

  defp check_directory_accessible(path) do
    case File.stat(path) do
      {:ok, %{access: :none}} -> {:error, :inaccessible_path}
      {:ok, _} -> {:ok, path}
      {:error, _} -> {:error, :inaccessible_path}
    end
  end

  @doc """
  Attempts manual recovery verification and resumes downloads if available space exceeds
  the recovery threshold (threshold + 1 GiB hysteresis).

  Returns {:ok, :resumed} | {:ok, :not_blocked} | {:error, atom(), any(), any()}
  """
  def manual_resume do
    setting = Settings.record()

    if setting.download_space_protection_blocked do
      do_manual_resume(setting)
    else
      {:ok, :not_blocked}
    end
  end

  defp do_manual_resume(setting) do
    recovery_target = recovery_threshold_bytes(setting.download_space_protection_threshold_bytes)

    case evaluate_storage(recovery_target) do
      :ok ->
        clear_blocked_state(setting)
        {:ok, :resumed}

      {:error, :low_space, location, free_bytes} ->
        {:error, :below_recovery_threshold, free_bytes, recovery_target, location}

      {:error, reason, location, _} ->
        {:error, reason, location}
    end
  end

  @doc """
  Handles settings modification effects: clears safety block when protection is disabled,
  or re-evaluates capacity when threshold changes.
  """
  def sync_settings_state(old_setting, new_setting) do
    cond do
      old_setting.download_space_protection_enabled and not new_setting.download_space_protection_enabled ->
        clear_blocked_state(new_setting)

      new_setting.download_space_protection_enabled and
          old_setting.download_space_protection_threshold_bytes !=
            new_setting.download_space_protection_threshold_bytes ->
        re_evaluate_threshold(new_setting)

      true ->
        :ok
    end
  end

  defp re_evaluate_threshold(setting) do
    case evaluate_storage(setting.download_space_protection_threshold_bytes) do
      :ok ->
        if setting.download_space_protection_blocked do
          clear_blocked_state(setting)
        end

      {:error, reason, location, free_bytes} ->
        unless setting.download_space_protection_blocked do
          block_and_alert(reason, location, free_bytes, setting.download_space_protection_threshold_bytes)
        end
    end
  end

  defp clear_blocked_state(setting) do
    attrs = %{
      download_space_protection_blocked: false,
      download_space_protection_blocked_reason: nil,
      download_space_protection_blocked_location: nil,
      download_space_protection_free_bytes: nil,
      download_space_protection_blocked_at: nil,
      download_space_protection_alerted_at: nil
    }

    {:ok, _} = Settings.update_setting(setting, attrs)
    :ok
  end

  defp block_and_alert(reason, location, free_bytes, threshold_bytes) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        query =
          if Database.postgres?() do
            from(s in Setting, lock: "FOR UPDATE")
          else
            Setting
          end

        setting = Repo.one!(query)

        unless setting.download_space_protection_blocked do
          attrs = %{
            download_space_protection_blocked: true,
            download_space_protection_blocked_reason: to_string(reason),
            download_space_protection_blocked_location: location,
            download_space_protection_free_bytes: free_bytes,
            download_space_protection_blocked_at: now,
            download_space_protection_alerted_at: nil
          }

          {:ok, updated} = Settings.update_setting(setting, attrs)
          {:newly_blocked, updated}
        end
      end)

    case result do
      {:ok, {:newly_blocked, updated_setting}} ->
        if send_apprise_alert(reason, location, free_bytes, threshold_bytes) do
          Settings.update_setting(updated_setting, %{download_space_protection_alerted_at: DateTime.utc_now()})
        end

      _ ->
        :ok
    end
  end

  defp maybe_retry_alert(%Setting{download_space_protection_alerted_at: nil} = setting) do
    reason = setting.download_space_protection_blocked_reason || "low_space"
    location = setting.download_space_protection_blocked_location || "destination"
    free_bytes = setting.download_space_protection_free_bytes
    threshold_bytes = setting.download_space_protection_threshold_bytes || @default_threshold_bytes

    if send_apprise_alert(reason, location, free_bytes, threshold_bytes) do
      Settings.update_setting(setting, %{download_space_protection_alerted_at: DateTime.utc_now()})
    end
  end

  defp maybe_retry_alert(_setting), do: :ok

  defp send_apprise_alert(reason, location, free_bytes, threshold_bytes) do
    server = Settings.get!(:apprise_server)

    if is_binary(server) and String.trim(server) != "" do
      opts = [
        title: "[Pinchflat-ngx] Downloads paused: Low storage space",
        body: build_alert_body(reason, location, free_bytes, threshold_bytes),
        input_format: "markdown",
        notification_type: "failure"
      ]

      case apprise_runner().run(server, opts) do
        {:ok, _} ->
          Logger.info("Sent download space protection alert for #{location}")
          true

        {:error, err} ->
          Logger.error("Failed to send download space protection alert: #{inspect(err)}")
          false
      end
    else
      false
    end
  rescue
    e ->
      Logger.error("Exception sending download space protection alert: #{inspect(e)}")
      false
  end

  defp build_alert_body(reason, location, free_bytes, threshold_bytes) do
    free_str = format_bytes_label(free_bytes)
    req_str = format_bytes_label(threshold_bytes)

    reason_desc =
      case reason do
        :low_space -> "has low disk space (**#{free_str}** available, **#{req_str}** required)"
        :missing_storage -> "directory is missing or inaccessible"
        :unknown_capacity -> "capacity cannot be determined"
        _ -> "is unable to accept downloads"
      end

    base_msg = "Downloads have been paused because **#{location}** storage #{reason_desc}."

    case Settings.get(:external_base_url) do
      {:ok, url} when is_binary(url) and url != "" ->
        settings_url = "#{String.trim_trailing(url, "/")}/settings"
        "#{base_msg}\n\n[Open Pinchflat Settings](#{settings_url})"

      _ ->
        base_msg
    end
  end

  defp format_bytes_label(nil), do: "unknown"

  defp format_bytes_label(bytes) when is_integer(bytes) do
    gib = bytes / (1024 * 1024 * 1024)
    :erlang.float_to_binary(gib, decimals: 2) <> " GiB"
  end

  defp maybe_update_task_status(nil, _status), do: :ok

  defp maybe_update_task_status(job_id, status) do
    case Tasks.get_task_by_job_id(job_id) do
      nil -> :ok
      task -> Tasks.update_task_progress(task, %{progress_status: status})
    end
  end

  defp checker do
    Application.get_env(:pinchflat, :disk_space_checker, DiskSpaceChecker)
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
