defmodule Pinchflat.Downloading.DownloadError do
  @moduledoc """
  Classifies download errors using the existing non-retryable matching rules.
  """

  @rate_limited_errors [
    "HTTP Error 429",
    "Too Many Requests",
    "rate limit",
    "rate-limit",
    "requested too many",
    "confirm you're not a bot",
    "confirm you\u2019re not a bot"
  ]

  @permanent_download_errors [
    "Video unavailable",
    "Sign in to confirm",
    "This video is available to this channel's members"
  ]

  @doc "Returns `{:permanent, progress_status}` or `:transient`."
  def classify(message) do
    message = to_string(message)

    cond do
      String.contains?(message, @rate_limited_errors) ->
        {:permanent, "Stopped: rate limited by remote source"}

      String.contains?(message, @permanent_download_errors) ->
        {:permanent, "Stopped: download unavailable"}

      true ->
        :transient
    end
  end
end
