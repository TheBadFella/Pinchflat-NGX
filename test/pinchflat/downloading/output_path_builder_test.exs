defmodule Pinchflat.Downloading.OutputPathBuilderTest do
  use Pinchflat.DataCase

  alias Pinchflat.Downloading.OutputPathBuilder

  describe "literal_component/1" do
    test "names remain one component and cannot inject either template syntax" do
      for {name, expected} <- [
            {"../../outside", ".._.._outside"},
            {"..\\..\\outside", ".._.._outside"},
            {" .. ", "_"},
            {"100% {{ title }}", "100%% {{ title }}"},
            {"%(title)s", "%%(title)s"},
            {"A/B:C", "A_B_C"},
            {"one\ntwo", "one_two"}
          ] do
        assert {:ok, output} =
                 OutputPathBuilder.build(
                   "{{ name }}/{{ title }}.{{ ext }}",
                   %{"name" => OutputPathBuilder.literal_component(name)}
                 )

        assert output == expected <> "/%(title)S.%(ext)S"
      end
    end
  end

  describe "sanitize_literal_text/2" do
    test "when restricted, restricts the template's own text but not yt-dlp fields" do
      assert OutputPathBuilder.sanitize_literal_text(
               "/%(channel)S/%(upload_date>%Y-%m-%d)S - %(title)S.%(ext)S",
               true
             ) == "/%(channel)S/%(upload_date>%Y-%m-%d)S_-_%(title)S.%(ext)S"
    end

    test "when restricted, transliterates accents and drops or replaces unsafe characters" do
      assert OutputPathBuilder.sanitize_literal_text("Season 1/Café: Q&A?.%(ext)s", true) ==
               "Season_1/Cafe_-_Q_A.%(ext)s"
    end

    test "when restricted, doesn't leave replacement underscores at component or extension boundaries" do
      assert OutputPathBuilder.sanitize_literal_text("/[Archive]/%(title)S [%(id)S].%(ext)S", true) ==
               "/Archive/%(title)S_%(id)S.%(ext)S"
    end

    test "when restricted, keeps underscores already in the template" do
      template = "/My Channel/__PINCHFLAT_SERIES_ROOT__/%(title)S.%(ext)S"

      assert OutputPathBuilder.sanitize_literal_text(template, true) ==
               "/My_Channel/__PINCHFLAT_SERIES_ROOT__/%(title)S.%(ext)S"
    end

    test "when restricted, keeps a path component that would sanitize to nothing" do
      assert OutputPathBuilder.sanitize_literal_text("/Лонгплей/%(title)S.%(ext)S", true) ==
               "/Лонгплей/%(title)S.%(ext)S"
    end

    test "keeps path separators in both modes" do
      template = "/Channel Videos/Season 1\\Extras/%(title)S.%(ext)S"

      assert OutputPathBuilder.sanitize_literal_text(template, true) ==
               "/Channel_Videos/Season_1\\Extras/%(title)S.%(ext)S"

      assert OutputPathBuilder.sanitize_literal_text(template, false) == template
    end

    test "field defaults and %% escapes are left intact" do
      assert OutputPathBuilder.sanitize_literal_text("%(title|Untitled video)s 100%%.%(ext)s", true) ==
               "%(title|Untitled video)s_100%%.%(ext)s"
    end

    test "when not restricted, replaces characters Windows can't use and keeps spaces" do
      assert OutputPathBuilder.sanitize_literal_text("Q&A: part 1?/%(title)S [%(id)S].%(ext)S", false) ==
               "Q&A_ part 1_/%(title)S [%(id)S].%(ext)S"
    end
  end

  describe "padded_integer/1" do
    test "pads to 2 digits by default and to the template's width when given" do
      options = %{"media_playlist_index" => OutputPathBuilder.padded_integer(7)}

      assert {:ok, "07"} = OutputPathBuilder.build("{{ media_playlist_index }}", options)
      assert {:ok, "007"} = OutputPathBuilder.build("{{ media_playlist_index:3 }}", options)
      assert {:ok, "7"} = OutputPathBuilder.build("{{ media_playlist_index:1 }}", options)
    end

    test "never truncates a value wider than the padding" do
      options = %{"media_playlist_index" => OutputPathBuilder.padded_integer(1234)}

      assert {:ok, "1234"} = OutputPathBuilder.build("{{ media_playlist_index:3 }}", options)
    end

    test "keeps the default padding inside nested custom aliases" do
      options = %{"media_playlist_index" => OutputPathBuilder.padded_integer(4)}

      assert {:ok, "Season 1/s01e04"} = OutputPathBuilder.build("{{ static_season__episode_by_index }}", options)
    end
  end

  describe "validate_template/1" do
    test "accepts templates without widths and index widths from 1 to 6" do
      for template <- [
            "{{ title }}.{{ ext }}",
            "{{ media_playlist_index:3 }} - {{ title }}.{{ ext }}",
            "{{ media_upload_date_index : 6 }}.%(ext)s",
            "{{media_playlist_index:1}}.{{ ext }}"
          ] do
        assert :ok = OutputPathBuilder.validate_template(template)
      end
    end

    test "rejects out-of-range widths, widths on other variables and unreadable variables" do
      assert {:error, "sets media_playlist_index padding to 7" <> _} =
               OutputPathBuilder.validate_template("{{ media_playlist_index:7 }}.{{ ext }}")

      assert {:error, "sets media_playlist_index padding to 0" <> _} =
               OutputPathBuilder.validate_template("{{ media_playlist_index:0 }}.{{ ext }}")

      assert {:error, "sets a padding width on title" <> _} =
               OutputPathBuilder.validate_template("{{ title:3 }}.{{ ext }}")

      assert {:error, "has a {{ }} variable that can't be read"} =
               OutputPathBuilder.validate_template("{{ media_playlist_index:x }}.{{ ext }}")
    end
  end

  describe "build/2" do
    test "it expands 'standard' curly brace variables in the template" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/{{ title }}.{{ ext }}")

      assert res == "/videos/%(title)S.%(ext)S"
    end

    test "it expands 'custom' curly brace variables in the template" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/{{ upload_year }}.{{ ext }}")

      assert res == "/videos/%(upload_date>%Y)S.%(ext)S"
    end

    test "it respects additional options" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/{{ custom }}.{{ ext }}", %{"custom" => "test"})

      assert res == "/videos/test.%(ext)S"
    end

    test "it leaves yt-dlp variables alone" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/%(title)s.%(ext)s")

      assert res == "/videos/%(title)s.%(ext)s"
    end

    test "recursively expands variables" do
      additional_options = %{
        "media_upload_date_index" => "99"
      }

      assert {:ok, res} = OutputPathBuilder.build("{{ season_episode_index_from_date }}.{{ ext }}", additional_options)

      assert res == "s%(upload_date>%Y)Se%(upload_date>%m%d)S99.%(ext)S"
    end
  end
end
