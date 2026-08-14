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
        <.input id={"#{@dom_id_base}_input"} field={f[:enabled]} type="toggle" />
      </.form>
    </div>
    """
  end

  def update(assigns, socket) do
    initial_data = %{
      dom_id_base: dom_id_base(assigns.id),
      source_id: assigns.source.id,
      form: Sources.change_source(%Source{}, assigns.source)
    }

    socket
    |> assign(initial_data)
    |> then(&{:ok, &1})
  end

  def handle_event("update", %{"source" => source_params}, %{assigns: assigns} = socket) do
    assigns.source_id
    |> Sources.get_source!()
    |> Sources.update_source(source_params)

    {:noreply, socket}
  end

  defp dom_id_base(component_id), do: "source_enable_toggle_#{component_id}"
end
