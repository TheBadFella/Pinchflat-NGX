defmodule PinchflatWeb.DiscoveryLive do
  @moduledoc """
  LiveView for channel discovery suggestions.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.Suggestion
  alias Pinchflat.Discovery.Worker

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        visible_suggestions: [],
        suggestions: [],
        dismissed_suggestions: [],
        discovery_enabled: Settings.get!(:channel_discovery_enabled),
        mentions_enabled: Settings.get!(:channel_discovery_mentions_enabled),
        featured_enabled: Settings.get!(:channel_discovery_featured_enabled),
        scan_busy: false,
        scan_status: :idle,
        notice: nil
      )
      |> refresh_suggestions()

    if connected?(socket), do: Discovery.subscribe()

    {:ok, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> refresh_suggestions()
     |> assign(notice: "Suggestions refreshed.")}
  end

  def handle_event("scan", _params, %{assigns: %{scan_busy: true}} = socket) do
    {:noreply,
     assign(socket,
       scan_status: :busy,
       notice: "A discovery scan is already queued or running."
     )}
  end

  def handle_event("scan", _params, socket) do
    case Worker.kickoff() do
      {:ok, _job} ->
        {:noreply,
         assign(socket,
           scan_busy: true,
           scan_status: :queued,
           notice: "Discovery scan queued. Suggestions will refresh when it completes."
         )}

      {:error, :duplicate_job} ->
        {:noreply,
         assign(socket,
           scan_busy: true,
           scan_status: :duplicate,
           notice: "A discovery scan is already queued or running."
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           scan_busy: false,
           scan_status: :error,
           notice: "Discovery scan could not be queued."
         )}
    end
  end

  def handle_event("accept", params, socket) do
    case suggestion_from_params(params) do
      %Suggestion{} = suggestion ->
        case Discovery.accept_suggestion(suggestion) do
          {:ok, accepted_suggestion} ->
            {:noreply, push_navigate(socket, to: source_new_path(accepted_suggestion))}

          {:error, _changeset} ->
            {:noreply, assign(socket, notice: "This suggestion could not be accepted.")}
        end

      nil ->
        {:noreply, assign(socket, notice: "This suggestion is no longer available.")}
    end
  end

  def handle_event("dismiss", params, socket) do
    update_suggestion(socket, params, &Discovery.dismiss_suggestion/1, "Suggestion dismissed.")
  end

  def handle_event("restore", params, socket) do
    update_suggestion(socket, params, &Discovery.restore_suggestion/1, "Suggestion restored.")
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}, socket) do
    if topic == Discovery.completion_topic() and event == Discovery.completion_event() do
      {:noreply,
       socket
       |> refresh_suggestions()
       |> assign(
         scan_busy: false,
         scan_status: completion_status(payload),
         notice: completion_notice(payload)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div id="discovery-page" class="space-y-6" data-view="channel-discovery">
      <header id="discovery-header" class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-2xl font-semibold text-theme-on-surface">Channel Discovery</h1>
          <p class="mt-2 max-w-2xl text-sm text-theme-on-surface-muted">
            Find channels from local metadata and your existing subscriptions.
          </p>
        </div>

        <div class="flex flex-wrap gap-2" role="group" aria-label="Discovery actions">
          <button
            id="discovery-refresh"
            type="button"
            class="theme-outline-button inline-flex items-center gap-2 rounded-m3-sm px-4 py-2 text-sm font-medium"
            phx-click="refresh"
            data-action="refresh"
          >
            <.icon name="hero-arrow-path" class="h-4 w-4" aria-hidden="true" /> Refresh
          </button>
          <button
            id="discovery-scan"
            type="button"
            class="theme-primary-button inline-flex items-center gap-2 rounded-m3-sm px-4 py-2 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50"
            phx-click="scan"
            data-action="scan"
            data-scan-state={to_string(@scan_status)}
            disabled={@scan_busy}
          >
            <.icon name="hero-magnifying-glass" class="h-4 w-4" aria-hidden="true" />
            {scan_button_label(@scan_busy, @scan_status)}
          </button>
        </div>
      </header>

      <section
        id="discovery-status-panel"
        class="theme-surface-raised p-5"
        aria-labelledby="discovery-status-heading"
        data-discovery-enabled={to_string(@discovery_enabled)}
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 id="discovery-status-heading" class="text-lg font-semibold text-theme-on-surface">Discovery status</h2>
          <span
            id="discovery-scan-status"
            class={["text-sm font-medium", scan_status_class(@scan_status)]}
            role="status"
            aria-live="polite"
            data-status={to_string(@scan_status)}
          >
            {scan_status_label(@scan_status)}
          </span>
        </div>

        <p id="discovery-status" class="mt-2 text-sm text-theme-on-surface-muted" role="status" aria-live="polite">
          {@notice || "Ready to scan."}
        </p>

        <dl id="discovery-settings" class="mt-5 grid gap-3 sm:grid-cols-3">
          <div class="theme-surface-accent p-3" data-setting="channel_discovery_enabled">
            <dt class="text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted">Scheduled scans</dt>
            <dd class="mt-1">
              <span class={[
                "inline-flex rounded-full px-2 py-1 text-xs font-medium",
                setting_badge_class(@discovery_enabled)
              ]}>
                {setting_label(@discovery_enabled)}
              </span>
            </dd>
          </div>
          <div class="theme-surface-accent p-3" data-setting="channel_discovery_mentions_enabled">
            <dt class="text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted">Mention discovery</dt>
            <dd class="mt-1">
              <span class={[
                "inline-flex rounded-full px-2 py-1 text-xs font-medium",
                setting_badge_class(@mentions_enabled)
              ]}>
                {setting_label(@mentions_enabled)}
              </span>
            </dd>
          </div>
          <div class="theme-surface-accent p-3" data-setting="channel_discovery_featured_enabled">
            <dt class="text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted">Featured discovery</dt>
            <dd class="mt-1">
              <span class={[
                "inline-flex rounded-full px-2 py-1 text-xs font-medium",
                setting_badge_class(@featured_enabled)
              ]}>
                {setting_label(@featured_enabled)}
              </span>
            </dd>
          </div>
        </dl>

        <p class="mt-4 text-sm text-theme-on-surface-muted">
          Scheduled discovery is controlled in <.link
            href={~p"/settings"}
            class="font-medium text-theme-primary hover:underline"
          >Settings</.link>.
          Manual scans remain available when scheduled scans are disabled.
        </p>
      </section>

      <section id="discovery-suggestions" aria-labelledby="discovery-suggestions-heading">
        <div class="mb-4 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 id="discovery-suggestions-heading" class="text-xl font-semibold text-theme-on-surface">Suggestions</h2>
            <p class="mt-1 text-sm text-theme-on-surface-muted">Review channels before adding them as sources.</p>
          </div>
          <span class="text-sm text-theme-on-surface-muted" data-visible-count={to_string(length(@visible_suggestions))}>
            {length(@visible_suggestions)} visible
          </span>
        </div>

        <div
          :if={@visible_suggestions == []}
          id="discovery-empty"
          class="theme-surface-accent p-8 text-center"
          role="status"
        >
          <h3 id="discovery-empty-heading" class="text-lg font-semibold text-theme-on-surface">
            No channel suggestions yet
          </h3>
          <p class="mx-auto mt-2 max-w-xl text-sm text-theme-on-surface-muted">
            Refresh the sample or run a scan to look for validated channel suggestions.
          </p>
        </div>

        <div
          :if={@visible_suggestions != []}
          id="discovery-suggestion-list"
          class="grid gap-4 md:grid-cols-2 xl:grid-cols-3"
          data-suggestion-count={to_string(length(@visible_suggestions))}
        >
          <article
            :for={suggestion <- @visible_suggestions}
            id={suggestion_dom_id(suggestion)}
            class="theme-surface-raised flex flex-col gap-4 p-5"
            data-suggestion-id={suggestion_external_id(suggestion)}
            data-suggestion-state="validated"
          >
            <div class="flex min-w-0 items-start gap-3">
              <img
                :if={suggestion_artwork_url(suggestion)}
                src={suggestion_artwork_url(suggestion)}
                alt={"Artwork for #{suggestion_name(suggestion)}"}
                class="h-14 w-14 shrink-0 rounded-m3-sm object-cover"
                loading="lazy"
              />
              <div class="min-w-0">
                <h3 class="break-words text-lg font-semibold text-theme-on-surface">{suggestion_name(suggestion)}</h3>
                <.link
                  href={suggestion.canonical_url}
                  target="_blank"
                  rel="noreferrer"
                  class="mt-1 block break-all text-sm text-theme-primary hover:underline"
                >
                  {suggestion.canonical_url}
                </.link>
              </div>
            </div>

            <div class="flex items-center justify-between gap-3 text-sm">
              <span class="text-theme-on-surface-muted">Discovery score</span>
              <span class="theme-badge-success rounded-full px-2 py-1 font-medium" data-score={to_string(suggestion.score)}>
                {suggestion.score}
              </span>
            </div>

            <dl class="theme-surface-accent p-3 text-sm">
              <dt class="text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted">Evidence</dt>
              <dd class="mt-1 break-words text-theme-on-surface">{suggestion.evidence}</dd>
            </dl>

            <div class="mt-auto flex flex-wrap gap-2 border-t border-theme-outline/60 pt-4">
              <button
                id={"accept-suggestion-#{suggestion_external_id(suggestion)}"}
                type="button"
                class="theme-primary-button rounded-m3-sm px-4 py-2 text-sm font-medium"
                phx-click="accept"
                phx-value-external_channel_id={suggestion_external_id(suggestion)}
                data-action="accept"
                aria-label={"Accept #{suggestion_name(suggestion)}"}
              >
                Accept
              </button>
              <button
                id={"dismiss-suggestion-#{suggestion_external_id(suggestion)}"}
                type="button"
                class="theme-outline-button rounded-m3-sm px-4 py-2 text-sm font-medium"
                phx-click="dismiss"
                phx-value-external_channel_id={suggestion_external_id(suggestion)}
                data-action="dismiss"
                aria-label={"Dismiss #{suggestion_name(suggestion)}"}
              >
                Dismiss
              </button>
            </div>
          </article>
        </div>
      </section>

      <section id="discovery-dismissed" aria-labelledby="discovery-dismissed-heading" class="theme-surface-raised p-5">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 id="discovery-dismissed-heading" class="text-xl font-semibold text-theme-on-surface">
              Dismissed suggestions
            </h2>
            <p class="mt-1 text-sm text-theme-on-surface-muted">
              Restore a dismissed channel if you want to review it again.
            </p>
          </div>
          <span class="text-sm text-theme-on-surface-muted" data-dismissed-count={to_string(length(@dismissed_suggestions))}>
            {length(@dismissed_suggestions)} dismissed
          </span>
        </div>

        <p
          :if={@dismissed_suggestions == []}
          id="discovery-dismissed-empty"
          class="mt-4 text-sm text-theme-on-surface-muted"
          role="status"
        >
          No dismissed suggestions.
        </p>

        <ul :if={@dismissed_suggestions != []} id="discovery-dismissed-list" class="mt-4 space-y-3">
          <li
            :for={suggestion <- @dismissed_suggestions}
            id={"dismissed-#{suggestion_external_id(suggestion)}"}
            class="flex flex-wrap items-center justify-between gap-3 border-t border-theme-outline/60 pt-3"
            data-suggestion-id={suggestion_external_id(suggestion)}
            data-suggestion-state="dismissed"
          >
            <div class="min-w-0">
              <p class="break-words font-medium text-theme-on-surface">{suggestion_name(suggestion)}</p>
              <p class="break-all text-sm text-theme-on-surface-muted">{suggestion.canonical_url}</p>
            </div>
            <button
              id={"restore-suggestion-#{suggestion_external_id(suggestion)}"}
              type="button"
              class="theme-outline-button rounded-m3-sm px-4 py-2 text-sm font-medium"
              phx-click="restore"
              phx-value-external_channel_id={suggestion_external_id(suggestion)}
              data-action="restore"
              aria-label={"Restore #{suggestion_name(suggestion)}"}
            >
              Restore
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp refresh_suggestions(socket) do
    visible_suggestions = Discovery.sample_suggestions()

    assign(socket,
      visible_suggestions: visible_suggestions,
      suggestions: visible_suggestions,
      dismissed_suggestions: Discovery.list_dismissed_suggestions()
    )
  end

  defp suggestion_from_params(%{"external_channel_id" => external_channel_id})
       when is_binary(external_channel_id) do
    Discovery.get_suggestion_by_external_channel_id(external_channel_id)
  end

  defp suggestion_from_params(%{"suggestion_id" => suggestion_id}), do: Discovery.get_suggestion(suggestion_id)
  defp suggestion_from_params(%{"id" => suggestion_id}), do: Discovery.get_suggestion(suggestion_id)
  defp suggestion_from_params(_params), do: nil

  defp update_suggestion(socket, params, update_fun, success_message) do
    case suggestion_from_params(params) do
      %Suggestion{} = suggestion ->
        case update_fun.(suggestion) do
          {:ok, _updated_suggestion} ->
            {:noreply,
             socket
             |> refresh_suggestions()
             |> assign(notice: success_message)}

          {:error, _changeset} ->
            {:noreply, assign(socket, notice: "The suggestion could not be updated.")}
        end

      nil ->
        {:noreply, assign(socket, notice: "This suggestion is no longer available.")}
    end
  end

  defp source_new_path(%Suggestion{} = suggestion) do
    ~p"/sources/new?#{[original_url: suggestion.canonical_url || "", custom_name: suggestion.channel_name || "", source_type: "channel"]}"
  end

  defp suggestion_external_id(%{external_channel_id: external_channel_id}), do: external_channel_id

  defp suggestion_name(%{channel_name: channel_name}) when is_binary(channel_name) and channel_name != "",
    do: channel_name

  defp suggestion_name(%{external_channel_id: external_channel_id}), do: external_channel_id

  defp suggestion_artwork_url(%{artwork_url: artwork_url}) when is_binary(artwork_url) and artwork_url != "",
    do: artwork_url

  defp suggestion_artwork_url(_suggestion), do: nil

  defp suggestion_dom_id(suggestion), do: "discovery-suggestion-#{suggestion_external_id(suggestion)}"

  defp setting_label(true), do: "Enabled"
  defp setting_label(false), do: "Disabled"
  defp setting_label(_value), do: "Unknown"

  defp setting_badge_class(true), do: "theme-badge-success"
  defp setting_badge_class(false), do: "theme-badge-warning"
  defp setting_badge_class(_value), do: "theme-badge-warning"

  defp scan_button_label(true, :duplicate), do: "Scan already queued"
  defp scan_button_label(true, _status), do: "Scan queued"
  defp scan_button_label(false, _status), do: "Scan now"

  defp scan_status_label(:idle), do: "Ready to scan."
  defp scan_status_label(:queued), do: "Scan queued."
  defp scan_status_label(:busy), do: "Scan in progress."
  defp scan_status_label(:duplicate), do: "A scan is already queued or running."
  defp scan_status_label(:completed), do: "Scan completed."
  defp scan_status_label(:disabled), do: "Scheduled discovery is disabled."
  defp scan_status_label(:error), do: "Scan could not be queued."
  defp scan_status_label(_status), do: "Discovery status unavailable."

  defp scan_status_class(status) when status in [:queued, :busy], do: "theme-status-info"
  defp scan_status_class(:completed), do: "theme-status-success"
  defp scan_status_class(status) when status in [:duplicate, :disabled], do: "theme-status-warning"
  defp scan_status_class(:error), do: "theme-status-error"
  defp scan_status_class(_status), do: "text-theme-on-surface-muted"

  defp completion_status(%{status: :disabled}), do: :disabled
  defp completion_status(%{"status" => "disabled"}), do: :disabled
  defp completion_status(%{status: :failed}), do: :error
  defp completion_status(%{"status" => "failed"}), do: :error
  defp completion_status(_payload), do: :completed

  defp completion_notice(%{status: :disabled}),
    do: "Discovery is disabled in Settings. Manual scans remain available."

  defp completion_notice(%{"status" => "disabled"}),
    do: "Discovery is disabled in Settings. Manual scans remain available."

  defp completion_notice(%{status: :failed}), do: "Discovery scan failed. Try again when ready."
  defp completion_notice(%{"status" => "failed"}), do: "Discovery scan failed. Try again when ready."

  defp completion_notice(%{inserted_count: inserted_count}) when is_integer(inserted_count) do
    "Scan completed. #{inserted_count} new suggestion(s) added."
  end

  defp completion_notice(_payload), do: "Discovery scan completed. Suggestions refreshed."
end
