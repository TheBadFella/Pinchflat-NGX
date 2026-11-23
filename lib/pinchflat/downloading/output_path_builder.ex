defmodule Pinchflat.Downloading.OutputPathBuilder do
  @moduledoc """
  Builds yt-dlp-friendly output paths for downloaded media
  """

  alias Pinchflat.Downloading.OutputPath.Parser, as: TemplateParser

  @padded_identifiers ~w(media_playlist_index media_upload_date_index)
  @default_padding_width 2
  @max_padding_width 6

  @yt_dlp_field_regex ~r/%%|%\((?:[^()]|\([^()]*\))*\)[#0\-+ ]*\d*(?:\.\d+)?[hlL]?[diouxXeEfFgGcrsaBjhlqDSU]/u
  @whole_yt_dlp_field_regex Regex.compile!("\\A(?:" <> Regex.source(@yt_dlp_field_regex) <> ")\\z", "u")
  @windows_unsafe_regex ~r/[<>:"|?*\x00-\x1f\x7f]/u
  @restricted_chars String.graphemes("|*<>!&'()[]{}$;`^,#")

  @doc """
  Encodes a display name as one literal filename component, without interpreting
  template syntax or allowing directory separators.
  """
  def literal_component(value) when is_binary(value) do
    component =
      value
      |> String.replace(~r/[<>:"\/\\|?*\x00-\x1f\x7f]/u, "_")
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.replace("%", "%%")

    {:literal, if(component == "", do: "_", else: component)}
  end

  @doc """
  Sanitizes the literal text of a yt-dlp output template the way yt-dlp
  sanitizes field values, following `--restrict-filenames` when `restrict`
  is true and `--windows-filenames` otherwise. `%(...)` fields are unchanged.

  Returns binary()
  """
  def sanitize_literal_text(template, restrict) do
    @yt_dlp_field_regex
    |> Regex.split(template, include_captures: true)
    |> Enum.map_join(fn piece ->
      if Regex.match?(@whole_yt_dlp_field_regex, piece),
        do: piece,
        else: sanitize_text(piece, restrict)
    end)
  end

  defp sanitize_text(text, false), do: String.replace(text, @windows_unsafe_regex, "_")

  defp sanitize_text(text, true) do
    text
    |> :unicode.characters_to_nfkd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.graphemes()
    |> Enum.flat_map(&restrict_char/1)
    |> collapse_replaced_underscores()
    |> trim_replaced_underscores()
    |> Enum.map_join(fn {char, _replaced?} -> char end)
  end

  defp restrict_char("/"), do: [{"/", false}]
  defp restrict_char(char) when char in ["?", "\""], do: []
  defp restrict_char(":"), do: [{"_", true}, {"-", true}]
  defp restrict_char(<<codepoint::utf8>>) when codepoint < 32 or codepoint == 127, do: []

  defp restrict_char(char) do
    if char in @restricted_chars or byte_size(char) > 1 or String.trim(char) == "",
      do: [{"_", true}],
      else: [{char, false}]
  end

  defp collapse_replaced_underscores(chars) do
    chars
    |> Enum.reduce([], fn
      {"_", replaced?}, [{"_", previous_replaced?} | rest] when replaced? or previous_replaced? ->
        [{"_", replaced? and previous_replaced?} | rest]

      char, acc ->
        [char | acc]
    end)
    |> Enum.reverse()
  end

  defp trim_replaced_underscores(chars) do
    chars
    |> Enum.with_index()
    |> Enum.reject(fn
      {{"_", true}, index} ->
        previous = if index > 0, do: Enum.at(chars, index - 1)
        following = Enum.at(chars, index + 1)

        match?({"/", _}, previous) or match?({"/", _}, following) or match?({".", _}, following)

      _ ->
        false
    end)
    |> Enum.map(fn {char, _index} -> char end)
  end

  @doc """
  Wraps an integer so templates render it zero-padded: two digits by default,
  or the width given with `{{ identifier:N }}`.
  """
  def padded_integer(value), do: {:padded_integer, value}

  @doc """
  Checks that a template parses and only sets a padding width on the numeric
  index variables, within the supported range.

  Returns `:ok` or `{:error, binary()}`.
  """
  def validate_template(template_string) do
    case TemplateParser.interpolations(template_string) do
      {:ok, interpolations} -> Enum.find_value(interpolations, :ok, &validate_interpolation/1)
      {:error, _message} -> {:error, "has a {{ }} variable that can't be read"}
    end
  end

  defp validate_interpolation({_identifier, nil}), do: nil

  defp validate_interpolation({identifier, width}) when identifier in @padded_identifiers do
    if width in 1..@max_padding_width,
      do: nil,
      else: {:error, "sets #{identifier} padding to #{width}; use a width from 1 to #{@max_padding_width}"}
  end

  defp validate_interpolation({identifier, _width}) do
    {:error, "sets a padding width on #{identifier}; only #{Enum.join(@padded_identifiers, " and ")} accept one"}
  end

  @doc """
  Builds the actual final filepath from a given template. Optionally, you can pass in
  a map of additional options to be used in the template.

  Custom options are recursively expanded _once_ so you can nest custom options
  one-deep if needed.

  Translates liquid-style templates into yt-dlp-style templates,
  leaving yt-dlp syntax intact.
  """
  def build(template_string, additional_template_options \\ %{}) do
    combined_options = Map.merge(custom_yt_dlp_option_map(), additional_template_options)

    expanded_options =
      Enum.map(combined_options, fn {key, value} ->
        case value do
          {:literal, literal} ->
            {key, literal}

          {:padded_integer, _} ->
            {key, value}

          template ->
            {:ok, parse_result} = TemplateParser.parse(template, combined_options, &identifier_fn/2)
            {key, parse_result}
        end
      end)

    TemplateParser.parse(template_string, Map.new(expanded_options), &identifier_fn/2)
  end

  # The `nil` case simply wraps the identifier in yt-dlp-style syntax. This assumes that
  # the identifier is a valid yt-dlp option. The upside is that this gives the user
  # access to ALL single-word yt-dlp options in the (imo) more friendly/forgiving liquid-style syntax.
  #
  # For all "custom" variables, we use the `Map.get/3` function to look up the value in the provided.
  # See `custom_yt_dlp_option_map` for a list of those.
  defp identifier_fn({identifier, width}, variables) do
    case Map.get(variables, identifier) do
      {:padded_integer, value} -> pad_integer(value, width)
      _ -> identifier_fn(identifier, variables)
    end
  end

  defp identifier_fn(identifier, variables) do
    case Map.get(variables, identifier) do
      nil -> "%(#{identifier})S"
      {:literal, literal} -> literal
      {:padded_integer, value} -> pad_integer(value, @default_padding_width)
      value -> value
    end
  end

  defp pad_integer(value, width) do
    value
    |> to_string()
    |> String.pad_leading(width, "0")
  end

  # This isn't the only source for custom options, since they can be passed in my the caller.
  # `download_option_builder` is the most likely place for other custom options to be added,
  # but if in doubt just search the codebase for `OutputPathBuilder.build`.
  defp custom_yt_dlp_option_map do
    %{
      # Individual parts of the upload date
      "upload_year" => "%(upload_date>%Y)S",
      "upload_month" => "%(upload_date>%m)S",
      "upload_day" => "%(upload_date>%d)S",
      "upload_yyyy_mm_dd" => "%(upload_date>%Y-%m-%d)S",
      "season_from_date" => "%(upload_date>%Y)S",
      "season_episode_from_date" => "s%(upload_date>%Y)Se%(upload_date>%m%d)S",
      "season_episode_index_from_date" => "s%(upload_date>%Y)Se%(upload_date>%m%d)S{{ media_upload_date_index }}",
      "artist_name" => "%(artist,creator,uploader,uploader_id)S",
      "static_season__episode_by_index" => "Season 1/s01e{{ media_playlist_index }}",
      "static_season__episode_by_date" => "Season 1/s01e%(upload_date>%y%m%d)S",
      "season_by_year__episode_by_date" => "Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S",
      "season_by_year__episode_by_date_and_index" =>
        "Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S{{ media_upload_date_index }}"
    }
  end
end
