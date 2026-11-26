defmodule Pinchflat.Downloading.OutputPath.Parser do
  @moduledoc """
  Parses liquid-ish-style strings into a rendered string

  Used for turning filepath templates into real filepaths
  """

  use Pinchflat.Downloading.OutputPath.Base

  @doc """
  Parses a string into a rendered string, using the provided variables. Optionally
  takes a custom fetcher function for handling missing variables.

  Variable identifiers are surrounded by {{ and }}. The variable keys MUST be strings.
  If an identifier is not found in the provided variables, it will be removed from the string.
  An identifier followed by `:N` (eg: `{{ media_playlist_index:3 }}`) is passed to the fetcher
  as `{identifier, N}` so it can apply that zero-padding width.

  Returns `{:ok, binary()}` or `{:error, binary()}`.
  """
  def parse(string, variables, value_fetch_fn \\ &default_fetcher/2) do
    # `do_parse` comes from `RenderedString.Base`
    case do_parse(string) do
      {:ok, parsed, _, _, _, _} ->
        {:ok, build_string(parsed, variables, value_fetch_fn)}

      {:error, message, _, _, _, _} ->
        {:error, message}
    end
  end

  defp build_string(parsed, variables, value_fetch_fn) do
    Enum.reduce(parsed, "", fn element, acc ->
      case element do
        {:text, text} ->
          acc <> text

        {:interpolation, [identifier: identifier]} ->
          acc <> value_fetch_fn.(identifier, variables)

        {:interpolation, [identifier: identifier, width: width]} ->
          acc <> value_fetch_fn.({identifier, width}, variables)
      end
    end)
  end

  @doc """
  Lists the interpolations in a template as `{identifier, width}` pairs, where
  `width` is `nil` when the template doesn't set one.

  Returns `{:ok, [{binary(), integer() | nil}]}` or `{:error, binary()}`.
  """
  def interpolations(string) do
    case do_parse(string) do
      {:ok, parsed, _, _, _, _} ->
        {:ok, for({:interpolation, parts} <- parsed, do: {parts[:identifier], parts[:width]})}

      {:error, message, _, _, _, _} ->
        {:error, message}
    end
  end

  def default_fetcher({identifier, _width}, variables), do: default_fetcher(identifier, variables)

  def default_fetcher(identifier, variables) do
    Map.get(variables, identifier, "")
  end
end
