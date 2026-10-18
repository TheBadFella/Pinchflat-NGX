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
  Validates selected sources and counts downloaded media before the proposed date.
  An empty date removes the cutoff. Preview never writes or queues work.

  Returns {:ok, map()} | {:error, term()}
  """
  def preview(ids, value) do
    with {:ok, cutoff} <- parse_cutoff(value),
         {:ok, sources} <- Sources.get_selected_sources(ids),
         :ok <- validate_sources(sources, cutoff) do
      source_ids = Enum.map(sources, & &1.id)

      before_cutoff =
        if cutoff do
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

      {:ok,
       Map.merge(counts, %{
         sources: sources,
         cutoff: cutoff,
         fingerprint: fingerprint(sources)
       })}
    end
  end

  @doc """
  Applies a confirmed preview in one transaction, rejecting changed source settings.
  Leaves jobs, files, indexing cutoffs and download/monitoring switches untouched.
  Normal indexing and retention later use the new download cutoff.

  Returns {:ok, [%Source{}]} | {:error, term()}
  """
  def apply_preview(ids, value, expected_fingerprint) do
    Repo.transaction(fn ->
      with {:ok, cutoff} <- parse_cutoff(value),
           {:ok, sources} <- Sources.get_selected_sources(ids, lock: true),
           true <- fingerprint(sources) == expected_fingerprint,
           :ok <- validate_sources(sources, cutoff) do
        Enum.map(sources, fn source ->
          case Sources.update_source(source, %{download_cutoff_date: cutoff}, run_post_commit_tasks: false) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      else
        false -> Repo.rollback(:stale_preview)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp parse_cutoff(""), do: {:ok, nil}

  defp parse_cutoff(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_cutoff}
    end
  end

  defp parse_cutoff(_), do: {:error, :invalid_cutoff}

  defp validate_sources(sources, cutoff) do
    if Enum.all?(sources, &Source.changeset(&1, %{download_cutoff_date: cutoff}).valid?),
      do: :ok,
      else: {:error, :invalid_source}
  end

  defp fingerprint(sources) do
    sources
    |> Enum.map(&{&1.id, &1.download_cutoff_date, &1.index_cutoff_date, &1.updated_at})
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16()
  end
end
