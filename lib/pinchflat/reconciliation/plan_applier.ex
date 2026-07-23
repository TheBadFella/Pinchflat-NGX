defmodule Pinchflat.Reconciliation.PlanApplier do
  @moduledoc """
  Executes a reviewed reconcile plan: moves/deletes files, backfills sidecars,
  and updates the corresponding `*_filepath` columns. Work is grouped per media
  item so one item failing doesn't abort the run; each plan item's row records
  what actually happened (done/skipped/failed). Rows whose `from_path` no longer
  matches the database (e.g. a download ran after planning) are skipped as stale.

  Media files are only ever moved — deletion rows exist solely for sidecars whose
  profile toggle is off, and the internal compressed metadata blob is never touched.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Reconciliation
  alias Pinchflat.Metadata.NfoBuilder
  alias Pinchflat.Reconciliation.ReconcilePlan
  alias Pinchflat.Reconciliation.ReconcilePlanItem
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Podcasts.PodcastExportWorker
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils
  alias Pinchflat.Utils.MapUtils

  @doc """
  Applies every planned row of the given plan. Returns the plan marked as
  applied, with `error_count` reflecting rows that failed.

  Returns {:ok, %ReconcilePlan{}}
  """
  def apply_plan(%ReconcilePlan{} = plan) do
    rows =
      ReconcilePlanItem
      |> where(reconcile_plan_id: ^plan.id, status: :planned)
      |> where([rpi], rpi.action in [:move, :backfill, :delete, :redownload])
      |> order_by(asc: :id)
      |> Repo.all()

    {media_item_rows, source_rows} = Enum.split_with(rows, & &1.media_item_id)

    media_item_rows
    |> Enum.group_by(& &1.media_item_id)
    |> Enum.each(fn {media_item_id, item_rows} -> apply_media_item_rows(media_item_id, item_rows) end)

    source_rows
    |> Enum.group_by(& &1.source_id)
    |> Enum.each(fn {source_id, src_rows} -> apply_source_rows(source_id, src_rows) end)

    kickoff_podcast_exports(rows)
    finalize_plan(plan)
  end

  # ---- Per-media-item application ----

  defp apply_media_item_rows(media_item_id, rows) do
    media_item = Repo.preload(Media.get_media_item!(media_item_id), [:metadata, source: :media_profile])

    {changes, _} =
      Enum.reduce(rows, {%{}, media_item}, fn row, {changes_acc, item} ->
        case apply_media_item_row(item, row) do
          {:ok, new_changes} ->
            mark_row(row, :done)
            {Map.merge(changes_acc, new_changes, &merge_change/3), item}

          {:skipped, reason} ->
            mark_row(row, :skipped, reason)
            {changes_acc, item}

          {:error, reason} ->
            mark_row(row, :failed, reason)
            {changes_acc, item}
        end
      end)

    persist_media_item_changes(media_item, changes)
  rescue
    Ecto.NoResultsError ->
      Enum.each(rows, &mark_row(&1, :skipped, "Media item no longer exists"))
  end

  # Subtitle changes accumulate as a map of lang => path-or-nil under :subtitle_changes
  defp merge_change(:subtitle_changes, existing, new), do: Map.merge(existing, new)
  defp merge_change(_key, _existing, new), do: new

  defp persist_media_item_changes(_media_item, changes) when changes == %{}, do: :ok

  defp persist_media_item_changes(media_item, changes) do
    {subtitle_changes, column_changes} = Map.pop(changes, :subtitle_changes, %{})

    attrs =
      if subtitle_changes == %{} do
        column_changes
      else
        current = MapUtils.from_nested_list(media_item.subtitle_filepaths)

        updated =
          current
          |> Map.merge(subtitle_changes)
          |> Enum.reject(fn {_lang, path} -> is_nil(path) end)
          |> Enum.map(fn {lang, path} -> [lang, path] end)

        Map.put(column_changes, :subtitle_filepaths, updated)
      end

    case Media.update_media_item(media_item, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Reconcile could not update media item ##{media_item.id}: #{inspect(changeset.errors)}")
        :ok
    end
  end

  defp apply_media_item_row(media_item, %{action: :move} = row) do
    with :ok <- verify_current_path(media_item, row),
         :ok <- verify_destination_free(row) do
      case FSUtils.move_p(row.from_path, row.to_path) do
        :ok -> {:ok, change_for_attribute(row.attribute, row.to_path)}
        {:error, reason} -> {:error, "Move failed: #{inspect(reason)}"}
      end
    end
  end

  defp apply_media_item_row(media_item, %{action: :delete} = row) do
    with :ok <- verify_current_path(media_item, row) do
      case FSUtils.delete_file_and_remove_empty_directories(row.from_path) do
        :ok -> {:ok, change_for_attribute(row.attribute, nil)}
        {:error, reason} -> {:error, "Delete failed: #{inspect(reason)}"}
      end
    end
  end

  defp apply_media_item_row(media_item, %{action: :backfill} = row) do
    with :ok <- verify_destination_free(row) do
      backfill_media_item_attribute(media_item, row)
    end
  end

  # Enqueues a forced re-download (same path as "Redownload Existing"): it
  # re-downloads to the current template, fixing both the format and the path,
  # and cleans up the old file itself. The job is inserted while the queues are
  # paused, so it waits and runs after the reconcile window closes — never
  # racing the moves. No filepath columns change here; the download updates them.
  defp apply_media_item_row(media_item, %{action: :redownload}) do
    case MediaDownloadWorker.kickoff_with_task(media_item, %{force: true}) do
      {:ok, _} -> {:ok, %{}}
      {:error, :duplicate_job} -> {:ok, %{}}
      {:error, reason} -> {:error, "Could not schedule re-download: #{inspect(reason)}"}
    end
  end

  # Rechecks the destination right before writing to close the gap between the
  # dry run and apply: a file created at the target since planning (Erlang's
  # rename/copy and File.write all clobber, and there's no exclusive rename) is
  # left untouched rather than overwritten. A target that is the same file as
  # the source (symlink/inode) is fine to proceed with.
  defp verify_destination_free(%{to_path: nil}), do: :ok

  defp verify_destination_free(%{to_path: to_path, from_path: from_path}) do
    cond do
      !File.exists?(to_path) -> :ok
      from_path && FSUtils.filepaths_reference_same_file?(from_path, to_path) -> :ok
      true -> {:skipped, "Target path is now occupied — re-run the dry run to re-plan"}
    end
  end

  # Moves/deletes only apply while the DB still agrees with the plan about where
  # the file is — a re-download or another process may have relocated it since
  defp verify_current_path(media_item, row) do
    current = current_path_for_attribute(media_item, row.attribute)

    cond do
      current != row.from_path -> {:skipped, "Stale: file has moved since the plan was created"}
      !File.exists?(row.from_path) -> {:skipped, "File no longer exists on disk"}
      true -> :ok
    end
  end

  defp current_path_for_attribute(media_item, "media"), do: media_item.media_filepath
  defp current_path_for_attribute(media_item, "thumbnail"), do: media_item.thumbnail_filepath
  defp current_path_for_attribute(media_item, "metadata"), do: media_item.metadata_filepath
  defp current_path_for_attribute(media_item, "nfo"), do: media_item.nfo_filepath

  defp current_path_for_attribute(media_item, "subtitle:" <> lang) do
    media_item.subtitle_filepaths
    |> MapUtils.from_nested_list()
    |> Map.get(lang)
  end

  defp change_for_attribute("media", path), do: %{media_filepath: path}
  defp change_for_attribute("thumbnail", path), do: %{thumbnail_filepath: path}
  defp change_for_attribute("metadata", path), do: %{metadata_filepath: path}
  defp change_for_attribute("nfo", path), do: %{nfo_filepath: path}
  defp change_for_attribute("subtitle:" <> lang, path), do: %{subtitle_changes: %{lang => path}}

  # ---- Media item backfills ----

  defp backfill_media_item_attribute(media_item, %{attribute: "nfo"} = row) do
    with {:ok, metadata} <- read_stored_metadata(media_item) do
      NfoBuilder.build_and_store_for_media_item(row.to_path, metadata)
      {:ok, %{nfo_filepath: row.to_path}}
    end
  end

  defp backfill_media_item_attribute(media_item, %{attribute: "metadata"} = row) do
    with {:ok, metadata} <- read_stored_metadata(media_item),
         {:ok, json} <- Phoenix.json_library().encode(metadata),
         :ok <- FSUtils.write_p(row.to_path, json) do
      {:ok, %{metadata_filepath: row.to_path}}
    else
      {:skipped, reason} -> {:skipped, reason}
      err -> {:error, "Could not write info.json: #{inspect(err)}"}
    end
  end

  defp backfill_media_item_attribute(media_item, %{attribute: "thumbnail"} = row) do
    rootname = Path.rootname(row.to_path)
    command_opts = [output: "#{rootname}.%(ext)s"]
    addl_opts = [use_cookies: Sources.use_cookies?(media_item.source, :metadata)]

    case YtDlpMedia.download_thumbnail(media_item.original_url, command_opts, addl_opts) do
      {:ok, _} ->
        if File.exists?(row.to_path) do
          {:ok, %{thumbnail_filepath: row.to_path}}
        else
          {:error, "Thumbnail fetch reported success but no file was written"}
        end

      {:error, message, _exit_code} ->
        {:error, "Thumbnail fetch failed: #{inspect(message)}"}

      err ->
        {:error, "Thumbnail fetch failed: #{inspect(err)}"}
    end
  end

  defp backfill_media_item_attribute(media_item, %{attribute: "subtitles"} = row) do
    profile = media_item.source.media_profile
    rootname = row.to_path |> Path.rootname() |> Path.rootname()

    # Mirror how a real download names subtitles: yt-dlp derives the sub filename
    # from the media output template (replacing its extension with `.<lang>.<ext>`),
    # so pass the `%(ext)s` template shape the thumbnail backfill and downloads use.
    # `--write-auto-subs` is only added when the profile opts into auto-captions —
    # exactly as `DownloadOptionBuilder.subtitle_options/1` does — so the backfill
    # can't fetch subs a normal download wouldn't.
    command_opts =
      [sub_langs: profile.sub_langs, output: "#{rootname}.%(ext)s"] ++
        if(profile.download_auto_subs, do: [:write_auto_subs], else: [])

    addl_opts = [use_cookies: Sources.use_cookies?(media_item.source, :metadata)]

    case YtDlpMedia.download_subtitles(media_item.original_url, command_opts, addl_opts) do
      {:ok, _} ->
        case discover_subtitles(rootname) do
          empty when map_size(empty) == 0 ->
            # yt-dlp exits 0 even when the video has no subs in the requested
            # languages — surface that (with a hint) instead of marking it done
            {:skipped, subtitles_unavailable_detail(profile)}

          subtitle_changes ->
            {:ok, %{subtitle_changes: subtitle_changes}}
        end

      {:error, message, _exit_code} ->
        {:error, "Subtitle fetch failed: #{inspect(message)}"}

      err ->
        {:error, "Subtitle fetch failed: #{inspect(err)}"}
    end
  end

  defp backfill_media_item_attribute(_media_item, row) do
    {:error, "Unknown backfill attribute: #{row.attribute}"}
  end

  # Many sources (e.g. most YouTube channels) only publish auto-generated
  # captions, which need auto-subs enabled; point the user at that toggle
  defp subtitles_unavailable_detail(%{download_auto_subs: false, sub_langs: langs}) do
    "No manual #{langs} subtitles were available. If this source only has auto-generated " <>
      "captions, enable auto-generated subtitles in the media profile."
  end

  defp subtitles_unavailable_detail(%{sub_langs: langs}) do
    "yt-dlp found no #{langs} subtitles to download for this video."
  end

  defp discover_subtitles(rootname) do
    "#{rootname}.*.srt"
    |> Path.wildcard()
    |> Map.new(fn path ->
      lang = path |> Path.rootname(".srt") |> Path.extname() |> String.trim_leading(".")
      {lang, path}
    end)
  end

  defp read_stored_metadata(%MediaItem{metadata: %{metadata_filepath: filepath}}) when is_binary(filepath) do
    if FSUtils.exists_and_nonempty?(filepath) do
      MetadataFileHelpers.read_compressed_metadata(filepath)
    else
      {:skipped, "Stored metadata is missing"}
    end
  end

  defp read_stored_metadata(_media_item), do: {:skipped, "Stored metadata is missing"}

  # ---- Source-level application ----

  defp apply_source_rows(source_id, rows) do
    source = Repo.preload(Sources.get_source!(source_id), [:metadata, :media_profile])

    changes =
      Enum.reduce(rows, %{}, fn row, changes_acc ->
        case apply_source_row(source, row) do
          {:ok, new_changes} ->
            mark_row(row, :done)
            Map.merge(changes_acc, new_changes)

          {:skipped, reason} ->
            mark_row(row, :skipped, reason)
            changes_acc

          {:error, reason} ->
            mark_row(row, :failed, reason)
            changes_acc
        end
      end)

    persist_source_changes(source, changes)
  rescue
    Ecto.NoResultsError ->
      Enum.each(rows, &mark_row(&1, :skipped, "Source no longer exists"))
  end

  defp persist_source_changes(_source, changes) when changes == %{}, do: :ok

  defp persist_source_changes(source, changes) do
    case Sources.update_source(source, changes, run_post_commit_tasks: false) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("Reconcile could not update source ##{source.id}: #{inspect(changeset.errors)}")
        :ok
    end
  end

  # Record-only row: the series directory itself moved, no file operation
  defp apply_source_row(source, %{action: :move, attribute: "series_directory"} = row) do
    if source.series_directory == row.from_path do
      {:ok, %{series_directory: row.to_path}}
    else
      {:skipped, "Stale: series directory changed since the plan was created"}
    end
  end

  defp apply_source_row(source, %{action: :move} = row) do
    with :ok <- verify_current_source_path(source, row),
         :ok <- verify_destination_free(row) do
      case FSUtils.move_p(row.from_path, row.to_path) do
        :ok -> {:ok, source_change_for_attribute(row.attribute, row.to_path)}
        {:error, reason} -> {:error, "Move failed: #{inspect(reason)}"}
      end
    end
  end

  defp apply_source_row(source, %{action: :delete} = row) do
    with :ok <- verify_current_source_path(source, row) do
      case FSUtils.delete_file_and_remove_empty_directories(row.from_path) do
        :ok -> {:ok, source_change_for_attribute(row.attribute, nil)}
        {:error, reason} -> {:error, "Delete failed: #{inspect(reason)}"}
      end
    end
  end

  defp apply_source_row(source, %{action: :backfill, attribute: "source_nfo"} = row) do
    with :ok <- verify_destination_free(row) do
      case Repo.preload(source, :metadata).metadata do
        %{metadata_filepath: filepath} when is_binary(filepath) ->
          with {:ok, metadata} <- MetadataFileHelpers.read_compressed_metadata(filepath) do
            NfoBuilder.build_and_store_for_source(row.to_path, metadata)
            {:ok, %{nfo_filepath: row.to_path}}
          end

        _ ->
          {:skipped, "Stored source metadata is missing"}
      end
    end
  end

  # Source images require a metadata fetch, which Refresh Metadata already does
  defp apply_source_row(source, %{action: :backfill, attribute: "source_images"}) do
    case Pinchflat.Metadata.SourceMetadataStorageWorker.kickoff_with_task(source) do
      {:ok, _} -> {:ok, %{}}
      {:error, :duplicate_job} -> {:ok, %{}}
      {:error, reason} -> {:error, "Could not schedule metadata refresh: #{inspect(reason)}"}
    end
  end

  defp apply_source_row(_source, row) do
    {:error, "Unknown source action/attribute: #{row.action}/#{row.attribute}"}
  end

  defp verify_current_source_path(source, row) do
    current = Map.get(source, source_attribute_column(row.attribute))

    cond do
      current != row.from_path -> {:skipped, "Stale: file has moved since the plan was created"}
      !File.exists?(row.from_path) -> {:skipped, "File no longer exists on disk"}
      true -> :ok
    end
  end

  defp source_attribute_column("source_nfo"), do: :nfo_filepath
  defp source_attribute_column("source_poster"), do: :poster_filepath
  defp source_attribute_column("source_fanart"), do: :fanart_filepath
  defp source_attribute_column("source_banner"), do: :banner_filepath

  defp source_change_for_attribute(attribute, path) do
    %{source_attribute_column(attribute) => path}
  end

  # ---- Wrap-up ----

  defp mark_row(row, status, detail \\ nil) do
    attrs = if detail, do: %{status: status, detail: detail}, else: %{status: status}
    {:ok, _} = Reconciliation.update_plan_item(row, attrs)
  end

  defp kickoff_podcast_exports(rows) do
    rows
    |> Enum.map(& &1.source_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn source_id ->
      case Repo.get(Source, source_id) do
        # kickoff no-ops for sources that aren't published as podcasts
        %Source{} = source -> PodcastExportWorker.kickoff(source)
        nil -> :ok
      end
    end)
  end

  defp finalize_plan(plan) do
    failed_count =
      ReconcilePlanItem
      |> where(reconcile_plan_id: ^plan.id, status: :failed)
      |> Repo.aggregate(:count)

    Reconciliation.update_plan(plan, %{
      status: :applied,
      applied_at: DateTime.utc_now(:second),
      error_count: failed_count
    })
  end
end
