defmodule PinchflatWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CoreComponents

  describe "list_items_from_map/1" do
    test "renders nested pairs with a nil path without raising" do
      html = render_component(&CoreComponents.list_items_from_map/1, %{map: %{subtitle_filepaths: [["en", nil]]}})

      assert html =~ "subtitle_filepaths"
      assert html =~ "[en, nil]"
    end

    test "renders language and path pairs" do
      html =
        render_component(&CoreComponents.list_items_from_map/1, %{
          map: %{
            subtitle_filepaths: [
              ["en", "/downloads/sub.en.srt"],
              ["ko", "/downloads/sub.ko.srt"]
            ]
          }
        })

      assert html =~ "[en, /downloads/sub.en.srt], [ko, /downloads/sub.ko.srt]"
    end

    test "renders multiple languages with a mix of complete and incomplete pairs" do
      html =
        render_component(&CoreComponents.list_items_from_map/1, %{
          map: %{
            subtitle_filepaths: [
              ["de", "/downloads/sub.de.srt"],
              ["en", nil],
              ["ko", "/downloads/sub.ko.srt"]
            ]
          }
        })

      assert html =~ "[de, /downloads/sub.de.srt], [en, nil], [ko, /downloads/sub.ko.srt]"
    end

    test "renders flat lists of scalars separated by commas" do
      html = render_component(&CoreComponents.list_items_from_map/1, %{map: %{tags: ["music", "live"]}})

      assert html =~ "tags"
      assert html =~ "music, live"
    end

    test "renders empty lists without raising" do
      html = render_component(&CoreComponents.list_items_from_map/1, %{map: %{subtitle_filepaths: []}})

      assert html =~ "subtitle_filepaths"
    end

    test "escapes HTML-like strings in rendered output" do
      html =
        render_component(&CoreComponents.list_items_from_map/1, %{
          map: %{title: "<script>alert('xss')</script>"}
        })

      assert html =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      refute html =~ "<script>alert"
    end

    test "renders long subtitle filepaths so long paths wrap instead of clipping" do
      long_path =
        "/storage/downloads/channel_with_a_very_long_name/20261116_extremely_long_video_title_with_extra_details_and_tags.en.vtt"

      html =
        render_component(&CoreComponents.list_items_from_map/1, %{
          map: %{
            subtitle_filepaths: [["en", long_path]]
          }
        })

      assert html =~ "[overflow-wrap:anywhere]"
      assert html =~ long_path
    end

    test "renders media profile attributes map without raising" do
      profile_map = %{
        name: "Default Profile",
        format: "mp4",
        audio_codec: "aac",
        custom_args: ["--sleep-subtitles", "5", "--no-warnings"]
      }

      html = render_component(&CoreComponents.list_items_from_map/1, %{map: profile_map})

      assert html =~ "Default Profile"
      assert html =~ "--sleep-subtitles, 5, --no-warnings"
    end
  end
end
