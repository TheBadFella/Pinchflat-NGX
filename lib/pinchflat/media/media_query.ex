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
    MediaItem
  end

  def for_source(source_id) when is_integer(source_id), do: dynamic([mi], mi.source_id == ^source_id)
  def for_source(source), do: dynamic([mi], mi.source_id == ^source.id)

  def downloaded, do: dynamic([mi], not is_nil(mi.media_filepath))
  def download_prevented, do: dynamic([mi], mi.prevent_download == true)
  def unavailable, do: dynamic([mi], not is_nil(mi.unavailable_at))
  def culling_prevented, do: dynamic([mi], mi.prevent_culling == true)
  def redownloaded, do: dynamic([mi], not is_nil(mi.media_redownloaded_at))

  def upload_date_matches(other_date) do
    if Pinchflat.Database.postgres?() do
      date = to_date(other_date)
      dynamic([mi], fragment("?::date = ?", mi.uploaded_at, ^date))
    else
      dynamic([mi], fragment("date(?) = date(?)", mi.uploaded_at, ^other_date))
    end
  end

  def upload_date_after_source_cutoff do
    if Pinchflat.Database.postgres?() do
      dynamic(
        [mi, source],
        is_nil(source.download_cutoff_date) or
          fragment("?::date >= ?", mi.uploaded_at, source.download_cutoff_date)
      )
    else
      dynamic(
        [mi, source],
        is_nil(source.download_cutoff_date) or
          fragment("date(?) >= ?", mi.uploaded_at, source.download_cutoff_date)
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
        is_nil(source.title_filter_regex) or fragment("? ~ ?", mi.title, source.title_filter_regex)
      )
    else
      dynamic(
        [mi, source],
        is_nil(source.title_filter_regex) or fragment("regexp_like(?, ?)", mi.title, source.title_filter_regex)
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

  def past_retention_period do
    if Pinchflat.Database.postgres?() do
      dynamic(
        [mi, source],
        fragment("""
          COALESCE(retention_period_days, 0) > 0 AND
          media_downloaded_at + (retention_period_days * INTERVAL '1 day') < NOW()
        """)
      )
    else
      dynamic(
        [mi, source],
        fragment("""
          IFNULL(retention_period_days, 0) > 0 AND
          DATETIME(media_downloaded_at, '+' || retention_period_days || ' day') < DATETIME('now')
        """)
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
        not (^culling_prevented())
    )
  end

  def deletable_based_on_source_cutoff do
    dynamic(
      [mi, source],
      ^downloaded() and
        not (^upload_date_after_source_cutoff()) and
        not (^culling_prevented())
    )
  end

  def pending do
    dynamic(
      [mi],
      not (^downloaded()) and
        not (^download_prevented()) and
        ^AvailabilityPolicy.query_condition() and
        ^upload_date_after_source_cutoff() and
        ^format_matching_profile_preference() and
        ^matches_source_title_regex() and
        ^meets_min_and_max_duration()
    )
  end

  def download_failed do
    dynamic([mi], (not is_nil(mi.last_error) or mi.error_type == :permanent) and not (^downloaded()))
  end

  def upgradeable do
    dynamic(
      [mi, source],
      ^downloaded() and
        not (^download_prevented()) and
        not (^redownloaded()) and
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
