defmodule Pinchflat.MediaWatch.NotificationWorker do
  @moduledoc """
  Delivers one durable watch event through the existing Apprise transport.

  Delivery state lives on the event row so a repeated worker run does not
  flood the destination. Failed sends are retried a bounded number of times.
  At-least-once delivery is possible if a send succeeds but the process stops
  before the acknowledgement is persisted.
  """

  use Oban.Worker,
    queue: :media_watch,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]],
    tags: ["media_watch"]

  require Logger

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.MediaWatchEvent, as: Event
  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @max_attempts 5
  @title_limit 200
  @body_limit 1024

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Repo.get(Event, id) do
      nil -> :ok
      %Event{delivery_state: state} when state in ["sent", "skipped", "failed"] -> :ok
      event -> deliver(event)
    end
  end

  defp deliver(%Event{} = event) do
    watch = Repo.get(Watch, event.media_watch_id)
    item = watch && watch.media_item_id && Repo.get(MediaItem, watch.media_item_id)

    case apprise_servers() do
      nil ->
        mark_delivered(event, "skipped", nil)
        :ok

      servers ->
        opts = [
          title: build_title(event),
          body: build_body(event, watch, item),
          notification_type: notification_type(event.kind)
        ]

        case backend_runner().run(servers, opts) do
          {:ok, _} ->
            mark_delivered(event, "sent", nil)
            :ok

          {:error, :no_servers} ->
            mark_delivered(event, "skipped", nil)
            :ok

          {:error, reason} ->
            register_failure(event, reason)
        end
    end
  end

  defp register_failure(%Event{} = event, reason) do
    attempts = event.attempts + 1
    state = if attempts >= @max_attempts, do: "failed", else: "pending"
    next_attempt_at = DateTime.add(now(), min(3_600, 60 * Integer.pow(2, attempts - 1)), :second)

    {:ok, _} =
      update_event(event, %{
        attempts: attempts,
        delivery_state: state,
        next_attempt_at: next_attempt_at,
        error_summary: summarize(reason)
      })

    if state == "failed" do
      Logger.error("Watch notification ##{event.id} failed permanently: #{inspect(reason)}")
      :ok
    else
      {:error, reason}
    end
  end

  defp mark_delivered(%Event{} = event, state, error_summary) do
    {:ok, _} =
      update_event(event, %{
        delivery_state: state,
        attempts: event.attempts + 1,
        next_attempt_at: nil,
        error_summary: error_summary
      })

    :ok
  end

  @doc false
  def build_title(%Event{} = event) do
    topic =
      case event.kind do
        "restored" -> "Watched video availability restored"
        "duration" -> "Watched video edited"
        "unlisted" -> "Watched video made unlisted"
        "visibility" -> "Watched video visibility changed"
        "unavailable" -> "Watched video unavailable"
        _ -> "Watched video changed"
      end

    String.slice("[Pinchflat-ngx] #{topic}", 0, @title_limit)
  end

  @doc false
  def build_body(%Event{} = event, %Watch{} = watch, nil) do
    """
    YouTube Video: #{watch.media_id} (local media record removed)
    Change: #{event.kind}: #{event.old_value} → #{event.new_value}
    Observed: #{Calendar.strftime(event.observed_at, "%Y-%m-%d %H:%M:%S UTC")}
    """
    |> String.trim()
    |> String.slice(0, @body_limit)
  end

  def build_body(%Event{} = event, %Watch{} = watch, %MediaItem{} = item) do
    change =
      case {event.old_value, event.new_value} do
        {nil, new} -> "#{event.kind}: #{new}"
        {old, nil} -> "#{event.kind}: #{old}"
        {old, new} -> "#{old} → #{new}"
      end

    action_note =
      if event.kind == "duration" do
        "Automatic replacement is blocked so the modified video does not overwrite your original file."
      else
        "Automatic replacement is blocked to protect your original file."
      end

    lines = [
      item.title,
      "Change: #{event.kind} (#{change})",
      "Observed: #{Calendar.strftime(event.observed_at, "%Y-%m-%d %H:%M:%S UTC")}",
      "Protection: #{action_note}",
      local_link(watch, item)
    ]

    lines
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> String.slice(0, @body_limit)
  end

  defp notification_type("restored"), do: "success"
  defp notification_type("unavailable"), do: "failure"
  defp notification_type(_kind), do: "warning"

  defp local_link(%Watch{} = watch, %MediaItem{} = item) do
    case Settings.get(:external_base_url) do
      {:ok, base_url} when is_binary(base_url) and base_url != "" ->
        base = String.trim_trailing(base_url, "/")
        "Open Media in Pinchflat: #{base}/sources/#{item.source_id}/media/#{watch.media_item_id}"

      _ ->
        nil
    end
  end

  defp apprise_servers do
    case Settings.get!(:apprise_server) do
      value when is_binary(value) -> if String.trim(value) != "", do: value
      _ -> nil
    end
  end

  defp update_event(%Event{} = event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  defp summarize(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp summarize(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp backend_runner, do: Application.get_env(:pinchflat, :apprise_runner)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
