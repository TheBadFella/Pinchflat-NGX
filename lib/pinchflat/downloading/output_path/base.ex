defmodule Pinchflat.Downloading.OutputPath.Base do
  @moduledoc """
  A base module for parsing rendered strings, designed as a macro to be used
  in other modules. See https://elixirforum.com/t/help-to-parse-a-template-with-nimbleparsec/47980

  NOTE: if the needs here get any more complicated, look into using a Liquid
  template parser. No need to reinvent the wheel any more than I already have.

  NOTE: this is effectively tested by the `Pinchflat.Downloading.OutputPath.Parser`'s tests
  """

  defmacro __using__(_opts) do
    quote location: :keep do
      import NimbleParsec

      opening_tag = string("{{")
      closing_tag = string("}}")
      optional_whitespaces = ascii_string(~c[ \t\n\r], min: 0)

      # Capture everything up to the opening object
      text =
        lookahead_not(opening_tag)
        # ... as long as it's a character
        |> utf8_char([])
        # ... and there's at least one character
        |> times(min: 1)
        # ... and then convert it to a string
        |> reduce({List, :to_string, []})
        # ... finally bag it and tag it
        |> unwrap_and_tag(:text)

      identifier =
        utf8_string([?a..?z, ?A..?Z, ?_, ?0..?9], min: 1)
        |> reduce({Enum, :join, []})
        |> unwrap_and_tag(:identifier)

      # an optional `:N` after the identifier sets a zero-padding width, eg: `{{ media_playlist_index:3 }}`
      width =
        ignore(concat(optional_whitespaces, string(":")))
        |> ignore(optional_whitespaces)
        |> integer(min: 1, max: 2)
        |> unwrap_and_tag(:width)

      defparsecp(:expression, identifier |> optional(width))

      # when spotting interpolation, ignore the opening tag and any whitespace
      interpolation =
        ignore(concat(opening_tag, optional_whitespaces))
        # ... then parse the expression (identifier and optional width)
        |> parsec(:expression)
        # ... then ignore any whitespace and the closing tags after the expression
        |> ignore(concat(optional_whitespaces, closing_tag))
        # ... once again we bag it and tag it
        |> tag(:interpolation)

      defparsec(:do_parse, choice([interpolation, text]) |> repeat() |> eos())
    end
  end
end
