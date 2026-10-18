defmodule PinchflatWeb.Sources.ImportLive do
  @moduledoc "Reviews a bounded text import and processes one source at a time with visible progress."
  use PinchflatWeb, :live_view

  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Sources

  @impl true
  def mount(_params, session, socket) do
    profile = Repo.get(MediaProfile, session["profile_id"])

    {:ok,
     assign(socket,
       urls: session["urls"],
       remaining: session["urls"],
       profile: profile,
       duplicates: session["duplicates"],
       results: [],
       current: nil,
       started: false,
       running: false,
       cancel_requested: false,
       error:
         if(profile,
           do: nil,
           else: "The selected profile no longer exists. Choose another file and profile."
         )
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-5">
      <h3 class="font-semibold text-theme-on-surface">Review sources</h3>
      <p :if={@profile}>Media Profile: {@profile.name}</p>
      <p>
        {@duplicates} repeated {if @duplicates == 1, do: "line", else: "lines"} skipped. {length(@urls)} {if length(@urls) ==
                                                                                                               1,
                                                                                                             do: "URL",
                                                                                                             else: "URLs"} to check.
      </p>
      <p class="text-sm text-theme-on-surface-muted">
        URLs are checked during import. New sources use the selected profile and can start indexing and downloading.
        Keep this page open. Cancel stops after the current source; sources already added are kept.
      </p>
      <p :if={@error} role="alert" class="theme-status-error">{@error}</p>
      <div class="flex flex-wrap gap-3">
        <.button :if={!@started && @profile} id="confirm-import" phx-click="start">Import Sources</.button>
        <.button :if={@running} id="cancel-import" phx-click="cancel" disabled={@cancel_requested}>
          {if @cancel_requested, do: "Stopping after current source", else: "Cancel import"}
        </.button>
        <.link href={~p"/sources/import"} class="theme-button theme-outline-button">Choose another file</.link>
      </div>
      <div :if={@started} role="status" aria-live="polite">
        {Enum.count(@results, &(&1.status == :added))} added, {Enum.count(@results, &(&1.status == :existing))} already exist, {Enum.count(
          @results,
          &(&1.status == :failed)
        )} failed. {length(@results)} of {length(@urls)} checked. {cond do
          @cancel_requested && !@running -> "Import cancelled."
          @running -> "Import in progress."
          true -> "Import finished."
        end}
      </div>
      <p :if={@current} role="status" class="break-all">Checking: {@current}</p>
      <ul :if={!@started} class="space-y-2">
        <li :for={url <- @urls} class="break-all">{url}</li>
      </ul>
      <ul class="space-y-2">
        <li :for={result <- Enum.reverse(@results)} class="break-all">
          {result.message}: {result.url}
        </li>
      </ul>
    </section>
    """
  end

  @impl true
  def handle_event("start", _, %{assigns: %{started: false, profile: %MediaProfile{}}} = socket) do
    {:noreply, socket |> assign(started: true, running: true) |> import_next()}
  end

  def handle_event("start", _, socket), do: {:noreply, socket}

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, :cancel_requested, true)}
  end

  @impl true
  def handle_async(:import_row, result, socket) do
    row =
      case result do
        {:ok, {:ok, _source}} ->
          %{status: :added, message: "Added"}

        {:ok, {:error, %Ecto.Changeset{} = changeset}} ->
          if Enum.any?(changeset.errors, fn {_, {_, opts}} -> opts[:constraint] == :unique end),
            do: %{status: :existing, message: "Already exists"},
            else: %{status: :failed, message: import_error_message(changeset)}

        _ ->
          %{status: :failed, message: "Could not add; check diagnostics before retrying"}
      end

    row = Map.put(row, :url, socket.assigns.current)
    socket = assign(socket, results: [row | socket.assigns.results], current: nil)
    {:noreply, import_next(socket)}
  end

  defp import_error_message(changeset) do
    changeset.errors
    |> Enum.map_join("; ", fn {field, error} ->
      "#{Phoenix.Naming.humanize(field)} #{PinchflatWeb.CoreComponents.translate_error(error)}"
    end)
  end

  defp import_next(%{assigns: %{cancel_requested: true}} = socket), do: assign(socket, running: false)
  defp import_next(%{assigns: %{remaining: []}} = socket), do: assign(socket, running: false)

  defp import_next(socket) do
    if Pinchflat.YoutubeBrowser.Intake.migration_hold_active?() do
      assign(socket, running: false, error: "Import stopped for migration review. Sources already added are kept.")
    else
      [url | remaining] = socket.assigns.remaining
      profile_id = socket.assigns.profile.id

      socket
      |> assign(current: url, remaining: remaining)
      |> start_async(:import_row, fn ->
        Sources.create_source(%{"original_url" => url, "media_profile_id" => profile_id})
      end)
    end
  end
end
