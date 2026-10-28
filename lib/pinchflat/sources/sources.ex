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
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Sources.Source
  alias Pinchflat.Sources.DirectoryMove
  alias Pinchflat.Sources.CustomPoster
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.FastIndexing.FastIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  @automated_metadata_lock_fields %{
    custom_name: :custom_name_locked,
    description: :description_locked
  }

  @doc """
  Pauses downloads for up to 100 available sources without disabling monitoring
  or deleting files. Rejects the entire selection if any source is unavailable.

  Returns {:ok, [%Source{}]} | {:error, term()}
  """
  def pause_selected_sources(ids) do
    result =
      Repo.transaction(fn ->
        case get_selected_sources(ids, lock: true) do
          {:ok, sources} ->
            Enum.map(sources, fn source ->
              case update_source(source, %{download_media: false}, run_post_commit_tasks: false) do
                {:ok, updated} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end
            end)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, sources} ->
        Enum.each(sources, &DownloadingHelpers.dequeue_pending_download_tasks(&1, include_executing: true))
        {:ok, sources}

      error ->
        error
    end
  end

  @doc """
  Resumes downloads for up to 100 available sources without changing monitoring
  or deleting files. Rejects the entire selection if any source is unavailable.
  Enqueues pending download tasks for enabled sources.

  Returns {:ok, [%Source{}]} | {:error, term()}
  """
  def resume_selected_sources(ids) do
    result =
      Repo.transaction(fn ->
        update_selected_sources(ids, %{download_media: true}, run_post_commit_tasks: false)
      end)

    case result do
      {:ok, sources} ->
        Enum.each(sources, fn source ->
          if source.enabled do
            DownloadingHelpers.enqueue_pending_download_tasks(source)
          end
        end)

        {:ok, sources}

      error ->
        error
    end
  end

  @doc """
  Updates the media profile for up to 100 available sources.
  Rejects the entire selection if any source is unavailable or if the profile is invalid.

  Returns {:ok, [%Source{}]} | {:error, term()}
  """
  def assign_selected_sources_profile(ids, profile_id) do
    Repo.transaction(fn ->
      case validate_target_profile(profile_id) do
        {:ok, profile} -> update_selected_sources(ids, %{media_profile_id: profile.id})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_selected_sources(ids, attrs, opts \\ []) do
    case get_selected_sources(ids, lock: true) do
      {:ok, sources} ->
        Enum.map(sources, fn source ->
          case update_source(source, attrs, opts) do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate_target_profile(profile_id) when is_binary(profile_id) do
    if Regex.match?(~r/^[1-9][0-9]{0,17}$/, profile_id),
      do: validate_target_profile(String.to_integer(profile_id)),
      else: {:error, :invalid_profile}
  end

  defp validate_target_profile(profile_id) when is_integer(profile_id) and profile_id in 1..999_999_999_999_999_999 do
    query = from p in MediaProfile, where: p.id == ^profile_id and is_nil(p.marked_for_deletion_at)

    query = if Pinchflat.Database.postgres?(), do: lock(query, "FOR SHARE"), else: query

    case Repo.one(query) do
      %MediaProfile{} = profile -> {:ok, profile}
      nil -> {:error, :invalid_profile}
    end
  end

  defp validate_target_profile(_profile_id), do: {:error, :invalid_profile}

  @doc """
  Loads up to 100 selected sources, rejecting the selection if any source or
  profile is being deleted. Use `lock: true` within a transaction when updating.

  Returns {:ok, [%Source{}]} | {:error, :invalid_selection | :unavailable_source}
  """
  def get_selected_sources(ids, opts \\ [])

  def get_selected_sources(ids, opts) when is_list(ids) and length(ids) in 1..100 do
    if Enum.all?(ids, &(is_binary(&1) and Regex.match?(~r/^[1-9][0-9]{0,17}$/, &1))) do
      ids = ids |> Enum.map(&String.to_integer/1) |> Enum.uniq()

      profiles = from p in MediaProfile, where: is_nil(p.marked_for_deletion_at), select: p.id

      query =
        from s in Source,
          where: s.id in ^ids and is_nil(s.marked_for_deletion_at) and s.media_profile_id in subquery(profiles),
          order_by: s.id

      query =
        if Keyword.get(opts, :lock, false) and Pinchflat.Database.postgres?(),
          do: lock(query, "FOR UPDATE"),
          else: query

      sources = Repo.all(query)
      if length(sources) == length(ids), do: {:ok, sources}, else: {:error, :unavailable_source}
    else
      {:error, :invalid_selection}
    end
  end

  def get_selected_sources(_ids, _opts), do: {:error, :invalid_selection}

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
  Shorts prefer the source's Shorts override, then the profile's Shorts template.
  Without a Shorts template, uses the primary source override or profile template.
  Omitting the media item always selects the primary template.

  Returns binary()
  """
  def output_path_template(source, media_item_or_short \\ nil)

  def output_path_template(%Source{} = source, %MediaItem{short_form_content: short?}) do
    output_path_template(source, short?)
  end

  def output_path_template(%Source{} = source, short?) do
    source = Repo.preload(source, :media_profile)
    primary = source.output_path_template_override || source.media_profile.output_path_template

    if short? == true do
      source.output_path_template_shorts_override || source.media_profile.output_path_template_shorts || primary
    else
      primary
    end
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
    custom_filepath = if type == :poster, do: CustomPoster.filepath(source)

    custom_filepath || Map.get(source, field) || (source.metadata && Map.get(source.metadata, field))
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
        "This source is set to index only — new media is cataloged but never downloaded."
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
         "Pinchflat-ngx can't write to #{storage_directory(source)}, so no download can be saved. Check the volume's permissions."}
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
      |> MediaQuery.require_assoc(:source)
      |> where(^MediaQuery.for_source(source))
      |> where(^dynamic(not (^MediaQuery.upload_date_after_source_cutoff()) and not (^MediaQuery.downloaded())))
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

  # Where this source's downloads actually land. Pinchflat-ngx writes all downloads
  # under `media_directory` (see `DownloadOptionBuilder`).
  defp storage_directory(%Source{} = _source) do
    Application.get_env(:pinchflat, :media_directory)
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
  Refreshes an unlocked video's title only if its identity and name still match
  the snapshot used to fetch metadata. Returns the reloaded source.
  """
  def refresh_video_metadata_title(%Source{collection_type: :video} = source, title) when is_binary(title) do
    if String.trim(title) != "" do
      from(s in Source,
        where:
          s.id == ^source.id and s.collection_type == :video and
            s.collection_id == ^source.collection_id and s.original_url == ^source.original_url and
            s.custom_name == ^source.custom_name and s.custom_name_locked == false
      )
      |> Repo.update_all(set: [custom_name: title, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
    end

    Repo.reload!(source)
  end

  def refresh_video_metadata_title(source, _title), do: source

  @doc """
  Resolves an intake-generated single-video name without replacing a manual name
  or a locked name. The database condition protects edits made during indexing.
  Returns the reloaded source.
  """
  def resolve_intake_video_title(%Source{collection_type: :video} = source, video_id, title)
      when is_binary(title) and video_id == source.collection_id do
    placeholder = "YouTube Video #{source.collection_id}"

    if String.trim(title) != "" do
      from(s in Source,
        where:
          s.id == ^source.id and s.collection_type == :video and s.collection_id == ^video_id and
            s.custom_name == ^placeholder and
            s.collection_name == ^placeholder and s.custom_name_locked == false
      )
      |> Repo.update_all(
        set: [custom_name: title, collection_name: title, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )
    end

    Repo.reload!(source)
  end

  def resolve_intake_video_title(source, _video_id, _title), do: Repo.reload!(source)

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
    attrs = maybe_apply_automated_metadata_locks(source, attrs, opts)

    case change_source(source, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        source
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> maybe_change_source_directory_paths()
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
        case source_directory_move_plan(changeset) do
          %{error: reason} -> {:error, directory_move_error(changeset, reason)}
          plan -> {:ok, plan}
        end

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

    case Repo.delete(source) do
      {:ok, _deleted_source} = result ->
        CustomPoster.delete_owned_file(source)
        result

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source changes.
  """
  def change_source(%Source{} = source, attrs \\ %{}, validation_stage \\ :pre_insert) do
    Source.changeset(source, attrs, validation_stage)
  end

  @doc """
  Removes source metadata fields protected by their lock flags when an
  automated metadata refresh is being applied.

  User-initiated changes are not filtered by this function unless the caller
  explicitly opts into the automated refresh contract in `update_source/3`.

  Returns a map with locked automated fields removed.
  """
  def apply_automated_metadata_locks(%Source{} = source, attrs) when is_map(attrs) do
    Enum.reduce(@automated_metadata_lock_fields, attrs, fn {field, lock_field}, filtered_attrs ->
      if Map.get(source, lock_field, false) do
        filtered_attrs
        |> Map.delete(field)
        |> Map.delete(Atom.to_string(field))
      else
        filtered_attrs
      end
    end)
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
      |> Ecto.Multi.update_all(:exclude_unselected, media_items_for_source_query(source),
        set: [prevent_download: true, download_prevented_reason: :manual]
      )
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
        set: [prevent_download: false, download_prevented_reason: nil]
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
    source_type = Ecto.Changeset.get_field(changeset, :source_type, :automatic)
    should_use_cookies = Ecto.Changeset.get_field(changeset, :cookie_behaviour) == :all_operations
    # Skipping sleep interval since this is UI blocking and we want to keep this as fast as possible
    command_opts =
      DownloadOptionBuilder.player_client_options(Ecto.Changeset.get_field(changeset, :player_client)) ++
        Pinchflat.YtDlp.PoTokenProvider.options()

    addl_opts = [use_cookies: should_use_cookies, skip_sleep_interval: true]

    watch_later? = watch_later_source?(original_url, source_type)

    result =
      if watch_later? and not (should_use_cookies and cookie_file_configured?()) do
        {:error, :watch_later_cookies_required}
      else
        MediaCollection.get_source_details(
          original_url,
          command_opts,
          Keyword.put(addl_opts, :source_type, source_type)
        )
      end

    case result do
      {:ok, source_details} ->
        add_source_details_by_collection_type(source, changeset, source_details)

      err ->
        Ecto.Changeset.add_error(
          changeset,
          :original_url,
          source_details_error_message(source_type, err, watch_later?),
          error: source_details_error(err)
        )
    end
  end

  defp add_source_details_by_collection_type(source, changeset, source_details) do
    %Ecto.Changeset{changes: changes} = changeset
    source_type = Ecto.Changeset.get_field(changeset, :source_type, :automatic)
    detected_type = detected_source_type(source_details)

    cond do
      detected_type == :unknown ->
        Ecto.Changeset.add_error(
          changeset,
          :original_url,
          "could not determine whether this URL is a channel, playlist, or video; choose Automatic or check the URL"
        )

      source_type != :automatic and source_type != detected_type ->
        Ecto.Changeset.add_error(changeset, :original_url, source_type_mismatch_message(source_type, detected_type))

      true ->
        add_detected_source_details(source, changeset, source_details, changes, detected_type)
    end
  end

  defp add_detected_source_details(source, _changeset, source_details, changes, :video) do
    collection_changes = %{
      collection_type: :video,
      collection_id: source_details.video_id,
      collection_name: source_details.video_title
    }

    change_source(source, Map.merge(changes, collection_changes))
  end

  defp add_detected_source_details(source, _changeset, source_details, changes, :channel) do
    collection_changes = %{
      collection_type: :channel,
      collection_id: source_details.channel_id,
      collection_name: source_details.channel_name
    }

    change_source(source, Map.merge(changes, collection_changes))
  end

  defp add_detected_source_details(source, _changeset, source_details, changes, :playlist) do
    collection_changes = %{
      collection_type: :playlist,
      collection_id: source_details.playlist_id,
      collection_name: source_details.playlist_name
    }

    change_source(source, Map.merge(changes, collection_changes))
  end

  defp detected_source_type(%{detected_type: detected_type}), do: detected_type

  defp detected_source_type(%{source_type: :video}), do: :video

  defp detected_source_type(%{playlist_id: playlist_id, channel_id: channel_id})
       when is_binary(channel_id) and channel_id == playlist_id,
       do: :channel

  defp detected_source_type(%{playlist_id: playlist_id}) when is_binary(playlist_id), do: :playlist
  defp detected_source_type(_source_details), do: :unknown

  defp source_type_mismatch_message(expected, detected) do
    "the selected source type is #{source_type_label(expected)}, but this URL resolves to a " <>
      "#{source_type_label(detected)}; choose #{source_type_label(detected)} or Automatic"
  end

  defp watch_later_source?(url, source_type) do
    collection? = source_type != :video and not (source_type == :automatic and Source.youtube_video_url?(url))
    collection? and URI.decode_query(URI.parse(url).query || "")["list"] == "WL"
  end

  defp source_details_error_message(_source_type, {:error, :watch_later_cookies_required}, _watch_later?) do
    "Watch Later is private. Upload cookies from the YouTube account that owns it and set Cookie Behaviour to All Operations."
  end

  defp source_details_error_message(_source_type, _error, true) do
    "Could not inspect Watch Later. Check that the playlist opens in the owning YouTube account, refresh the cookies, and keep Cookie Behaviour set to All Operations. If the playlist is empty, add a video and try again."
  end

  defp source_details_error_message(source_type, _error, false), do: source_details_error_message(source_type)

  defp source_details_error_message(:automatic), do: "could not fetch source details from URL"

  defp source_details_error_message(source_type) do
    "could not inspect this URL as a #{source_type_label(source_type)}; check the URL or choose Automatic"
  end

  defp source_details_error({:error, error_msg, _status_code}), do: error_msg
  defp source_details_error({:error, error_msg}), do: error_msg
  defp source_details_error(error), do: error

  defp source_type_label(:automatic), do: "Automatic"
  defp source_type_label(:channel), do: "Channel"
  defp source_type_label(:playlist), do: "Playlist"
  defp source_type_label(:video), do: "Video"

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

  defp source_directory_move_plan(%{data: %{series_directory: old}, changes: changes})
       when is_binary(old) and is_map_key(changes, :download_subdirectory) do
    new = source_directory_for(changes.download_subdirectory)

    if same_path?(old, new) do
      nil
    else
      root = Path.expand(Application.fetch_env!(:pinchflat, :media_directory))

      result =
        cond do
          not path_under_directory?(Path.expand(old), root) -> {:error, :outside_root}
          protected_source_directory?(old, new) -> {:error, :protected_directory}
          true -> DirectoryMove.preview(old, new)
        end

      case result do
        {:ok, plan} -> plan
        {:error, reason} -> %{error: reason}
      end
    end
  end

  defp source_directory_move_plan(_changeset), do: nil

  defp protected_source_directory?(old, new) do
    Enum.any?([:metadata_directory, :extras_directory, :tmpfile_directory, :download_staging_directory], fn key ->
      case Application.get_env(:pinchflat, key) do
        root when is_binary(root) ->
          Enum.any?([old, new], &(path_under_directory?(root, &1) or path_under_directory?(&1, root)))

        _ ->
          false
      end
    end)
  end

  defp directory_move_error(changeset, reason) do
    message =
      case reason do
        :symlink -> "cannot move a folder containing symbolic links; remove the links or move the files manually"
        :entry_limit -> "folder is too large for a safe automatic move; move the files manually"
        :depth_limit -> "folder nesting is too deep for a safe automatic move"
        :scan_timeout -> "storage did not respond in time; check the mount and try again"
        :enoent -> "current folder is missing; check the storage mount before moving files"
        :eacces -> "cannot read the folder; check storage permissions"
        :nested_destination -> "destination cannot be inside the current folder"
        :missing_files -> "tracked files are missing; reconnect storage before moving the folder"
        :recovery_required -> "a previous folder move needs recovery; restart and check the application logs"
        :busy -> "downloads or indexing are running for this source; wait before moving its folder"
        :protected_directory -> "folder overlaps application metadata or staging storage; move it manually"
        :shared_destination -> "destination folder is already owned by another source"
        :shared_files -> "files in this folder are also referenced by another source"
        :eexist -> "cannot move files because the destination already contains files with the same names"
        _ -> "folder move could not be completed safely; check the storage and try again"
      end

    changeset |> Ecto.Changeset.add_error(:download_subdirectory, message) |> Map.put(:action, :update)
  end

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

  defp commit_and_handle_tasks(%{valid?: true} = changeset, opts) do
    case source_directory_move_plan(changeset) do
      nil -> commit_without_move(changeset, opts)
      %{error: reason} -> {:error, directory_move_error(changeset, reason)}
      %{conflicts: [_ | _]} -> {:error, directory_move_error(changeset, :eexist)}
      plan -> commit_directory_move(changeset, plan, opts)
    end
  end

  defp commit_and_handle_tasks(changeset, opts), do: commit_without_move(changeset, opts)

  defp commit_without_move(changeset, opts) do
    run_post_commit_tasks = Keyword.get(opts, :run_post_commit_tasks, true)

    case Repo.insert_or_update(changeset) do
      {:ok, %Source{} = source} ->
        log_source_created(changeset, source)

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

  defp commit_directory_move(changeset, plan, opts) do
    # ponytail: serialize folder moves while sharing a queue pause; per-source reservations if needed.
    :global.trans({__MODULE__.DirectoryMove, self()}, fn ->
      case with_move_queues_paused(fn -> do_commit_directory_move(changeset, plan, opts) end) do
        {:error, :queues_not_paused} -> {:error, directory_move_error(changeset, :queues_not_paused)}
        result -> result
      end
    end)
  end

  defp with_move_queues_paused(callback) do
    queues = Pinchflat.Diagnostics.QueueDiagnostics.queue_names()

    active =
      Enum.filter(queues, fn queue ->
        case Oban.check_queue(queue: queue) do
          %{paused: false} -> true
          _ -> false
        end
      end)

    Enum.each(active, &Oban.pause_queue(queue: &1))

    try do
      if await_paused(active, 50), do: callback.(), else: {:error, :queues_not_paused}
    after
      Enum.each(active, &Oban.resume_queue(queue: &1))
    end
  end

  defp await_paused([], _attempts), do: true
  defp await_paused(_queues, 0), do: false

  defp await_paused(queues, attempts) do
    if Enum.all?(queues, &match?(%{paused: true}, Oban.check_queue(queue: &1))) do
      true
    else
      Process.sleep(20)
      await_paused(queues, attempts - 1)
    end
  end

  defp do_commit_directory_move(changeset, plan, opts) do
    blocked =
      cond do
        active_source_jobs?(changeset.data) -> :busy
        missing_source_files?(changeset.data, plan.old_directory) -> :missing_files
        shared_directory_files?(changeset.data, plan.old_directory) -> :shared_files
        shared_directory_files?(changeset.data, plan.new_directory) -> :shared_destination
        true -> nil
      end

    if blocked do
      {:error, directory_move_error(changeset, blocked)}
    else
      DirectoryMove.with_moves(
        plan,
        fn ->
          Repo.transaction(fn ->
            case Repo.update(changeset) do
              {:ok, source} ->
                update_media_filepaths_for_source(source, plan.old_directory, plan.new_directory)
                update_metadata_filepaths_for_source(source, plan.old_directory, plan.new_directory)
                run_move_tasks(changeset, source, opts)
                Repo.reload!(source)

              {:error, error} ->
                Repo.rollback(error)
            end
          end)
        end,
        source_id: changeset.data.id
      )
      |> case do
        {:error, %Ecto.Changeset{} = error} -> {:error, error}
        {:error, reason} -> {:error, directory_move_error(changeset, reason)}
        result -> result
      end
    end
  rescue
    _error in [
      Postgrex.Error,
      Exqlite.Error,
      DBConnection.ConnectionError,
      Ecto.InvalidChangesetError,
      Ecto.StaleEntryError
    ] ->
      {:error, directory_move_error(changeset, :database_error)}
  end

  defp missing_source_files?(source, directory) do
    paths = source |> Map.take(Source.filepath_attributes()) |> Map.values()
    items = Repo.all(from item in MediaItem, where: item.source_id == ^source.id)
    metadata = source_metadata_for(source.id) ++ media_metadata_for(source.id)

    paths =
      paths ++
        Enum.flat_map(metadata, fn record ->
          Map.values(Map.take(record, record.__struct__.filepath_attributes()))
        end)

    paths =
      paths ++
        Enum.flat_map(items, fn item ->
          scalar =
            item
            |> Map.take(MediaItem.filepath_attributes() -- [:subtitle_filepaths, :predicted_media_filepath])
            |> Map.values()

          scalar ++ Enum.flat_map(item.subtitle_filepaths || [], &List.wrap/1)
        end)

    Enum.any?(paths, fn path ->
      is_binary(path) and String.starts_with?(path, directory <> "/") and
        not File.regular?(path)
    end)
  end

  defp active_source_jobs?(source) do
    tracked =
      Repo.exists?(
        from task in Task,
          join: job in Oban.Job,
          on: task.job_id == job.id,
          left_join: item in MediaItem,
          on: task.media_item_id == item.id,
          where: job.state == "executing" and (task.source_id == ^source.id or item.source_id == ^source.id)
      )

    source_workers =
      ~w(Pinchflat.Metadata.SourceMetadataStorageWorker Pinchflat.SlowIndexing.MediaCollectionIndexingWorker Pinchflat.FastIndexing.FastIndexingWorker)

    tracked or
      Enum.any?(
        Repo.all(from job in Oban.Job, where: job.state == "executing", select: {job.worker, job.args}),
        fn {worker, args} ->
          args["source_id"] == source.id or (worker in source_workers and args["id"] == source.id)
        end
      )
  end

  defp run_move_tasks(changeset, source, opts) do
    if Keyword.get(opts, :run_post_commit_tasks, true) do
      maybe_handle_media_tasks(changeset, source)
      maybe_run_indexing_task(changeset, source)
      maybe_run_metadata_storage_task(changeset, source)
    end
  end

  defp shared_directory_files?(source, directory) do
    prefix = Path.expand(directory) <> "/"
    fields = MediaItem.filepath_attributes() -- [:subtitle_filepaths]

    condition =
      Enum.reduce(fields, dynamic(false), fn field, acc ->
        dynamic(
          [item],
          ^acc or fragment("substr(?, 1, ?) = ?", field(item, ^field), ^length(String.codepoints(prefix)), ^prefix)
        )
      end)

    media_shared = Repo.exists?(from item in MediaItem, where: item.source_id != ^source.id, where: ^condition)

    source_condition =
      Enum.reduce(Source.filepath_attributes() ++ [:series_directory], dynamic(false), fn field, acc ->
        dynamic(
          [other],
          ^acc or field(other, ^field) == ^directory or
            fragment("substr(?, 1, ?) = ?", field(other, ^field), ^length(String.codepoints(prefix)), ^prefix)
        )
      end)

    source_shared = Repo.exists?(from other in Source, where: other.id != ^source.id, where: ^source_condition)
    # Subtitle paths are nested arrays. A literal substring check is conservative.
    subtitle_shared =
      if Pinchflat.Database.postgres?() do
        Repo.exists?(
          from item in MediaItem,
            where:
              item.source_id != ^source.id and
                fragment("strpos(CAST(? AS text), ?) > 0", item.subtitle_filepaths, ^prefix)
        )
      else
        Repo.exists?(
          from item in MediaItem,
            where:
              item.source_id != ^source.id and
                fragment("instr(CAST(? AS text), ?) > 0", item.subtitle_filepaths, ^prefix)
        )
      end

    source_metadata_condition = path_prefix_condition(SourceMetadata.filepath_attributes(), prefix)

    source_metadata_shared =
      Repo.exists?(
        from metadata in SourceMetadata, where: metadata.source_id != ^source.id, where: ^source_metadata_condition
      )

    media_metadata_condition = path_prefix_condition(Pinchflat.Metadata.MediaMetadata.filepath_attributes(), prefix)

    media_metadata_shared =
      Repo.exists?(
        from metadata in Pinchflat.Metadata.MediaMetadata,
          join: item in MediaItem,
          on: item.id == metadata.media_item_id,
          where: item.source_id != ^source.id,
          where: ^media_metadata_condition
      )

    media_shared or source_shared or subtitle_shared or source_metadata_shared or media_metadata_shared
  end

  defp path_prefix_condition(fields, prefix) do
    Enum.reduce(fields, dynamic(false), fn field, acc ->
      dynamic(
        [record],
        ^acc or fragment("substr(?, 1, ?) = ?", field(record, ^field), ^length(String.codepoints(prefix)), ^prefix)
      )
    end)
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
        case Media.update_media_item(media_item, attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  defp update_metadata_filepaths_for_source(source, old, new) do
    records = source_metadata_for(source.id) ++ media_metadata_for(source.id)

    Enum.each(records, fn record ->
      attrs =
        Map.new(record.__struct__.filepath_attributes(), fn field ->
          {field, relocate_filepath(Map.get(record, field), old, new)}
        end)

      record |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end)
  end

  defp source_metadata_for(id), do: Repo.all(from metadata in SourceMetadata, where: metadata.source_id == ^id)

  defp media_metadata_for(id) do
    Repo.all(
      from metadata in Pinchflat.Metadata.MediaMetadata,
        join: item in MediaItem,
        on: item.id == metadata.media_item_id,
        where: item.source_id == ^id
    )
  end

  defp relocate_subtitle_filepaths(subtitle_filepaths, old_directory, new_directory) do
    Enum.map(subtitle_filepaths || [], fn values ->
      Enum.map(List.wrap(values), &relocate_filepath(&1, old_directory, new_directory))
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

    if availability_policy_changed?(current_changes) do
      DownloadingHelpers.reconcile_availability_policy(source)
    else
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
    end

    :ok
  end

  defp maybe_apply_automated_metadata_locks(source, attrs, opts) do
    if Keyword.get(opts, :automated_metadata_refresh, false) do
      apply_automated_metadata_locks(source, attrs)
    else
      attrs
    end
  end

  defp availability_policy_changed?(changes) do
    Map.has_key?(changes, :download_public_media) || Map.has_key?(changes, :download_members_only_media)
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
      set: [prevent_download: false, download_prevented_reason: nil]
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
