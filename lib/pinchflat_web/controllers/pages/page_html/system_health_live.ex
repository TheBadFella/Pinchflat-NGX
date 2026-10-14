defmodule Pinchflat.Pages.SystemHealthLive do
  @moduledoc """
  LiveView component for displaying system health indicators.

  Shows database status, queue metrics, and source health information.
  """
  use PinchflatWeb, :live_view

  import Ecto.Query, warn: false

  alias Pinchflat.Diagnostics.DatabaseDiagnostics
  alias Pinchflat.Repo
  alias Pinchflat.Diagnostics.SourceHealth
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

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <.health_card title="Database">
          <div class="space-y-2">
            <.health_row label="Adapter" value={database_adapter_name(@db_stats.adapter)} />
            <.health_row label="Size" value={format_bytes(@db_stats.size)} />
            <.health_row :if={@db_stats.adapter == :sqlite} label="WAL Size" value={format_bytes(@db_stats.wal_size)} />
            <.health_row
              :if={@db_stats.adapter == :sqlite}
              label="Page Count"
              value={format_number(@db_stats.page_count)}
            />
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
            <.health_row label="Healthy" value={@source_stats.healthy} />
            <.health_row label="Overdue" value={@source_stats.overdue} status={status_for_count(@source_stats.overdue)} />
            <.health_row label="Failed check" value={@source_stats.failed} status={status_for_count(@source_stats.failed)} />
            <.health_row label="Unknown" value={@source_stats.unknown} />
            <.health_row label="Paused / held" value={@source_stats.paused} />
            <.health_row label="Manual" value={@source_stats.manual} />
            <.health_row label="Active" value={@source_stats.active} />
            <.health_row label="Scheduled / pending" value={@source_stats.pending} />
          </div>
        </.health_card>

        <.health_card title="Storage Protection">
          <div class="space-y-2">
            <.health_row
              label="Protection"
              value={if(@storage_stats.enabled, do: "Enabled", else: "Disabled")}
            />
            <.health_row
              label="Status"
              value={
                case @storage_stats.status do
                  :disabled -> "Disabled"
                  :blocked -> "Blocked (Low Space)"
                  :healthy -> "Healthy"
                end
              }
              status={if(@storage_stats.status == :blocked, do: :error, else: :normal)}
            />
            <.health_row
              :if={@storage_stats.enabled}
              label="Threshold"
              value={format_bytes(@storage_stats.threshold)}
            />
            <.health_row
              :if={@storage_stats.blocked && @storage_stats.free_bytes}
              label="Free Space"
              value={format_bytes(@storage_stats.free_bytes)}
              status={:warning}
            />
          </div>
        </.health_card>
      </div>

      <div :if={@source_attention != []} class="theme-surface-raised p-4">
        <h3 class="mb-3 text-lg font-semibold text-theme-on-surface">Indexing checks to review</h3>

        <p class="mb-4 text-sm text-theme-on-surface-muted">
          Fast checks and full scans use their own schedules. Overdue includes half an interval of grace
          (at least ten minutes). Unknown means no retained success or queue status is available;
          it does not mean your library is broken. Paused and manual sources are counted separately.
          Showing up to ten sources needing review.
        </p>

        <div class="space-y-4">
          <article :for={health <- @source_attention} class="theme-surface-accent space-y-3 rounded-m3-lg p-4">
            <div class="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <.link
                href={~p"/sources/#{health.source.id}"}
                class="min-h-[44px] min-w-0 flex-1 break-words [overflow-wrap:anywhere] font-medium text-theme-primary"
              >
                {health.source.custom_name}
              </.link>

              <.link
                :if={health.status in [:overdue, :failed]}
                href={~p"/sources/#{health.source.id}/force_index"}
                method="post"
                class="inline-flex min-h-[44px] shrink-0 items-center text-sm text-theme-primary"
              >
                Force Full Scan
              </.link>
            </div>

            <dl class="grid grid-cols-1 gap-3 text-sm sm:grid-cols-2">
              <div>
                <dt class="text-theme-on-surface-muted">Check</dt><dd class="text-theme-on-surface">{health.mode}</dd>
              </div>

              <div>
                <dt class="text-theme-on-surface-muted">Status</dt><dd class="text-theme-on-surface">
                  {health.status |> Atom.to_string() |> String.capitalize()}
                </dd>
              </div>

              <div>
                <dt class="text-theme-on-surface-muted">Last successful check</dt><dd class="text-theme-on-surface">
                  {format_last_indexed(health.last_success_at)}
                </dd>
              </div>

              <div>
                <dt class="text-theme-on-surface-muted">Check interval</dt><dd class="text-theme-on-surface">
                  {format_frequency(health.interval_minutes)}
                </dd>
              </div>

              <div :if={health.source.fast_index}>
                <dt class="text-theme-on-surface-muted">Last full scan</dt><dd class="text-theme-on-surface">
                  {format_last_indexed(health.source.last_indexed_at)}
                </dd>
              </div>

              <div :if={health.source.fast_index}>
                <dt class="text-theme-on-surface-muted">Full-scan interval</dt><dd class="text-theme-on-surface">
                  {format_frequency(health.source.index_frequency_minutes)}
                </dd>
              </div>
            </dl>
          </article>
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
    health = SourceHealth.snapshot()

    assign(socket,
      db_stats: fetch_db_stats(),
      queue_stats: fetch_queue_stats(),
      source_stats: health.stats,
      source_attention: health.attention,
      storage_stats: fetch_storage_stats()
    )
  end

  defp fetch_storage_stats do
    setting = Settings.record()

    status =
      cond do
        not setting.download_space_protection_enabled -> :disabled
        setting.download_space_protection_blocked -> :blocked
        true -> :healthy
      end

    %{
      enabled: setting.download_space_protection_enabled,
      blocked: setting.download_space_protection_blocked,
      threshold: setting.download_space_protection_threshold_bytes,
      free_bytes: setting.download_space_protection_free_bytes,
      status: status
    }
  end

  defp fetch_db_stats do
    stats = DatabaseDiagnostics.get_database_stats()

    %{
      size: stats.total_bytes,
      wal_size: stats.wal_file_bytes,
      page_count: stats.page_count,
      adapter: stats.adapter
    }
  end

  defp database_adapter_name(:postgres), do: "PostgreSQL"
  defp database_adapter_name(:sqlite), do: "SQLite"

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

  defp format_last_indexed(nil), do: "No retained success"

  defp format_last_indexed(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end

  defp format_frequency(nil), do: "Manual"
  defp format_frequency(0), do: "Manual"

  defp format_frequency(minutes) when minutes < 60, do: "#{minutes} min"
  defp format_frequency(minutes) when minutes < 1440, do: "#{div(minutes, 60)} hours"
  defp format_frequency(minutes), do: "#{div(minutes, 1440)} days"
end
