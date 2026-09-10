defmodule PinchflatWeb.Sources.SourceLive.SourceEnableToggle do
  use PinchflatWeb, :live_component

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  def render(assigns) do
    ~H"""
    <div>
      <.form
        :let={f}
        for={@form}
        id={"#{@dom_id_base}_form"}
        phx-change="update"
        phx-target={@myself}
        class="enabled_toggle_form"
      >
        <.input
          id={"#{@dom_id_base}_input"}
          field={f[:enabled]}
          type="toggle"
          aria_label={"Monitor #{source_label(@source)}"}
        />
        <p :if={@error} class="mt-1 text-xs theme-status-error" role="alert">{@error}</p>
      </.form>
    </div>
    """
  end

  def update(assigns, socket) do
    initial_data = %{
      dom_id_base: dom_id_base(assigns.id),
      source_id: assigns.source.id,
      source: assigns.source,
      error: nil,
      form: Sources.change_source(%Source{}, assigns.source)
    }

    socket
    |> assign(initial_data)
    |> then(&{:ok, &1})
  end

  def handle_event("update", %{"source" => source_params}, %{assigns: assigns} = socket) do
    source = Sources.get_source!(assigns.source_id)

    case Sources.update_source(source, source_params) do
      {:ok, updated_source} ->
        send(self(), {:source_enabled_updated, updated_source.id})

        {:noreply,
         assign(socket,
           source: updated_source,
           error: nil,
           form: Sources.change_source(updated_source)
         )}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           source: source,
           error: "Could not update monitoring state.",
           form: Sources.change_source(source)
         )}
    end
  end

  defp source_label(%{custom_name: custom_name}) when is_binary(custom_name), do: custom_name
  defp source_label(_source), do: "source"

  defp dom_id_base(component_id), do: "source_enable_toggle_#{component_id}"
end
