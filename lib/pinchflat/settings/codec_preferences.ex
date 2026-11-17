defmodule Pinchflat.Settings.CodecPreferences do
  @moduledoc """
  Parses, validates and formats the ordered video/audio codec preference lists.

  The preferences live in the existing `settings.video_codec_preference` and
  `settings.audio_codec_preference` string columns as a canonical comma-separated
  list. A single token keeps its historical meaning, so existing installations stay
  compatible without a data migration.

  An empty list is stored as `""` rather than SQL NULL: the columns are NOT NULL and
  blank must mean "no application codec preference for this stream".

  Validation is bounded and server-side, and rejects codecs the packaged yt-dlp
  cannot rank. Tokens are compared by codec family, so `vp9`/`vp09` or `aac`/`m4a`
  count as duplicates instead of silently collapsing into one rank.
  """

  @max_items 8
  @max_bytes 256

  # Mirrors the vcodec/acodec order tables in yt-dlp's FormatSorter. Kept as explicit
  # patterns so validation never depends on loading yt-dlp itself, and so the accepted
  # aliases are documented in one place.
  @video_families [
    {~r/^av0?1/, :av1},
    {~r/^vp0?9/, :vp9},
    {~r/^he?vc?|^[hx]265/, :hevc},
    {~r/^avc|^[hx]264/, :avc},
    {~r/^vp0?8/, :vp8},
    {~r/^mp4v|^h263/, :mp4v}
  ]

  @audio_families [
    {~r/^[af]lac/, :flac},
    {~r/^wav|^aiff|^pcm/, :wav},
    {~r/^opus/, :opus},
    {~r/^vorbis|^ogg/, :vorbis},
    # yt-dlp collapses both aac and m4a to the same mp4a.* regex, so they are one
    # family here: listing both would silently merge into a single rank.
    {~r/^aac|^mp?4a?/, :m4a},
    {~r/^mp3/, :mp3},
    {~r/^ac-?4/, :ac4},
    {~r/^e-?a?c-?3/, :eac3},
    {~r/^ac-?3|^dts/, :ac3}
  ]

  @doc """
  Returns the maximum number of entries allowed in each list.
  """
  def max_items, do: @max_items

  @doc """
  Returns the maximum serialized size in bytes for each list.
  """
  def max_bytes, do: @max_bytes

  @doc """
  Returns the recognized families for a stream, in yt-dlp preference order.
  """
  def families(:video), do: Enum.map(@video_families, &elem(&1, 1))
  def families(:audio), do: Enum.map(@audio_families, &elem(&1, 1))

  @doc """
  Parses a stored string into a list of tokens. Blank input returns []. Malformed
  entries are preserved so validation can report them instead of silently changing
  what the user saved.

  Returns [String.t()]
  """
  def parse(nil), do: []

  def parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Formats a list of tokens into the canonical stored string.

  Returns String.t()
  """
  def format(nil), do: ""

  def format(tokens) when is_list(tokens) do
    tokens
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  @doc """
  Validates a raw preference string for the given stream.

  Returns :ok or {:error, String.t()} with an actionable message.
  """
  def validate(kind, value) do
    raw = value || ""

    if byte_size(raw) > @max_bytes do
      {:error, "must be at most #{@max_bytes} bytes; shorten the list"}
    else
      validate_tokens(kind, parse(raw))
    end
  end

  defp validate_tokens(kind, tokens) do
    if length(tokens) > @max_items do
      {:error, "must contain at most #{@max_items} codecs"}
    else
      with :ok <- validate_known(kind, tokens) do
        validate_unique(kind, tokens)
      end
    end
  end

  defp validate_known(kind, tokens) do
    case Enum.find(tokens, &(family(kind, &1) == nil)) do
      nil -> :ok
      token -> {:error, "contains an unsupported codec #{inspect(token)}; use a recognized codec name"}
    end
  end

  defp validate_unique(kind, tokens) do
    duplicates =
      tokens
      |> Enum.group_by(&family(kind, &1))
      |> Enum.filter(fn {_family, group} -> length(group) > 1 end)

    case duplicates do
      [] ->
        :ok

      [{_family, group} | _] ->
        {:error, "lists the same codec twice (#{Enum.join(group, ", ")}); keep only one entry"}
    end
  end

  @doc """
  Returns the codec family for a single token, or nil when unsupported.

  Returns atom() | nil
  """
  def family(kind, token) when is_binary(token) do
    normalized = token |> String.trim() |> String.downcase()

    Enum.find_value(families_for(kind), fn {pattern, family} ->
      if Regex.match?(pattern, normalized), do: family
    end)
  end

  def family(_kind, _token), do: nil

  @doc """
  Returns the canonical token for a given codec token, matching the select options.
  Known aliases are mapped to the canonical select value (e.g., "h264" -> "avc", "aac" -> "m4a").
  Unknown tokens are returned trimmed and lowercased so validation can report them.
  """
  def canonical_token(kind, token) when is_binary(token) do
    normalized = token |> String.trim() |> String.downcase()

    case family(kind, normalized) do
      nil -> normalized
      family -> Atom.to_string(family)
    end
  end

  def canonical_token(token, kind) when is_binary(token) and is_atom(kind) do
    canonical_token(kind, token)
  end

  def canonical_token(_kind, token), do: token

  @doc """
  Canonicalizes a list of tokens.
  """
  def canonical_tokens(tokens, kind) when is_list(tokens) and is_atom(kind) do
    Enum.map(tokens, &canonical_token(kind, &1))
  end

  def canonical_tokens(kind, tokens) when is_list(tokens) and is_atom(kind) do
    Enum.map(tokens, &canonical_token(kind, &1))
  end

  defp families_for(:video), do: @video_families
  defp families_for(:audio), do: @audio_families

  @doc """
  Returns true when the list is a single entry, which keeps the legacy command path.

  Returns boolean()
  """
  def single_entry?(value), do: length(parse(value)) == 1

  @doc """
  Returns true when the list holds more than one entry, which needs the ordered
  plugin path.

  Returns boolean()
  """
  def ordered?(value), do: length(parse(value)) > 1

  @doc """
  Returns the first token, used by the legacy single-codec command path.

  Returns String.t() | nil
  """
  def single_token(value) do
    case parse(value) do
      [token | _] -> token
      [] -> nil
    end
  end

  @doc """
  Returns true when at least one stream has an ordered list, so the
  application-owned plugin is required for this download.

  Returns boolean()
  """
  def plugin_required?(video_value, audio_value) do
    ordered?(video_value) or ordered?(audio_value)
  end
end
