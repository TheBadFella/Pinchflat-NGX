defmodule PinchflatWeb.DiscoveryController do
  @moduledoc """
  Renders Channel Discovery inside the app layout. The LiveView is nested so
  it gets the same sidebar, header, and page padding as the rest of the UI.
  """

  use PinchflatWeb, :controller

  def index(conn, _params) do
    render(conn, :index, page_title: "Channel Discovery")
  end
end
