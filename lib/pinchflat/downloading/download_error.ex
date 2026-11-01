defmodule Pinchflat.Downloading.DownloadError do
  @moduledoc """
  Classifies download errors and cookie-recoverable authentication errors.
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

  @doc "Returns true when an authentication error may be recovered with cookies."
  def cookie_recoverable?(message) do
    String.contains?(to_string(message), ["Sign in to confirm", "This video is available to this channel's members"])
  end

  @doc """
  Returns `{:rate_limited, progress_status}`, `{:permanent, progress_status}`,
  or `:transient`.

  Rate limits and bot challenges must not retry immediately, but they are not
  durable blocks: a later index or a bulk retry should pick the item up again.
  True unavailability (removed, members-only, age-gated) stays permanent.
  """
  def classify(message) do
    message = to_string(message)

    cond do
      String.contains?(message, @rate_limited_errors) ->
        {:rate_limited, "Stopped: rate limited by remote source"}

      String.contains?(message, @permanent_download_errors) ->
        {:permanent, "Stopped: download unavailable"}

      true ->
        :transient
    end
  end
end
