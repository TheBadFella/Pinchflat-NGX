defmodule Pinchflat.Settings.CookieFileLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.CookieHealth
  alias Pinchflat.CookieHealth.HealthCheckWorker
  alias Pinchflat.Settings
  alias Pinchflat.Settings.CookieFile

  def render(assigns) do
    ~H"""
    <div>
      <.label>
        Cookies File
        <span :if={@present} class="theme-badge-success ml-2 rounded-full px-3 py-1 text-xs font-medium">
          Populated
        </span>
        <span
          :if={!@present}
          class="ml-2 rounded-full bg-theme-surface-4 px-3 py-1 text-xs font-medium text-theme-on-surface-muted"
        >
          Empty
        </span>
      </.label>

      <.help>{Phoenix.HTML.raw(cookie_help())}</.help>

      <form
        id="cookie-file-form"
        phx-submit="upload_cookies"
        phx-change="validate_upload"
        class="mt-3 flex flex-wrap items-center gap-3"
      >
        <label
          phx-drop-target={@uploads.cookies.ref}
          class="theme-button theme-button-secondary cursor-pointer gap-2 focus-within:ring-2 focus-within:ring-theme-primary/70"
        >
          <.icon name="hero-arrow-up-tray" class="h-5 w-5" />
          <span>{upload_label(@uploads.cookies.entries)}</span>
          <.live_file_input upload={@uploads.cookies} class="sr-only" />
        </label>

        <.button :if={@uploads.cookies.entries != []} type="submit" variant="primary">
          Save File
        </.button>

        <.button
          :if={@present}
          href={~p"/settings/cookies"}
          variant="secondary"
        >
          <.icon name="hero-arrow-down-tray" class="h-5 w-5" /> Download
        </.button>

        <.icon_button
          :if={@present}
          icon_name={@validate_icon}
          phx-click="validate_cookies"
          tooltip={@validate_tooltip}
          type="button"
        />

        <.button
          :if={@present}
          type="button"
          phx-click="clear_cookies"
          data-confirm="Clear the cookies file?"
          variant="danger"
        >
          <.icon name="hero-trash" class="h-5 w-5" /> Clear
        </.button>
      </form>

      <.error :for={err <- upload_errors(@uploads.cookies)}>{error_to_string(err)}</.error>

      <!-- Cookie Health & Truthful Monitoring Card -->
      <div class="mt-6 rounded-m3-md border border-theme-outline/60 bg-theme-surface-2 p-5 shadow-m3-1">
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-theme-outline/40 pb-4">
          <div class="flex items-center gap-3">
            <h4 class="text-base font-semibold text-theme-on-surface">Cookie Health Status</h4>
            <span class={["rounded-full px-3 py-0.5 text-xs font-medium", status_badge_class(@health_status)]}>
              {status_label(@health_status)}
            </span>
          </div>

          <.button
            type="button"
            phx-click="test_cookie_health"
            variant="secondary"
            size="compact"
            disabled={!@present or @checking}
          >
            <.icon
              name={if @checking, do: "hero-arrow-path", else: "hero-play"}
              class={if(@checking, do: "h-4 w-4 animate-spin", else: "h-4 w-4")}
            />
            {if @checking, do: "Testing...", else: "Test Now"}
          </.button>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-4 text-sm sm:grid-cols-2">
          <div>
            <span class="text-xs font-medium text-theme-on-surface-muted">Last Checked</span>
            <p class="text-theme-on-surface">{format_timestamp(@last_checked_at)}</p>
          </div>
          <div>
            <span class="text-xs font-medium text-theme-on-surface-muted">Last Confirmed Authenticated</span>
            <p class="text-theme-on-surface">{format_timestamp(@last_authenticated_at)}</p>
          </div>
        </div>

        <div :if={@last_error} class="theme-status-card theme-status-card-error mt-4 text-xs">
          <span class="font-medium">Error:</span> {@last_error}
        </div>

        <div :if={@health_details && !@last_error} class="mt-3 text-xs text-theme-on-surface-muted">
          {@health_details}
        </div>

        <!-- Inline Monitoring Settings Form -->
        <form phx-submit="save_monitoring_config" class="mt-5 border-t border-theme-outline/40 pt-4">
          <div class="flex flex-col gap-4">
            <label class="flex min-h-11 items-center gap-3 cursor-pointer">
              <input
                type="checkbox"
                name="cookie_health_monitoring_enabled"
                value="true"
                checked={@monitoring_enabled}
                class="rounded border-theme-outline bg-theme-surface text-theme-primary focus:ring-theme-primary"
              />
              <span class="text-sm font-medium text-theme-on-surface">Enable Automatic Periodic Health Monitoring</span>
            </label>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <div>
                <label for="cookie-health-interval" class="mb-2 block text-sm font-medium text-theme-on-surface">Check Interval (Hours)</label>
                <div class="theme-field-shell">
                  <input
                    type="number"
                    id="cookie-health-interval"
                    name="cookie_health_check_interval_hours"
                    min="1"
                    max="168"
                    value={@check_interval_hours}
                    class="theme-input w-full rounded-m3-sm px-4 py-2.5 text-sm font-normal outline-none transition"
                  />
                </div>
              </div>

              <div class="sm:col-span-2">
                <label for="cookie-health-canary" class="mb-2 block text-sm font-medium text-theme-on-surface">
                  Canary URL (Members-only / Auth-gated video)
                </label>
                <div class="theme-field-shell">
                  <input
                    type="text"
                    id="cookie-health-canary"
                    name="cookie_health_canary_url"
                    placeholder="https://www.youtube.com/watch?v=..."
                    value={@canary_url}
                    class="theme-input w-full rounded-m3-sm px-4 py-2.5 font-mono text-sm font-normal outline-none transition"
                  />
                </div>
              </div>
            </div>

            <p class="text-sm leading-5 text-theme-on-surface-muted">
              Note: To verify YouTube authentication truthfully, configure a canary video that requires account access
              (e.g. members-only, private, or age-restricted). Public videos can be extracted without login and will
              always be reported as unverified.
            </p>

            <div class="flex flex-wrap items-center gap-3">
              <.button
                type="submit"
                variant="primary"
                class="w-full whitespace-normal sm:w-auto"
              >
                Save Monitoring Settings
              </.button>
              <span :if={@config_saved} class="text-sm font-medium text-theme-success">Saved!</span>
              <span :if={@config_error} role="alert" class="min-w-0 w-full break-words text-sm font-medium text-theme-error">
                {@config_error}
              </span>
            </div>
          </div>
        </form>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      CookieHealth.subscribe()
    end

    socket =
      socket
      |> assign(%{
        present: CookieFile.present?(),
        validate_icon: "hero-check-badge",
        validate_tooltip: "Validate cookies file",
        checking: false,
        config_saved: false,
        config_error: nil
      })
      |> assign_from_setting(Settings.record())
      |> allow_upload(:cookies, accept: ~w(.txt), max_entries: 1, max_file_size: 5_000_000)

    {:ok, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_cookies", _params, socket) do
    consume_uploaded_entries(socket, :cookies, fn %{path: path}, _entry ->
      {:ok, CookieFile.save_from_path(path)}
    end)

    CookieHealth.perform_check_and_update()

    {:noreply,
     socket
     |> assign(present: CookieFile.present?())
     |> assign_from_setting(Settings.record())}
  end

  def handle_event("clear_cookies", _params, socket) do
    CookieFile.clear()

    Settings.update_setting(Settings.record(), %{
      cookie_health_status: "not_configured",
      cookie_health_last_error: nil,
      cookie_health_cookie_digest: nil
    })

    {:noreply,
     socket
     |> assign(present: false)
     |> assign_from_setting(Settings.record())}
  end

  def handle_event("validate_cookies", _params, socket) do
    {icon, tooltip} =
      case CookieFile.validate() do
        {:ok, %{total: total, active: active, expired: 0}} ->
          {"hero-check", "Valid: #{total} cookie(s), #{active} active"}

        {:ok, %{total: total, expired: expired}} when expired == total ->
          {"hero-x-mark", "All #{total} cookie(s) are expired"}

        {:ok, %{total: total, active: active, expired: expired}} ->
          {"hero-exclamation-triangle", "#{active} of #{total} active, #{expired} expired"}

        {:error, :empty} ->
          {"hero-x-mark", "File is empty"}

        {:error, :invalid} ->
          {"hero-x-mark", "Not a valid Netscape cookies file"}
      end

    Process.send_after(self(), :reset_validate_icon, 6_000)

    {:noreply, assign(socket, validate_icon: icon, validate_tooltip: tooltip)}
  end

  def handle_event("test_cookie_health", _params, socket) do
    socket = assign(socket, checking: true)

    HealthCheckWorker.kickoff_manual()

    {:noreply, socket}
  end

  def handle_event("save_monitoring_config", params, socket) do
    enabled = params["cookie_health_monitoring_enabled"] == "true"

    interval =
      case Integer.parse(params["cookie_health_check_interval_hours"] || "6") do
        {int, _} -> int
        _ -> 6
      end

    canary = params["cookie_health_canary_url"]

    attrs = %{
      cookie_health_monitoring_enabled: enabled,
      cookie_health_check_interval_hours: interval,
      cookie_health_canary_url: canary
    }

    setting = Settings.record()

    case Settings.update_setting(setting, attrs) do
      {:ok, updated} ->
        if !setting.cookie_health_monitoring_enabled && updated.cookie_health_monitoring_enabled do
          HealthCheckWorker.kickoff_manual()
        end

        Process.send_after(self(), :reset_config_saved, 3_000)
        {:noreply, socket |> assign_from_setting(updated) |> assign(config_saved: true, config_error: nil)}

      {:error, changeset} ->
        error_msg =
          Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, assign(socket, config_saved: false, config_error: error_msg)}
    end
  end

  def handle_info(:reset_validate_icon, socket) do
    {:noreply, assign(socket, validate_icon: "hero-check-badge", validate_tooltip: "Validate cookies file")}
  end

  def handle_info(:reset_config_saved, socket) do
    {:noreply, assign(socket, config_saved: false)}
  end

  def handle_info({:cookie_health_updated, updated_setting, result}, socket) do
    {:noreply,
     socket
     |> assign_from_setting(updated_setting)
     |> assign(
       checking: false,
       health_details: result[:details] || details_for_status(updated_setting.cookie_health_status)
     )}
  end

  defp assign_from_setting(socket, setting) do
    assign(socket, %{
      health_status: setting.cookie_health_status || "not_configured",
      last_checked_at: setting.cookie_health_last_checked_at,
      last_authenticated_at: setting.cookie_health_last_authenticated_at,
      last_error: setting.cookie_health_last_error,
      monitoring_enabled: setting.cookie_health_monitoring_enabled || false,
      check_interval_hours: setting.cookie_health_check_interval_hours || 6,
      canary_url: setting.cookie_health_canary_url || "",
      health_details: details_for_status(setting.cookie_health_status || "not_configured")
    })
  end

  defp status_label("authenticated"), do: "Authenticated"
  defp status_label("auth_unverified"), do: "Unverified Auth"
  defp status_label("expired"), do: "Expired"
  defp status_label("malformed"), do: "Malformed"
  defp status_label("authentication_rejected"), do: "Auth Rejected"
  defp status_label("canary_unavailable"), do: "Canary Unavailable"
  defp status_label("network_error"), do: "Network Error"
  defp status_label("not_configured"), do: "Not Configured"
  defp status_label(_), do: "Unknown"

  defp status_badge_class("authenticated"), do: "theme-badge-success"
  defp status_badge_class("auth_unverified"), do: "theme-badge-info"
  defp status_badge_class("expired"), do: "theme-badge-warning"
  defp status_badge_class("malformed"), do: "theme-badge-error"
  defp status_badge_class("authentication_rejected"), do: "theme-badge-error"
  defp status_badge_class("canary_unavailable"), do: "theme-badge-warning"
  defp status_badge_class("network_error"), do: "theme-badge-warning"
  defp status_badge_class(_), do: "bg-theme-surface-4 text-theme-on-surface-muted"

  defp details_for_status("authenticated"),
    do: "Authentication confirmed against auth-gated canary."

  defp details_for_status("auth_unverified"),
    do: "Cookies are valid offline, but no auth-gated canary verified authentication."

  defp details_for_status("expired"),
    do: "Cookies are past expiration date. Please export and upload fresh cookies."

  defp details_for_status("malformed"),
    do: "File is not in valid Netscape format. Please re-export cookies."

  defp details_for_status("authentication_rejected"),
    do: "YouTube rejected authentication. Sign-in or new cookies required."

  defp details_for_status("canary_unavailable"),
    do: "Canary video is unavailable, deleted, or removed."

  defp details_for_status("network_error"),
    do: "Network error or rate limit during health check."

  defp details_for_status("not_configured"),
    do: "No cookies file uploaded."

  defp details_for_status(_),
    do: nil

  defp format_timestamp(nil), do: "Never"
  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_timestamp(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S UTC")

  defp upload_label([]), do: "Choose cookies.txt"
  defp upload_label([entry | _]), do: entry.client_name

  defp error_to_string(:too_large), do: "File is too large (max 5MB)"
  defp error_to_string(:not_accepted), do: "Only .txt files are accepted"
  defp error_to_string(:too_many_files), do: "Only one file can be uploaded"
  defp error_to_string(_), do: "Invalid file"

  defp cookie_help do
    url = "https://github.com/kieraneglin/pinchflat/wiki/Cookies"

    ~s(Upload a Netscape-format <span class="font-mono">cookies.txt</span> to let yt-dlp access age-restricted, ) <>
      ~s(members-only, or bot-gated content. See <a href="#{url}" class="underline decoration-theme-on-surface-muted ) <>
      ~s(decoration-1 hover:text-theme-on-surface hover:decoration-theme-on-surface" target="_blank">the wiki</a> for how to export one)
  end
end
