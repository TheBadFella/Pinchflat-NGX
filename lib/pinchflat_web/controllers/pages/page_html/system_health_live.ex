defmodule Pinchflat.Pages.SystemHealthLive do
  @moduledoc """
  LiveView component for displaying system health indicators.

  Shows database status, queue metrics, and source health information.
  """
  use PinchflatWeb, :live_view

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias PinchflatWeb.CustomComponents.TextComponents

  @refresh_interval_ms 10_000

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center space-x-2">
          <.icon_button icon_name="hero-arrow-path" class="h-8 w-8" phx-click="refresh" tooltip="Refresh" />
          <span class="text-sm text-theme-on-surface-muted">Auto-refreshes every {div(@refresh_interval, 1000)}s</span>
        </div>
      </div>
      
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.health_card title="Database">
          <div class="space-y-2">
            <.health_row label="Size" value={format_bytes(@db_stats.size)} />
            <.health_row label="WAL Size" value={format_bytes(@db_stats.wal_size)} />
            <.health_row label="Page Count" value={format_number(@db_stats.page_count)} />
          </div>
        </.health_card>
        
        <.health_card title="Job Queue">
          <div class="space-y-2">
            <.health_row label="Pending" value={@queue_stats.pending} />
            <.health_row label="Executing" value={@queue_stats.executing} />
            <.health_row label="Failed (24h)" value={@queue_stats.failed_24h} />
            <.health_row label="Completed (24h)" value={@queue_stats.completed_24h} />
          </div>
        </.health_card>
        
        <.health_card title="Sources">
          <div class="space-y-2">
            <.health_row label="Total" value={@source_stats.total} />
            <.health_row label="Enabled" value={@source_stats.enabled} />
            <.health_row
              label="Never Indexed"
              value={@source_stats.never_indexed}
              status={status_for_count(@source_stats.never_indexed)}
            />
            <.health_row label="Stale (>24h)" value={@source_stats.stale} status={status_for_count(@source_stats.stale)} />
          </div>
        </.health_card>
      </div>
      
      <div :if={@stale_sources != []} class="theme-surface-raised p-4">
        <h3 class="mb-3 flex items-center text-lg font-semibold text-theme-on-surface">
          <.icon name="hero-exclamation-triangle" class="theme-status-warning mr-2 h-5 w-5" /> Sources Not Indexed Recently
        </h3>
        
        <p class="mb-4 text-sm text-theme-on-surface-muted">
          These sources haven't been indexed in over 24 hours. They may be stuck or have configuration issues.
        </p>
        
        <div class="max-w-full overflow-x-auto">
          <.table rows={@stale_sources} table_class="text-sm">
            <:col :let={source} label="Source">
              <.subtle_link href={~p"/sources/#{source.id}"}>{source.custom_name}</.subtle_link>
            </:col>
            
            <:col :let={source} label="Last Indexed">{format_last_indexed(source.last_indexed_at)}</:col>
            
            <:col :let={source} label="Index Frequency">{format_frequency(source.index_frequency_minutes)}</:col>
            
            <:col :let={source} label="Enabled"><span :if={source.enabled} class="theme-status-success">Yes</span>
              <span :if={!source.enabled} class="text-theme-on-surface-muted">No</span></:col>
            
            <:col :let={source} label="">
              <.link
                href={~p"/sources/#{source.id}/force_index"}
                method="post"
                class="text-xs text-theme-primary transition hover:text-theme-secondary"
              >
                Force Index
              </.link>
            </:col>
          </.table>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp health_card(assigns) do
    ~H"""
    <div class="theme-surface-raised p-4">
      <h3 class="mb-3 text-md font-semibold text-theme-on-surface">{@title}</h3>
       {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :status, :atom, default: :normal

  defp health_row(assigns) do
    status_class =
      case assigns.status do
        :warning -> "theme-status-warning"
        :error -> "theme-status-error"
        _ -> "text-theme-on-surface"
      end

    assigns = assign(assigns, :status_class, status_class)

    ~H"""
    <div class="flex justify-between items-center">
      <span class="text-sm text-theme-on-surface-muted">{@label}</span>
      <span class={"font-medium #{@status_class}"}>{@value}</span>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @refresh_interval_ms)
    end

    {:ok, assign(socket, refresh_interval: @refresh_interval_ms) |> fetch_health_data()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_health_data(socket)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_interval_ms)
    {:noreply, fetch_health_data(socket)}
  end

  defp fetch_health_data(socket) do
    assign(socket,
      db_stats: fetch_db_stats(),
      queue_stats: fetch_queue_stats(),
      source_stats: fetch_source_stats(),
      stale_sources: fetch_stale_sources()
    )
  end

  defp fetch_db_stats do
    db_path = Application.get_env(:pinchflat, Pinchflat.Repo)[:database]
    wal_path = db_path <> "-wal"

    db_size = safe_file_size(db_path)
    wal_size = safe_file_size(wal_path)

    page_count =
      case Repo.query("SELECT page_count FROM pragma_page_count()") do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end

    %{
      size: db_size,
      wal_size: wal_size,
      page_count: page_count
    }
  end

  defp safe_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp fetch_queue_stats do
    cutoff_24h = DateTime.utc_now() |> DateTime.add(-24, :hour)

    pending =
      from(j in Oban.Job, where: j.state in ["available", "scheduled", "retryable"])
      |> Repo.aggregate(:count, :id)

    executing =
      from(j in Oban.Job, where: j.state == "executing")
      |> Repo.aggregate(:count, :id)

    failed_24h =
      from(j in Oban.Job,
        where: j.state in ["discarded", "cancelled"],
        where: j.inserted_at > ^cutoff_24h
      )
      |> Repo.aggregate(:count, :id)

    completed_24h =
      from(j in Oban.Job,
        where: j.state == "completed",
        where: j.completed_at > ^cutoff_24h
      )
      |> Repo.aggregate(:count, :id)

    %{
      pending: pending,
      executing: executing,
      failed_24h: failed_24h,
      completed_24h: completed_24h
    }
  end

  defp fetch_source_stats do
    cutoff_24h = DateTime.utc_now() |> DateTime.add(-24, :hour)

    total = Repo.aggregate(Source, :count, :id)

    enabled =
      from(s in Source, where: s.enabled == true)
      |> Repo.aggregate(:count, :id)

    never_indexed =
      from(s in Source, where: is_nil(s.last_indexed_at), where: s.enabled == true)
      |> Repo.aggregate(:count, :id)

    stale =
      from(s in Source,
        where: s.enabled == true,
        where: not is_nil(s.last_indexed_at),
        where: s.last_indexed_at < ^cutoff_24h
      )
      |> Repo.aggregate(:count, :id)

    %{
      total: total,
      enabled: enabled,
      never_indexed: never_indexed,
      stale: stale
    }
  end

  defp fetch_stale_sources do
    cutoff_24h = DateTime.utc_now() |> DateTime.add(-24, :hour)

    from(s in Source,
      where: s.enabled == true,
      where: is_nil(s.last_indexed_at) or s.last_indexed_at < ^cutoff_24h,
      order_by: [asc: s.last_indexed_at],
      limit: 10
    )
    |> Repo.all()
  end

  defp status_for_count(0), do: :normal
  defp status_for_count(count) when count > 0, do: :warning

  defp format_bytes(nil), do: "N/A"
  defp format_bytes(0), do: "0 B"

  defp format_bytes(bytes) when bytes < 1024 do
    "#{bytes} B"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
  end

  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_number(_), do: "N/A"

  defp format_last_indexed(nil), do: "Never"

  defp format_last_indexed(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end

  defp format_frequency(minutes) when minutes < 60, do: "#{minutes} min"
  defp format_frequency(minutes) when minutes < 1440, do: "#{div(minutes, 60)} hours"
  defp format_frequency(minutes), do: "#{div(minutes, 1440)} days"
end
