defmodule Pinchflat.Downloading.FormatDetails do
  @moduledoc """
  Reads the downloaded format and the formats YouTube offered from a yt-dlp
  info dict: the one a download prints, or the info JSON stored beside it.
  """

  @doc """
  Returns the media item attributes describing a yt-dlp info dict. Values are
  nil when the info dict does not include them, such as audio-only downloads.

  Returns map()
  """
  def from_info(info) when is_map(info) do
    video_formats = video_formats(info["formats"])

    %{
      video_height: positive_integer(info["height"]),
      video_codec: codec(info["vcodec"]),
      audio_codec: codec(info["acodec"]),
      max_available_height: video_formats |> Enum.map(& &1.height) |> Enum.max(fn -> nil end),
      available_video_codecs: available_codecs(video_formats)
    }
  end

  def from_info(_info), do: %{}

  @doc """
  Returns the tallest height offered that does not exceed `target_height`,
  which is the height yt-dlp's `res:` sort picks, or nil if none is offered.

  Returns integer() | nil
  """
  def best_height_within(formats, target_height) when is_integer(target_height) do
    formats
    |> video_formats()
    |> Enum.map(& &1.height)
    |> Enum.filter(&(&1 <= target_height))
    |> Enum.max(fn -> nil end)
  end

  defp video_formats(formats) when is_list(formats) do
    Enum.flat_map(formats, fn
      %{"height" => height} = format ->
        case {positive_integer(height), codec(format["vcodec"])} do
          {height, codec} when is_integer(height) and is_binary(codec) -> [%{height: height, codec: codec}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp video_formats(_formats), do: []

  # "avc1.640028" and "avc1.4d401f" are the same codec family for users.
  defp available_codecs([]), do: nil

  defp available_codecs(formats) do
    formats |> Enum.map(&(&1.codec |> String.split(".") |> hd())) |> Enum.uniq() |> Enum.sort() |> Enum.join(",")
  end

  defp codec(value) when is_binary(value) and value not in ["", "none"], do: value
  defp codec(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end
