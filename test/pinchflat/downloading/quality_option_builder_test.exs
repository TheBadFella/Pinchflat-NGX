defmodule Pinchflat.Downloading.QualityOptionBuilderTest do
  use Pinchflat.DataCase
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles
  alias Pinchflat.Settings
  alias Pinchflat.Downloading.QualityOptionBuilder

  describe "build/1" do
    test "includes format options if audio_track is set to original" do
      media_profile = media_profile_fixture(%{audio_track: "original"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo+bestaudio[format_note*=original]/bestvideo*+bestaudio/best"} in res
    end

    test "includes format options if audio_track is set to default" do
      media_profile = media_profile_fixture(%{audio_track: "default"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo+bestaudio[format_note*='(default)']/bestvideo*+bestaudio/best"} in res
    end

    test "includes format options if audio_track is set to a language code" do
      media_profile = media_profile_fixture(%{audio_track: "en"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo+bestaudio[language^=en]/bestvideo*+bestaudio/best"} in res
    end

    test "excludes AI-upscaled formats from video and fallback selectors" do
      media_profile =
        media_profile_fixture(%{
          audio_track: "original",
          ignore_youtube_super_resolution: true
        })

      assert res = QualityOptionBuilder.build(media_profile)

      filter = "[format_note!*=?AI-upscaled]"

      assert {:format,
              "bestvideo#{filter}+bestaudio[format_note*=original]#{filter}/" <>
                "bestvideo*#{filter}+bestaudio#{filter}/best#{filter}"} in res
    end
  end

  describe "build/1 when testing audio profiles" do
    setup do
      {:ok, media_profile: media_profile_fixture(%{preferred_resolution: :audio})}
    end

    test "includes quality options for audio only", %{media_profile: media_profile} do
      assert res = QualityOptionBuilder.build(media_profile)

      assert :extract_audio in res
      assert {:format_sort, "+acodec:m4a"} in res

      refute {:remux_video, "mp4"} in res
    end

    test "includes custom format target for audio if specified", %{media_profile: media_profile} do
      {:ok, media_profile} =
        Profiles.update_media_profile(media_profile, %{media_container: "flac", preferred_resolution: :audio})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:audio_format, "flac"} in res
    end

    test "includes custom format options", %{media_profile: media_profile} do
      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestaudio/best"} in res
    end

    test "excludes AI-upscaled formats from audio selectors", %{media_profile: media_profile} do
      {:ok, media_profile} =
        Profiles.update_media_profile(media_profile, %{ignore_youtube_super_resolution: true})

      assert res = QualityOptionBuilder.build(media_profile)

      filter = "[format_note!*=?AI-upscaled]"
      assert {:format, "bestaudio#{filter}/best#{filter}"} in res
    end

    test "combines the AI-upscaled filter with an audio track preference", %{media_profile: media_profile} do
      {:ok, media_profile} =
        Profiles.update_media_profile(media_profile, %{
          audio_track: "original",
          ignore_youtube_super_resolution: true
        })

      assert res = QualityOptionBuilder.build(media_profile)

      filter = "[format_note!*=?AI-upscaled]"

      assert {:format, "bestaudio[format_note*=original]#{filter}/bestaudio#{filter}/best#{filter}"} in res
    end
  end

  describe "build/1 when testing non-audio profiles" do
    setup do
      {:ok, media_profile: media_profile_fixture(%{preferred_resolution: :"480p"})}
    end

    test "includes quality options" do
      resolutions = ["360", "480", "720", "1080", "1440", "2160", "4320"]

      Enum.each(resolutions, fn resolution ->
        resolution_atom = String.to_existing_atom(resolution <> "p")
        media_profile = media_profile_fixture(%{preferred_resolution: resolution_atom})

        assert res = QualityOptionBuilder.build(media_profile)

        assert {:format_sort, "res:#{resolution},+codec:avc:m4a"} in res
        assert {:remux_video, "mp4"} in res
      end)
    end

    test "includes custom quality options if specified", %{media_profile: media_profile} do
      on_exit(fn ->
        Settings.set(video_codec_preference: "avc")
        Settings.set(audio_codec_preference: "m4a")
      end)

      Settings.set(video_codec_preference: "av01")
      Settings.set(audio_codec_preference: "aac")

      {:ok, media_profile} = Profiles.update_media_profile(media_profile, %{preferred_resolution: :"1080p"})

      assert res = QualityOptionBuilder.build(media_profile)

      # Stored aliases are canonicalized to select values (av01 -> av1, aac -> m4a)
      assert {:format_sort, "res:1080,+codec:av1:m4a"} in res
    end

    test "includes custom remux target for videos if specified", %{media_profile: media_profile} do
      {:ok, media_profile} = Profiles.update_media_profile(media_profile, %{media_container: "mkv"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:remux_video, "mkv"} in res
    end

    test "includes custom format options", %{media_profile: media_profile} do
      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo*+bestaudio/best"} in res
    end

    test "excludes AI-upscaled formats from video selectors", %{media_profile: media_profile} do
      {:ok, media_profile} =
        Profiles.update_media_profile(media_profile, %{ignore_youtube_super_resolution: true})

      assert res = QualityOptionBuilder.build(media_profile)

      filter = "[format_note!*=?AI-upscaled]"
      assert {:format, "bestvideo*#{filter}+bestaudio#{filter}/best#{filter}"} in res
    end
  end

  describe "build/1 with ordered codec preferences" do
    setup do
      {:ok, media_profile: media_profile_fixture(%{preferred_resolution: :"1080p"})}
    end

    test "emits the plugin options and drops generated codec keys", %{media_profile: media_profile} do
      Settings.set(video_codec_preference: "vp9,avc,av1")
      Settings.set(audio_codec_preference: "opus,m4a")

      res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080"} in res
      assert {:plugin_dirs, QualityOptionBuilder.app_plugin_dir()} in res

      assert {:use_postprocessor, "CodecOrder:when=pre_process;video=vp9,avc,av1;audio=opus,m4a"} in res

      refute Enum.any?(res, fn
               {:format_sort, value} -> value =~ "vcodec" or value =~ "acodec" or value =~ "+codec:"
               _ -> false
             end)
    end

    test "orders video only and omits the audio parameter", %{media_profile: media_profile} do
      Settings.set(video_codec_preference: "av1,hevc")
      Settings.set(audio_codec_preference: "")

      res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080"} in res
      assert {:use_postprocessor, "CodecOrder:when=pre_process;video=av1,hevc"} in res
    end

    test "ordered video with single audio passes single audio to plugin and drops generated codec keys", %{
      media_profile: media_profile
    } do
      Settings.set(video_codec_preference: "vp9,avc,av1")
      Settings.set(audio_codec_preference: "m4a")

      res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080"} in res
      assert {:plugin_dirs, QualityOptionBuilder.app_plugin_dir()} in res
      assert {:use_postprocessor, "CodecOrder:when=pre_process;video=vp9,avc,av1;audio=m4a"} in res

      refute Enum.any?(res, fn
               {:format_sort, value} -> value =~ "vcodec" or value =~ "acodec" or value =~ "+codec:"
               _ -> false
             end)
    end

    test "single video with ordered audio passes single video to plugin and drops generated codec keys", %{
      media_profile: media_profile
    } do
      Settings.set(video_codec_preference: "avc")
      Settings.set(audio_codec_preference: "opus,m4a")

      res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080"} in res
      assert {:plugin_dirs, QualityOptionBuilder.app_plugin_dir()} in res
      assert {:use_postprocessor, "CodecOrder:when=pre_process;video=avc;audio=opus,m4a"} in res

      refute Enum.any?(res, fn
               {:format_sort, value} -> value =~ "vcodec" or value =~ "acodec" or value =~ "+codec:"
               _ -> false
             end)
    end

    test "clearing video preference with single audio emits +acodec without forcing avc", %{
      media_profile: media_profile
    } do
      Settings.set(video_codec_preference: "")
      Settings.set(audio_codec_preference: "m4a")

      res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080,+acodec:m4a"} in res
      refute Keyword.has_key?(res, :plugin_dirs)
      refute Keyword.has_key?(res, :use_postprocessor)

      refute Enum.any?(res, fn
               {:format_sort, value} -> value =~ "avc" or value =~ "vcodec" or value =~ "+codec:"
               _ -> false
             end)
    end

    test "clearing audio preference with single video emits +vcodec without forcing m4a", %{
      media_profile: media_profile
    } do
      Settings.set(video_codec_preference: "avc")
      Settings.set(audio_codec_preference: "")

      res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080,+vcodec:avc"} in res
      refute Keyword.has_key?(res, :plugin_dirs)
      refute Keyword.has_key?(res, :use_postprocessor)

      refute Enum.any?(res, fn
               {:format_sort, value} -> value =~ "m4a" or value =~ "acodec" or value =~ "+codec:"
               _ -> false
             end)
    end

    test "clearing both preferences omits format_sort entirely on video profiles", %{
      media_profile: media_profile
    } do
      Settings.set(video_codec_preference: "")
      Settings.set(audio_codec_preference: "")

      res = QualityOptionBuilder.build(media_profile)

      refute Keyword.has_key?(res, :format_sort)
      refute Keyword.has_key?(res, :plugin_dirs)
      refute Keyword.has_key?(res, :use_postprocessor)
    end
  end

  describe "build/1 audio-only ordered profiles" do
    setup do
      {:ok, audio_profile: media_profile_fixture(%{preferred_resolution: :audio})}
    end

    test "ordered audio omits +acodec and adds the plugin", %{audio_profile: audio_profile} do
      Settings.set(video_codec_preference: "")
      Settings.set(audio_codec_preference: "opus,m4a")

      res = QualityOptionBuilder.build(audio_profile)

      assert :extract_audio in res
      assert {:plugin_dirs, QualityOptionBuilder.app_plugin_dir()} in res
      assert {:use_postprocessor, "CodecOrder:when=pre_process;audio=opus,m4a"} in res
      refute Keyword.has_key?(res, :format_sort)
    end

    test "audio-only profile with ordered audio and single video emits plugin for audio only", %{
      audio_profile: audio_profile
    } do
      Settings.set(video_codec_preference: "avc")
      Settings.set(audio_codec_preference: "opus,m4a")

      res = QualityOptionBuilder.build(audio_profile)

      assert :extract_audio in res
      assert {:plugin_dirs, QualityOptionBuilder.app_plugin_dir()} in res
      assert {:use_postprocessor, "CodecOrder:when=pre_process;audio=opus,m4a"} in res
      refute Keyword.has_key?(res, :format_sort)
    end

    test "single audio token keeps the legacy +acodec command", %{audio_profile: audio_profile} do
      Settings.set(video_codec_preference: "")
      Settings.set(audio_codec_preference: "m4a")

      res = QualityOptionBuilder.build(audio_profile)

      assert {:format_sort, "+acodec:m4a"} in res
      refute Keyword.has_key?(res, :plugin_dirs)
      refute Keyword.has_key?(res, :use_postprocessor)
    end

    test "blank preferences leave custom sorting untouched", %{audio_profile: audio_profile} do
      Settings.set(video_codec_preference: "")
      Settings.set(audio_codec_preference: "")

      res = QualityOptionBuilder.build(audio_profile)

      refute Keyword.has_key?(res, :format_sort)
      refute Keyword.has_key?(res, :plugin_dirs)
      refute Keyword.has_key?(res, :use_postprocessor)
    end
  end

  describe "preflight/0" do
    test "passes when ordered preferences are not configured" do
      Settings.set(video_codec_preference: "avc")
      Settings.set(audio_codec_preference: "m4a")

      assert :ok = QualityOptionBuilder.preflight()
    end

    test "passes when the bundled plugin is present" do
      plugin_dir_with_plugin!()
      Settings.set(video_codec_preference: "vp9,avc")
      Settings.set(audio_codec_preference: "")

      assert :ok = QualityOptionBuilder.preflight()
    end

    test "fails with an actionable message when the plugin is missing" do
      missing = Path.join(System.tmp_dir!(), "missing-app-plugins-#{System.unique_integer([:positive])}")
      Application.put_env(:pinchflat, :yt_dlp_app_plugin_dir, missing)
      on_exit(fn -> Application.delete_env(:pinchflat, :yt_dlp_app_plugin_dir) end)

      Settings.set(video_codec_preference: "vp9,avc")
      Settings.set(audio_codec_preference: "")

      assert {:error, message} = QualityOptionBuilder.preflight()
      assert message =~ "codec-order plugin is missing"
      assert message =~ missing
      assert message =~ "clear the ordered codec preferences"
    end

    test "fails when the directory exists but exposes no plugin" do
      empty = Path.join(System.tmp_dir!(), "empty-app-plugins-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      Application.put_env(:pinchflat, :yt_dlp_app_plugin_dir, empty)

      on_exit(fn ->
        Application.delete_env(:pinchflat, :yt_dlp_app_plugin_dir)
        File.rm_rf(empty)
      end)

      Settings.set(video_codec_preference: "vp9,avc")
      Settings.set(audio_codec_preference: "")

      assert {:error, _message} = QualityOptionBuilder.preflight()
    end

    test "fails when the directory contains only unrelated python files without CodecOrderPP" do
      dir = Path.join(System.tmp_dir!(), "unrelated-app-plugins-#{System.unique_integer([:positive])}")
      nested = Path.join([dir, "some_plugin", "yt_dlp_plugins", "postprocessor"])
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "unrelated.py"), "# unrelated file without the required plugin class\n")
      Application.put_env(:pinchflat, :yt_dlp_app_plugin_dir, dir)

      on_exit(fn ->
        Application.delete_env(:pinchflat, :yt_dlp_app_plugin_dir)
        File.rm_rf(dir)
      end)

      Settings.set(video_codec_preference: "vp9,avc")
      Settings.set(audio_codec_preference: "")

      assert {:error, message} = QualityOptionBuilder.preflight()
      assert message =~ "codec-order plugin is missing"
    end
  end

  defp plugin_dir_with_plugin! do
    dir = Path.join(System.tmp_dir!(), "app-plugins-#{System.unique_integer([:positive])}")
    nested = Path.join([dir, "pinchflat_ngx_codec_order", "yt_dlp_plugins", "postprocessor"])
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "codec_order.py"), "class CodecOrderPP:\n    pass\n")
    Application.put_env(:pinchflat, :yt_dlp_app_plugin_dir, dir)
    on_exit(fn -> File.rm_rf(dir) end)

    dir
  end
end
