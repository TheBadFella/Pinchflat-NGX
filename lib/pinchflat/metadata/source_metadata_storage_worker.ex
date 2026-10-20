defmodule Pinchflat.Metadata.SourceMetadataStorageWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :remote_metadata,
    tags: ["media_source", "source_metadata", "remote_metadata", "show_in_dashboard"],
    max_attempts: 3

  require Logger

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Settings
  alias Pinchflat.Utils.StringUtils
  alias Pinchflat.Metadata.NfoBuilder
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.YtDlp.ResponseDecoder
  alias Pinchflat.YtDlp.UnavailableMedia
  alias Pinchflat.Metadata.SourceImageParser
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Downloading.DownloadOptionBuilder

  @doc """
  Starts the source metadata storage worker and creates a task for the source.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(source, opts \\ []) do
    {worker_args, oban_opts} = Keyword.split(opts, [:mode])
    mode = Keyword.get(worker_args, :mode)

    args =
      if mode do
        %{id: source.id, mode: to_string(mode)}
      else
        %{id: source.id}
      end

    args
    |> SourceMetadataStorageWorker.new(oban_opts)
    |> Tasks.create_job_with_task(source)
  end

  @doc """
  Fetches and stores various forms of metadata for a source:
    - Attributes like `description`
    - JSON metadata for internal use
    - The series directory for the source
    - The NFO file for the source (if specified)
    - Downloads and stores source images (if specified)

  The worker is kicked off after a source is inserted or it's original_url
  is updated - this can take an unknown amount of time so don't rely on this
  data being here before, say, the first indexing or downloading task is complete.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id} = args}) do
    mode = Map.get(args, "mode") || Map.get(args, :mode)
    artwork_repair? = mode in ["artwork_repair", :artwork_repair]

    source = Repo.preload(Sources.get_source!(source_id), [:metadata, :media_profile])

    series_directory_result =
      if artwork_repair? do
        {:ok, source.series_directory}
      else
        determine_series_directory(source)
      end

    with {:ok, series_directory} <- series_directory_result,
         {:ok, metadata_result} <-
           fetch_source_metadata_and_images(series_directory, source, artwork_repair: artwork_repair?) do
      case metadata_result do
        :unavailable_fallback ->
          handle_unavailable_fallback(source)

        {source_metadata, source_image_attrs, metadata_image_attrs} ->
          if artwork_repair? do
            handle_artwork_repair_metadata(source, source_metadata, source_image_attrs, metadata_image_attrs)
          else
            handle_standard_metadata(
              source,
              series_directory,
              source_metadata,
              source_image_attrs,
              metadata_image_attrs
            )
          end
      end
    else
      # A failed metadata/details fetch used to blow up here via a strict `{:ok, _} =` match,
      # producing an opaque MatchError crash-loop. Instead, surface source context and let the
      # job fail (and retry) cleanly. For decode errors, `ResponseDecoder` has already logged
      # the raw yt-dlp response.
      error ->
        decode_hint =
          if ResponseDecoder.decode_error?(error) do
            " See the preceding yt-dlp log line for the raw response."
          else
            ""
          end

        Logger.error(
          "#{__MODULE__} could not fetch metadata for source ##{source_id} (#{source.original_url}): " <>
            "#{inspect(error)}." <> decode_hint
        )

        {:error, :source_metadata_fetch_failed}
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: source #{source_id} stale")
  end

  def perform(%Oban.Job{args: %{id: source_id} = args} = job) do
    perform(%{job | args: Map.put(args, "id", source_id)})
  end

  defp handle_unavailable_fallback(source) do
    if source.metadata && source.metadata.metadata_filepath do
      Logger.info(
        "Unavailable media encountered on existing source ##{source.id}; preserving existing metadata and paths"
      )

      :ok
    else
      source_metadata_filepath = MetadataFileHelpers.compress_and_store_metadata_for(source, %{})

      metadata_attrs = %{metadata: %{metadata_filepath: source_metadata_filepath}}

      Sources.update_source(
        source,
        metadata_attrs,
        run_post_commit_tasks: false,
        automated_metadata_refresh: true
      )

      :ok
    end
  end

  defp handle_artwork_repair_metadata(source, source_metadata, source_image_attrs, metadata_image_attrs) do
    existing_metadata =
      if source.metadata do
        %{
          metadata_filepath: source.metadata.metadata_filepath,
          poster_filepath: source.metadata.poster_filepath,
          fanart_filepath: source.metadata.fanart_filepath,
          banner_filepath: source.metadata.banner_filepath
        }
      else
        source_metadata_filepath =
          MetadataFileHelpers.compress_and_store_metadata_for(source, source_metadata)

        %{metadata_filepath: source_metadata_filepath}
      end

    updated_metadata =
      Enum.reduce(metadata_image_attrs, existing_metadata, fn {key, val}, acc ->
        if Map.get(acc, key) == nil and val != nil do
          Map.put(acc, key, val)
        else
          acc
        end
      end)

    filtered_source_image_attrs =
      Enum.reduce(source_image_attrs, %{}, fn {key, val}, acc ->
        if Map.get(source, key) == nil and val != nil do
          Map.put(acc, key, val)
        else
          acc
        end
      end)

    metadata_attrs = %{metadata: updated_metadata}

    Sources.update_source(
      source,
      Map.merge(metadata_attrs, filtered_source_image_attrs),
      run_post_commit_tasks: false,
      automated_metadata_refresh: true
    )

    :ok
  end

  defp handle_standard_metadata(
         source,
         series_directory,
         source_metadata,
         source_image_attrs,
         metadata_image_attrs
       ) do
    source_metadata_filepath = MetadataFileHelpers.compress_and_store_metadata_for(source, source_metadata)

    source =
      source
      |> Sources.refresh_video_metadata_title(source_metadata["title"])
      |> Repo.preload([:metadata, :media_profile])

    merged_metadata =
      if source.custom_name_locked and source.metadata do
        existing_meta = %{
          metadata_filepath: source_metadata_filepath,
          poster_filepath: source.metadata.poster_filepath,
          fanart_filepath: source.metadata.fanart_filepath,
          banner_filepath: source.metadata.banner_filepath
        }

        Enum.reduce(metadata_image_attrs, existing_meta, fn {key, val}, acc ->
          if Map.get(acc, key) == nil and val != nil do
            Map.put(acc, key, val)
          else
            acc
          end
        end)
      else
        Map.merge(%{metadata_filepath: source_metadata_filepath}, metadata_image_attrs)
      end

    metadata_attrs =
      %{
        series_directory: series_directory,
        nfo_filepath: store_source_nfo(source, series_directory, source_metadata),
        metadata: merged_metadata
      }
      |> put_if_binary(:custom_name, source_name_from_metadata(source, source_metadata))
      |> put_if_binary(:description, source_metadata["description"])

    Sources.update_source(
      source,
      Map.merge(metadata_attrs, source_image_attrs),
      run_post_commit_tasks: false,
      automated_metadata_refresh: true
    )

    :ok
  end

  defp fetch_source_metadata_and_images(series_directory, source, opts) do
    metadata_directory = MetadataFileHelpers.metadata_directory_for(source)
    artwork_repair? = Keyword.get(opts, :artwork_repair, false)
    overwrite? = !artwork_repair? and !source.custom_name_locked

    case maybe_ignore_unavailable_source_metadata(source, fetch_metadata_for_source(source)) do
      {:ok, _metadata, :unavailable_fallback} ->
        {:ok, :unavailable_fallback}

      {:ok, metadata} ->
        metadata_image_attrs =
          SourceImageParser.store_source_images(metadata_directory, metadata, overwrite: overwrite?)

        if source.media_profile.download_source_images && series_directory do
          source_image_attrs =
            SourceImageParser.store_source_images(series_directory, metadata, overwrite: overwrite?)

          {:ok, {metadata, source_image_attrs, metadata_image_attrs}}
        else
          {:ok, {metadata, %{}, metadata_image_attrs}}
        end

      err ->
        err
    end
  end

  # Both the details fetch and the metadata/thumbnail fetch sample a single video (the
  # first item for playlists). If that sampled video is members-only/private/removed,
  # yt-dlp exits non-zero and the fetch returns an error.
  #
  # When the "ignore unavailable media" setting is enabled we fall back to empty metadata
  # (skipping source images and the series directory) so the source can still be set up,
  # rather than failing the job. Otherwise the original error is passed through unchanged,
  # preserving the fail-and-retry behaviour.
  defp maybe_ignore_unavailable_source_metadata(source, {:error, message, _exit_code} = err) do
    if Settings.get!(:ignore_unavailable_media) && UnavailableMedia.error?(message) do
      Logger.info("Ignoring unavailable media while fetching metadata for source ##{source.id}: #{inspect(message)}")

      {:ok, %{}, :unavailable_fallback}
    else
      err
    end
  end

  defp maybe_ignore_unavailable_source_metadata(_source, result), do: result

  defp determine_series_directory(source) do
    # Source-only rendering always uses the primary template, including for Shorts-only channels.
    runner_opts =
      [output: DownloadOptionBuilder.build_output_path_for(source)] ++
        DownloadOptionBuilder.build_youtube_options_for(source)

    addl_opts = [use_cookies: Sources.use_cookies?(source, :metadata)]
    details_result = MediaCollection.get_source_details(source.original_url, runner_opts, addl_opts)

    case maybe_ignore_unavailable_source_metadata(source, details_result) do
      {:ok, %{filepath: filepath}} when is_binary(filepath) ->
        case MetadataFileHelpers.series_directory_from_media_filepath(filepath) do
          {:ok, series_directory} -> {:ok, series_directory}
          {:error, _} -> {:ok, nil}
        end

      {:ok, _metadata, :unavailable_fallback} ->
        {:ok, source.series_directory}

      # Either the ignored-unavailable fallback (`{:ok, %{}}`) or a parseable response
      # that's missing `filename` - there's no filepath to derive a series directory from
      {:ok, _} ->
        {:ok, nil}

      err ->
        err
    end
  end

  defp store_source_nfo(source, series_directory, metadata) do
    if source.media_profile.download_nfo && series_directory do
      nfo_filepath = Path.join(series_directory, "tvshow.nfo")

      NfoBuilder.build_and_store_for_source(nfo_filepath, metadata)
    end
  end

  defp fetch_metadata_for_source(source) do
    tmp_output_path = "#{tmp_directory()}/#{StringUtils.random_string(16)}/source_image.%(ext)S"
    base_opts = [convert_thumbnails: "jpg", output: tmp_output_path]
    base_opts = if source.collection_type == :video, do: [:no_playlist | base_opts], else: base_opts
    should_use_cookies = Sources.use_cookies?(source, :metadata)

    opts =
      if source.collection_type == :channel do
        base_opts ++ [:write_all_thumbnails, playlist_items: 0]
      else
        base_opts ++ [:write_thumbnail, playlist_items: 1]
      end

    opts = opts ++ DownloadOptionBuilder.build_youtube_options_for(source)

    MediaCollection.get_source_metadata(source.original_url, opts, use_cookies: should_use_cookies)
  end

  defp source_name_from_metadata(source, metadata) do
    name_keys =
      case source.collection_type do
        :channel -> ["channel", "uploader", "title"]
        :playlist -> ["playlist_title", "playlist", "title"]
        # Video names are refreshed conditionally above to protect concurrent edits.
        :video -> []
        _ -> ["title", "channel", "uploader"]
      end

    Enum.find_value(name_keys, fn key ->
      case metadata[key] do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp put_if_binary(attrs, key, value) when is_binary(value), do: Map.put(attrs, key, value)
  defp put_if_binary(attrs, _key, _value), do: attrs

  defp tmp_directory do
    Application.get_env(:pinchflat, :tmpfile_directory)
  end
end
