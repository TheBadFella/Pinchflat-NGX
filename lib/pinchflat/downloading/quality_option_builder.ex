defmodule Pinchflat.Downloading.QualityOptionBuilder do
  @moduledoc """
  A standalone builder module for building quality-related options for yt-dlp to download media.

  Currently exclusively used in DownloadOptionBuilder since this logic is too complex to just
  place in the main module.

  Codec preferences come in three shapes:

    * empty - no application codec override; native defaults or custom scoped
      `-S` sorting decide
    * a single token - the legacy command, passed as `+codec:`/`+acodec:`
    * several tokens - ordered mode, where the application-owned yt-dlp plugin
      re-sorts formats and the generated `+codec:`/`+acodec:` keys are omitted so
      they cannot outrank the configured order
  """

  alias Pinchflat.Settings
  alias Pinchflat.Settings.CodecPreferences
  alias Pinchflat.Profiles.MediaProfile

  @app_plugin_dir "/opt/pinchflat-ngx/yt-dlp-app-plugins"
  @postprocessor "CodecOrder:when=pre_process"

  @doc """
  Returns the application-owned yt-dlp plugin directory.
  """
  def app_plugin_dir, do: Application.get_env(:pinchflat, :yt_dlp_app_plugin_dir, @app_plugin_dir)

  @doc """
  Returns true when the current settings require the ordered-codec plugin.
  """
  def ordered_codecs_enabled? do
    CodecPreferences.plugin_required?(
      Settings.get!(:video_codec_preference),
      Settings.get!(:audio_codec_preference)
    )
  end

  @doc """
  Returns :ok when the plugin can be used, or {:error, message} when ordered
  preferences are configured but the application-owned plugin is unavailable.

  Runs before a download so a missing plugin fails loudly with an actionable
  message instead of yt-dlp's raw KeyError traceback.
  """
  def preflight do
    if ordered_codecs_enabled?() do
      if plugin_available?() do
        :ok
      else
        {:error,
         "Ordered codec preferences are enabled but the bundled codec-order plugin is missing at " <>
           "#{app_plugin_dir()}. Rebuild or reinstall Pinchflat-ngx, or clear the ordered codec " <>
           "preferences in Settings to fall back to a single codec."}
      end
    else
      :ok
    end
  end

  defp plugin_available? do
    if File.dir?(app_plugin_dir()) do
      app_plugin_dir()
      |> Path.join("**/yt_dlp_plugins/postprocessor/*.py")
      |> Path.wildcard()
      |> Enum.any?(fn path ->
        case File.read(path) do
          {:ok, content} -> String.contains?(content, "CodecOrderPP")
          _ -> false
        end
      end)
    else
      false
    end
  end

  @doc """
  Returns the quality-related options for yt-dlp, including codec ordering.

  The shape depends on the configured preferences: empty lists leave sorting to
  native defaults or custom scoped options, a single entry keeps the legacy
  `+codec:`/`+acodec:` command, and several entries switch to the ordered plugin.
  """
  def build(media_profile, opts \\ [])

  def build(%MediaProfile{preferred_resolution: :audio, media_container: container} = media_profile, _opts) do
    audio_pref = Settings.get!(:audio_codec_preference)

    [
      :extract_audio,
      audio_format: container || "best",
      format: build_format_string(media_profile)
    ]
    |> put_audio_sort(audio_pref)
    |> append_audio_ordered_options(audio_pref)
  end

  def build(%MediaProfile{preferred_resolution: resolution_atom, media_container: container} = media_profile, _opts) do
    video_pref = Settings.get!(:video_codec_preference)
    audio_pref = Settings.get!(:audio_codec_preference)
    {resolution_string, _} = resolution_atom |> Atom.to_string() |> Integer.parse()

    [
      # Since Plex doesn't support reading metadata from MKV
      remux_video: container || "mp4",
      format: build_format_string(media_profile)
    ]
    |> put_video_sort(resolution_string, video_pref, audio_pref)
    |> append_ordered_options(video_pref, audio_pref)
  end

  # Empty list: leave sorting untouched. Single entry: the legacy +acodec key.
  # Ordered: omit the key so the plugin's inserted ranks are authoritative.
  # Ordered audio lists emit no generated key at all: the plugin's inserted audio
  # rank must not be outranked by a stale `+acodec:` entry.
  defp put_audio_sort(opts, audio_pref) do
    case classify(audio_pref) do
      {:single, token} -> opts ++ [format_sort: "+acodec:#{token}"]
      _empty_or_ordered -> opts
    end
  end

  defp append_audio_ordered_options(opts, audio_pref) do
    if CodecPreferences.ordered?(audio_pref) do
      opts ++
        [
          {:plugin_dirs, app_plugin_dir()},
          {:use_postprocessor, "#{@postprocessor};audio=#{CodecPreferences.format(CodecPreferences.parse(audio_pref))}"}
        ]
    else
      opts
    end
  end

  defp put_video_sort(opts, resolution_string, video_pref, audio_pref) do
    video_shape = classify(video_pref)
    audio_shape = classify(audio_pref)

    sort =
      cond do
        video_shape == :empty and audio_shape == :empty ->
          nil

        ordered?(video_shape) or ordered?(audio_shape) ->
          # Drop generated codec keys entirely: the plugin owns codec ranking and
          # res: keeps its existing resolution-first meaning.
          "res:#{resolution_string}"

        video_shape == :empty ->
          {:single, audio_token} = audio_shape
          "res:#{resolution_string},+acodec:#{audio_token}"

        audio_shape == :empty ->
          {:single, video_token} = video_shape
          "res:#{resolution_string},+vcodec:#{video_token}"

        true ->
          {:single, video_token} = video_shape
          {:single, audio_token} = audio_shape
          "res:#{resolution_string},+codec:#{video_token}:#{audio_token}"
      end

    if sort, do: opts ++ [format_sort: sort], else: opts
  end

  defp append_ordered_options(opts, video_pref, audio_pref) do
    if CodecPreferences.plugin_required?(video_pref, audio_pref) do
      opts ++
        [
          {:plugin_dirs, app_plugin_dir()},
          {:use_postprocessor, postprocessor_arg(video_pref, audio_pref)}
        ]
    else
      opts
    end
  end

  defp postprocessor_arg(video_pref, audio_pref) do
    parts = [@postprocessor]
    video_tokens = CodecPreferences.parse(video_pref)
    audio_tokens = CodecPreferences.parse(audio_pref)

    parts =
      if video_tokens != [],
        do: parts ++ ["video=#{CodecPreferences.format(video_tokens)}"],
        else: parts

    parts =
      if audio_tokens != [],
        do: parts ++ ["audio=#{CodecPreferences.format(audio_tokens)}"],
        else: parts

    Enum.join(parts, ";")
  end

  defp classify(value) do
    case CodecPreferences.parse(value) do
      [] -> :empty
      [token] -> {:single, token}
      tokens -> {:ordered, tokens}
    end
  end

  defp ordered?({:ordered, _tokens}), do: true
  defp ordered?(_shape), do: false

  defp build_format_string(%MediaProfile{preferred_resolution: :audio, audio_track: audio_track} = media_profile) do
    filter = super_resolution_filter(media_profile)

    if audio_track do
      "bestaudio[#{build_format_modifier(audio_track)}]#{filter}/bestaudio#{filter}/best#{filter}"
    else
      "bestaudio#{filter}/best#{filter}"
    end
  end

  defp build_format_string(%MediaProfile{audio_track: audio_track} = media_profile) do
    filter = super_resolution_filter(media_profile)

    if audio_track do
      "bestvideo#{filter}+bestaudio[#{build_format_modifier(audio_track)}]#{filter}/" <>
        "bestvideo*#{filter}+bestaudio#{filter}/best#{filter}"
    else
      "bestvideo*#{filter}+bestaudio#{filter}/best#{filter}"
    end
  end

  defp super_resolution_filter(%MediaProfile{ignore_youtube_super_resolution: true}) do
    "[format_note!*=?AI-upscaled]"
  end

  defp super_resolution_filter(%MediaProfile{}), do: ""

  # Reminder to self: this conflicts with `--extractor-args "youtube:lang=<LANG>"`
  # since that will translate the format_notes as well, which means they may not match.
  # At least that's what happens now - worth a re-check if I have to come back to this
  defp build_format_modifier("original"), do: "format_note*=original"
  defp build_format_modifier("default"), do: "format_note*='(default)'"
  # This uses the carat to anchor the language to the beginning of the string
  # since that's what's needed to match `en` to `en-US` and `en-GB`, etc. The user
  # can always specify the full language code if they want.
  defp build_format_modifier(language_code), do: "language^=#{language_code}"
end
