defmodule Pinchflat.YtDlp.TransientMedia do
  @moduledoc """
  Classifies yt-dlp errors for media that is not available yet but may become
  available later, such as upcoming or offline live events.

  These are distinct from permanently unavailable media in
  `Pinchflat.YtDlp.UnavailableMedia` so callers can skip the item for now and
  retry on a later index.
  """

  @error_strings [
    "This live event will begin in a few moments",
    "Offline."
  ]

  @doc """
  The list of yt-dlp error substrings indicating transiently unavailable media.
  """
  def error_strings, do: @error_strings

  @doc """
  Returns true if the given yt-dlp error message indicates a transient live
  event that may become available later.
  """
  def error?(message) do
    String.contains?(to_string(message), @error_strings)
  end

  @doc """
  Returns the first matched transient-media substring, or nil if none match.
  """
  def matched_reason(message) do
    string = to_string(message)

    Enum.find(@error_strings, fn substring -> String.contains?(string, substring) end)
  end
end
