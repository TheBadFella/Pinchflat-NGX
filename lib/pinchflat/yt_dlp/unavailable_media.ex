defmodule Pinchflat.YtDlp.UnavailableMedia do
  @moduledoc """
  Classifies yt-dlp error output for media that can never be downloaded
  (members-only, private, or removed videos).

  Shared by the download path (`MediaDownloadWorker`) and the source
  metadata/indexing path (`SourceMetadataStorageWorker`) so both treat the
  same set of errors as "permanently unavailable" when the
  `ignore_unavailable_media` setting is enabled.

  These substrings are kept distinct from the cookie-recoverable errors in
  `Pinchflat.Downloading.MediaDownloader` so the cookie-retry path always runs
  first - a members-only video may become downloadable with the right cookies.
  """

  @error_strings [
    "Join this channel to get access to members-only content",
    "This video is available to this channel's members",
    "members-only content",
    "Private video",
    "Sign in if you've been granted access to this video",
    "Video unavailable",
    "This video has been removed",
    "This video is no longer available"
  ]

  @doc """
  The list of yt-dlp error substrings indicating permanently unavailable media.
  """
  def error_strings, do: @error_strings

  @doc """
  Returns true if the given yt-dlp error message indicates permanently
  unavailable media.
  """
  def error?(message) do
    String.contains?(to_string(message), @error_strings)
  end
end
