defmodule Pinchflat.Sources.SourceRemoval do
  @moduledoc """
  Detects when YouTube has removed a source's channel, playlist or video and
  stops checking it.

  Only errors that clearly mean the content is gone count, such as a terminated
  account or a playlist that no longer exists. Rate limits, private videos,
  sign-in prompts and other temporary failures keep the existing retry
  behaviour. A removed source is turned off (no indexing or downloads), keeps
  its files and media items, and shows a warning on its page until the user
  checks it again or deletes it.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.Lifecycle.Notifications.SourceNotifications
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  @removed_phrases [
    "this channel does not exist",
    "this channel is not available",
    "account has been terminated",
    "uploader has closed their youtube account",
    "the playlist does not exist",
    "this playlist does not exist",
    "this video has been removed by the uploader",
    "video has been removed for violating",
    "this page isn't available"
  ]
  @max_reason_length 500

  @doc """
  Returns yt-dlp's error message when it says the content was removed, or nil.

  Returns String.t() | nil
  """
  def removal_message({:error, message, _status}), do: removal_message(message)
  def removal_message({:error, message}), do: removal_message(message)

  def removal_message(message) when is_binary(message) do
    downcased = String.downcase(message)

    if Enum.any?(@removed_phrases, &String.contains?(downcased, &1)) do
      message |> String.split("\n") |> Enum.find(message, &removal_line?/1) |> clean_line()
    end
  end

  def removal_message(_error), do: nil

  @doc """
  Marks a source as removed from YouTube: turns it off, records when and why,
  removes its scheduled indexing and sends a notification if one is set up.
  Does not cancel the job that found the removal, so the caller can finish.

  Returns {:ok, %Source{}}
  """
  def mark_removed(%Source{} = source, message) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason = String.slice(message, 0, @max_reason_length)

    Repo.update_all(from(s in Source, where: s.id == ^source.id),
      set: [enabled: false, removed_at: now, removed_reason: reason, updated_at: now]
    )

    SlowIndexingHelpers.delete_indexing_tasks(source)
    Logger.warning("Source ##{source.id} #{inspect(source.custom_name)} was removed from YouTube: #{reason}")
    SourceNotifications.send_source_removed_notification(Settings.get!(:apprise_server), source, reason)

    {:ok, Sources.get_source!(source.id)}
  end

  @doc """
  Turns a removed source back on and indexes it again. If YouTube still
  reports it as removed, the index marks it removed again.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def check_again(%Source{} = source) do
    with {:ok, source} <- Sources.update_source(source, %{enabled: true}) do
      SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})
      {:ok, source}
    end
  end

  defp removal_line?(line) do
    downcased = String.downcase(line)
    Enum.any?(@removed_phrases, &String.contains?(downcased, &1))
  end

  # "ERROR: [youtube:tab] UCxxxx: This channel does not exist." -> "This channel does not exist."
  defp clean_line(line) do
    line
    |> String.replace(~r/^\s*ERROR:\s*/, "")
    |> String.replace(~r/^\[[^\]]+\]\s*[^:\s]+:\s*/, "")
    |> String.trim()
  end
end
