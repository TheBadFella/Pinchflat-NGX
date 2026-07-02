defmodule PinchflatWeb.Settings.SettingController do
  use PinchflatWeb, :controller

  alias Pinchflat.Settings
  alias Pinchflat.Settings.CookieFile
  alias Pinchflat.YtDlp.UpdateWorker

  @yt_dlp_policy_fields [:yt_dlp_update_policy, :yt_dlp_pinned_version]

  def show(conn, _params) do
    setting = Settings.record()
    changeset = Settings.change_setting(setting)

    render(conn, "show.html", changeset: changeset)
  end

  def update(conn, %{"setting" => setting_params}) do
    setting = Settings.record()

    case Settings.update_setting(setting, setting_params) do
      {:ok, updated_setting} ->
        maybe_apply_yt_dlp_policy(setting, updated_setting)

        conn
        |> put_flash(:info, "Settings updated successfully.")
        |> redirect(to: ~p"/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "show.html", changeset: changeset)
    end
  end

  # Performs the one-shot yt-dlp update (jump to the chosen channel/version) only
  # when the policy or pinned version actually changed, so saving unrelated
  # settings doesn't trigger an update.
  defp maybe_apply_yt_dlp_policy(old_setting, new_setting) do
    changed? = Enum.any?(@yt_dlp_policy_fields, &(Map.get(old_setting, &1) != Map.get(new_setting, &1)))

    if changed?, do: UpdateWorker.kickoff_apply()
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
end
