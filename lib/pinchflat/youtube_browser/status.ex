defmodule Pinchflat.YoutubeBrowser.Status do
  @moduledoc """
  Batch-enriches YouTube video and channel IDs against local library sources,
  media items, and active/historical background jobs with a constant query budget.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task

  defmodule VideoStatus do
    @moduledoc """
    Represents the library and download status of a YouTube video.
    """
    defstruct [
      :video_id,
      :state,
      :badge_text,
      :can_download?,
      :open_local_path,
      :media_item_uuid,
      :media_item_id,
      :source_id,
      :selected_copy,
      :copies,
      :selected_profile_id
    ]
  end

  defmodule ChannelStatus do
    @moduledoc """
    Represents the tracking and subscription status of a YouTube channel.
    """
    defstruct [
      :channel_id,
      :state,
      :badge_text,
      :can_subscribe?,
      :open_source_id,
      :sources,
      :selected_profile_id
    ]
  end

  @active_job_states ["executing", "available", "scheduled", "retryable"]

  @download_workers [
    "Pinchflat.Downloading.MediaDownloadWorker",
    "Elixir.Pinchflat.Downloading.MediaDownloadWorker"
  ]

  @indexing_workers [
    "Pinchflat.SlowIndexing.MediaCollectionIndexingWorker",
    "Elixir.Pinchflat.SlowIndexing.MediaCollectionIndexingWorker",
    "Pinchflat.FastIndexing.FastIndexingWorker",
    "Elixir.Pinchflat.FastIndexing.FastIndexingWorker"
  ]

  @doc """
  Enriches a list of video IDs against local library media items, sources,
  and Oban background tasks within a bounded query budget (at most 4 queries).
  """
  def enrich_videos(video_ids, opts \\ []) when is_list(video_ids) do
    clean_ids =
      video_ids
      |> Enum.filter(fn id -> is_binary(id) and String.trim(id) != "" end)
      |> Enum.uniq()

    if clean_ids == [] do
      %{}
    else
      selected_profile_id = Keyword.get(opts, :selected_profile_id)
      verify_files? = Keyword.get(opts, :verify_files?, true)

      # Query 1: MediaItems matching video_ids with joined source and media_profile
      media_items =
        from(m in MediaItem,
          join: s in assoc(m, :source),
          left_join: p in assoc(s, :media_profile),
          where: m.media_id in ^clean_ids,
          preload: [source: {s, media_profile: p}]
        )
        |> Repo.all()

      media_item_ids = Enum.map(media_items, & &1.id)

      # Query 2: Active or recent download tasks/jobs for these media items (filtered by download workers)
      media_tasks =
        if media_item_ids == [] do
          []
        else
          from(t in Task,
            join: j in assoc(t, :job),
            where: t.media_item_id in ^media_item_ids and j.worker in ^@download_workers,
            order_by: [desc: j.id],
            select: {t.media_item_id, j, t}
          )
          |> Repo.all()
        end

      # Query 3: Standalone single-video sources in preparation/indexing (where MediaItem may not exist yet)
      video_sources =
        from(s in Source,
          left_join: p in assoc(s, :media_profile),
          where: s.collection_type == :video and s.collection_id in ^clean_ids,
          preload: [media_profile: p]
        )
        |> Repo.all()

      video_source_ids = Enum.map(video_sources, & &1.id)

      # Query 4: Indexing tasks/jobs for standalone single-video sources (filtered by indexing workers)
      source_tasks =
        if video_source_ids == [] do
          []
        else
          from(t in Task,
            join: j in assoc(t, :job),
            where: t.source_id in ^video_source_ids and j.worker in ^@indexing_workers,
            order_by: [desc: j.id],
            select: {t.source_id, j, t}
          )
          |> Repo.all()
        end

      # Group media items and tasks by video_id
      media_items_by_vid = Enum.group_by(media_items, & &1.media_id)
      media_tasks_by_item_id = Enum.group_by(media_tasks, fn {item_id, _j, _t} -> item_id end)
      video_sources_by_vid = Enum.group_by(video_sources, & &1.collection_id)
      source_tasks_by_source_id = Enum.group_by(source_tasks, fn {src_id, _j, _t} -> src_id end)

      Map.new(clean_ids, fn vid ->
        items = Map.get(media_items_by_vid, vid, [])
        sources_for_vid = Map.get(video_sources_by_vid, vid, [])

        copies =
          build_video_copies(items, media_tasks_by_item_id, verify_files?) ++
            build_indexing_source_copies(sources_for_vid, items, source_tasks_by_source_id)

        status = resolve_video_status(vid, copies, selected_profile_id)
        {vid, status}
      end)
    end
  end

  @doc """
  Enriches a list of channel IDs against local tracked sources within a bounded query budget (2 queries).
  """
  def enrich_channels(channel_ids, opts \\ []) when is_list(channel_ids) do
    clean_ids =
      channel_ids
      |> Enum.filter(fn id -> is_binary(id) and String.trim(id) != "" end)
      |> Enum.uniq()

    if clean_ids == [] do
      %{}
    else
      selected_profile_id = Keyword.get(opts, :selected_profile_id)

      # Query 1: Sources matching channel_ids
      sources =
        from(s in Source,
          left_join: p in assoc(s, :media_profile),
          where: s.collection_type == :channel and s.collection_id in ^clean_ids,
          preload: [media_profile: p]
        )
        |> Repo.all()

      source_ids = Enum.map(sources, & &1.id)

      # Query 2: Active indexing tasks for these channel sources
      tasks =
        if source_ids == [] do
          []
        else
          from(t in Task,
            join: j in assoc(t, :job),
            where: t.source_id in ^source_ids and j.worker in ^@indexing_workers,
            order_by: [desc: j.id],
            select: {t.source_id, j, t}
          )
          |> Repo.all()
        end

      sources_by_channel_id = Enum.group_by(sources, & &1.collection_id)
      tasks_by_source_id = Enum.group_by(tasks, fn {src_id, _j, _t} -> src_id end)

      Map.new(clean_ids, fn ch_id ->
        ch_sources = Map.get(sources_by_channel_id, ch_id, [])

        source_entries =
          Enum.map(ch_sources, fn src ->
            src_tasks = Map.get(tasks_by_source_id, src.id, [])
            active_task = Enum.find(src_tasks, fn {_src_id, j, _t} -> j.state in @active_job_states end)

            %{
              source_id: src.id,
              custom_name: src.custom_name || src.collection_name,
              collection_id: src.collection_id,
              collection_type: src.collection_type,
              media_profile_id: src.media_profile_id,
              media_profile_name: (src.media_profile && src.media_profile.name) || "Default",
              enabled: src.enabled,
              download_media: src.download_media,
              selection_mode: src.selection_mode,
              has_active_job?: not is_nil(active_task)
            }
          end)

        status = resolve_channel_status(ch_id, source_entries, selected_profile_id)
        {ch_id, status}
      end)
    end
  end

  @doc """
  Safely verifies the existence and regular-file state of a media file on disk within configured storage roots.
  Returns :verified_present, :missing, :inaccessible, or :unverified.
  """
  def check_file_state(filepath) when is_binary(filepath) and byte_size(filepath) > 0 do
    expanded_path = Path.expand(filepath)

    if within_allowed_roots?(expanded_path) do
      case File.stat(expanded_path) do
        {:ok, %File.Stat{type: :regular}} ->
          :verified_present

        {:ok, %File.Stat{type: :directory}} ->
          :unverified

        {:error, :enoent} ->
          :missing

        {:error, reason} when reason in [:eacces, :eio] ->
          :inaccessible

        _ ->
          :unverified
      end
    else
      :unverified
    end
  rescue
    _ -> :unverified
  end

  def check_file_state(_), do: :no_path

  @doc """
  Returns the list of allowed storage roots.
  """
  def allowed_roots do
    media_dir = Application.get_env(:pinchflat, :media_directory)

    configured_roots =
      case Application.get_env(:pinchflat, :allowed_storage_roots) do
        list when is_list(list) -> Enum.map(list, &Path.expand/1)
        _ -> []
      end

    media_roots = if media_dir, do: [Path.expand(media_dir)], else: []

    (media_roots ++ configured_roots)
    |> Enum.uniq()
  end

  defp within_allowed_roots?(expanded_path) do
    roots = allowed_roots()

    Enum.any?(roots, fn root ->
      expanded_path == root or String.starts_with?(expanded_path, root <> "/")
    end)
  end

  # --- Internal Helpers ---

  defp build_video_copies(items, tasks_by_item_id, verify_files?) do
    Enum.map(items, fn item ->
      item_tasks = Map.get(tasks_by_item_id, item.id, [])

      # Look for active job first, or most recent historical job
      active_task_job = Enum.find(item_tasks, fn {_id, j, _t} -> j.state in @active_job_states end)

      {job, task} =
        case active_task_job do
          {_id, j, t} ->
            {j, t}

          nil ->
            # Find any recent job
            case List.first(item_tasks) do
              {_id, j, t} -> {j, t}
              nil -> {nil, nil}
            end
        end

      file_state =
        if verify_files? and is_binary(item.media_filepath) and item.media_filepath != "" do
          check_file_state(item.media_filepath)
        else
          :unverified
        end

      src = item.source

      %{
        type: :media_item,
        media_item_id: item.id,
        media_item_uuid: item.uuid,
        source_id: src.id,
        source_name: src.custom_name || src.collection_name,
        source_type: src.collection_type,
        source_enabled: src.enabled,
        source_download_media: src.download_media,
        media_profile_id: src.media_profile_id,
        media_profile_name: (src.media_profile && src.media_profile.name) || "Default",
        media_filepath: item.media_filepath,
        file_state: file_state,
        media_downloaded_at: item.media_downloaded_at,
        prevent_download: item.prevent_download,
        download_prevented_reason: item.download_prevented_reason,
        culled_at: item.culled_at,
        unavailable_at: item.unavailable_at,
        unavailable_reason: item.unavailable_reason,
        job_state: job && job.state,
        job_id: job && job.id,
        progress_percent: task && task.progress_percent,
        progress_status: task && task.progress_status
      }
    end)
  end

  defp build_indexing_source_copies(sources, items, source_tasks_by_source_id) do
    # Only include single-video sources that don't yet have media items in `items`
    item_source_ids = MapSet.new(Enum.map(items, & &1.source_id))

    sources
    |> Enum.reject(&MapSet.member?(item_source_ids, &1.id))
    |> Enum.map(fn src ->
      src_tasks = Map.get(source_tasks_by_source_id, src.id, [])
      active_task = Enum.find(src_tasks, fn {_id, j, _t} -> j.state in @active_job_states end)

      {job, task} =
        case active_task do
          {_id, j, t} -> {j, t}
          nil -> {nil, nil}
        end

      %{
        type: :source_indexing,
        media_item_id: nil,
        media_item_uuid: nil,
        source_id: src.id,
        source_name: src.custom_name || src.collection_name,
        source_type: :video,
        source_enabled: src.enabled,
        source_download_media: src.download_media,
        media_profile_id: src.media_profile_id,
        media_profile_name: (src.media_profile && src.media_profile.name) || "Default",
        media_filepath: nil,
        file_state: :no_path,
        media_downloaded_at: nil,
        prevent_download: false,
        download_prevented_reason: nil,
        culled_at: nil,
        unavailable_at: nil,
        unavailable_reason: nil,
        job_state: job && job.state,
        job_id: job && job.id,
        progress_percent: task && task.progress_percent,
        progress_status: task && task.progress_status
      }
    end)
  end

  @doc """
  Builds the canonical route to the media detail page for a downloaded media item.
  """
  def build_local_media_path(source_id, media_item_id) when not is_nil(source_id) and not is_nil(media_item_id) do
    base = Application.get_env(:pinchflat, :base_route_path, "/")
    rel = "/sources/#{source_id}/media/#{media_item_id}"

    if base in [nil, "", "/"] do
      rel
    else
      Path.join(base, rel)
    end
  end

  def build_local_media_path(_source_id, _media_item_id), do: nil

  defp resolve_video_status(vid, copies, selected_profile_id) do
    selected_copies =
      if selected_profile_id do
        Enum.filter(copies, &(&1.media_profile_id == selected_profile_id))
      else
        copies
      end

    case selected_copies do
      [] ->
        # No copy in selected profile
        other_copies = copies

        if other_copies != [] do
          # Present in another profile
          first_other = List.first(other_copies)

          %VideoStatus{
            video_id: vid,
            state: :not_in_library,
            badge_text: "In other profile (#{first_other.media_profile_name})",
            can_download?: true,
            open_local_path: build_local_media_path(first_other.source_id, first_other.media_item_id),
            media_item_uuid: first_other.media_item_uuid,
            media_item_id: first_other.media_item_id,
            source_id: first_other.source_id,
            selected_copy: nil,
            copies: copies,
            selected_profile_id: selected_profile_id
          }
        else
          %VideoStatus{
            video_id: vid,
            state: :not_in_library,
            badge_text: nil,
            can_download?: true,
            open_local_path: nil,
            media_item_uuid: nil,
            media_item_id: nil,
            source_id: nil,
            selected_copy: nil,
            copies: [],
            selected_profile_id: selected_profile_id
          }
        end

      [single_copy] ->
        classify_single_copy(vid, single_copy, copies, selected_profile_id)

      multi_copies ->
        # Multiple copies under the same profile
        # Determine if all or any are downloaded
        %VideoStatus{
          video_id: vid,
          state: :ambiguous_copies,
          badge_text: "Multiple copies (#{length(multi_copies)})",
          can_download?: false,
          open_local_path: nil,
          media_item_uuid: nil,
          media_item_id: nil,
          source_id: nil,
          selected_copy: nil,
          copies: copies,
          selected_profile_id: selected_profile_id
        }
    end
  end

  defp classify_single_copy(vid, copy, all_copies, selected_profile_id) do
    open_path = build_local_media_path(copy.source_id, copy.media_item_id)

    cond do
      # 1. Active Oban job executing -> downloading
      copy.job_state == "executing" ->
        pct = if copy.progress_percent, do: " (#{round(copy.progress_percent)}%)", else: ""

        %VideoStatus{
          video_id: vid,
          state: :downloading,
          badge_text: "Downloading#{pct}",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 2. Active Oban job available or scheduled -> queued
      copy.job_state in ["available", "scheduled"] ->
        badge = if copy.job_state == "scheduled", do: "Scheduled", else: "Queued"

        %VideoStatus{
          video_id: vid,
          state: if(copy.job_state == "scheduled", do: :scheduled, else: :queued),
          badge_text: badge,
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 3. Active Oban job retryable -> retrying
      copy.job_state == "retryable" ->
        %VideoStatus{
          video_id: vid,
          state: :retrying,
          badge_text: "Retrying",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 4. Standalone source indexing (before media_item created)
      copy.type == :source_indexing ->
        %VideoStatus{
          video_id: vid,
          state: :indexing,
          badge_text: "Preparing...",
          can_download?: false,
          open_local_path: nil,
          media_item_uuid: nil,
          media_item_id: nil,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 5. File verified present on disk -> in library
      copy.file_state == :verified_present ->
        %VideoStatus{
          video_id: vid,
          state: :in_library,
          badge_text: "In library",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 6. Saved path but file missing on disk -> missing file
      is_binary(copy.media_filepath) and copy.media_filepath != "" and copy.file_state == :missing ->
        %VideoStatus{
          video_id: vid,
          state: :missing_file,
          badge_text: "Missing file",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 7. Saved path but storage inaccessible -> storage inaccessible
      is_binary(copy.media_filepath) and copy.media_filepath != "" and copy.file_state == :inaccessible ->
        %VideoStatus{
          video_id: vid,
          state: :storage_inaccessible,
          badge_text: "Storage unverified",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 8. Prevent download flag
      copy.prevent_download == true ->
        reason = copy.download_prevented_reason || :manual

        %VideoStatus{
          video_id: vid,
          state: :prevented,
          badge_text: "Prevented (#{reason})",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 9. Culled
      not is_nil(copy.culled_at) ->
        %VideoStatus{
          video_id: vid,
          state: :culled,
          badge_text: "Culled",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 10. Unavailable
      not is_nil(copy.unavailable_at) ->
        reason = copy.unavailable_reason || "Unavailable"

        %VideoStatus{
          video_id: vid,
          state: :unavailable,
          badge_text: "Unavailable: #{reason}",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 11. Source disabled
      copy.source_enabled == false ->
        %VideoStatus{
          video_id: vid,
          state: :source_disabled,
          badge_text: "Source disabled",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 12. Source downloads disabled
      copy.source_download_media == false ->
        %VideoStatus{
          video_id: vid,
          state: :downloads_disabled,
          badge_text: "Downloads disabled",
          can_download?: false,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }

      # 13. Indexed in library, but no saved file -> indexed, eligible for download
      true ->
        %VideoStatus{
          video_id: vid,
          state: :indexed,
          badge_text: "Indexed",
          can_download?: true,
          open_local_path: open_path,
          media_item_uuid: copy.media_item_uuid,
          media_item_id: copy.media_item_id,
          source_id: copy.source_id,
          selected_copy: copy,
          copies: all_copies,
          selected_profile_id: selected_profile_id
        }
    end
  end

  defp resolve_channel_status(ch_id, sources, selected_profile_id) do
    case sources do
      [] ->
        %ChannelStatus{
          channel_id: ch_id,
          state: :not_tracked,
          badge_text: nil,
          can_subscribe?: true,
          open_source_id: nil,
          sources: [],
          selected_profile_id: selected_profile_id
        }

      sources_list ->
        matching_profile_source =
          if selected_profile_id do
            Enum.find(sources_list, &(&1.media_profile_id == selected_profile_id))
          else
            List.first(sources_list)
          end

        if matching_profile_source do
          if matching_profile_source.enabled do
            %ChannelStatus{
              channel_id: ch_id,
              state: :subscribed,
              badge_text: "Subscribed",
              can_subscribe?: false,
              open_source_id: matching_profile_source.source_id,
              sources: sources_list,
              selected_profile_id: selected_profile_id
            }
          else
            %ChannelStatus{
              channel_id: ch_id,
              state: :disabled,
              badge_text: "Disabled/Paused",
              can_subscribe?: false,
              open_source_id: matching_profile_source.source_id,
              sources: sources_list,
              selected_profile_id: selected_profile_id
            }
          end
        else
          first_other = List.first(sources_list)

          %ChannelStatus{
            channel_id: ch_id,
            state: :tracked_other_profile,
            badge_text: "Tracked in #{first_other.media_profile_name}",
            can_subscribe?: true,
            open_source_id: first_other.source_id,
            sources: sources_list,
            selected_profile_id: selected_profile_id
          }
        end
    end
  end
end
