defmodule Pinchflat.YoutubeBrowser.UrlParserTest do
  use ExUnit.Case, async: true

  alias Pinchflat.YoutubeBrowser.UrlParser

  describe "parse/1 valid URLs" do
    test "parses canonical desktop watch URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "parses naked domain watch URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "parses mobile watch URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://m.youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "parses music.youtube.com watch URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "parses HTTP and canonicalizes to HTTPS without fetching" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("http://www.youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "parses youtu.be short URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://youtu.be/dQw4w9WgXcQ")
    end

    test "parses /shorts/ URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ")
    end

    test "parses embedded video URLs" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ"}} =
               UrlParser.parse("https://www.youtube.com/embed/dQw4w9WgXcQ")
    end

    test "parses /live/ URL" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://www.youtube.com/live/dQw4w9WgXcQ")
    end

    test "parses watch URL with list parameter as single video, stripping list" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLrEnWoR732-C4r42LQ428442")
    end

    test "strips timestamp, tracking, and query params from watch and youtu.be URLs" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&si=abc123tracking&feature=share")

      assert {:ok, %{video_id: "dQw4w9WgXcQ", canonical_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}} =
               UrlParser.parse("https://youtu.be/dQw4w9WgXcQ?si=trackingcode&t=10")
    end

    test "trims leading and trailing whitespace" do
      assert {:ok, %{video_id: "dQw4w9WgXcQ"}} =
               UrlParser.parse("   https://www.youtube.com/watch?v=dQw4w9WgXcQ  \n")
    end
  end

  describe "parse/1 channel and playlist rejection" do
    test "rejects pure playlist URL with guidance" do
      assert {:error, {:channel_or_playlist, msg}} =
               UrlParser.parse("https://www.youtube.com/playlist?list=PLrEnWoR732-C4r42LQ428442")

      assert msg =~ "subscription workflow"
    end

    test "rejects channel ID URL" do
      assert {:error, {:channel_or_playlist, msg}} =
               UrlParser.parse("https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw")

      assert msg =~ "subscription workflow"
    end

    test "rejects channel custom URL (/c/)" do
      assert {:error, {:channel_or_playlist, msg}} =
               UrlParser.parse("https://www.youtube.com/c/GoogleDevelopers")

      assert msg =~ "subscription workflow"
    end

    test "rejects channel handle URL (/@handle)" do
      assert {:error, {:channel_or_playlist, msg}} =
               UrlParser.parse("https://www.youtube.com/@GoogleDevelopers")

      assert msg =~ "subscription workflow"
    end

    test "rejects user channel URL (/user/)" do
      assert {:error, {:channel_or_playlist, msg}} =
               UrlParser.parse("https://www.youtube.com/user/GoogleDevelopers")

      assert msg =~ "subscription workflow"
    end
  end

  describe "parse/1 invalid and hostile inputs" do
    test "rejects empty string or whitespace" do
      assert {:error, :empty_url} = UrlParser.parse("")
      assert {:error, :empty_url} = UrlParser.parse("   ")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_input} = UrlParser.parse(nil)
      assert {:error, :invalid_input} = UrlParser.parse(12_345)
    end

    test "rejects strings exceeding 2048 bytes" do
      oversized = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&extra=" <> String.duplicate("a", 2050)
      assert {:error, :url_too_long} = UrlParser.parse(oversized)
    end

    test "rejects non-http schemes" do
      assert {:error, :unsupported_scheme} = UrlParser.parse("javascript:alert(1)")
      assert {:error, :unsupported_scheme} = UrlParser.parse("file:///etc/passwd")
      assert {:error, :unsupported_scheme} = UrlParser.parse("ftp://youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "rejects user credentials in URL" do
      assert {:error, :credentials_not_allowed} =
               UrlParser.parse("https://admin:secret@youtube.com/watch?v=dQw4w9WgXcQ")
    end

    test "rejects non-default ports" do
      assert {:error, :non_default_port} =
               UrlParser.parse("https://youtube.com:8443/watch?v=dQw4w9WgXcQ")

      assert {:error, :non_default_port} =
               UrlParser.parse("http://youtube.com:8080/watch?v=dQw4w9WgXcQ")
    end

    test "rejects deceptive suffix hosts and untrusted domains" do
      assert {:error, :unsupported_host} =
               UrlParser.parse("https://youtube.com.attacker.com/watch?v=dQw4w9WgXcQ")

      assert {:error, :unsupported_host} =
               UrlParser.parse("https://evil-site.org/watch?v=dQw4w9WgXcQ")
    end

    test "rejects IP literals" do
      assert {:error, :unsupported_host} =
               UrlParser.parse("http://127.0.0.1/watch?v=dQw4w9WgXcQ")

      assert {:error, :unsupported_host} =
               UrlParser.parse("http://[::1]/watch?v=dQw4w9WgXcQ")
    end

    test "rejects extra path segments on youtu.be" do
      assert {:error, :extra_path_segments} =
               UrlParser.parse("https://youtu.be/dQw4w9WgXcQ/extra/path")
    end

    test "rejects extra path segments on shorts and live" do
      assert {:error, :extra_path_segments} =
               UrlParser.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ/extra")

      assert {:error, :extra_path_segments} =
               UrlParser.parse("https://www.youtube.com/live/dQw4w9WgXcQ/extra")
    end

    test "rejects watch URL without v parameter" do
      assert {:error, :missing_video_id} =
               UrlParser.parse("https://www.youtube.com/watch")
    end

    test "rejects conflicting multiple v parameters" do
      assert {:error, :conflicting_video_id_parameters} =
               UrlParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&v=anotherVid12")
    end

    test "rejects malformed video ID (not 11 valid characters)" do
      assert {:error, :invalid_video_id} =
               UrlParser.parse("https://www.youtube.com/watch?v=tooShort")

      assert {:error, :invalid_video_id} =
               UrlParser.parse("https://www.youtube.com/watch?v=wayTooLongVideoId1234567")

      assert {:error, :invalid_video_id} =
               UrlParser.parse("https://www.youtube.com/watch?v=invalid$char")
    end
  end
end
