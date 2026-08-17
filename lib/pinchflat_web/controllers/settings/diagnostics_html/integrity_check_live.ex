defmodule Pinchflat.Settings.IntegrityCheckLive do
  @moduledoc """
  The "Check Integrity" button and its results modal in the Database section of
  the diagnostics page.

  A LiveView rather than a plain POST because a full `PRAGMA integrity_check`
  on a large database can outlast the HTTP request timeout. Here the check runs
  in the LiveView process and the modal shows a spinner until it returns, so it
  reads as a synchronous action without a request hanging behind it.

  Deliberately report-only: findings are shown verbatim and nothing is
  repaired. Repairs vary by what's damaged and are safest done with the app
  stopped, so they stay a manual, documented procedure.
  """

  use PinchflatWeb, :live_view

  require Logger

  alias Pinchflat.Diagnostics.DatabaseDiagnostics

  @modal_id "integrity-check-modal"

  def render(assigns) do
    ~H"""
    <div class="flex w-full sm:inline-flex sm:w-auto">
      <.button
        color="theme-primary-button"
        rounding="rounded-m3-sm"
        class="w-full text-sm sm:w-auto"
        type="button"
        phx-click={show_modal(@modal_id)}
      >
        <.icon name="hero-shield-check" class="h-4 w-4 mr-1" /> Check Integrity
      </.button>

      <.modal id={@modal_id}>
        <h3 class="text-xl font-bold text-theme-on-surface mb-2">Database Integrity Check</h3>
        <p class="text-sm text-theme-on-surface-muted mb-6">
          Reads the database and reports any corruption SQLite finds. This is read-only — it
          changes and repairs nothing, and downloads and indexing keep running while it works.
        </p>

        <div class="flex flex-wrap gap-3 mb-3">
          <.button
            color="theme-primary-button"
            rounding="rounded-m3-sm"
            class="text-sm"
            type="button"
            disabled={@status == :running}
            phx-click="check"
            phx-value-mode="quick"
          >
            Quick Check
          </.button>
          <.button
            color="theme-primary-button"
            rounding="rounded-m3-sm"
            class="text-sm"
            type="button"
            disabled={@status == :running}
            phx-click="check"
            phx-value-mode="full"
          >
            Full Check
          </.button>
        </div>
        <p class="text-xs text-theme-on-surface-muted mb-6">
          A quick check verifies the structure of every page and the contents of the search index.
          A full check additionally cross-checks every index entry against its table — more
          thorough, but considerably slower on a large database or slow storage.
        </p>

        <%= case @status do %>
          <% :idle -> %>
          <% :running -> %>
            <div class="rounded-m3-md border border-theme-outline bg-theme-surface-3 p-4 flex items-center gap-2">
              <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin text-theme-on-surface" />
              <span class="text-sm text-theme-on-surface">
                Running a {mode_label(@mode)}. On a large database this can take a few minutes —
                leave this window open.
              </span>
            </div>
          <% :clean -> %>
            <div class="rounded-m3-md border border-theme-outline bg-theme-surface-2 p-4">
              <p class="text-sm theme-status-success font-semibold">
                <.icon name="hero-check-circle" class="h-4 w-4 mr-1" /> No problems found.
              </p>
              <p class="text-xs text-theme-on-surface-muted mt-1">
                {String.capitalize(mode_label(@mode))} completed at {format_time(@checked_at)}.
              </p>
            </div>
          <% :findings -> %>
            <div class="rounded-m3-md border border-theme-outline bg-theme-surface-2 p-4">
              <div class="flex justify-between items-start gap-4 mb-3">
                <div>
                  <p class="text-sm theme-status-error font-semibold">
                    <.icon name="hero-exclamation-triangle" class="h-4 w-4 mr-1" />
                    SQLite reported {length(@findings)} problem(s).
                  </p>
                  <p class="text-xs text-theme-on-surface-muted mt-1">
                    {String.capitalize(mode_label(@mode))} completed at {format_time(@checked_at)}.
                  </p>
                </div>
                <.button
                  color="theme-primary-button"
                  rounding="rounded-m3-sm"
                  class="text-xs whitespace-nowrap"
                  type="button"
                  x-data="{ copied: false }"
                  x-on:click={~s"
                    copyWithCallbacks(
                      `#{js_escape(Enum.join(@findings, "\n"))}`,
                      () => copied = true,
                      () => copied = false
                    )
                  "}
                >
                  Copy
                  <span x-show="copied" x-transition.duration.150ms>
                    <.icon name="hero-check" class="ml-1 h-3 w-3" />
                  </span>
                </.button>
              </div>
              <ul class="max-h-64 overflow-y-auto rounded-m3-xs border border-theme-outline/50 bg-theme-surface-1 p-3 space-y-1">
                <li :for={finding <- @findings} class="text-xs text-theme-on-surface font-mono break-words">
                  {finding}
                </li>
              </ul>
              <p class="text-xs text-theme-on-surface-muted mt-3">
                Nothing has been changed. Repairs depend on what's damaged and are safest done with
                the server stopped, so they aren't automated here — back up your database file before
                attempting one.
                <span :if={search_index_finding?(@findings)} class="block mt-1">
                  Problems naming <span class="font-mono">media_items_search_index</span>
                  affect only the search index, which is derived from your media and can be rebuilt
                  without losing anything.
                </span>
              </p>
            </div>
          <% :error -> %>
            <div class="rounded-m3-md border border-theme-outline bg-theme-surface-2 p-4">
              <p class="text-sm theme-status-error font-semibold">The check could not run.</p>
              <p class="text-xs text-theme-on-surface font-mono mt-2 break-words">{@error}</p>
            </div>
        <% end %>
      </.modal>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        modal_id: @modal_id,
        status: :idle,
        mode: nil,
        findings: [],
        error: nil,
        checked_at: nil
      )

    {:ok, socket}
  end

  # The check runs via a message to self rather than inline so this event can
  # return first and paint the spinner. It deliberately blocks the LiveView
  # while it runs — the buttons are disabled for the duration anyway, and
  # keeping it in this process avoids a second database connection.
  def handle_event("check", %{"mode" => mode}, socket) do
    mode = parse_mode(mode)
    send(self(), {:run_check, mode})

    {:noreply, assign(socket, status: :running, mode: mode, findings: [], error: nil)}
  end

  def handle_info({:run_check, mode}, socket) do
    socket = assign(socket, checked_at: DateTime.utc_now())

    case DatabaseDiagnostics.run_integrity_check(mode) do
      {:ok, []} ->
        {:noreply, assign(socket, status: :clean)}

      {:ok, findings} ->
        Logger.warning("Database #{mode_label(mode)} found #{length(findings)} problem(s): #{inspect(findings)}")

        {:noreply, assign(socket, status: :findings, findings: findings)}

      {:error, message} ->
        Logger.warning("Database #{mode_label(mode)} could not run: #{message}")

        {:noreply, assign(socket, status: :error, error: message)}
    end
  end

  defp parse_mode("full"), do: :full
  defp parse_mode(_mode), do: :quick

  defp mode_label(:full), do: "full check"
  defp mode_label(_mode), do: "quick check"

  defp search_index_finding?(findings) do
    Enum.any?(findings, &String.contains?(&1, "media_items_search_index"))
  end

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  # Findings are pasted into a JS template literal for the copy button, so the
  # three sequences that can break out of one are neutralised.
  defp js_escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("${", "\\${")
  end
end
