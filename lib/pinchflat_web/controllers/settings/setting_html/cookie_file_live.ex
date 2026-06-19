defmodule Pinchflat.Settings.CookieFileLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.Settings.CookieFile

  def render(assigns) do
    ~H"""
    <div>
      <.label>
        Cookies File
        <span :if={@present} class="ml-2 rounded-full bg-meta-3 bg-opacity-20 px-3 py-1 text-xs font-medium text-meta-3">
          Populated
        </span>
        <span :if={!@present} class="ml-2 rounded-full bg-meta-4 px-3 py-1 text-xs font-medium text-bodydark">
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
            "flex cursor-pointer items-center gap-2 rounded-lg border-[1.5px] border-form-strokedark",
            "bg-form-input px-5 py-3 text-sm text-white hover:bg-meta-4"
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
            "flex items-center gap-2 rounded-lg border-2 border-strokedark bg-form-input",
            "px-5 py-3 text-sm text-white hover:bg-meta-4"
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
            "flex items-center gap-2 rounded-lg border-2 border-strokedark bg-form-input",
            "px-5 py-3 text-sm text-meta-1 hover:bg-meta-4"
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
      ~s(members-only, or bot-gated content. See <a href="#{url}" class="underline decoration-bodydark ) <>
      ~s(decoration-1 hover:decoration-white" target="_blank">the wiki</a> for how to export one)
  end
end
