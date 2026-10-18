defmodule Pinchflat.YoutubeBrowser.UrlParser do
  @moduledoc """
  Validates, parses, and canonicalizes YouTube video URLs for quick intake.

  Enforces strict scheme, host, path, port, and credential boundaries to ensure
  safe parsing without network requests, redirects, or arbitrary shell invocations.
  """

  @max_url_length 2048

  @allowed_hosts [
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be"
  ]

  @video_id_regex ~r/^[a-zA-Z0-9_-]{11}$/

  @doc """
  Parses a raw input string into a validated video ID and canonical HTTPS watch URL.

  Returns `{:ok, %{video_id: String.t(), canonical_url: String.t()}}` or `{:error, reason}`.
  """
  @spec parse(String.t() | any()) ::
          {:ok, %{video_id: String.t(), canonical_url: String.t()}}
          | {:error, atom() | {atom(), String.t()}}
  def parse(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" ->
        {:error, :empty_url}

      byte_size(trimmed) > @max_url_length ->
        {:error, :url_too_long}

      true ->
        do_parse_uri(trimmed)
    end
  end

  def parse(_), do: {:error, :invalid_input}

  defp do_parse_uri(raw_url) do
    case URI.new(raw_url) do
      {:ok, %URI{} = uri} ->
        validate_uri_components(uri)

      _ ->
        {:error, :malformed_url}
    end
  end

  defp validate_uri_components(%URI{scheme: scheme}) when scheme not in ["http", "https"] do
    {:error, :unsupported_scheme}
  end

  defp validate_uri_components(%URI{userinfo: userinfo}) when not is_nil(userinfo) and userinfo != "" do
    {:error, :credentials_not_allowed}
  end

  defp validate_uri_components(%URI{port: port, scheme: scheme})
       when not is_nil(port) and not (scheme == "http" and port == 80) and not (scheme == "https" and port == 443) do
    {:error, :non_default_port}
  end

  defp validate_uri_components(%URI{host: host} = uri) do
    normalized_host = if host, do: String.downcase(host), else: ""

    cond do
      normalized_host not in @allowed_hosts ->
        {:error, :unsupported_host}

      ip_address_host?(normalized_host) ->
        {:error, :unsupported_host}

      normalized_host == "youtu.be" ->
        parse_short_host_path(uri)

      true ->
        parse_standard_host_path(uri)
    end
  end

  defp ip_address_host?(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, _} -> true
      _ -> String.starts_with?(host, "[") and String.ends_with?(host, "]")
    end
  end

  defp parse_short_host_path(%URI{path: path}) do
    segments = extract_path_segments(path)

    case segments do
      [candidate_id] ->
        validate_and_canonicalize(candidate_id)

      [] ->
        {:error, :missing_video_id}

      _ ->
        {:error, :extra_path_segments}
    end
  end

  defp parse_standard_host_path(%URI{path: path, query: query}) do
    segments = extract_path_segments(path)

    case segments do
      ["watch"] ->
        parse_watch_query(query)

      ["embed", candidate_id] ->
        validate_and_canonicalize(candidate_id)

      ["embed" | _] ->
        {:error, :extra_path_segments}

      ["shorts", candidate_id] ->
        validate_and_canonicalize(candidate_id)

      ["shorts" | _] ->
        {:error, :extra_path_segments}

      ["live", candidate_id] ->
        validate_and_canonicalize(candidate_id)

      ["live" | _] ->
        {:error, :extra_path_segments}

      ["channel" | _] ->
        {:error,
         {:channel_or_playlist,
          "Channel URLs cannot be downloaded via Quick URL. Use the subscription workflow to add channel sources."}}

      ["c" | _] ->
        {:error,
         {:channel_or_playlist,
          "Channel URLs cannot be downloaded via Quick URL. Use the subscription workflow to add channel sources."}}

      ["user" | _] ->
        {:error,
         {:channel_or_playlist,
          "Channel URLs cannot be downloaded via Quick URL. Use the subscription workflow to add channel sources."}}

      ["playlist" | _] ->
        {:error,
         {:channel_or_playlist,
          "Playlist URLs cannot be downloaded via Quick URL. Use the subscription workflow to add playlist sources."}}

      ["@" <> _ | _] ->
        {:error,
         {:channel_or_playlist,
          "Channel URLs cannot be downloaded via Quick URL. Use the subscription workflow to add channel sources."}}

      [] ->
        {:error, :missing_video_id}

      _ ->
        {:error, :invalid_path}
    end
  end

  defp parse_watch_query(query) when is_nil(query) or query == "" do
    {:error, :missing_video_id}
  end

  defp parse_watch_query(query) do
    pairs =
      query
      |> String.split("&", trim: true)
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> {URI.decode(k), URI.decode(v)}
          [k] -> {URI.decode(k), ""}
        end
      end)

    v_values =
      for {"v", val} <- pairs do
        val
      end

    case v_values do
      [single_id] ->
        validate_and_canonicalize(single_id)

      [] ->
        if Enum.any?(pairs, fn {k, _} -> k == "list" end) do
          {:error,
           {:channel_or_playlist,
            "Playlists cannot be downloaded via Quick URL. Use the subscription workflow to add playlist sources."}}
        else
          {:error, :missing_video_id}
        end

      _multiple ->
        {:error, :conflicting_video_id_parameters}
    end
  end

  defp extract_path_segments(nil), do: []

  defp extract_path_segments(path) do
    path
    |> String.split("/", trim: true)
  end

  defp validate_and_canonicalize(candidate_id) do
    if Regex.match?(@video_id_regex, candidate_id) do
      {:ok,
       %{
         video_id: candidate_id,
         canonical_url: "https://www.youtube.com/watch?v=#{candidate_id}"
       }}
    else
      {:error, :invalid_video_id}
    end
  end
end
