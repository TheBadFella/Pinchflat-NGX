defmodule Pinchflat.Sources.BulkCutoff do
  @moduledoc """
  Previews and applies download cutoff changes to selected sources.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  @doc """
  Validates selected sources and counts downloaded media before the proposed cutoff.
  The value is a date (`"2026-01-31"`), a rolling window (`"days:30"`, counted back from
  today) or empty to remove the cutoff. Preview never writes or queues work.

  Returns {:ok, map()} | {:error, term()}
  """
  def preview(ids, value) do
    with {:ok, setting} <- parse_cutoff(value),
         {:ok, sources} <- Sources.get_selected_sources(ids),
         :ok <- validate_sources(sources, setting) do
      {:ok, impact(sources, setting, :bulk)}
    end
  end

  @doc """
  Applies the cutoff only if the source settings and deletion impact still
  match the preview. Normal retention runs separately.

  Returns {:ok, [%Source{}]} | {:error, term()}
  """
  def apply_preview(ids, value, expected, mode \\ :bulk) do
    postgres? = Pinchflat.Database.postgres?()
    opts = if postgres?, do: [], else: [mode: :immediate]

    Repo.transaction(
      fn ->
        # Block media writes before acquiring source row locks. A media insert
        # can need a foreign-key lock on the source. SQLite already holds its
        # database write lock through the immediate transaction.
        if postgres?, do: Repo.query!("LOCK TABLE media_items IN SHARE MODE")

        with {:ok, setting} <- parse_cutoff(value),
             {:ok, sources} <- Sources.get_selected_sources(ids, lock: true),
             true <- is_nil(expected.fingerprint) or fingerprint(sources) == expected.fingerprint,
             :ok <- validate_sources(sources, setting) do
          preview = impact(sources, setting, mode)

          if preview.removable != expected.removable or
               (expected.removable > 0 and preview.cutoff != expected.cutoff) do
            Repo.rollback({:changed_impact, preview})
          end

          Enum.map(sources, fn source ->
            case Sources.update_source(source, cutoff_attrs(setting), run_post_commit_tasks: false) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        else
          false -> Repo.rollback(:stale_preview)
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      opts
    )
  end

  defp impact(sources, setting, mode) do
    source_ids = Enum.map(sources, & &1.id)
    cutoff = cutoff_date(setting)

    before_cutoff =
      if cutoff && check_removals?(sources, cutoff, mode) do
        from m in MediaItem,
          where: m.source_id in ^source_ids and not is_nil(m.media_filepath),
          where: fragment("date(?)", m.uploaded_at) < ^cutoff
      else
        from m in MediaItem, where: false
      end

    counts =
      Repo.one(
        from m in before_cutoff,
          select: %{
            downloaded_before: count(m.id),
            removable: coalesce(sum(fragment("CASE WHEN ? = FALSE THEN 1 ELSE 0 END", m.prevent_culling)), 0)
          }
      )

    Map.merge(counts, %{
      sources: sources,
      cutoff: cutoff,
      rolling_days: rolling_days(setting),
      fingerprint: fingerprint(sources)
    })
  end

  defp check_removals?([source], cutoff, :single) do
    current = Source.effective_download_cutoff_date(source)
    is_nil(current) or Date.compare(cutoff, current) == :gt
  end

  defp check_removals?(_sources, _cutoff, :bulk), do: true

  defp parse_cutoff(""), do: {:ok, nil}

  defp parse_cutoff("days:" <> days) do
    case Integer.parse(days) do
      {days, ""} when days >= 1 -> {:ok, {:days, days}}
      _ -> {:error, :invalid_cutoff}
    end
  end

  defp parse_cutoff(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_cutoff}
    end
  end

  defp parse_cutoff(_), do: {:error, :invalid_cutoff}

  defp cutoff_attrs({:days, days}), do: %{download_cutoff_date: nil, download_cutoff_days: days}
  defp cutoff_attrs(date), do: %{download_cutoff_date: date, download_cutoff_days: nil}

  defp cutoff_date({:days, _days} = setting), do: Source.effective_download_cutoff_date(cutoff_attrs(setting))
  defp cutoff_date(date), do: date

  defp rolling_days({:days, days}), do: days
  defp rolling_days(_setting), do: nil

  defp validate_sources(sources, setting) do
    cutoff = cutoff_date(setting)
    invalid = Enum.reject(sources, &Source.changeset(&1, cutoff_attrs(setting)).valid?)

    index_conflicts =
      for source <- invalid,
          source.index_cutoff_date && cutoff && Date.compare(source.index_cutoff_date, cutoff) == :gt,
          do: {source.custom_name, source.index_cutoff_date}

    cond do
      invalid == [] -> :ok
      length(index_conflicts) == length(invalid) -> {:error, {:index_cutoff_after, index_conflicts}}
      true -> {:error, :invalid_source}
    end
  end

  defp fingerprint(sources) do
    sources
    |> Enum.map(&{&1.id, &1.download_cutoff_date, &1.download_cutoff_days, &1.index_cutoff_date, &1.updated_at})
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16()
  end
end
