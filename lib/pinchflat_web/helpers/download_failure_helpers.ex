defmodule PinchflatWeb.Helpers.DownloadFailureHelpers do
  @moduledoc "Presentation guidance for download errors. Does not change download or retry policy."

  @doc "Returns a plain explanation, recovery advice and whether settings may help."
  def explanation(message) do
    message = String.downcase(message)

    cond do
      String.contains?(message, ["no space left", "disk quota exceeded", "insufficient storage space", ":enospc"]) ->
        {"Not enough storage space", "Free space on the download and temporary storage volumes before retrying.", false}

      String.contains?(message, ["permission denied", "read-only file system", ":eacces", ":erofs"]) ->
        {"Storage could not be written",
         "Check that the download and temporary storage volumes are writable by the app before retrying.", false}

      String.contains?(message, ["confirm you're not a bot", "confirm you\u2019re not a bot"]) ->
        {"YouTube requested a bot check",
         "Wait before retrying. If it persists, review the Cookies section in Settings. Repeated retries may not help.",
         true}

      String.contains?(message, [
        "http error 429",
        "too many requests",
        "rate limit",
        "rate-limit",
        "requested too many"
      ]) ->
        {"YouTube is limiting requests", "Wait before retrying. Repeated immediate retries may prolong the limit.",
         false}

      String.contains?(message, ["sign in to confirm", "login required", "authentication required"]) ->
        {"Sign-in is required",
         "Check that the video plays with your account, then review the Cookies section in Settings before retrying.",
         true}

      String.contains?(message, [
        "video unavailable",
        "private video",
        "has been removed",
        "members-only",
        "available to this channel's members",
        "not available in your country"
      ]) ->
        {"This video is unavailable to the app",
         "Check access on YouTube. A retry cannot restore a removed video or grant account or regional access.", false}

      String.contains?(message, [
        "network is unreachable",
        "temporary failure in name resolution",
        "name or service not known",
        "connection timed out",
        "connection reset",
        "connection refused",
        "unable to connect",
        "read timed out",
        "<urlopen error timed out>"
      ]) ->
        {"The network request failed", "Check the app's network and DNS connection before retrying.", false}

      true ->
        {"The download failed", "The cause was not recognized. Review the technical details and diagnostics.", false}
    end
  end

  @doc "Returns current queue guidance and a scheduled time, using only the active job supplied by the view."
  def retry_status(_item, %{job: %{state: "executing"}}), do: {"A download attempt is running.", nil}

  def retry_status(_item, %{job: %{state: "available"}}), do: {"A download attempt is queued.", nil}

  def retry_status(_item, %{job: %{state: "retryable", scheduled_at: scheduled_at}}),
    do: {"An automatic retry is scheduled.", scheduled_at}

  def retry_status(_item, %{job: %{state: "scheduled", scheduled_at: scheduled_at}}),
    do: {"A download attempt is scheduled.", scheduled_at}

  def retry_status(_item, task) when not is_nil(task),
    do: {"The current download queue state is unavailable. Check diagnostics.", nil}

  def retry_status(%{prevent_download: true}, _task),
    do: {"Automatic downloads are blocked for this item. Review the cause before retrying manually.", nil}

  def retry_status(_item, _task), do: {"No download attempt is currently queued.", nil}
end
