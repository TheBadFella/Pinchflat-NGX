defmodule PinchflatWeb.Settings.SettingController do
  use PinchflatWeb, :controller

  alias Pinchflat.CookieHealth.HealthCheckWorker
  alias Pinchflat.Settings
  alias Pinchflat.Reconciliation
  alias Pinchflat.Downloading.SpaceProtection
  alias Pinchflat.Settings.CookieFile
  alias Pinchflat.Settings.QueueConcurrency
  alias Pinchflat.YtDlp.UpdateWorker

  @yt_dlp_policy_fields [:yt_dlp_update_policy, :yt_dlp_pinned_version]

  def show(conn, _params) do
    setting = Settings.record()
    changeset = Settings.change_setting(setting, QueueConcurrency.form_attrs(setting))

    render(conn, "show.html",
      changeset: changeset,
      concurrency_fields: QueueConcurrency.field_states(setting)
    )
  end

  def update(conn, %{"setting" => setting_params}) do
    setting = Settings.record()

    case Settings.update_setting(setting, setting_params) do
      {:ok, updated_setting} ->
        maybe_apply_yt_dlp_policy(setting, updated_setting)
        maybe_reschedule_cookie_health(setting, updated_setting)
        QueueConcurrency.apply!(updated_setting)
        SpaceProtection.sync_settings_state(setting, updated_setting)
        # A settings change can alter predicted paths, so any staged reconcile
        # plan may no longer be accurate — mark it stale so it must be rebuilt
        Reconciliation.mark_ready_plans_stale()

        conn
        |> put_flash(:info, "Settings updated successfully.")
        |> redirect(to: ~p"/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "show.html",
          changeset: changeset,
          concurrency_fields: QueueConcurrency.field_states(setting)
        )
    end
  end

  # Performs the one-shot yt-dlp update (jump to the chosen channel/version) only
  # when the policy or pinned version actually changed, so saving unrelated
  # settings doesn't trigger an update.
  defp maybe_apply_yt_dlp_policy(old_setting, new_setting) do
    changed? = Enum.any?(@yt_dlp_policy_fields, &(Map.get(old_setting, &1) != Map.get(new_setting, &1)))

    if changed?, do: UpdateWorker.kickoff_apply()
  end

  defp maybe_reschedule_cookie_health(old_setting, new_setting) do
    cond do
      !old_setting.cookie_health_monitoring_enabled && new_setting.cookie_health_monitoring_enabled ->
        HealthCheckWorker.kickoff_manual()

      old_setting.cookie_health_check_interval_hours != new_setting.cookie_health_check_interval_hours ->
        HealthCheckWorker.schedule_next()

      true ->
        :ok
    end
  end

  def download_cookies(conn, _params) do
    if CookieFile.present?() do
      send_download(conn, {:file, CookieFile.filepath()}, filename: "cookies.txt")
    else
      conn
      |> put_flash(:error, "No cookies file has been uploaded")
      |> redirect(to: ~p"/settings")
    end
  end

  def download_logs(conn, _params) do
    log_path = Application.get_env(:pinchflat, :log_path)

    if log_path && File.exists?(log_path) do
      send_download(conn, {:file, log_path}, filename: "pinchflat-logs-#{Date.utc_today()}.txt")
    else
      conn
      |> put_flash(:error, "Log file couldn't be found")
      |> redirect(to: ~p"/diagnostics")
    end
  end

  def resume_downloads(conn, params) do
    redirect_target = Map.get(params, "redirect_to", ~p"/settings")

    case SpaceProtection.manual_resume() do
      {:ok, :resumed} ->
        conn
        |> put_flash(:info, "Storage check passed. Download protection block lifted.")
        |> redirect(to: redirect_target)

      {:ok, :not_blocked} ->
        conn
        |> put_flash(:info, "Downloads are not blocked by storage protection.")
        |> redirect(to: redirect_target)

      {:error, :below_recovery_threshold, free_bytes, recovery_target, location} ->
        free_gib = :erlang.float_to_binary(free_bytes / (1024 * 1024 * 1024), decimals: 2)
        target_gib = :erlang.float_to_binary(recovery_target / (1024 * 1024 * 1024), decimals: 2)

        conn
        |> put_flash(
          :error,
          "Storage check failed: #{location} storage free space (#{free_gib} GiB) is still below " <>
            "the recovery threshold of #{target_gib} GiB (configured threshold + 1 GiB). " <>
            "Free more disk space before resuming."
        )
        |> redirect(to: redirect_target)

      {:error, :missing_storage, location} ->
        conn
        |> put_flash(:error, "Storage check failed: #{location} storage path is missing or inaccessible.")
        |> redirect(to: redirect_target)

      {:error, :unknown_capacity, location} ->
        conn
        |> put_flash(
          :error,
          "Storage check failed: unable to determine available disk space for #{location} storage."
        )
        |> redirect(to: redirect_target)

      {:error, reason, location} ->
        conn
        |> put_flash(:error, "Storage check failed for #{location}: #{inspect(reason)}.")
        |> redirect(to: redirect_target)
    end
  end
end
