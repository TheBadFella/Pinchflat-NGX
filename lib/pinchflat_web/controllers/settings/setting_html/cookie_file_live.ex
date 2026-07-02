defmodule Pinchflat.Settings.CookieFileLive do
  use PinchflatWeb, :live_view

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
          class={[
            "theme-outline-button flex cursor-pointer items-center gap-2 px-5 py-3 text-sm",
            "hover:border-theme-outline-strong hover:bg-theme-surface-2"
          ]}
        >
          <.icon name="hero-arrow-up-tray" class="h-5 w-5" />
          <span>{upload_label(@uploads.cookies.entries)}</span>
          <.live_file_input upload={@uploads.cookies} class="hidden" />
        </label>

        <.button :if={@uploads.cookies.entries != []} type="submit" rounding="rounded-lg" class="!px-5 !py-3">
          Save File
        </.button>

        <.link
          :if={@present}
          href={~p"/settings/cookies"}
          class={[
            "theme-outline-button flex items-center gap-2 px-5 py-3 text-sm",
            "hover:border-theme-outline-strong hover:bg-theme-surface-2"
          ]}
        >
          <.icon name="hero-arrow-down-tray" class="h-5 w-5" /> Download
        </.link>

        <.icon_button
          :if={@present}
          icon_name={@validate_icon}
          class="h-12 w-12"
          phx-click="validate_cookies"
          tooltip={@validate_tooltip}
          type="button"
        />

        <button
          :if={@present}
          type="button"
          phx-click="clear_cookies"
          data-confirm="Clear the cookies file?"
          class={[
            "theme-danger-button flex items-center gap-2 rounded-m3-sm border px-5 py-3 text-sm"
          ]}
        >
          <.icon name="hero-trash" class="h-5 w-5" /> Clear
        </button>
      </form>

      <.error :for={err <- upload_errors(@uploads.cookies)}>{error_to_string(err)}</.error>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(%{
        present: CookieFile.present?(),
        validate_icon: "hero-check-badge",
        validate_tooltip: "Validate cookies file"
      })
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

    {:noreply, assign(socket, present: CookieFile.present?())}
  end

  def handle_event("clear_cookies", _params, socket) do
    CookieFile.clear()

    {:noreply, assign(socket, present: false)}
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

  def handle_info(:reset_validate_icon, socket) do
    {:noreply, assign(socket, validate_icon: "hero-check-badge", validate_tooltip: "Validate cookies file")}
  end

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
