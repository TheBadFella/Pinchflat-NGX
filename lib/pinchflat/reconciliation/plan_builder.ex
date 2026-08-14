defmodule Pinchflat.Reconciliation.PlanBuilder do
  @moduledoc """
  Builds a reconcile plan's items (the dry run): walks every downloaded media
  item in scope, predicts where its files would land under the current settings
  (via `PathPredictor` — no network in `:local` mode), and records the moves,
  backfills, and deletions needed to true up disk + DB. Nothing here touches
  the filesystem beyond reads; `PlanApplier` executes the plan later.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.MediaQuery
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.PathPredictor
  alias Pinchflat.Reconciliation.ReconcilePlan
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @doc """
  Builds and persists the plan's items, then refreshes its counts.

  Returns {:ok, %ReconcilePlan{}}
  """
  def build_plan_items(%ReconcilePlan{} = plan) do
    rows =
      plan
      |> sources_in_scope()
      |> Enum.flat_map(&rows_for_source(plan, &1))
      |> detect_collisions()

    Reconciliation.create_plan_items(rows)
    Reconciliation.refresh_plan_counts(plan)
  end

  defp sources_in_scope(%ReconcilePlan{source_id: nil}) do
    Repo.all(from(s in Source, where: is_nil(s.marked_for_deletion_at))) |> Repo.preload(:media_profile)
  end

  defp sources_in_scope(%ReconcilePlan{source_id: source_id}) do
    [Repo.preload(Sources.get_source!(source_id), :media_profile)]
  end

  defp rows_for_source(plan, source) do
    media_items =
      MediaQuery.new()
      |> where(^MediaQuery.for_source(source))
      |> where(^MediaQuery.downloaded())
      |> Repo.all()
      |> Repo.preload(:metadata)
      |> Enum.map(fn %MediaItem{} = media_item -> %MediaItem{media_item | source: source} end)

    item_rows =
      media_items
      |> Task.async_stream(&rows_for_media_item(plan, &1),
        max_concurrency: prediction_concurrency(plan),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, rows} -> rows end)

    source_rows = rows_for_source_artifacts(plan, source, media_items)

    item_rows ++ source_rows
  end

  # Path prediction shells out to yt-dlp once per media item — a cold Python start
  # each time, which serially dominates the scan. In :local mode every call is fully
  # offline (`--load-info-json`), so we fan them out across schedulers. In network
  # modes the metadata-missing fallback can hit YouTube, so we keep concurrency low
  # to avoid tripping yt-dlp's rate limiting / bot detection.
  defp prediction_concurrency(%{mode: :local}), do: max(System.schedulers_online(), 4)
  defp prediction_concurrency(_plan), do: 2

  # File extensions that unambiguously indicate an audio-only vs a video file.
  # Ambiguous containers (webm, ogg, mkv can technically hold either) are left
  # out of both sets so a mismatch only ever fires when we're certain.
  @audio_exts ~w(mp3 m4a aac flac wav opus oga wma alac)
  @video_exts ~w(mp4 mkv avi mov flv wmv m4v ts mpg mpeg 3gp)

  # ---- Per-media-item rows ----

  # "Online mode, plus" — an item always gets its normal move/backfill/delete
  # rows (relocating and truing up the existing files offline), and in :full mode
  # a format-mismatched item ALSO gets a re-download row. The moves put the current
  # file in the right place with no bandwidth; the later re-download replaces it
  # with the correct format at that same path (cleaning the stale one up itself).
  defp rows_for_media_item(plan, media_item) do
    path_rows(plan, media_item) ++ redownload_rows(plan, media_item)
  end

  defp redownload_rows(plan, media_item) do
    case redownload_reason(plan, media_item) do
      nil -> []
      reason -> [item_row(plan, media_item, :redownload, "media", from_path: media_item.media_filepath, detail: reason)]
    end
  end

  # Only in :full mode, and only for the format dimensions we can read straight
  # off the on-disk extension (audio-vs-video, container) — no JSON parsing
  # needed, and the extension reflects the real post-remux file.
  defp redownload_reason(%{mode: :full}, media_item) do
    profile = media_item.source.media_profile
    actual_ext = media_item.media_filepath |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    audio_profile? = profile.preferred_resolution == :audio

    cond do
      actual_ext == "" -> nil
      audio_profile? && actual_ext in @video_exts -> "Profile is Audio Only but the file is video (.#{actual_ext})"
      !audio_profile? && actual_ext in @audio_exts -> "Profile is video but the file is audio-only (.#{actual_ext})"
      true -> container_mismatch_reason(profile, audio_profile?, actual_ext)
    end
  end

  defp redownload_reason(_plan, _media_item), do: nil

  # A downloaded video is remuxed to `media_container` (or mp4 when unset); an
  # audio download uses `media_container` when set (unset means yt-dlp keeps the
  # native "best" audio container, which we can't predict, so no trigger there).
  defp container_mismatch_reason(profile, audio_profile?, actual_ext) do
    expected = expected_container(profile, audio_profile?)

    cond do
      is_nil(expected) -> nil
      actual_ext == expected -> nil
      true -> "File container .#{actual_ext} doesn't match the profile's .#{expected}"
    end
  end

  defp expected_container(profile, true = _audio_profile?), do: normalize_container(profile.media_container)
  defp expected_container(profile, false = _audio_profile?), do: normalize_container(profile.media_container) || "mp4"

  defp normalize_container(nil), do: nil

  defp normalize_container(container) do
    case container |> to_string() |> String.trim() |> String.trim_leading(".") |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp path_rows(plan, media_item) do
    case predict_media_filepath(plan, media_item) do
      {:ok, new_media_filepath} ->
        media_move_rows(plan, media_item, new_media_filepath) ++
          sidecar_rows(plan, media_item, Path.rootname(new_media_filepath))

      {:error, :no_metadata} ->
        [item_row(plan, media_item, :skip, "media", detail: no_metadata_detail(plan))]

      {:error, message} ->
        [item_row(plan, media_item, :skip, "media", detail: "Path prediction failed: #{message}")]
    end
  end

  # Both :online and :full allow light network calls; :local never does
  defp network_mode?(%{mode: mode}), do: mode in [:online, :full]

  defp predict_media_filepath(plan, media_item) do
    case PathPredictor.predict_media_filepath(media_item) do
      {:error, :no_metadata} -> maybe_network_predict(plan, media_item)
      result -> result
    end
  end

  defp maybe_network_predict(plan, media_item) do
    if network_mode?(plan) do
      network_predict_media_filepath(media_item)
    else
      {:error, :no_metadata}
    end
  end

  # Fallback for items missing their stored metadata blob: one metadata-only
  # yt-dlp call (never the YouTube Data API) to render the filename remotely
  defp network_predict_media_filepath(media_item) do
    command_opts =
      [output: DownloadOptionBuilder.build_output_path_for(media_item)] ++
        DownloadOptionBuilder.build_quality_options_for(media_item.source)

    addl_opts = [use_cookies: Sources.use_cookies?(media_item.source, :metadata)]

    case YtDlpMedia.get_media_attributes(media_item.original_url, command_opts, addl_opts) do
      {:ok, %YtDlpMedia{predicted_media_filepath: filepath}} when is_binary(filepath) ->
        {:ok, Path.rootname(filepath) <> Path.extname(media_item.media_filepath)}

      {:error, message, _exit_code} ->
        {:error, to_string(message)}

      {:error, message} ->
        {:error, to_string(message)}

      other ->
        {:error, inspect(other)}
    end
  end

  defp no_metadata_detail(%{mode: :local}) do
    "No stored metadata to render the new path from — run in Online or Full sync mode to fetch it"
  end

  defp no_metadata_detail(_plan), do: "No stored metadata and the network fetch failed"

  defp media_move_rows(plan, media_item, new_media_filepath) do
    move_or_skip_rows(plan, media_item, "media", media_item.media_filepath, new_media_filepath)
  end

  defp sidecar_rows(plan, media_item, new_rootname) do
    profile = media_item.source.media_profile

    thumbnail_rows(plan, media_item, profile, new_rootname) ++
      infojson_rows(plan, media_item, profile, new_rootname) ++
      nfo_rows(plan, media_item, profile, new_rootname) ++
      subtitle_rows(plan, media_item, profile, new_rootname)
  end

  defp thumbnail_rows(plan, media_item, %{download_thumbnail: true}, new_rootname) do
    current = media_item.thumbnail_filepath

    cond do
      current && File.exists?(current) ->
        move_or_skip_rows(plan, media_item, "thumbnail", current, new_rootname <> Path.extname(current))

      network_mode?(plan) ->
        [item_row(plan, media_item, :backfill, "thumbnail", to_path: new_rootname <> ".jpg", detail: "Fetch thumbnail")]

      true ->
        [item_row(plan, media_item, :skip, "thumbnail", detail: "Backfill requires Online or Full sync mode")]
    end
  end

  defp thumbnail_rows(plan, media_item, _profile, _new_rootname) do
    delete_rows(plan, media_item, "thumbnail", media_item.thumbnail_filepath)
  end

  defp infojson_rows(plan, media_item, %{download_metadata: true}, new_rootname) do
    current = media_item.metadata_filepath
    target = new_rootname <> ".info.json"

    cond do
      current && File.exists?(current) ->
        move_or_skip_rows(plan, media_item, "metadata", current, target)

      stored_metadata?(media_item) ->
        [item_row(plan, media_item, :backfill, "metadata", to_path: target, detail: "Write from stored metadata")]

      true ->
        [item_row(plan, media_item, :skip, "metadata", detail: "No stored metadata to write the info.json from")]
    end
  end

  defp infojson_rows(plan, media_item, _profile, _new_rootname) do
    delete_rows(plan, media_item, "metadata", media_item.metadata_filepath)
  end

  defp nfo_rows(plan, media_item, %{download_nfo: true}, new_rootname) do
    current = media_item.nfo_filepath
    target = new_rootname <> ".nfo"

    cond do
      current && File.exists?(current) ->
        move_or_skip_rows(plan, media_item, "nfo", current, target)

      stored_metadata?(media_item) ->
        [item_row(plan, media_item, :backfill, "nfo", to_path: target, detail: "Build from stored metadata")]

      true ->
        [item_row(plan, media_item, :skip, "nfo", detail: "No stored metadata to build the NFO from")]
    end
  end

  defp nfo_rows(plan, media_item, _profile, _new_rootname) do
    delete_rows(plan, media_item, "nfo", media_item.nfo_filepath)
  end

  defp subtitle_rows(plan, media_item, profile, new_rootname) do
    subs_enabled = profile.download_subs || profile.download_auto_subs

    case {subs_enabled, media_item.subtitle_filepaths} do
      {true, []} ->
        subtitle_backfill_rows(plan, media_item, profile, new_rootname)

      {true, pairs} ->
        Enum.flat_map(pairs, fn [lang, path] ->
          target = "#{new_rootname}.#{lang}#{Path.extname(path)}"
          move_or_skip_rows(plan, media_item, "subtitle:#{lang}", path, target)
        end)

      {false, pairs} ->
        Enum.flat_map(pairs, fn [lang, path] -> delete_rows(plan, media_item, "subtitle:#{lang}", path) end)
    end
  end

  defp subtitle_backfill_rows(plan, media_item, profile, new_rootname) do
    if network_mode?(plan) do
      [
        item_row(plan, media_item, :backfill, "subtitles",
          to_path: "#{new_rootname}.#{profile.sub_langs}.srt",
          detail: "Fetch subtitles (#{profile.sub_langs})"
        )
      ]
    else
      [item_row(plan, media_item, :skip, "subtitles", detail: "Backfill requires Online or Full sync mode")]
    end
  end

  defp stored_metadata?(%MediaItem{metadata: %{metadata_filepath: filepath}}) when is_binary(filepath) do
    FSUtils.exists_and_nonempty?(filepath)
  end

  defp stored_metadata?(_media_item), do: false

  # ---- Source-level artifact rows ----

  defp rows_for_source_artifacts(plan, source, media_items) do
    profile = source.media_profile

    cond do
      # Podcasts have no series directory — series-level artifacts left over from a
      # previous media-center profile can't be placed anywhere, so they're removed
      MediaProfile.podcast?(profile) ->
        delete_all_source_artifacts(plan, source)

      profile.download_nfo || profile.download_source_images || any_source_artifact?(source) ->
        case predict_series_directory(media_items) do
          {:ok, series_directory} -> source_artifact_rows(plan, source, series_directory)
          {:error, _} -> source_artifact_error_rows(plan, source)
        end

      true ->
        []
    end
  end

  defp delete_all_source_artifacts(plan, source) do
    delete_rows(plan, source, "source_nfo", source.nfo_filepath) ++ source_image_delete_rows(plan, source)
  end

  defp any_source_artifact?(source) do
    Source.filepath_attributes()
    |> Enum.any?(fn attr -> Map.get(source, attr) end)
  end

  defp predict_series_directory(media_items) do
    sample = Enum.find(media_items, &stored_metadata?/1)

    if sample do
      PathPredictor.predict_series_directory(sample)
    else
      {:error, :no_metadata}
    end
  end

  defp source_artifact_error_rows(plan, source) do
    if any_source_artifact?(source) do
      [source_row(plan, source, :skip, "series_directory", detail: "Could not determine the new series directory")]
    else
      []
    end
  end

  defp source_artifact_rows(plan, source, series_directory) do
    profile = source.media_profile

    series_directory_rows(plan, source, series_directory) ++
      source_nfo_rows(plan, source, profile, series_directory) ++
      source_image_rows(plan, source, profile, series_directory)
  end

  # A record-only "move": the applier updates source.series_directory, no file op
  defp series_directory_rows(plan, source, series_directory) do
    if source.series_directory && source.series_directory != series_directory do
      [
        source_row(plan, source, :move, "series_directory",
          from_path: source.series_directory,
          to_path: series_directory,
          detail: "Update the recorded series directory"
        )
      ]
    else
      []
    end
  end

  defp source_nfo_rows(plan, source, %{download_nfo: true}, series_directory) do
    current = source.nfo_filepath
    target = Path.join(series_directory, "tvshow.nfo")

    cond do
      current && File.exists?(current) ->
        move_or_skip_rows(plan, source, "source_nfo", current, target)

      source_stored_metadata?(source) ->
        [source_row(plan, source, :backfill, "source_nfo", to_path: target, detail: "Build from stored metadata")]

      true ->
        [source_row(plan, source, :skip, "source_nfo", detail: "No stored source metadata to build the NFO from")]
    end
  end

  defp source_nfo_rows(plan, source, _profile, _series_directory) do
    delete_rows(plan, source, "source_nfo", source.nfo_filepath)
  end

  defp source_image_rows(plan, source, %{download_source_images: true}, series_directory) do
    recorded =
      [:poster_filepath, :fanart_filepath, :banner_filepath]
      |> Enum.map(fn attr -> {attr, Map.get(source, attr)} end)
      |> Enum.filter(fn {_attr, path} -> path end)

    any_missing_on_disk? = Enum.any?(recorded, fn {_attr, path} -> !File.exists?(path) end)

    cond do
      # Nothing recorded (e.g. images were just enabled) — fetch them all
      recorded == [] ->
        source_image_backfill_rows(plan, source)

      # Some recorded artwork has vanished from disk. A metadata refresh both
      # restores it and re-places every image under the new series directory,
      # so it supersedes the individual moves. Only available with the network;
      # in local mode we fall through to moving what's present and skipping the
      # missing (via move_or_skip_rows).
      any_missing_on_disk? && network_mode?(plan) ->
        source_image_backfill_rows(plan, source)

      true ->
        Enum.flat_map(recorded, fn {attr, path} ->
          attribute = "source_#{attr |> to_string() |> String.replace("_filepath", "")}"
          move_or_skip_rows(plan, source, attribute, path, Path.join(series_directory, Path.basename(path)))
        end)
    end
  end

  defp source_image_rows(plan, source, _profile, _series_directory) do
    source_image_delete_rows(plan, source)
  end

  defp source_image_delete_rows(plan, source) do
    [:poster_filepath, :fanart_filepath, :banner_filepath]
    |> Enum.flat_map(fn attr ->
      attribute = "source_#{attr |> to_string() |> String.replace("_filepath", "")}"
      delete_rows(plan, source, attribute, Map.get(source, attr))
    end)
  end

  defp source_image_backfill_rows(plan, source) do
    if network_mode?(plan) do
      [source_row(plan, source, :backfill, "source_images", detail: "Fetch source images (runs Refresh Metadata)")]
    else
      [source_row(plan, source, :skip, "source_images", detail: "Backfill requires Online or Full sync mode")]
    end
  end

  defp source_stored_metadata?(source) do
    case Repo.preload(source, :metadata).metadata do
      %{metadata_filepath: filepath} when is_binary(filepath) -> FSUtils.exists_and_nonempty?(filepath)
      _ -> false
    end
  end

  # ---- Shared row helpers ----

  defp move_or_skip_rows(plan, record, attribute, from_path, to_path) do
    cond do
      from_path == to_path ->
        []

      !File.exists?(from_path) ->
        [build_row(plan, record, :skip, attribute, from_path: from_path, detail: missing_on_disk_detail(attribute))]

      File.exists?(to_path) && FSUtils.filepaths_reference_same_file?(from_path, to_path) ->
        []

      true ->
        [build_row(plan, record, :move, attribute, from_path: from_path, to_path: to_path)]
    end
  end

  defp missing_on_disk_detail("media"), do: "File missing on disk — run Sync Files on Disk first"
  defp missing_on_disk_detail(_attribute), do: "File missing on disk"

  defp delete_rows(plan, record, attribute, filepath) do
    if filepath && File.exists?(filepath) do
      [build_row(plan, record, :delete, attribute, from_path: filepath, detail: "Disabled in the media profile")]
    else
      []
    end
  end

  defp item_row(plan, media_item, action, attribute, opts) do
    build_row(plan, media_item, action, attribute, opts)
  end

  defp source_row(plan, source, action, attribute, opts) do
    build_row(plan, source, action, attribute, opts)
  end

  defp build_row(plan, record, action, attribute, opts) do
    {media_item_id, source_id} =
      case record do
        %MediaItem{} = mi -> {mi.id, mi.source_id}
        %Source{} = s -> {nil, s.id}
      end

    %{
      reconcile_plan_id: plan.id,
      media_item_id: media_item_id,
      source_id: source_id,
      action: action,
      attribute: attribute,
      from_path: Keyword.get(opts, :from_path),
      to_path: Keyword.get(opts, :to_path),
      detail: Keyword.get(opts, :detail),
      status: :planned
    }
  end

  # ---- Collision detection ----

  # A move/backfill whose target is already occupied on disk, or that shares a
  # target with another row, becomes a collision (both sides). A target occupied
  # by a file that this same plan would move away still counts — applying the
  # plan and re-running reconcile resolves those chains one step at a time.
  defp detect_collisions(rows) do
    duplicate_targets =
      rows
      |> Enum.filter(&(&1.action in [:move, :backfill] && &1.to_path))
      |> Enum.frequencies_by(& &1.to_path)
      |> Enum.filter(fn {_target, count} -> count > 1 end)
      |> MapSet.new(fn {target, _count} -> target end)

    Enum.map(rows, fn row ->
      cond do
        row.action not in [:move, :backfill] || is_nil(row.to_path) || row.attribute == "series_directory" ->
          row

        MapSet.member?(duplicate_targets, row.to_path) ->
          %{row | action: :collision, detail: "Multiple files resolve to this target path"}

        # Applies to moves and backfills alike: an occupied target would be
        # clobbered by the rename/copy or the write, so never touch it
        File.exists?(row.to_path) ->
          %{
            row
            | action: :collision,
              detail: "Target path already occupied — if a planned move will free it, re-run after applying"
          }

        true ->
          row
      end
    end)
  end
end
