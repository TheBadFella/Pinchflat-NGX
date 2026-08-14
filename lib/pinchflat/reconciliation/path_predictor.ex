defmodule Pinchflat.Reconciliation.PathPredictor do
  @moduledoc """
  Computes where a media item's files WOULD land under the current path-affecting
  settings, without any network calls: the item's stored (compressed) metadata is
  fed back to yt-dlp via `--load-info-json` and the filename is rendered against
  the current effective output template. Because yt-dlp itself does the rendering,
  sanitization (`--windows-filenames`, the `restrict_filenames` setting) matches a
  real download exactly.

  Media items must have `:metadata` and `source: :media_profile` preloaded.
  """

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @doc """
  Predicts the media item's target filepath under the current settings. The
  rendered extension is replaced with the actual downloaded file's extension
  (when known) since post-download merging can change it.

  Returns {:ok, binary()} | {:error, :no_metadata | binary()}
  """
  def predict_media_filepath(%MediaItem{} = media_item_with_preloads) do
    case render_filepath(media_item_with_preloads, %{}) do
      {:ok, rendered} -> {:ok, substitute_actual_extension(rendered, media_item_with_preloads)}
      err -> err
    end
  end

  @doc """
  Predicts the source's series directory under the current settings by rendering
  the output template with the `{{ series_root }}` sentinel attached (the same
  trick `SourceMetadataStorageWorker` uses, but offline). Falls back to the
  season-folder heuristic when the template has no marker.

  Returns {:ok, binary()} | {:error, :no_metadata | :indeterminable | binary()}
  """
  def predict_series_directory(%MediaItem{} = media_item_with_preloads) do
    marker_override = %{"series_root" => MetadataFileHelpers.series_root_marker()}

    with {:ok, rendered} <- render_filepath(media_item_with_preloads, marker_override) do
      MetadataFileHelpers.series_directory_from_media_filepath(rendered)
    end
  end

  defp render_filepath(media_item, template_opts) do
    with {:ok, metadata_map} <- read_stored_metadata(media_item),
         {:ok, info_json_filepath} <- write_info_json_tmpfile(metadata_map) do
      output_path = DownloadOptionBuilder.build_output_path_for(media_item, template_opts)

      result =
        YtDlpMedia.predict_filepath_from_metadata(
          media_item.original_url,
          info_json_filepath,
          output: output_path
        )

      File.rm(info_json_filepath)
      normalize_render_result(result)
    end
  end

  defp read_stored_metadata(%MediaItem{metadata: %{metadata_filepath: filepath}}) when is_binary(filepath) do
    if FSUtils.exists_and_nonempty?(filepath) do
      MetadataFileHelpers.read_compressed_metadata(filepath)
    else
      {:error, :no_metadata}
    end
  end

  defp read_stored_metadata(_media_item), do: {:error, :no_metadata}

  defp write_info_json_tmpfile(metadata_map) do
    filepath = FSUtils.generate_metadata_tmpfile(:json)

    with {:ok, json} <- Phoenix.json_library().encode(metadata_map),
         :ok <- File.write(filepath, json) do
      {:ok, filepath}
    end
  end

  defp normalize_render_result({:ok, filename}) when is_binary(filename) and filename != "", do: {:ok, filename}
  defp normalize_render_result({:ok, other}), do: {:error, "Unexpected rendered filename: #{inspect(other)}"}
  defp normalize_render_result({:error, output, _status}), do: {:error, to_string(output)}
  defp normalize_render_result({:error, reason}), do: {:error, to_string(reason)}

  defp substitute_actual_extension(rendered, %MediaItem{media_filepath: media_filepath}) do
    case media_filepath && Path.extname(media_filepath) do
      ext when is_binary(ext) and ext != "" -> Path.rootname(rendered) <> ext
      _ -> rendered
    end
  end
end
