defmodule Pinchflat.YtDlp.PluginDiagnostics do
  @moduledoc """
  Surfaces yt-dlp plugin import failures in Pinchflat logs and notifications.

  yt-dlp catches plugin import errors and continues, so a failed plugin can
  otherwise disappear into command output that is only logged at debug level.
  """

  require Logger

  alias Pinchflat.Settings

  @import_error ~r/Error while importing module '((?:yt_dlp_plugins|ytdlp_plugins)\.[^']+)'/
  @alert_cooldown_seconds 3_600
  @alert_state_key {__MODULE__, :alerts}
  @diagnostics_failure_message "Plugin diagnostics failed"

  @doc """
  Extracts yt-dlp plugin import failures from command output.

  Returns [%{module: String.t(), detail: String.t()}]
  """
  def extract_issues(output) do
    lines = String.split(to_string(output), "\n")

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      case Regex.run(@import_error, line) do
        [_, module] -> [%{module: module, detail: detail_for(lines, index)}]
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.module)
  end

  @doc """
  Logs plugin import failures and dispatches a deduplicated Apprise alert.

  Diagnostics are a side channel for the yt-dlp command that produced the output,
  so any failure here is logged and swallowed rather than raised into the caller.

  Returns :ok
  """
  def report(output, status, action_name) do
    issues = extract_issues(output)

    if issues != [] do
      Enum.each(issues, &log_issue(&1, status, action_name))
      maybe_alert(issues, status, action_name)
    end

    :ok
  rescue
    error ->
      Logger.error("[yt-dlp plugins] #{@diagnostics_failure_message}: #{Exception.message(error)}")
      :ok
  end

  @doc false
  def reset_alert_state do
    :persistent_term.erase(@alert_state_key)
    :ok
  end

  defp detail_for(lines, index) do
    lines
    |> Enum.drop(index + 1)
    |> Enum.take(8)
    |> Enum.find(fn candidate ->
      String.contains?(candidate, "Error:") or String.contains?(candidate, "Exception:")
    end)
    |> case do
      nil -> "import failed"
      detail -> String.trim(detail)
    end
  end

  defp log_issue(issue, status, action_name) do
    Logger.error(
      "[yt-dlp plugins] #{issue.module} failed to load: #{issue.detail} " <>
        "(action: #{action_name}, status: #{status})"
    )
  end

  defp maybe_alert(issues, status, action_name) do
    signature = signature(issues)
    now = System.os_time(:second)
    alerts = :persistent_term.get(@alert_state_key, %{})

    if now - Map.get(alerts, signature, 0) >= @alert_cooldown_seconds do
      case send_alert(issues, status, action_name) do
        :ok -> :persistent_term.put(@alert_state_key, Map.put(alerts, signature, now))
        _ -> :ok
      end
    end

    :ok
  end

  defp signature(issues) do
    issues
    |> Enum.map_join("|", &"#{&1.module}: #{&1.detail}")
    |> then(&:erlang.phash2/1)
  end

  defp send_alert(issues, status, action_name) do
    case Settings.get!(:apprise_server) do
      server when is_binary(server) and server != "" ->
        opts = [
          title: "[Pinchflat-ngx] yt-dlp plugin issue detected",
          body: alert_body(issues, status, action_name),
          notification_type: "failure"
        ]

        case apprise_runner().run([server], opts) do
          {:ok, _output} ->
            Logger.info("[yt-dlp plugins] Sent plugin failure alert")
            :ok

          {:error, reason} ->
            Logger.error("[yt-dlp plugins] Failed to send plugin failure alert: #{inspect(reason)}")
            {:error, reason}
        end

      _ ->
        :no_server
    end
  end

  defp alert_body(issues, status, action_name) do
    details =
      issues
      |> Enum.map_join("\n", &"- #{&1.module}: #{&1.detail}")
      |> String.slice(0, 900)

    """
    yt-dlp could not load one or more plugins (action: #{action_name}, status: #{status}):
    #{details}
    """
    |> String.trim()
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner, Pinchflat.Lifecycle.Notifications.CommandRunner)
  end
end
