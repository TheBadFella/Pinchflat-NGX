defmodule PinchflatWeb.Sources.ImportLive do
  @moduledoc "Reviews bounded text or Takeout CSV imports and processes one source at a time with visible progress."
  use PinchflatWeb, :live_view

  import Ecto.Query, warn: false

  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  @impl true
  def mount(_params, session, socket) do
    profile =
      case Repo.get(MediaProfile, session["profile_id"]) do
        %MediaProfile{marked_for_deletion_at: nil} = profile -> profile
        _ -> nil
      end

    channel_ids = session["channel_ids"] || %{}
    ids = Map.values(channel_ids)

    existing_ids =
      Repo.all(
        from s in Source, where: s.collection_type == :channel and s.collection_id in ^ids, select: s.collection_id
      )

    existing_urls =
      channel_ids
      |> Enum.filter(fn {_url, id} -> id in existing_ids end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    {:ok,
     assign(socket,
       urls: session["urls"],
       remaining: session["urls"],
       profile: profile,
       duplicates: session["duplicates"],
       titles: session["titles"] || %{},
       channel_ids: channel_ids,
       row_errors: session["row_errors"] || [],
       download_media: Map.get(session, "download_media", true),
       existing_urls: existing_urls,
       new_count: length(session["urls"]) - MapSet.size(existing_urls),
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
      <p :if={@download_media} class="text-sm text-theme-on-surface-muted">
        URLs are checked during import. New sources use the selected profile and can start indexing and downloading.
      </p>
      <p :if={!@download_media} class="text-sm text-theme-on-surface-muted">
        CSV imports create monitored sources with downloads paused. Use Resume selected on Sources when ready.
        Existing channels keep their current profile, monitoring and download settings.
      </p>
      <p class="text-sm text-theme-on-surface-muted">
        Keep this page open. Closing it or restarting the app can interrupt the import; progress is not saved.
        Cancel stops after the current source; sources already added are kept.
      </p>
      <div :if={@row_errors != []} class="rounded-m3-sm bg-theme-surface-3 p-3" role="alert">
        <h4 class="font-medium text-theme-on-surface">Rejected CSV rows: {length(@row_errors)}</h4>
        <p class="text-sm text-theme-on-surface-muted">
          These rows will not be imported. Correct them in the file and upload again.
        </p>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={error <- @row_errors}>Row {error.row}: {error.message}</li>
        </ul>
      </div>
      <p :if={@urls == []} class="text-sm text-theme-on-surface-muted">No valid sources to import.</p>
      <p :if={@urls != [] && @new_count == 0} class="text-sm text-theme-on-surface-muted">No new sources to import.</p>
      <p :if={@error} role="alert" class="theme-status-error">{@error}</p>
      <div class="flex flex-wrap gap-3">
        <.button :if={!@started && @profile && @new_count > 0} id="confirm-import" phx-click="start">Import Sources</.button>
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
        <li :for={url <- @urls} class="space-y-1 break-words [overflow-wrap:anywhere]">
          <p :if={Map.get(@titles, url, "") != ""} class="font-medium">{@titles[url]}</p>
          <p class="text-sm text-theme-on-surface-muted">{url}</p>
          <span :if={MapSet.member?(@existing_urls, url)} class="text-xs font-medium text-theme-on-surface-muted">
            Already exists — left unchanged
          </span>
        </li>
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
        {:ok, :existing} ->
          %{status: :existing, message: "Already exists"}

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
    profile_id = socket.assigns.profile.id

    cond do
      Pinchflat.YoutubeBrowser.Intake.migration_hold_active?() ->
        assign(socket, running: false, error: "Import stopped for migration review. Sources already added are kept.")

      !Repo.exists?(from p in MediaProfile, where: p.id == ^profile_id and is_nil(p.marked_for_deletion_at)) ->
        assign(socket,
          running: false,
          error: "The selected media profile is no longer available. Sources already added are kept."
        )

      true ->
        [url | remaining] = socket.assigns.remaining
        channel_id = socket.assigns.channel_ids[url]

        attrs = %{
          "original_url" => url,
          "media_profile_id" => profile_id,
          "download_media" => socket.assigns.download_media
        }

        socket
        |> assign(current: url, remaining: remaining)
        |> start_async(:import_row, fn -> import_source(attrs, channel_id) end)
    end
  end

  defp import_source(attrs, nil), do: Sources.create_source(attrs)

  defp import_source(attrs, channel_id) do
    if Repo.exists?(from s in Source, where: s.collection_type == :channel and s.collection_id == ^channel_id) do
      :existing
    else
      Sources.create_source(attrs)
    end
  end
end
