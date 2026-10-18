defmodule Pinchflat.YoutubeBrowser.Provider.YtDlp do
  @moduledoc """
  Read-only yt-dlp provider implementation for YouTube search, video details,
  and bounded channel preview. Uses `priv/cmd_wrapper.sh` for reliable subprocess
  cleanup upon Port closure.
  """

  @behaviour Pinchflat.YoutubeBrowser.Provider

  require Logger

  @max_buffer_bytes 8 * 1024 * 1024
  @default_limit 25
  @max_query_length 200

  @impl true
  def search_videos(query, opts \\ []) do
    case validate_query(query) do
      {:ok, clean_query} ->
        limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))
        arg = "ytsearch#{limit}:#{clean_query}"
        args = base_args() ++ [arg]

        case execute_cmd(args, opts) do
          {:ok, json_string} -> parse_video_search_output(json_string)
          error -> error
        end

      error ->
        error
    end
  end

  @impl true
  def search_channels(query, opts \\ []) do
    case validate_query(query) do
      {:ok, clean_query} ->
        limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))
        encoded_query = URI.encode_www_form(clean_query)
        # Channel type filter: sp=EgIQAg%253D%253D
        url = "https://www.youtube.com/results?search_query=#{encoded_query}&sp=EgIQAg%253D%253D"
        args = base_args() ++ ["--playlist-end", to_string(limit), url]

        case execute_cmd(args, opts) do
          {:ok, json_string} -> parse_channel_search_output(json_string)
          error -> error
        end

      error ->
        error
    end
  end

  @impl true
  def get_video_details(video_id, opts \\ []) do
    case validate_video_id(video_id) do
      {:ok, clean_id} ->
        args = base_args() ++ ["--no-playlist", "https://www.youtube.com/watch?v=#{clean_id}"]

        case execute_cmd(args, opts) do
          {:ok, json_string} -> parse_video_details_output(json_string, clean_id)
          error -> error
        end

      error ->
        error
    end
  end

  @impl true
  def get_channel_preview(channel_id_or_url, opts \\ []) do
    case canonicalize_channel_url(channel_id_or_url) do
      {:ok, channel_url} ->
        limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))
        args = base_args() ++ ["--playlist-end", to_string(limit), channel_url]

        case execute_cmd(args, opts) do
          {:ok, json_string} -> parse_channel_preview_output(json_string)
          error -> error
        end

      error ->
        error
    end
  end

  # --- Internal Command Execution via Port & cmd_wrapper.sh ---

  defp base_args do
    [
      "--no-warnings",
      "--no-config",
      "--no-cache-dir",
      "--skip-download",
      "--dump-single-json",
      "--flat-playlist"
    ]
  end

  def execute_cmd(args, opts \\ []) do
    ytdlp = yt_dlp_executable()
    wrapper = wrapper_path()
    timeout = Keyword.get(opts, :timeout, 60_000)

    # Wrap the command with priv/cmd_wrapper.sh to ensure subprocess death on Port close
    cmd_args = [ytdlp | args]

    port =
      Port.open(
        {:spawn_executable, wrapper},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: cmd_args
        ]
      )

    collect_output(port, [], 0, System.monotonic_time(:millisecond) + timeout)
  end

  defp collect_output(port, acc, bytes_acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      Port.close(port)
      {:error, :timeout}
    else
      receive_output(port, acc, bytes_acc, deadline, remaining)
    end
  end

  defp receive_output(port, acc, bytes_acc, deadline, remaining) do
    receive do
      {^port, {:data, binary}} ->
        new_bytes = bytes_acc + byte_size(binary)

        if new_bytes > @max_buffer_bytes do
          Port.close(port)
          {:error, :output_exceeded_buffer_limit}
        else
          collect_output(port, [binary | acc], new_bytes, deadline)
        end

      {^port, {:exit_status, 0}} ->
        combined =
          acc
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, combined}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_status, code}}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  def wrapper_path do
    if File.exists?("priv/cmd_wrapper.sh") do
      "priv/cmd_wrapper.sh"
    else
      case :code.priv_dir(:pinchflat) do
        {:error, _} -> "priv/cmd_wrapper.sh"
        dir -> Path.join(to_string(dir), "cmd_wrapper.sh")
      end
    end
  end

  def yt_dlp_executable do
    Application.get_env(:pinchflat, :yt_dlp_executable) || System.find_executable("yt-dlp") || "yt-dlp"
  end

  # --- Input Validation & Normalization ---

  defp validate_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:error, :empty_query}

      String.length(trimmed) > @max_query_length ->
        {:error, :query_too_long}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_query(_), do: {:error, :invalid_query}

  defp validate_video_id(video_id) when is_binary(video_id) do
    trimmed = String.trim(video_id)

    if trimmed != "" and byte_size(trimmed) <= 64 and Regex.match?(~r/^[a-zA-Z0-9_-]+$/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_video_id}
    end
  end

  defp validate_video_id(_), do: {:error, :invalid_video_id}

  defp canonicalize_channel_url(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      Regex.match?(~r/^UC[a-zA-Z0-9_-]+$/, trimmed) ->
        {:ok, "https://www.youtube.com/channel/#{trimmed}/videos"}

      Regex.match?(~r/^@[\p{L}\p{N}_.-]+$/u, trimmed) ->
        {:ok, "https://www.youtube.com/#{trimmed}/videos"}

      true ->
        case URI.parse(trimmed) do
          %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, port: 443, path: path}
          when host in ["www.youtube.com", "youtube.com"] and is_binary(path) ->
            case String.split(path, "/", trim: true) do
              ["channel", id] -> canonicalize_channel_url(id)
              ["channel", id, "videos"] -> canonicalize_channel_url(id)
              ["@" <> _ = handle] -> canonicalize_channel_url(handle)
              ["@" <> _ = handle, "videos"] -> canonicalize_channel_url(handle)
              _ -> {:error, :invalid_channel}
            end

          _ ->
            {:error, :invalid_channel}
        end
    end
  end

  defp canonicalize_channel_url(_), do: {:error, :invalid_channel}

  defp clamp_limit(limit) when is_integer(limit) do
    limit |> max(1) |> min(25)
  end

  defp clamp_limit(_), do: @default_limit

  # --- Output Parsing ---

  defp decode_output(json_string) do
    with {:ok, %{} = data} <- Jason.decode(json_string),
         entries when is_list(entries) <- Map.get(data, "entries") || [],
         true <- Enum.all?([data | entries], &valid_output_entry?/1) do
      {:ok, data}
    else
      _ -> {:error, :malformed_json_output}
    end
  end

  defp valid_output_entry?(nil), do: true

  defp valid_output_entry?(entry) when is_map(entry) do
    Enum.all?(~w(id title channel_id channel uploader uploader_id description upload_date url thumbnail), fn key ->
      is_nil(entry[key]) or is_binary(entry[key])
    end) and (is_nil(entry["thumbnails"]) or is_list(entry["thumbnails"]))
  end

  defp valid_output_entry?(_), do: false

  defp parse_video_search_output(json_string) do
    case decode_output(json_string) do
      {:ok, data} ->
        entries = Map.get(data, "entries") || []

        results =
          entries
          |> Enum.take(@default_limit)
          |> Enum.filter(fn e -> is_map(e) and is_binary(e["id"]) and e["id"] != "" end)
          |> Enum.map(&normalize_video_entry/1)

        {:ok, results}

      {:error, _} ->
        {:error, :malformed_json_output}
    end
  end

  defp parse_channel_search_output(json_string) do
    case decode_output(json_string) do
      {:ok, data} ->
        entries = Map.get(data, "entries") || []

        results =
          entries
          |> Enum.take(@default_limit)
          |> Enum.filter(fn e ->
            if is_map(e) do
              id = e["id"] || e["channel_id"]
              is_binary(id) and id != ""
            else
              false
            end
          end)
          |> Enum.map(&normalize_channel_entry/1)

        {:ok, results}

      {:error, _} ->
        {:error, :malformed_json_output}
    end
  end

  defp parse_video_details_output(json_string, video_id) do
    case decode_output(json_string) do
      {:ok, data} ->
        entries = Map.get(data, "entries") || [data]

        entry = Enum.find(entries, fn e -> is_map(e) and e["id"] == video_id end)

        if entry && is_binary(entry["id"]) do
          {:ok, normalize_video_detail(entry)}
        else
          {:error, :video_not_found}
        end

      {:error, _} ->
        {:error, :malformed_json_output}
    end
  end

  defp parse_channel_preview_output(json_string) do
    case decode_output(json_string) do
      {:ok, data} ->
        entries = Map.get(data, "entries") || []

        results =
          entries
          |> Enum.take(@default_limit)
          |> Enum.filter(fn e -> is_map(e) and is_binary(e["id"]) and e["id"] != "" end)
          |> Enum.map(&normalize_video_entry/1)

        {:ok, results}

      {:error, _} ->
        {:error, :malformed_json_output}
    end
  end

  defp normalize_video_entry(e) do
    thumbnails = e["thumbnails"] || []
    best_thumb = select_best_thumbnail(thumbnails) || sanitize_image_url(e["thumbnail"])

    %{
      id: e["id"],
      url: "https://www.youtube.com/watch?v=#{e["id"]}",
      title: e["title"] || "Untitled",
      channel_id: e["channel_id"] || e["uploader_id"],
      channel_title: e["channel"] || e["uploader"] || "Unknown",
      duration: e["duration"],
      upload_date: e["upload_date"],
      thumbnail: best_thumb,
      view_count: e["view_count"]
    }
  end

  defp normalize_channel_entry(e) do
    channel_id = e["id"] || e["channel_id"]
    thumbnails = e["thumbnails"] || []
    best_thumb = select_best_thumbnail(thumbnails) || sanitize_image_url(e["thumbnail"])

    url =
      cond do
        is_binary(e["url"]) and safe_youtube_url?(e["url"]) -> e["url"]
        is_binary(channel_id) -> "https://www.youtube.com/channel/#{channel_id}"
        true -> nil
      end

    %{
      id: channel_id,
      url: url,
      title: e["title"] || e["channel"] || "Untitled Channel",
      handle: e["uploader_id"] || e["channel_id"],
      thumbnail: best_thumb,
      subscriber_count: e["channel_follower_count"]
    }
  end

  defp normalize_video_detail(e) do
    raw_thumbnails = e["thumbnails"] || []

    thumbnails =
      Enum.filter(raw_thumbnails, fn t -> is_map(t) and safe_image_url?(t["url"]) end)

    best_thumb = select_best_thumbnail(thumbnails) || sanitize_image_url(e["thumbnail"])

    %{
      id: e["id"],
      url: "https://www.youtube.com/watch?v=#{e["id"]}",
      title: e["title"] || "Untitled",
      description: e["description"] && String.slice(e["description"], 0, 10_000),
      channel_id: e["channel_id"] || e["uploader_id"],
      channel_title: e["channel"] || e["uploader"] || "Unknown",
      duration: e["duration"],
      upload_date: e["upload_date"],
      thumbnails: thumbnails,
      thumbnail: best_thumb,
      view_count: e["view_count"]
    }
  end

  defp select_best_thumbnail(nil), do: nil
  defp select_best_thumbnail([]), do: nil

  defp select_best_thumbnail(thumbnails) when is_list(thumbnails) do
    valid =
      thumbnails
      |> Enum.filter(fn t -> is_map(t) and safe_image_url?(t["url"]) end)

    case valid do
      [] ->
        nil

      thumbs ->
        sorted =
          Enum.sort_by(thumbs, fn t -> t["width"] || 0 end, :desc)

        (List.first(sorted) && List.first(sorted)["url"]) ||
          (List.first(thumbs) && List.first(thumbs)["url"])
    end
  end

  defp safe_image_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)

        host == "ytimg.com" or String.ends_with?(host, ".ytimg.com") or
          host == "ggpht.com" or String.ends_with?(host, ".ggpht.com") or
          host == "googleusercontent.com" or String.ends_with?(host, ".googleusercontent.com")

      _ ->
        false
    end
  end

  defp safe_image_url?(_), do: false

  defp sanitize_image_url(url) when is_binary(url) do
    if safe_image_url?(url), do: url, else: nil
  end

  defp sanitize_image_url(_), do: nil

  defp safe_youtube_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)

        host == "youtube.com" or String.ends_with?(host, ".youtube.com") or
          host == "youtu.be" or String.ends_with?(host, ".youtu.be")

      _ ->
        false
    end
  end

  defp safe_youtube_url?(_), do: false
end
