defmodule Pinchflat.Sources do
  @moduledoc """
  The Sources context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery
  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.FastIndexing.FastIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  @doc """
  Returns the configured path to the shared cookie file.

  Returns binary()
  """
  def cookie_file_path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
  end

  @doc """
  Returns whether the shared cookie file exists on disk.

  Returns boolean()
  """
  def cookie_file_exists? do
    File.exists?(cookie_file_path())
  end

  @doc """
  Returns whether the shared cookie file exists and has non-whitespace contents.

  Returns boolean()
  """
  def cookie_file_configured? do
    FilesystemUtils.exists_and_nonempty?(cookie_file_path())
  end

  @doc """
  Reads the shared cookie file.

  Returns {:ok, binary()} | {:error, any()}
  """
  def read_cookie_file do
    File.read(cookie_file_path())
  end

  @doc """
  Writes contents to the shared cookie file, creating parent directories as needed.

  Returns :ok | {:error, any()}
  """
  def write_cookie_file(contents) when is_binary(contents) do
    FilesystemUtils.write_p(cookie_file_path(), contents)
  end

  @doc """
  Copies an uploaded file into the shared cookie file path, creating parent directories as needed.

  Returns :ok | {:error, any()}
  """
  def save_uploaded_cookie_file(%Plug.Upload{path: source_path}) do
    case File.read(source_path) do
      {:ok, contents} -> write_cookie_file(contents)
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Returns the relevant output path template for a source.
  Pulls from the source's override if present, otherwise uses the media profile's.

  Returns binary()
  """
  def output_path_template(source) do
    source = Repo.preload(source, :media_profile)
    media_profile = source.media_profile

    source.output_path_template_override || media_profile.output_path_template
  end

  @doc """
  Returns a boolean indicating whether or not cookies should be used for a given operation.

  Returns boolean()
  """
  def use_cookies?(source, operation) when operation in [:indexing, :downloading, :metadata, :error_recovery] do
    case source.cookie_behaviour do
      :disabled -> false
      :all_operations -> true
      :when_needed -> operation in [:indexing, :error_recovery]
    end
  end

  @doc """
  Returns the list of sources. Returns [%Source{}, ...]
  """
  def list_sources do
    Repo.all(Source)
  end

  @doc """
  Preloads associations used by API serialization.

  Returns [%Source{}, ...] | %Source{}.
  """
  def preload_api_assocs(sources) do
    Repo.preload(sources, :media_profile)
  end

  @doc """
  Returns the list of sources for a media_profile.

  Returns [%Source{}, ...]
  """
  def list_sources_for(%MediaProfile{} = media_profile) do
    Repo.all(from s in Source, where: s.media_profile_id == ^media_profile.id)
  end

  @doc """
  Gets a single source.

  Returns %Source{}. Raises `Ecto.NoResultsError` if the Source does not exist.
  """
  def get_source!(id), do: Repo.get!(Source, id)

  @image_fields %{banner: :banner_filepath, poster: :poster_filepath, fanart: :fanart_filepath}

  @doc """
  Resolves the on-disk path for a source's artwork of the given type
  (`:banner`, `:poster`, or `:fanart`). Prefers the source's own copy (written
  when `download_source_images` is enabled) and falls back to the copy stored
  alongside the source metadata. Returns the path string, or nil when neither is
  set. Does not check that the file actually exists on disk.

  Returns binary() | nil
  """
  def image_filepath(%Source{} = source, type) when is_map_key(@image_fields, type) do
    field = @image_fields[type]
    source = Repo.preload(source, :metadata)

    Map.get(source, field) || (source.metadata && Map.get(source.metadata, field))
  end

  @doc """
  Returns the media-item counts for each tab on the source show page, plus the
  total on-disk byte size of the downloaded (Library) items, in a single round
  trip: `%{pending: n, library: n, skipped: n, library_bytes: b}`.

  Each count uses the exact same predicate as the tab it labels (the `pending`
  and `library` tabs share `MediaQuery.pending/0` and `MediaQuery.downloaded/0`,
  and `skipped` is everything that is neither) so a badge can never disagree with
  its list. `library_bytes` sums the stored `media_size_bytes` (no filesystem
  calls).

  Note `pending` is an *eligibility* count — media this source's rules say should
  be downloaded — not a count of live Oban jobs. An eligible item with no download
  job (downloads disabled, job cancelled/pruned) still counts, which is why the UI
  says "Pending" rather than "Queued".

  Returns %{pending: integer(), library: integer(), skipped: integer(), library_bytes: integer()}
  """
  def tab_counts(%Source{} = source) do
    pending = MediaQuery.pending()
    downloaded = MediaQuery.downloaded()
    skipped = dynamic(not (^downloaded) and not (^pending))

    base =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^MediaQuery.for_source(source))

    # ONE pass over the source's media items: each tab is a conditional aggregate
    # over the same scan rather than its own query (or its own branch of a union,
    # which would still read the rows three times).
    library_bytes =
      dynamic(
        [mi],
        fragment("COALESCE(SUM(CASE WHEN ? THEN ? ELSE 0 END), 0)", ^downloaded, mi.media_size_bytes)
      )

    counts = %{
      pending: count_where(pending),
      library: count_where(downloaded),
      skipped: count_where(skipped),
      library_bytes: library_bytes
    }

    Repo.one(select(base, ^counts))
  end

  defp count_where(condition) do
    dynamic(fragment("COALESCE(SUM(CASE WHEN ? THEN 1 ELSE 0 END), 0)", ^condition))
  end

  @doc """
  Returns a coarse health status for the source, used by the header status pill:

    - `:paused` — the source is disabled (indexing/downloads won't run)
    - `:error` — enabled, but an indexing or download job for it is currently
      failing (in a `retryable` or `discarded` state)
    - `:active` — enabled and nothing is failing

  `:indexing_failed?` can be injected via `opts` by a caller that has already
  resolved it (the source page renders the pill and the blocking-conditions
  banner from the same request, and both need the answer).

  Returns :active | :paused | :error
  """
  def status(source, opts \\ [])

  def status(%Source{enabled: false}, _opts), do: :paused

  def status(%Source{} = source, opts) do
    indexing_failed? = Keyword.get_lazy(opts, :indexing_failed?, fn -> indexing_failing?(source) end)

    if indexing_failed? or download_failing?(source), do: :error, else: :active
  end

  @doc """
  Whether the most recent job of either indexing chain (fast or slow) is failing.

  Public because both `status/1` and `blocking_conditions/2` need it and it costs
  a query — a caller rendering both can resolve it once and inject it.

  Returns boolean()
  """
  # Indexing tasks are attached to the source directly. The slow/fast indexing
  # chains are self-perpetuating, so a discarded job can linger for weeks (until
  # Oban prunes it) even after a newer run recovered — only the LATEST indexing
  # job's state reflects current health.
  #
  # Fast and slow indexing are INDEPENDENT chains, so health is judged per worker:
  # a successful RSS fast index must not paper over a dead slow-indexing chain (or
  # vice versa). The source is failing if either chain's most recent job is bad.
  def indexing_failing?(%Source{} = source) do
    latest_per_worker =
      from(t in Task,
        join: j in assoc(t, :job),
        where: t.source_id == ^source.id,
        where: fragment("? LIKE '%IndexingWorker'", j.worker),
        group_by: j.worker,
        select: %{latest_job_id: max(j.id)}
      )

    from(sub in subquery(latest_per_worker),
      join: j in Oban.Job,
      on: j.id == sub.latest_job_id,
      where: j.state in ["retryable", "discarded"]
    )
    |> Repo.exists?()
  end

  # Download tasks are attached through media items (their own `source_id` is
  # null), so join through `media_items`. For each item only its most recent
  # download job matters — a successful re-download must not stay overshadowed by
  # an earlier discarded attempt.
  defp download_failing?(%Source{} = source) do
    latest_per_item =
      from(t in Task,
        join: j in assoc(t, :job),
        join: mi in assoc(t, :media_item),
        where: mi.source_id == ^source.id,
        where: fragment("? LIKE '%.MediaDownloadWorker'", j.worker),
        group_by: mi.id,
        select: %{latest_job_id: max(j.id)}
      )

    from(sub in subquery(latest_per_item),
      join: j in Oban.Job,
      on: j.id == sub.latest_job_id,
      where: j.state in ["retryable", "discarded"]
    )
    |> Repo.exists?()
  end

  @doc """
  Everything currently standing between this source and a downloaded file, in
  order of how fundamental it is. Powers the "why is nothing downloading?" banner
  on the source page, which renders only the first entry.

  Returns `[%{code: atom(), message: binary()}, ...]`, **empty for a healthy
  source** — no news is good news, there is deliberately no `:all_good` code.

  A **paused source returns no conditions at all**. Being paused isn't a problem
  to diagnose — it's a state the user chose, and the header already says so with
  a status pill and a resume button. Everything downstream of it (nothing
  indexed, nothing downloaded) is a consequence rather than a cause, so a banner
  there would only restate the pill.

  Checked in order:

    - `:downloads_disabled` — indexes, but `download_media` is off
    - `:indexing_failed` — the latest run of an indexing chain is failing. Ranked
      **above** the nothing-indexed conditions because it explains them: a first
      index that is retrying or gave up would otherwise be reported as "being
      indexed, please wait" or "hasn't been indexed yet", hiding the actual error
      and the diagnostics link behind a description of its symptom
    - `:index_pending` — nothing indexed yet, but an index is already queued or
      running (and not failing). Distinct from `:never_indexed` because there's
      nothing to do but wait; offering a "check for new videos" button here just
      invites a duplicate of the job that's already on its way
    - `:never_indexed` — nothing indexed and no index job in flight either
    - `:index_found_nothing` — an index ran and turned up nothing
    - `:cutoff_excludes_everything` — everything indexed was excluded, and
      specifically by the download cutoff date, which is worth naming separately
      since it's the usual culprit
    - `:all_filtered_out` — ...or by the other filters
    - `:queue_paused` — the download queue is paused (a reconcile or database
      compaction reserving its quiet window)
    - `:storage_directory_unwritable` — nothing can be written to disk

  The two cutoff/filter conditions are mutually exclusive, as are the three
  nothing-indexed ones, so their relative order doesn't matter.

  The two conditions that probe the world outside the database (the queue state
  and the filesystem) are injectable via `opts` (`:queue_paused?`,
  `:storage_directory_writable?`) so this stays a pure function of its inputs
  under test. Callers in the app pass nothing and get the real probes.
  `:tab_counts` and `:indexing_failed?` are injectable for the same reason a
  caller would want to: the source page has already paid for both.
  """
  def blocking_conditions(source, opts \\ [])

  def blocking_conditions(%Source{enabled: false}, _opts), do: []

  def blocking_conditions(%Source{} = source, opts) do
    counts = Keyword.get_lazy(opts, :tab_counts, fn -> tab_counts(source) end)
    queue_paused? = Keyword.get_lazy(opts, :queue_paused?, &download_queue_paused?/0)

    directory_writable? =
      Keyword.get_lazy(opts, :storage_directory_writable?, fn -> storage_directory_writable?(source) end)

    total = counts.pending + counts.library + counts.skipped
    nothing_indexed_yet = total == 0 && is_nil(source.last_indexed_at)
    # Each of these costs a query, so they're resolved once up front rather than
    # inline in the (eagerly evaluated) list below — including `index_in_flight?`,
    # which two mutually exclusive entries would otherwise each ask for
    indexing_failed? = Keyword.get_lazy(opts, :indexing_failed?, fn -> indexing_failing?(source) end)
    index_in_flight? = nothing_indexed_yet && not indexing_failed? && indexing_in_flight?(source)
    nothing_downloadable? = total > 0 && counts.pending == 0 && counts.library == 0
    cutoff_excludes_everything? = nothing_downloadable? && everything_before_cutoff?(source, counts)

    [
      not source.download_media &&
        "This source is set to index only — new media is catalogged but never downloaded."
        |> then(&{:downloads_disabled, &1}),
      indexing_failed? &&
        {:indexing_failed, "The most recent indexing run for this source failed, so new media isn't being discovered."},
      index_in_flight? &&
        {:index_pending,
         "This source is being indexed for the first time. Media will start appearing here as it's found — large channels can take a while."},
      nothing_indexed_yet && not indexing_failed? && not index_in_flight? &&
        {:never_indexed, "This source hasn't been indexed yet, so there's nothing to download."},
      total == 0 && source.last_indexed_at &&
        {:index_found_nothing,
         "The last index of this source found no media at all. Check that its URL still points at a channel or playlist with content."},
      cutoff_excludes_everything? &&
        {:cutoff_excludes_everything,
         "Every indexed item was published before this source's download cutoff date, so nothing qualifies for download."},
      nothing_downloadable? && not cutoff_excludes_everything? &&
        {:all_filtered_out,
         "All #{counts.skipped} indexed items were excluded by this source's filters. The Skipped tab says why for each one."},
      queue_paused? &&
        {:queue_paused,
         "The download queue is paused. This happens while a file reconcile or database compaction reserves a quiet window, and lifts on its own when that finishes."},
      not directory_writable? &&
        {:storage_directory_unwritable,
         "Pinchflat can't write to #{storage_directory(source)}, so no download can be saved. Check the volume's permissions."}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Enum.map(fn {code, message} -> %{code: code, message: message} end)
  end

  # Whether an indexing run is already queued, scheduled, or underway. A source
  # kicks off its first index on creation, so this is true for essentially every
  # freshly-added source — which is exactly when a "check for new videos" prompt
  # would be worst: the work is already on its way.
  defp indexing_in_flight?(%Source{} = source) do
    from(t in Task,
      join: j in assoc(t, :job),
      where: t.source_id == ^source.id,
      where: fragment("? LIKE '%IndexingWorker'", j.worker),
      where: j.state in ["available", "scheduled", "executing", "retryable"]
    )
    |> Repo.exists?()
  end

  # Only meaningful when everything is already skipped: is the download cutoff
  # date the thing doing the excluding, rather than the duration/title/format
  # filters? Reuses the same query fragment the Skipped tab's reason filter uses,
  # so this can't disagree with the per-row reason shown there.
  defp everything_before_cutoff?(%Source{download_cutoff_date: nil}, _counts), do: false

  defp everything_before_cutoff?(%Source{} = source, counts) do
    before_cutoff_count =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^MediaQuery.for_source(source))
      |> where(^MediaQuery.skip_reason_is(:before_cutoff))
      |> Repo.aggregate(:count)

    before_cutoff_count > 0 and before_cutoff_count == counts.skipped
  end

  # Oban's queue state lives in memory, not the database. In test (and any other
  # environment without running queues) `check_queue` raises, which is not a
  # blocked download — treat anything unanswerable as "not paused".
  defp download_queue_paused?() do
    case Oban.check_queue(queue: :media_fetching) do
      %{paused: paused} -> !!paused
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Where this source's downloads actually land. A podcast-publishing source
  # downloads into `podcast_directory` (see `DownloadOptionBuilder.base_directory/1`),
  # which is often a separate volume — checking `media_directory` for it would
  # diagnose the wrong disk.
  defp storage_directory(%Source{} = source) do
    if PodcastExport.enabled?(source) do
      Application.get_env(:pinchflat, :podcast_directory)
    else
      Application.get_env(:pinchflat, :media_directory)
    end
  end

  # One `stat` per page render, not per media item. This reports the mode bits
  # rather than attempting a probe write, which would mean touching the media
  # volume every time someone opens a source page.
  defp storage_directory_writable?(%Source{} = source) do
    case File.stat(storage_directory(source)) do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      # A missing or unreadable directory is its own kind of unwritable
      _ -> false
    end
  end

  @doc """
  Creates a source. May attempt to pull additional source details from the
  original_url (if provided). Will attempt to start indexing the source's
  media if successfully inserted.

  Runs an initial `change_source` check to ensure most of the source is valid
  before making an expensive API call. Runs it through `Repo.insert` even
  though we know it's going to fail so it picks up any addl. database errors
  and fulfills our return contract.

  You can pass options to control the behavior of the function:
    - `run_post_commit_tasks` (default: true) - If false, the function will not
      enqueue any tasks in `commit_and_handle_tasks`.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def create_source(attrs, opts \\ []) do
    case change_source(%Source{}, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        %Source{}
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> maybe_enable_manual_selection(opts)
        |> commit_and_handle_tasks(opts)

      changeset ->
        Repo.insert(changeset)
    end
  end

  @doc """
  Updates a source. May attempt to pull additional source details from the
  original_url (if changed). May attempt to start indexing the source's
  media if the indexing frequency has been changed.

  Existing indexing tasks will be cancelled if the indexing frequency has been
  changed (logic in `SlowIndexingHelpers.kickoff_indexing_task`)

  Runs an initial `change_source` check to ensure most of the source is valid
  before making an expensive API call. Runs it through `Repo.update` even
  though we know it's going to fail so it picks up any addl. database errors
  and fulfills our return contract.

  You can pass options to control the behavior of the function:
    - `run_post_commit_tasks` (default: true) - If false, the function will not
      enqueue any tasks in `commit_and_handle_tasks`.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def update_source(%Source{} = source, attrs, opts \\ []) do
    case change_source(source, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        source
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> maybe_change_source_directory_paths()
        |> maybe_prevent_conflicting_source_directory_move()
        |> commit_and_handle_tasks(opts)

      changeset ->
        Repo.update(changeset)
    end
  end

  @doc """
  Builds a preview for the filesystem move caused by changing a source's download subdirectory.

  Returns {:ok, map() | nil} | {:error, %Ecto.Changeset{}}
  """
  def preview_source_directory_move(%Source{} = source, attrs) do
    case change_source(source, attrs, :initial) do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, source_directory_move_plan(changeset)}

      changeset ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a source, its media items, and its associated tasks (of any state).
  Can optionally delete the source's media files.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_source(%Source{} = source, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)
    Tasks.delete_tasks_for(source)

    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> Repo.all()
    |> Enum.each(fn media_item ->
      Media.delete_media_item(media_item, delete_files: delete_files)
    end)

    if delete_files do
      delete_source_files(source)
    end

    delete_internal_metadata_files(source)
    Repo.delete(source)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source changes.
  """
  def change_source(%Source{} = source, attrs \\ %{}, validation_stage \\ :pre_insert) do
    Source.changeset(source, attrs, validation_stage)
  end

  @doc """
  Applies manual playlist selection to a source.

  Selected media items will have `prevent_download: false`. All others will be
  marked `prevent_download: true`. If `enable_downloads` is true, the source is
  switched to downloading mode and only the selected pending items are enqueued.
  """
  def apply_media_selection(%Source{} = source, selected_media_item_ids, opts \\ []) do
    enable_downloads = Keyword.get(opts, :enable_downloads, false)
    selected_ids = normalize_media_item_ids(selected_media_item_ids)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(:exclude_unselected, media_items_for_source_query(source), set: [prevent_download: true])
      |> maybe_include_selected_items(source, selected_ids)
      |> maybe_enable_source_downloads(source, enable_downloads)

    case Repo.transaction(multi) do
      {:ok, _changes} ->
        source = Repo.reload!(source)

        if enable_downloads do
          source
          |> Media.list_pending_media_items_for_ids(selected_ids)
          |> Enum.each(&MediaDownloadWorker.kickoff_with_task/1)
        end

        {:ok, source}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Restores a manually-selected playlist source to normal automatic downloads.

  This switches the source back to `selection_mode: :all`, enables downloads,
  and clears any existing `prevent_download` flags for the source's media items.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def restore_automatic_downloads(%Source{} = source) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:source, change_source(source, %{selection_mode: :all, download_media: true}, :initial))
      |> Ecto.Multi.update_all(:restore_media_items, media_items_for_source_query(source),
        set: [prevent_download: false]
      )

    case Repo.transaction(multi) do
      {:ok, _changes} ->
        source = Repo.reload!(source)

        if source.enabled do
          DownloadingHelpers.enqueue_pending_download_tasks(source)
        end

        {:ok, source}

      {:error, :source, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # NOTE: When operating in the ideal path, this effectively adds an API call
  # to the source creation/update process. Should be used only when needed.
  defp maybe_change_source_from_url(%Source{} = source, attrs) do
    case change_source(source, attrs) do
      %Ecto.Changeset{changes: %{original_url: _}} = changeset ->
        add_source_details_to_changeset(source, changeset)

      changeset ->
        changeset
    end
  end

  defp delete_source_files(source) do
    mapped_struct = Map.from_struct(source)

    Source.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp delete_internal_metadata_files(source) do
    metadata = Repo.preload(source, :metadata).metadata || %SourceMetadata{}
    mapped_struct = Map.from_struct(metadata)

    SourceMetadata.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp add_source_details_to_changeset(source, changeset) do
    original_url = changeset.changes.original_url
    should_use_cookies = Ecto.Changeset.get_field(changeset, :cookie_behaviour) == :all_operations
    # Skipping sleep interval since this is UI blocking and we want to keep this as fast as possible
    addl_opts = [use_cookies: should_use_cookies, skip_sleep_interval: true]

    case MediaCollection.get_source_details(original_url, [], addl_opts) do
      {:ok, source_details} ->
        add_source_details_by_collection_type(source, changeset, source_details)

      err ->
        runner_error =
          case err do
            {:error, error_msg, _status_code} -> error_msg
            {:error, error_msg} -> error_msg
          end

        Ecto.Changeset.add_error(
          changeset,
          :original_url,
          "could not fetch source details from URL",
          error: runner_error
        )
    end
  end

  defp add_source_details_by_collection_type(source, changeset, source_details) do
    %Ecto.Changeset{changes: changes} = changeset

    collection_changes =
      if source_details.source_type == :video do
        %{
          collection_type: :video,
          collection_id: source_details.video_id,
          collection_name: source_details.video_title
        }
      else
        if source_details.playlist_id == source_details.channel_id do
          %{
            collection_type: :channel,
            collection_id: source_details.channel_id,
            collection_name: source_details.channel_name
          }
        else
          %{
            collection_type: :playlist,
            collection_id: source_details.playlist_id,
            collection_name: source_details.playlist_name
          }
        end
      end

    change_source(source, Map.merge(changes, collection_changes))
  end

  defp maybe_change_indexing_frequency(changeset) do
    changeset
    |> maybe_disable_recurring_indexing_for_single_video()
    |> maybe_change_fast_index_frequency()
  end

  defp maybe_change_source_directory_paths(
         %{
           data: %{__meta__: %{state: :loaded}, series_directory: old_series_directory},
           changes: changes
         } = changeset
       )
       when is_binary(old_series_directory) and is_map_key(changes, :download_subdirectory) do
    new_series_directory = source_directory_for(changes.download_subdirectory)

    if same_path?(old_series_directory, new_series_directory) do
      changeset
    else
      changeset
      |> Ecto.Changeset.put_change(:series_directory, new_series_directory)
      |> maybe_relocate_source_filepath_attrs(old_series_directory, new_series_directory)
    end
  end

  defp maybe_change_source_directory_paths(changeset), do: changeset

  defp maybe_prevent_conflicting_source_directory_move(changeset) do
    case source_directory_move_plan(changeset) do
      %{conflicts: [_ | _]} ->
        Ecto.Changeset.add_error(
          changeset,
          :download_subdirectory,
          "cannot move files because the destination already contains files with the same names"
        )

      _ ->
        changeset
    end
  end

  defp source_directory_move_plan(%{
         data: %{__meta__: %{state: :loaded}, series_directory: old_series_directory},
         changes: changes
       })
       when is_binary(old_series_directory) and is_map_key(changes, :download_subdirectory) do
    new_series_directory = source_directory_for(changes.download_subdirectory)

    if same_path?(old_series_directory, new_series_directory) do
      nil
    else
      %{
        old_directory: old_series_directory,
        new_directory: new_series_directory,
        old_directory_exists: File.dir?(old_series_directory),
        new_directory_exists: File.exists?(new_series_directory),
        file_count: count_files(old_series_directory),
        conflicts: move_conflicts(old_series_directory, new_series_directory)
      }
    end
  end

  defp source_directory_move_plan(_changeset), do: nil

  defp source_directory_for(nil), do: Application.get_env(:pinchflat, :media_directory)

  defp source_directory_for(subdirectory),
    do: Path.join(Application.get_env(:pinchflat, :media_directory), subdirectory)

  defp maybe_relocate_source_filepath_attrs(changeset, old_directory, new_directory) do
    Source.filepath_attributes()
    |> Enum.reject(&Map.has_key?(changeset.changes, &1))
    |> Enum.reduce(changeset, fn field, acc ->
      value = Map.get(acc.data, field)

      case relocate_filepath(value, old_directory, new_directory) do
        ^value -> acc
        relocated_value -> Ecto.Changeset.put_change(acc, field, relocated_value)
      end
    end)
  end

  defp maybe_enable_manual_selection(changeset, opts) do
    if Keyword.get(opts, :delay_automatic_download, false) &&
         Ecto.Changeset.get_field(changeset, :collection_type) == :playlist do
      changeset
      |> Ecto.Changeset.put_change(:selection_mode, :manual)
      |> Ecto.Changeset.put_change(:download_media, false)
    else
      changeset
    end
  end

  defp maybe_disable_recurring_indexing_for_single_video(changeset) do
    if Ecto.Changeset.get_field(changeset, :collection_type) == :video do
      changeset
      |> Ecto.Changeset.put_change(:fast_index, false)
      |> Ecto.Changeset.put_change(:index_frequency_minutes, 0)
    else
      changeset
    end
  end

  defp maybe_change_fast_index_frequency(changeset) do
    fast_index = Ecto.Changeset.get_field(changeset, :fast_index)

    if fast_index do
      Ecto.Changeset.put_change(
        changeset,
        :index_frequency_minutes,
        Source.index_frequency_when_fast_indexing()
      )
    else
      changeset
    end
  end

  defp commit_and_handle_tasks(changeset, opts) do
    run_post_commit_tasks = Keyword.get(opts, :run_post_commit_tasks, true)

    case Repo.insert_or_update(changeset) do
      {:ok, %Source{} = source} ->
        log_source_created(changeset, source)
        source = maybe_move_existing_source_files(changeset, source)

        if run_post_commit_tasks do
          maybe_handle_media_tasks(changeset, source)
          maybe_run_indexing_task(changeset, source)
          maybe_run_metadata_storage_task(changeset, source)
        end

        {:ok, source}

      err ->
        err
    end
  end

  defp maybe_move_existing_source_files(
         %{
           data: %{__meta__: %{state: :loaded}, series_directory: old_series_directory} = old_source,
           changes: %{download_subdirectory: _}
         },
         %Source{series_directory: new_series_directory} = source
       )
       when is_binary(old_series_directory) and is_binary(new_series_directory) do
    if same_path?(old_series_directory, new_series_directory) do
      source
    else
      case move_directory_contents(old_series_directory, new_series_directory) do
        :ok ->
          update_media_filepaths_for_source(old_source, old_series_directory, new_series_directory)
          Repo.reload!(source)

        {:error, reason} ->
          Logger.warning(
            "source_directory_move_failed source_id=#{source.id} old_directory=#{old_series_directory} " <>
              "new_directory=#{new_series_directory} reason=#{inspect(reason)}"
          )

          source
      end
    end
  end

  defp maybe_move_existing_source_files(_changeset, source), do: source

  defp move_directory_contents(old_directory, new_directory) do
    if File.dir?(old_directory) do
      move_path(old_directory, new_directory)
    else
      :ok
    end
  end

  defp move_conflicts(old_directory, new_directory) do
    cond do
      !File.dir?(old_directory) ->
        []

      !File.exists?(new_directory) ->
        []

      true ->
        do_move_conflicts(old_directory, new_directory)
    end
  end

  defp do_move_conflicts(source_path, destination_path) do
    cond do
      File.dir?(source_path) && File.dir?(destination_path) ->
        source_path
        |> File.ls!()
        |> Enum.flat_map(fn entry ->
          do_move_conflicts(Path.join(source_path, entry), Path.join(destination_path, entry))
        end)

      File.exists?(destination_path) ->
        [destination_path]

      true ->
        []
    end
  end

  defp count_files(directory) do
    if File.dir?(directory) do
      directory
      |> File.ls!()
      |> Enum.map(&Path.join(directory, &1))
      |> Enum.reduce(0, fn path, acc ->
        if File.dir?(path), do: acc + count_files(path), else: acc + 1
      end)
    else
      0
    end
  end

  defp move_path(source_path, destination_path) do
    cond do
      File.dir?(source_path) && File.dir?(destination_path) ->
        source_path
        |> File.ls!()
        |> Enum.reduce_while(:ok, fn entry, _acc ->
          case move_path(Path.join(source_path, entry), Path.join(destination_path, entry)) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> tap(fn
          :ok -> remove_empty_directory(source_path)
          _ -> :ok
        end)

      File.exists?(destination_path) ->
        {:error, :eexist}

      true ->
        destination_path
        |> Path.dirname()
        |> File.mkdir_p()
        |> case do
          :ok -> File.rename(source_path, destination_path)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp remove_empty_directory(directory) do
    case File.rmdir(directory) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp update_media_filepaths_for_source(source, old_directory, new_directory) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> Repo.all()
    |> Enum.each(fn media_item ->
      attrs =
        MediaItem.filepath_attributes()
        |> Enum.map(fn
          :subtitle_filepaths = field ->
            {field, relocate_subtitle_filepaths(media_item.subtitle_filepaths, old_directory, new_directory)}

          field ->
            {field, relocate_filepath(Map.get(media_item, field), old_directory, new_directory)}
        end)
        |> Enum.reject(fn {field, value} -> value == Map.get(media_item, field) end)
        |> Enum.into(%{})

      if map_size(attrs) > 0 do
        Media.update_media_item(media_item, attrs)
      end
    end)
  end

  defp relocate_subtitle_filepaths(subtitle_filepaths, old_directory, new_directory) do
    Enum.map(subtitle_filepaths || [], fn
      [language, filepath] when is_binary(filepath) ->
        [language, relocate_filepath(filepath, old_directory, new_directory)]

      subtitle ->
        subtitle
    end)
  end

  defp relocate_filepath(filepath, old_directory, new_directory) when is_binary(filepath) do
    if path_under_directory?(filepath, old_directory) do
      Path.join(new_directory, Path.relative_to(filepath, old_directory))
    else
      filepath
    end
  end

  defp relocate_filepath(filepath, _old_directory, _new_directory), do: filepath

  defp same_path?(path_1, path_2) do
    Path.expand(path_1) == Path.expand(path_2)
  end

  defp path_under_directory?(filepath, directory) do
    expanded_filepath = Path.expand(filepath)
    expanded_directory = Path.expand(directory)

    expanded_filepath == expanded_directory ||
      String.starts_with?(expanded_filepath, expanded_directory <> directory_separator(expanded_directory))
  end

  defp directory_separator(path) do
    if String.contains?(path, "\\"), do: "\\", else: "/"
  end

  # If the source is new (ie: not persisted), do nothing
  defp maybe_handle_media_tasks(%{data: %{__meta__: %{state: state}}}, _source) when state != :loaded do
    :ok
  end

  # If the source is NOT new (ie: updated),
  # enqueue or dequeue media download tasks as necessary.
  defp maybe_handle_media_tasks(changeset, source) do
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    # We need both current_changes and applied_changes to determine
    # the course of action to take. For example, we only care if a source is supposed
    # to be `enabled` or not - we don't care if that information comes from the
    # current changes or if that's how it already was in the database.
    # Rephrased, we're essentially using it in place of `get_field/2`
    case {current_changes, applied_changes} do
      {%{download_media: true}, %{enabled: true}} ->
        DownloadingHelpers.enqueue_pending_download_tasks(source)

      {%{enabled: true}, %{download_media: true}} ->
        DownloadingHelpers.enqueue_pending_download_tasks(source)

      {%{download_media: false}, _} ->
        DownloadingHelpers.dequeue_pending_download_tasks(source)

      {%{enabled: false}, _} ->
        DownloadingHelpers.dequeue_pending_download_tasks(source)

      _ ->
        nil
    end

    :ok
  end

  defp maybe_run_indexing_task(changeset, source) do
    case changeset.data do
      # If the changeset is new (not persisted), attempt indexing no matter what
      %{__meta__: %{state: :built}} ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

        if Ecto.Changeset.get_field(changeset, :fast_index) do
          FastIndexingHelpers.kickoff_indexing_task(source)
        end

      # If the record has been persisted, only run indexing if the
      # indexing frequency has been changed and is now greater than 0
      %{__meta__: %{state: :loaded}} ->
        maybe_update_slow_indexing_task(changeset, source)
        maybe_update_fast_indexing_task(changeset, source)
    end
  end

  defp maybe_run_metadata_storage_task(changeset, source) do
    case {changeset.data, changeset.changes} do
      # If the changeset is new (not persisted), fetch metadata no matter what
      {%{__meta__: %{state: :built}}, _} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      # If the record has been persisted, only fetch metadata if the
      # original_url has changed
      {_, %{original_url: _}} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      # If the media_profile_id has changed, re-fetch metadata to potentially
      # download source images if the new profile has download_source_images enabled
      {_, %{media_profile_id: _}} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      _ ->
        :ok
    end
  end

  defp maybe_update_slow_indexing_task(changeset, source) do
    # See comment in `maybe_handle_media_tasks` as to why we need these
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    case {current_changes, applied_changes} do
      # Widening the index cutoff further into the past means videos that were
      # previously out of range are now in range, so we need to re-crawl. This
      # must be a *forced* index: a normal scheduled index builds a
      # `--break-on-existing` download archive that would halt at the first known
      # video and never reach the newly-in-range older ones (see
      # `SlowIndexingHelpers.build_download_archive_options/3`). Narrowing the
      # cutoff needs no action since those items are already indexed.
      {%{index_cutoff_date: _}, %{enabled: true, index_frequency_minutes: mins}}
      when mins > 0 ->
        if index_cutoff_widened?(changeset) do
          SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})
        else
          :ok
        end

      {%{index_frequency_minutes: mins}, %{enabled: true}} when mins > 0 ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

      {%{enabled: true}, %{index_frequency_minutes: mins}} when mins > 0 ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

      {%{index_frequency_minutes: _}, _} ->
        SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)

      {%{enabled: false}, _} ->
        SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)

      _ ->
        :ok
    end
  end

  # A cutoff is "widened" when the new date reaches further into the past than
  # the old one (or is removed entirely, making indexing unbounded). Removing a
  # cutoff (-> nil) always widens; adding one to a previously unbounded source
  # (nil -> date) only narrows and needs no re-index.
  defp index_cutoff_widened?(changeset) do
    old_cutoff = changeset.data.index_cutoff_date
    new_cutoff = Ecto.Changeset.get_field(changeset, :index_cutoff_date)

    case {old_cutoff, new_cutoff} do
      {_, nil} -> not is_nil(old_cutoff)
      {nil, _} -> false
      {old, new} -> Date.compare(new, old) == :lt
    end
  end

  defp maybe_update_fast_indexing_task(changeset, source) do
    # See comment in `maybe_handle_media_tasks` as to why we need these
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    # This technically could be simplified since `maybe_update_slow_indexing_task`
    # has some overlap re: deleting pending tasks, but I'm keeping it separate
    # for clarity and explicitness.
    case {current_changes, applied_changes} do
      {%{fast_index: true}, %{enabled: true}} ->
        FastIndexingHelpers.kickoff_indexing_task(source)

      {%{enabled: true}, %{fast_index: true}} ->
        FastIndexingHelpers.kickoff_indexing_task(source)

      {%{fast_index: false}, _} ->
        Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)

      {%{enabled: false}, _} ->
        Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)

      _ ->
        :ok
    end
  end

  defp maybe_include_selected_items(multi, _source, []), do: multi

  defp maybe_include_selected_items(multi, source, selected_ids) do
    Ecto.Multi.update_all(
      multi,
      :include_selected,
      media_items_for_source_query(source, selected_ids),
      set: [prevent_download: false]
    )
  end

  defp maybe_enable_source_downloads(multi, _source, false), do: multi

  defp maybe_enable_source_downloads(multi, source, true) do
    changeset = change_source(source, %{download_media: true}, :initial)
    Ecto.Multi.update(multi, :enable_downloads, changeset)
  end

  defp media_items_for_source_query(source, selected_ids \\ nil) do
    query =
      MediaQuery.new()
      |> where(^MediaQuery.for_source(source))

    if is_list(selected_ids) do
      where(query, [m], m.id in ^selected_ids)
    else
      query
    end
  end

  defp normalize_media_item_ids(media_item_ids) do
    media_item_ids
    |> List.wrap()
    |> Enum.map(fn
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {parsed_id, ""} -> parsed_id
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp log_source_created(%{data: %{__meta__: %{state: :built}}}, %Source{} = source) do
    Logger.info(
      "source_created source_id=#{source.id} collection_type=#{source.collection_type} " <>
        "selection_mode=#{source.selection_mode} download_media=#{source.download_media} enabled=#{source.enabled}"
    )
  end

  defp log_source_created(_changeset, _source), do: :ok
end
