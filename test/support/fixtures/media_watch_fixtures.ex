defmodule Pinchflat.MediaWatchFixtures do
  @moduledoc "Test-only approved watches for synthetic local artifacts."

  alias Pinchflat.Downloading.FirstArtifact
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.MediaWatch.ReplacementIntent
  alias Pinchflat.Repo

  def completed_first_artifact(item, path, at) do
    staged = path <> ".first-stage"
    File.write!(staged, "first artifact")
    metadata = %{"filepath" => path}
    :ok = FirstArtifact.remember(item, metadata, staged)
    File.rename!(staged, path)
    :ok = FirstArtifact.mark_transferred(item, metadata)
    :ok = FirstArtifact.mark_completed(item, at)
  end

  def enroll_approved_watch(item, source) do
    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, source)
    {:ok, %{entries: entries}} = OriginalArchive.archive_entries(Repo.preload(item, :metadata))

    approved =
      entries
      |> Enum.with_index()
      |> Map.new(fn {entry, index} ->
        {:ok, %{sha256: hash, size: size}} = ReplacementIntent.fingerprint(entry.source)

        {Integer.to_string(index),
         %{"role" => entry.role, "path" => Path.expand(entry.source), "sha256" => hash, "size" => size}}
      end)

    {:ok, watch |> Watch.changeset(%{approved_active_files: Map.put(approved, "first", approved)}) |> Repo.update!()}
  end
end
