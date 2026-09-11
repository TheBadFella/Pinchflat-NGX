defmodule Pinchflat.Discovery.Normalizer do
  @moduledoc """
  Pure normalization for YouTube channel IDs, handles, and channel references.

  It deliberately returns references rather than making network calls. A
  handle is only a pre-validation key; the durable channel ID is established by
  the bounded validation step.
  """

  @channel_id_regex ~r/^UC[A-Za-z0-9_-]{22}$/
  @handle_regex ~r/^[A-Za-z0-9._-]{2,30}$/
  @youtube_url_regex ~r{https?://(?:www\.|m\.)?(?:youtube\.com|youtu\.be)/[^\s<>"']+}i
  @channel_id_token_regex ~r/\bUC[A-Za-z0-9_-]{20,}\b/
  @handle_token_regex ~r/(?:^|[^A-Za-z0-9_])(@[A-Za-z0-9._-]{2,30})/
  @channel_suffixes ~w(featured videos shorts streams live)
  @reserved_custom_paths ~w(
    about channel channels community c clip embed feed featured live membership
    playlist playlists results shorts store user watch watch_videos videos
  )

  @doc """
  Extracts normalized channel references from arbitrary local text.

  Returns `%{kind: :channel_id | :handle, key: binary(), ...}` values. Invalid
  and self-referential values are discarded and duplicates are removed.
  """
  def normalize(text, opts \\ [])

  def normalize(text, opts) when is_binary(text) do
    self_keys = self_reference_keys(Keyword.get(opts, :self_references, []))

    text
    |> extract_references()
    |> Enum.reject(&(reference_key(&1) in self_keys))
    |> Enum.uniq_by(&reference_key/1)
  end

  def normalize(_text, _opts), do: []

  @doc """
  Normalizes one channel ID, handle, or YouTube channel URL.
  """
  def normalize_reference(reference, opts \\ [])

  def normalize_reference(%{key: _key} = reference, opts) do
    if valid_reference?(reference) and
         reference_key(reference) not in self_reference_keys(Keyword.get(opts, :self_references, [])) do
      reference
    end
  end

  def normalize_reference(reference, opts) when is_binary(reference) do
    reference
    |> extract_references()
    |> Enum.find(fn normalized ->
      reference_key(normalized) not in self_reference_keys(Keyword.get(opts, :self_references, []))
    end)
  end

  def normalize_reference(%{external_channel_id: channel_id}, opts) when is_binary(channel_id),
    do: normalize_reference(channel_id, opts)

  def normalize_reference(%{"external_channel_id" => channel_id}, opts) when is_binary(channel_id),
    do: normalize_reference(channel_id, opts)

  def normalize_reference(%{channel_id: channel_id}, opts) when is_binary(channel_id),
    do: normalize_reference(channel_id, opts)

  def normalize_reference(%{"channel_id" => channel_id}, opts) when is_binary(channel_id),
    do: normalize_reference(channel_id, opts)

  def normalize_reference(%{channel_url: channel_url}, opts) when is_binary(channel_url),
    do: normalize_reference(channel_url, opts)

  def normalize_reference(%{"channel_url" => channel_url}, opts) when is_binary(channel_url),
    do: normalize_reference(channel_url, opts)

  def normalize_reference(%{url: url}, opts) when is_binary(url), do: normalize_reference(url, opts)
  def normalize_reference(%{"url" => url}, opts) when is_binary(url), do: normalize_reference(url, opts)

  def normalize_reference(%{original_url: url}, opts) when is_binary(url), do: normalize_reference(url, opts)

  def normalize_reference(%{"original_url" => url}, opts) when is_binary(url),
    do: normalize_reference(url, opts)

  def normalize_reference(_reference, _opts), do: nil

  @doc """
  Returns the identity key for a normalized reference.
  """
  def reference_key(%{key: key}), do: key

  @doc """
  Returns whether a value is a syntactically valid YouTube channel ID.
  """
  def valid_channel_id?(value) when is_binary(value), do: Regex.match?(@channel_id_regex, String.trim(value))
  def valid_channel_id?(_value), do: false

  @doc """
  Returns the canonical channel URL for a stable channel ID.
  """
  def channel_url(channel_id), do: "https://www.youtube.com/channel/#{channel_id}"

  defp extract_references(text) do
    url_refs =
      @youtube_url_regex
      |> Regex.scan(text, capture: :first)
      |> Enum.flat_map(fn [url] -> maybe_parse_url(url) end)

    id_refs =
      @channel_id_token_regex
      |> Regex.scan(text, capture: :first)
      |> Enum.flat_map(fn [channel_id] -> maybe_channel_id(channel_id) end)

    handle_refs =
      @handle_token_regex
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.flat_map(fn [handle] -> maybe_handle(handle) end)

    url_refs ++ id_refs ++ handle_refs
  end

  defp maybe_parse_url(url) do
    url = trim_reference_punctuation(url)

    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        parse_youtube_path(String.downcase(host), String.split(path, "/", trim: true))

      _ ->
        []
    end
  end

  defp parse_youtube_path(host, _path) when host == "youtu.be", do: []
  defp parse_youtube_path(host, _path) when host not in ["youtube.com", "www.youtube.com", "m.youtube.com"], do: []

  defp parse_youtube_path(_host, ["channel", channel_id | rest]) do
    if valid_channel_suffix?(rest), do: maybe_channel_id(channel_id), else: []
  end

  defp parse_youtube_path(_host, ["@" <> handle | rest]) do
    if valid_channel_suffix?(rest), do: maybe_handle(handle), else: []
  end

  defp parse_youtube_path(_host, [prefix, handle | rest]) when prefix in ["user", "c"] do
    if valid_channel_suffix?(rest), do: maybe_handle(handle), else: []
  end

  defp parse_youtube_path(_host, [custom_path | rest]) do
    if custom_path not in @reserved_custom_paths and valid_channel_suffix?(rest) do
      maybe_handle(custom_path)
    else
      []
    end
  end

  defp parse_youtube_path(_host, _path), do: []

  defp valid_channel_suffix?([]), do: true
  defp valid_channel_suffix?(suffix), do: suffix == [List.last(suffix)] and List.last(suffix) in @channel_suffixes

  defp maybe_channel_id(channel_id) do
    if valid_channel_id?(channel_id) do
      channel_id = String.trim(channel_id)

      [
        %{
          kind: :channel_id,
          key: "channel_id:" <> channel_id,
          external_channel_id: channel_id,
          handle: nil,
          canonical_url: channel_url(channel_id)
        }
      ]
    else
      []
    end
  end

  defp maybe_handle(handle) do
    handle = String.trim_leading(trim_reference_punctuation(handle), "@")

    if Regex.match?(@handle_regex, handle) do
      handle = String.downcase(handle)

      [
        %{
          kind: :handle,
          key: "handle:" <> handle,
          external_channel_id: nil,
          handle: handle,
          canonical_url: "https://www.youtube.com/@#{handle}"
        }
      ]
    else
      []
    end
  end

  defp self_reference_keys(references) do
    references
    |> List.wrap()
    |> Enum.flat_map(fn
      %{key: key} = reference when is_binary(key) -> [reference]
      reference when is_binary(reference) -> extract_references(reference)
      _reference -> []
    end)
    |> MapSet.new(&reference_key/1)
  end

  defp valid_reference?(%{kind: :channel_id, external_channel_id: id}) do
    valid_channel_id?(id)
  end

  defp valid_reference?(%{kind: :handle, handle: handle}), do: is_binary(handle) and Regex.match?(@handle_regex, handle)
  defp valid_reference?(_reference), do: false

  defp trim_reference_punctuation(reference) do
    String.trim(reference, " \t\r\n.,;:!?)]}>\"")
  end
end
