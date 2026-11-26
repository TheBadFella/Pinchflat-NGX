defmodule Pinchflat.Media.MediaQuery do
  @moduledoc """
  Query helpers for the Media context.

  These methods are made to be one-ish liners used
  to compose queries. Each method should strive to do
  _one_ thing. These don't need to be tested as
  they are just building blocks for other functionality
  which, itself, will be tested.
  """
  import Ecto.Query, warn: false

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.AvailabilityPolicy
  alias Pinchflat.Tasks.Task

  # Mirrors DownloadingHelpers' active job states so the keep-newest cleanup
  # does not delete a file that a queued or running download will still write.
  @active_download_job_states [:available, :scheduled, :retryable, :executing, :suspended]

  # This allows the module to be aliased and query methods to be used
  # all in one go
  # usage: use Pinchflat.Media.MediaQuery
  defmacro __using__(_opts) do
    quote do
      import Ecto.Query, warn: false

      alias unquote(__MODULE__)
    end
  end

  def new do
    from(media_item in MediaItem, as: :media_item)
  end

  def for_source(source_id) when is_integer(source_id), do: dynamic([mi], mi.source_id == ^source_id)
  def for_source(source), do: dynamic([mi], mi.source_id == ^source.id)

  def downloaded, do: dynamic([mi], not is_nil(mi.media_filepath))
  def download_prevented, do: dynamic([mi], mi.prevent_download == true)
  def unavailable, do: dynamic([mi], not is_nil(mi.unavailable_at))
  def culling_prevented, do: dynamic([mi], mi.prevent_culling == true)

  # A watch with an active window, an incident hold, or an interrupted archive
  # must keep its active files available to automatic retention and cutoff
  # cleanup. A published archive alone does not protect the active copy after
  # the window ends; the archive itself is outside these queries.
  def watch_protected do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    dynamic(
      [media_item],
      (not is_nil(media_item.watch_download_started_at) and is_nil(media_item.media_downloaded_at)) or
        media_item.watch_postprocessing_pending or not is_nil(media_item.watch_enrollment_pending_at) or
        exists(
          from watch in "media_watches",
            where:
              watch.media_item_id == parent_as(:media_item).id and
                ((is_nil(watch.released_at) and (watch.ends_at > ^now or not is_nil(watch.hold_reason))) or
                   watch.archive_state == "needs_recovery" or watch.operation_kind == "delete_original"),
            select: 1
        )
    )
  end

  # Quality upgrades and force retries must not obtain or overwrite a watched
  # copy while the preservation gate is unapproved or the item is held. The
  # execution boundary rechecks the same state before mutating active files.
  def watch_replacement_blocked do
    blocked_without_gate = not destructive_gate_enabled?()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    fresh_after = DateTime.add(now, -(6 * 60 * 60 + 10 * 60), :second)

    dynamic(
      [media_item],
      exists(
        from watch in "media_watches",
          where:
            watch.media_item_id == parent_as(:media_item).id and
              (is_nil(watch.released_at) or watch.archive_state != "none") and
              (^blocked_without_gate or not is_nil(watch.released_at) or watch.confirmed_state != "unchanged" or
                 not is_nil(watch.hold_reason) or watch.archive_state == "needs_recovery" or
                 not is_nil(watch.last_error_at) or is_nil(watch.last_success_at) or
                 watch.last_success_at < ^fresh_after or watch.ends_at <= ^now or
                 parent_as(:media_item).prevent_download or parent_as(:media_item).prevent_culling),
          select: 1
      )
    )
  end

  def redownloaded, do: dynamic([mi], not is_nil(mi.media_redownloaded_at))

  # Media-catalog filters for watched items. The labels stay distinct so a
  # inconclusive remote check is never shown as a download failure, and an
  # unlisted or private video is never called deleted.
  def watch_filter(:all), do: dynamic([media_item], true)

  def watch_filter(filter) when filter in [:changed_or_unavailable, :changed, :unlisted, :unavailable, :check_failed] do
    condition =
      case filter do
        :changed_or_unavailable ->
          dynamic(
            [watch],
            watch.confirmed_state != "unchanged" or not is_nil(watch.hold_reason) or
              coalesce(watch.observed_visibility, watch.current_visibility) in ["unlisted", "private", "unavailable"]
          )

        :changed ->
          dynamic([watch], watch.confirmed_state == "confirmed" or not is_nil(watch.hold_reason))

        :unlisted ->
          dynamic([watch], coalesce(watch.observed_visibility, watch.current_visibility) == "unlisted")

        :unavailable ->
          dynamic([watch], coalesce(watch.observed_visibility, watch.current_visibility) in ["private", "unavailable"])

        :check_failed ->
          dynamic([watch], not is_nil(watch.last_error_at))
      end

    dynamic(
      [media_item],
      exists(
        from watch in "media_watches",
          where: watch.media_item_id == parent_as(:media_item).id and is_nil(watch.released_at),
          where: ^condition,
          select: 1
      )
    )
  end

  def watch_filter(_filter), do: dynamic([media_item], true)

  def upload_date_matches(other_date) do
    if Pinchflat.Database.postgres?() do
      date = to_date(other_date)
      dynamic([mi], fragment("?::date = ?", mi.uploaded_at, ^date))
    else
      dynamic([mi], fragment("date(?) = date(?)", mi.uploaded_at, ^other_date))
    end
  end

  def upload_date_after_source_cutoff(today \\ Date.utc_today()) do
    if Pinchflat.Database.postgres?() do
      dynamic(
        [mi, source],
        (is_nil(source.download_cutoff_date) or fragment("?::date >= ?", mi.uploaded_at, source.download_cutoff_date)) and
          (is_nil(source.download_cutoff_days) or
             fragment("?::date >= ?::date - ?::integer", mi.uploaded_at, ^today, source.download_cutoff_days))
      )
    else
      dynamic(
        [mi, source],
        (is_nil(source.download_cutoff_date) or fragment("date(?) >= ?", mi.uploaded_at, source.download_cutoff_date)) and
          (is_nil(source.download_cutoff_days) or
             fragment(
               "date(?) >= date(?, '-' || ? || ' day')",
               mi.uploaded_at,
               ^Date.to_iso8601(today),
               source.download_cutoff_days
             ))
      )
    end
  end

  def format_matching_profile_preference do
    dynamic(
      [mi, source, media_profile],
      fragment("""
        CASE
          WHEN shorts_behaviour = 'only' AND livestream_behaviour = 'only' THEN
            livestream = true OR short_form_content = true
          WHEN shorts_behaviour = 'only' THEN
            short_form_content = true
          WHEN livestream_behaviour = 'only' THEN
            livestream = true
          WHEN shorts_behaviour = 'exclude' AND livestream_behaviour = 'exclude' THEN
            short_form_content = false AND livestream = false
          WHEN shorts_behaviour = 'exclude' THEN
            short_form_content = false
          WHEN livestream_behaviour = 'exclude' THEN
            livestream = false
          ELSE
            true
        END
      """)
    )
  end

  def matches_source_title_regex do
    if Pinchflat.Database.postgres?() do
      dynamic(
        [mi, source],
        is_nil(source.title_filter_regex) or
          fragment("? ~ ?", mi.title, source.title_filter_regex) or
          (not is_nil(source.title_language) and not is_nil(mi.translated_title) and
             fragment("? ~ ?", mi.translated_title, source.title_filter_regex))
      )
    else
      dynamic(
        [mi, source],
        is_nil(source.title_filter_regex) or
          fragment("regexp_like(?, ?)", mi.title, source.title_filter_regex) or
          (not is_nil(source.title_language) and not is_nil(mi.translated_title) and
             fragment("regexp_like(?, ?)", mi.translated_title, source.title_filter_regex))
      )
    end
  end

  def meets_min_and_max_duration do
    dynamic(
      [mi, source],
      (is_nil(source.min_duration_seconds) or fragment("duration_seconds >= ?", source.min_duration_seconds)) and
        (is_nil(source.max_duration_seconds) or fragment("duration_seconds <= ?", source.max_duration_seconds))
    )
  end

  # Playlists can contain uploads from other channels. When the source owner lock
  # is enabled, only items whose `channel_id` matches the source's
  # `owner_channel_id` are eligible. A missing owner or item channel leaves the
  # item eligible, so enabling the lock never silently drops unclassified items.
  def uploaded_by_source_owner do
    dynamic(
      [mi, source],
      not source.only_owner_uploads or is_nil(source.owner_channel_id) or is_nil(mi.channel_id) or
        mi.channel_id == source.owner_channel_id
    )
  end

  def past_retention_period do
    if Pinchflat.Database.postgres?() do
      dynamic(
        [mi, source, media_profile],
        fragment(
          "COALESCE(?, ?, 0) > 0 AND ? + (COALESCE(?, ?, 0) * INTERVAL '1 day') < NOW()",
          source.retention_period_days,
          media_profile.retention_period_days,
          mi.media_downloaded_at,
          source.retention_period_days,
          media_profile.retention_period_days
        )
      )
    else
      dynamic(
        [mi, source, media_profile],
        fragment(
          "COALESCE(?, ?, 0) > 0 AND DATETIME(?, '+' || COALESCE(?, ?, 0) || ' day') < DATETIME('now')",
          source.retention_period_days,
          media_profile.retention_period_days,
          mi.media_downloaded_at,
          source.retention_period_days,
          media_profile.retention_period_days
        )
      )
    end
  end

  def past_redownload_delay do
    if Pinchflat.Database.postgres?() do
      dynamic(
        [mi, source, media_profile],
        fragment("""
          COALESCE(redownload_delay_days, 0) > 0 AND
          (NOW() - (redownload_delay_days * INTERVAL '1 day'))::date > uploaded_at::date AND
          (media_downloaded_at - (redownload_delay_days * INTERVAL '1 day'))::date < uploaded_at::date
        """)
      )
    else
      dynamic(
        [mi, source, media_profile],
        # Returns media items where the uploaded_at is at least redownload_delay_days ago AND
        # downloaded_at minus the redownload_delay_days is before the upload date
        fragment("""
          IFNULL(redownload_delay_days, 0) > 0 AND
          DATE('now', '-' || redownload_delay_days || ' day') > DATE(uploaded_at) AND
          DATE(media_downloaded_at, '-' || redownload_delay_days || ' day') < DATE(uploaded_at)
        """)
      )
    end
  end

  def cullable do
    dynamic(
      [mi, source],
      ^downloaded() and
        ^past_retention_period() and
        not (^culling_prevented()) and
        not (^watch_protected())
    )
  end

  def deletable_based_on_source_cutoff(today \\ Date.utc_today()) do
    dynamic(
      [mi, source],
      ^downloaded() and
        not (^upload_date_after_source_cutoff(today)) and
        not (^culling_prevented()) and
        not (^watch_protected())
    )
  end

  def pending(today \\ Date.utc_today()) do
    dynamic(
      [mi],
      ^pending_ignoring_keep_newest(today) and ^within_keep_newest_count(today)
    )
  end

  # Download eligibility for a source whose `keep_newest_count` is nil or whose
  # item is among the newest counted items. An item outside the newest N is not
  # pending, so lowering N never downloads a backlog that the cleanup would then
  # delete.
  #
  # This ranks the counted items once with a window function rather than
  # counting newer rows per candidate. A correlated count is O(items x items)
  # within a large source: on a 51k-item source it took ~1.2s per query against
  # ~15-24ms here (measured in issue #288 M1), which made the whole request time
  # out. The `prevent_culling` escape keeps those items pending without letting
  # them consume a slot, matching the correlated form.
  def within_keep_newest_count(today \\ Date.utc_today()) do
    dynamic(
      [mi, source],
      is_nil(source.keep_newest_count) or
        ^culling_prevented() or
        mi.id in subquery(counted_items_within_keep_newest_count(today))
    )
  end

  # Downloaded items outside the newest N for a source that set the limit. The
  # caller must still apply the download-job guard before deleting files.
  def deletable_beyond_keep_newest_count do
    dynamic(
      [mi, source],
      not is_nil(source.keep_newest_count) and
        ^downloaded() and
        not (^culling_prevented()) and
        not (^watch_protected()) and
        not (^within_keep_newest_count()) and
        not (^active_download_job())
    )
  end

  # Downloaded items a source would lose if its keep-newest limit became
  # `target_count`. Ranks against the counted items for that source alone, so it
  # works when the source has no stored limit yet. Mirrors
  # `deletable_beyond_keep_newest_count/0` so the pre-save confirmation matches
  # what the cleanup would actually delete.
  def removable_beyond_keep_newest(source_id, target_count)
      when is_integer(source_id) and is_integer(target_count) and target_count > 0 do
    within =
      from(r in subquery(counted_items_ranked(false, source_id, Date.utc_today())),
        where: r.rank <= ^target_count,
        select: r.id
      )

    dynamic(
      [mi],
      ^downloaded() and
        not (^culling_prevented()) and
        not (^watch_protected()) and
        mi.id not in subquery(within) and
        not (^active_download_job())
    )
  end

  # The other `pending/0` rules without the keep-newest ranking, so the counted
  # subquery cannot recurse into itself.
  defp pending_ignoring_keep_newest(today) do
    dynamic(
      [mi],
      is_nil(mi.media_filepath) and
        not (^download_prevented()) and
        ^AvailabilityPolicy.query_condition() and
        ^upload_date_after_source_cutoff(today) and
        ^format_matching_profile_preference() and
        ^matches_source_title_regex() and
        ^meets_min_and_max_duration() and
        ^uploaded_by_source_owner()
    )
  end

  # Counted items are downloaded or would be pending, and never `prevent_culling`.
  # Watch-protected items count here but are excluded from deletion separately.
  #
  # Ranked once per source: `uploaded_at` descending, then `id` descending, so a
  # nil `uploaded_at` ranks as oldest. Ties on `uploaded_at` are broken by the
  # higher `id`. Only sources that set the limit are ranked, so a database where
  # no source opts in produces no rows here.
  defp counted_items_within_keep_newest_count(today) do
    from(r in subquery(counted_items_ranked(true, nil, today)),
      where: r.rank <= r.keep_newest_count,
      select: r.id
    )
  end

  # Shared ranking used by both the stored-limit query and the pre-save
  # confirmation. With `require_limit?` it only ranks sources that have a
  # `keep_newest_count` set; with `source_id` it ranks one source regardless of
  # its current limit, so a first-time or lowered value can be previewed.
  defp counted_items_ranked(require_limit?, source_id, today) do
    counted =
      dynamic(
        [kni, kns, knmp],
        (^downloaded() or ^pending_ignoring_keep_newest(today)) and not (^culling_prevented())
      )

    ranked =
      from(kni in MediaItem,
        join: kns in assoc(kni, :source),
        join: knmp in assoc(kns, :media_profile),
        where: ^counted,
        select: %{
          id: kni.id,
          keep_newest_count: kns.keep_newest_count,
          rank:
            over(row_number(),
              partition_by: kni.source_id,
              order_by: [desc_nulls_last: kni.uploaded_at, desc: kni.id]
            )
        }
      )
      |> maybe_require_keep_newest(require_limit?)
      |> maybe_for_source(source_id)

    ranked
  end

  defp maybe_require_keep_newest(query, true), do: where(query, [kni, kns, _knmp], not is_nil(kns.keep_newest_count))
  defp maybe_require_keep_newest(query, false), do: query

  defp maybe_for_source(query, nil), do: query

  defp maybe_for_source(query, source_id) when is_integer(source_id),
    do: where(query, [kni, _kns, _knmp], kni.source_id == ^source_id)

  # The cleanup step must not delete a file that a queued or running download
  # will still write. Mirrors DownloadingHelpers' active job states.
  defp active_download_job do
    state_filter = active_download_job_state_filter()

    dynamic(
      [mi],
      exists(
        from task in Task,
          join: job in assoc(task, :job),
          where: task.media_item_id == parent_as(:media_item).id,
          where: fragment("? LIKE ?", job.worker, ^"%.MediaDownloadWorker"),
          where: ^state_filter,
          select: 1
      )
    )
  end

  defp active_download_job_state_filter do
    states = Enum.map(@active_download_job_states, &to_string/1)

    if Pinchflat.Database.postgres?() do
      dynamic([_task, job], fragment("?::text", job.state) in ^states)
    else
      dynamic([_task, job], fragment("CAST(? AS text)", job.state) in ^states)
    end
  end

  # Not downloaded and skipped by the source's rules (format, title, duration, cutoff, availability or
  # the owner lock for other channels' uploads), rather than prevented by the user or held back by a
  # failure. Requires the media_profile assoc.
  # CASE turns a NULL (e.g. from a NULL error_type) into "excluded" so this and its negation never both
  # drop an item. It also keeps SQLite short-circuiting, so regexp_like never sees a NULL pattern.
  def excluded do
    kept = dynamic(^pending() or ^download_prevented() or ^download_failed())

    dynamic([mi], not (^downloaded()) and fragment("(CASE WHEN ? THEN 0 ELSE 1 END) = 1", ^kept))
  end

  def download_failed do
    dynamic([mi], (not is_nil(mi.last_error) or mi.error_type == :permanent) and is_nil(mi.media_filepath))
  end

  # A permanent failure blocks automatic downloads until the user explicitly
  # forces a retry, so both fields must agree for a retry to be meaningful.
  def permanent_failure do
    dynamic([mi], mi.error_type == :permanent and mi.prevent_download == true)
  end

  def upgradeable do
    dynamic(
      [mi, source],
      ^downloaded() and
        not (^download_prevented()) and
        not (^redownloaded()) and
        not (^cullable()) and
        not (^watch_replacement_blocked()) and
        ^past_redownload_delay()
    )
  end

  def matches_search_term(nil), do: dynamic([mi], true)

  def matches_search_term(term) do
    case String.trim(term) do
      "" -> dynamic([mi], true)
      trimmed -> matches_nonblank_search_term(trimmed)
    end
  end

  def require_assoc(query, identifier) do
    if has_named_binding?(query, identifier) do
      query
    else
      do_require_assoc(query, identifier)
    end
  end

  defp destructive_gate_enabled? do
    Application.get_env(:pinchflat, :media_watch_destructive_enabled, true) != false
  end

  defp do_require_assoc(query, :media_items_search_index) do
    if Pinchflat.Database.postgres?() do
      query
    else
      from(mi in query, join: s in assoc(mi, :media_items_search_index), as: :media_items_search_index)
    end
  end

  defp do_require_assoc(query, :source) do
    from(mi in query, join: s in assoc(mi, :source), as: :source)
  end

  defp do_require_assoc(query, :media_profile) do
    query
    |> require_assoc(:source)
    |> join(:inner, [mi, source], mp in assoc(source, :media_profile), as: :media_profile)
  end

  # This needs to be a non-dynamic query because it alone should control things like
  # ordering and `snippets` for full-text search
  def matching_search_term(query, nil), do: query

  def matching_search_term(query, term) do
    if Pinchflat.Database.postgres?() do
      matching_postgres_search_term(query, term)
    else
      matching_sqlite_search_term(query, term)
    end
  end

  defp matches_nonblank_search_term(term) do
    if Pinchflat.Database.postgres?() do
      case build_tsquery(term) do
        "" -> dynamic([mi], true)
        tsquery -> dynamic([mi], fragment("search_vector @@ to_tsquery('simple', ?)", ^tsquery))
      end
    else
      escaped_term = clean_search_term(term)
      dynamic([mi], fragment("media_items_search_index MATCH ?", ^escaped_term))
    end
  end

  defp matching_sqlite_search_term(query, term) do
    escaped_term = clean_search_term(term)

    from(mi in query,
      join: mi_search_index in assoc(mi, :media_items_search_index),
      where: fragment("media_items_search_index MATCH ?", ^escaped_term),
      select_merge: %{
        matching_search_term:
          fragment("""
            coalesce(snippet(media_items_search_index, 0, '[PF_HIGHLIGHT]', '[/PF_HIGHLIGHT]', '...', 20), '') ||
            ' ' ||
            coalesce(snippet(media_items_search_index, 1, '[PF_HIGHLIGHT]', '[/PF_HIGHLIGHT]', '...', 20), '')
          """)
      },
      order_by: [desc: fragment("rank")]
    )
  end

  def order_by_search_relevance(query, term) do
    if Pinchflat.Database.postgres?() do
      case build_tsquery(term) do
        "" ->
          query

        tsquery ->
          from mi in query, order_by: [desc: fragment("ts_rank(search_vector, to_tsquery('simple', ?))", ^tsquery)]
      end
    else
      from mi in query, order_by: [desc: fragment("rank")]
    end
  end

  defp matching_postgres_search_term(query, term) do
    case build_tsquery(term) do
      "" ->
        query

      tsquery ->
        from(mi in query,
          where: fragment("search_vector @@ to_tsquery('simple', ?)", ^tsquery),
          select_merge: %{
            matching_search_term:
              fragment(
                """
                coalesce(ts_headline('simple', ?, to_tsquery('simple', ?),
                  'StartSel=[PF_HIGHLIGHT], StopSel=[/PF_HIGHLIGHT], MaxWords=20, MinWords=5'), '') ||
                ' ' ||
                coalesce(ts_headline('simple', ?, to_tsquery('simple', ?),
                  'StartSel=[PF_HIGHLIGHT], StopSel=[/PF_HIGHLIGHT], MaxWords=20, MinWords=5'), '')
                """,
                mi.title,
                ^tsquery,
                mi.description,
                ^tsquery
              )
          },
          order_by: [desc: fragment("ts_rank(search_vector, to_tsquery('simple', ?))", ^tsquery)]
        )
    end
  end

  # SQLite's FTS5 is very picky about what it will accept as a search term.
  # To that end, we need to clean up the search term before passing it to the
  # MATCH clause.
  # This method:
  #   - Trims leading and trailing whitespace
  #   - Collapses multiple spaces into a single space
  #   - Removes quote characters
  #   - Wraps any word in quotes (must happen after the double quote replacement)
  #
  # This allows for works with apostrophes and quotes to be searched for correctly
  defp clean_search_term(nil), do: ""
  defp clean_search_term(""), do: ""

  defp clean_search_term(term) do
    term
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/\s+/)
    |> Enum.map(fn str -> String.replace(str, ~s("), "") end)
    |> Enum.map_join(" ", fn str -> ~s("#{str}") end)
  end

  defp build_tsquery(term) do
    term
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.split(" ")
    |> Enum.map(fn word -> Regex.replace(~r/[^\p{L}\p{N}]/u, word, "") end)
    |> Enum.reject(fn word -> not Regex.match?(~r/[\p{L}\p{N}]/u, word) end)
    |> Enum.map_join(" & ", fn word -> "#{word}:*" end)
  end

  defp to_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp to_date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp to_date(%Date{} = date), do: date
end
