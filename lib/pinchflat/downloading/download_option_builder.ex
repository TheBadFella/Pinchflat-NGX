defmodule Pinchflat.Downloading.DownloadOptionBuilder do
  @moduledoc """
  Builds the options for yt-dlp to download media based on the given media profile.
  """

  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Downloading.OutputPathBuilder
  alias Pinchflat.Downloading.QualityOptionBuilder
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Settings
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.YtDlp.PoTokenProvider

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @doc """
  Builds the options for yt-dlp to download media based on the given media's profile.

  Returns {:ok, [Keyword.t()]}
  """
  def build(%MediaItem{} = media_item_with_preloads, override_opts \\ []) do
    media_profile = media_item_with_preloads.source.media_profile

    youtube_options =
      if Keyword.has_key?(override_opts, :player_client) do
        build_youtube_options_for(media_item_with_preloads, Keyword.get(override_opts, :player_client))
      else
        build_youtube_options_for(media_item_with_preloads)
      end

    with {:ok, output_options} <- output_options(media_item_with_preloads, override_opts),
         {:ok, thumbnail_options} <- thumbnail_options(media_item_with_preloads, override_opts) do
      built_options =
        default_options(override_opts) ++
          youtube_options ++
          subtitle_options(media_profile) ++
          thumbnail_options ++
          metadata_options(media_profile) ++
          quality_options(media_profile) ++
          sponsorblock_options(media_profile) ++
          output_options ++
          build_config_file_options_for(media_item_with_preloads)

      {:ok, built_options}
    end
  end

  @doc """
  Builds the yt-dlp extractor arguments for a source's optional YouTube
  player-client override.

  Returns [] when the source uses the default client selection.
  """
  def build_player_client_options_for(source_or_item, client_override \\ nil)

  def build_player_client_options_for(%Source{} = source, client_override) do
    client = if is_nil(client_override), do: source.player_client, else: client_override
    player_client_options(client)
  end

  def build_player_client_options_for(%MediaItem{} = media_item, client_override) do
    build_player_client_options_for(media_item.source, client_override)
  end

  @doc """
  Builds the source-specific yt-dlp extractor arguments used by every YouTube
  operation. The player-client override remains source-specific, while the
  optional provider argument is global and is omitted when disabled.
  """
  def build_youtube_options_for(source_or_item, client_override \\ nil)

  def build_youtube_options_for(%Source{} = source, client_override) do
    client = if is_nil(client_override), do: source.player_client, else: client_override
    player_client_options(client) ++ PoTokenProvider.options()
  end

  def build_youtube_options_for(%MediaItem{} = media_item, client_override) do
    build_youtube_options_for(media_item.source, client_override)
  end

  @doc false
  def player_client_options(nil), do: []

  def player_client_options(player_client) do
    if player_client in Source.player_client_values() do
      [{:extractor_args, "youtube:player-client=#{player_client}"}]
    else
      []
    end
  end

  @doc """
  Builds the output path for yt-dlp to download media based on the given source's
  or media_item's media profile. Uses the source's override output path template if it exists.

  Accepts a %MediaItem{} or %Source{} struct. If a %Source{} struct is passed, it
  will use a default %MediaItem{} struct with the given source.

  Returns binary()
  """
  def build_output_path_for(struct, template_options \\ %{})

  def build_output_path_for(%Source{} = source_with_preloads, template_options) do
    build_output_path_for(%MediaItem{source: source_with_preloads}, template_options)
  end

  def build_output_path_for(%MediaItem{} = media_item_with_preloads, template_options) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source, media_item_with_preloads)

    build_output_path(output_path_template, media_item_with_preloads, template_options)
  end

  @doc """
  Builds the quality options for yt-dlp to download media based on the given source's
  or media_item's media profile. Useful for helping predict final filepath of downloaded
  media.

  returns [Keyword.t()]
  """
  def build_quality_options_for(%Source{} = source_with_preloads) do
    build_quality_options_for(%MediaItem{source: source_with_preloads})
  end

  def build_quality_options_for(%MediaItem{} = media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile

    quality_options(media_profile)
  end

  defp default_options(override_opts) do
    overwrite_behaviour = Keyword.get(override_opts, :overwrite_behaviour, :force_overwrites)
    emit_progress = Keyword.get(override_opts, :emit_progress, false)

    progress_opts = if emit_progress, do: [], else: [:no_progress]

    progress_opts ++
      [
        overwrite_behaviour,
        # This makes the date metadata conform to what jellyfin expects
        parse_metadata: "%(upload_date>%Y-%m-%d)s:(?P<meta_date>.+)"
      ]
  end

  defp subtitle_options(media_profile) do
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case {attr, media_profile} do
        {{:download_subs, true}, _} ->
          # Force SRT for now - MAY provide as an option in the future
          acc ++ [:write_subs, convert_subs: "srt"]

        {{:download_auto_subs, true}, %{download_subs: true}} ->
          acc ++ [:write_auto_subs]

        {{:download_auto_subs, true}, %{embed_subs: true}} ->
          acc ++ [:write_auto_subs]

        {{:embed_subs, true}, %{preferred_resolution: pr}} when pr != :audio ->
          acc ++ [:embed_subs]

        {{:sub_langs, sub_langs}, %{download_subs: true}} ->
          acc ++ [sub_langs: sub_langs]

        {{:sub_langs, sub_langs}, %{embed_subs: true}} ->
          acc ++ [sub_langs: sub_langs]

        _ ->
          acc
      end
    end)
  end

  defp thumbnail_options(media_item_with_preloads, override_opts) do
    media_profile = media_item_with_preloads.source.media_profile
    mapped_struct = Map.from_struct(media_profile)

    with {:ok, thumbnail_save_location} <- determine_thumbnail_location(media_item_with_preloads, override_opts) do
      options =
        Enum.reduce(mapped_struct, [], fn attr, acc ->
          case attr do
            {:download_thumbnail, true} ->
              acc ++ [:write_thumbnail, convert_thumbnail: "jpg", output: "thumbnail:#{thumbnail_save_location}"]

            {:embed_thumbnail, true} ->
              acc ++ [:embed_thumbnail, convert_thumbnail: "jpg"]

            _ ->
              acc
          end
        end)

      {:ok, options}
    end
  end

  defp metadata_options(media_profile) do
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case attr do
        {:download_metadata, true} -> acc ++ [:write_info_json, :clean_info_json]
        {:embed_metadata, true} -> acc ++ [:embed_metadata]
        _ -> acc
      end
    end)
  end

  defp quality_options(media_profile) do
    QualityOptionBuilder.build(media_profile)
  end

  # yt-dlp accepts both flags in one invocation, so each category can be
  # removed or marked as a chapter independently
  defp sponsorblock_options(media_profile) do
    [
      sponsorblock_remove: Enum.join(media_profile.sponsorblock_remove_categories, ","),
      sponsorblock_mark: Enum.join(media_profile.sponsorblock_mark_categories, ",")
    ]
    |> Enum.reject(fn {_flag, categories} -> categories == "" end)
  end

  @doc """
  Builds the yt-dlp `--config-locations` options for a media item or source.

  Scoped config files live in `extras/yt-dlp-configs`. This is the single source
  of truth for them: `build/2` uses it for downloads, and the offline
  `--load-info-json` path predictions use it so a prediction cannot drift from
  the real download. Only files that exist and are non-empty are returned.

  These stay out of the CommandRunner module on purpose: they must not apply to
  every yt-dlp command (such as indexing). Predictions add them explicitly to
  match the download argument list.

  A media item uses its own file, its source, its media profile and the base
  file. A source (used where there is no item yet) uses the source, profile and
  base files. Files are emitted lowest priority first because yt-dlp applies
  later `--config-locations` files over earlier ones, so the item file wins.

  Returns [{:config_locations, binary()}]
  """
  def build_config_file_options_for(item_or_source)

  def build_config_file_options_for(%MediaItem{} = media_item) do
    source = loaded_source(media_item.source)
    source_id = media_item.source_id || (source && source.id)
    profile_id = source && source.media_profile_id

    config_file_options([
      scoped_config_filename("media-item", media_item.id),
      scoped_config_filename("source", source_id),
      scoped_config_filename("media-profile", profile_id),
      "base-config.txt"
    ])
  end

  def build_config_file_options_for(%Source{} = source) do
    config_file_options([
      scoped_config_filename("source", source.id),
      scoped_config_filename("media-profile", source.media_profile_id),
      "base-config.txt"
    ])
  end

  def build_config_file_options_for(_other), do: []

  # The association is `%Ecto.Association.NotLoaded{}` unless the caller
  # preloaded it, and an unloaded source must not contribute an id.
  defp loaded_source(%Source{} = source), do: source
  defp loaded_source(_other), do: nil

  defp scoped_config_filename(prefix, id) when is_integer(id), do: "#{prefix}-#{id}-config.txt"
  defp scoped_config_filename(_prefix, _absence), do: nil

  # Filenames arrive highest priority first, so prepending reverses them into the
  # order yt-dlp needs: later files override earlier ones.
  defp config_file_options(filenames) do
    base_dir = Path.join(Application.get_env(:pinchflat, :extras_directory), "yt-dlp-configs")

    filenames
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce([], fn filename, acc ->
      filepath = Path.join(base_dir, filename)

      if FSUtils.exists_and_nonempty?(filepath) do
        [filepath | acc]
      else
        acc
      end
    end)
    |> Enum.map(fn filepath -> {:config_locations, filepath} end)
  end

  defp output_options(media_item_with_preloads, override_opts) do
    relative_output_path = build_relative_output_path(media_item_with_preloads)

    case Keyword.get(override_opts, :staging_directory) do
      nil ->
        {:ok, [output: Path.join(base_directory(), relative_output_path)]}

      staging_directory ->
        with {:ok, output_path} <- DownloadStaging.output_path(staging_directory, relative_output_path) do
          {:ok, [output: output_path]}
        end
    end
  end

  defp build_output_path(string, media_item_with_preloads, template_options) do
    relative_path = build_relative_output_path(string, media_item_with_preloads, template_options)

    case DownloadStaging.output_path(base_directory(), relative_path) do
      {:ok, path} -> path
      {:error, :path_escape} -> raise ArgumentError, "output path escapes the media directory"
    end
  end

  defp build_relative_output_path(media_item_with_preloads) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source, media_item_with_preloads)
    build_relative_output_path(output_path_template, media_item_with_preloads, %{})
  end

  defp build_relative_output_path(string, media_item_with_preloads, template_options) do
    additional_options_map = Map.merge(output_options_map(media_item_with_preloads), template_options)
    {:ok, output_path} = OutputPathBuilder.build(string, additional_options_map)

    relative_output_path =
      output_path
      |> OutputPathBuilder.sanitize_literal_text(Settings.get!(:restrict_filenames))
      |> String.trim_leading("/")
      |> String.trim_leading("\\")

    source_subdirectory = media_item_with_preloads.source.download_subdirectory

    [source_subdirectory, relative_output_path]
    |> Enum.reject(&is_nil/1)
    |> Path.join()
  end

  defp output_options_map(media_item_with_preloads) do
    source = media_item_with_preloads.source

    %{
      "media_item_id" => to_string(media_item_with_preloads.id),
      "source_id" => to_string(source.id),
      "media_profile_id" => to_string(source.media_profile_id),
      "source_custom_name" => OutputPathBuilder.literal_component(source.custom_name),
      "source_collection_id" => source.collection_id,
      "source_collection_name" => OutputPathBuilder.literal_component(source.collection_name),
      "source_collection_type" => to_string(source.collection_type),
      "translated_title" =>
        OutputPathBuilder.literal_component(
          media_item_with_preloads.translated_title || media_item_with_preloads.title || ""
        ),
      "media_playlist_index" => OutputPathBuilder.padded_integer(media_item_with_preloads.playlist_index),
      "media_upload_date_index" => OutputPathBuilder.padded_integer(media_item_with_preloads.upload_date_index)
    }
  end

  # The thumbnail must share the media file's basename (differing only in
  # extension) for media center apps to pick it up as the episode thumbnail -
  # Plex in particular only matches an exactly-named sidecar image
  defp determine_thumbnail_location(media_item_with_preloads, override_opts) do
    if media_item_with_preloads.source.media_profile.download_thumbnail do
      case Keyword.get(override_opts, :staging_directory) do
        nil ->
          {:ok, build_output_path_for(media_item_with_preloads)}

        staging_directory ->
          DownloadStaging.output_path(staging_directory, build_relative_output_path(media_item_with_preloads))
      end
    else
      {:ok, nil}
    end
  end

  defp base_directory do
    Application.get_env(:pinchflat, :media_directory)
  end
end
