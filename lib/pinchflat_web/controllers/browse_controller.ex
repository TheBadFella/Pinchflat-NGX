defmodule PinchflatWeb.BrowseController do
  @moduledoc "Renders the YouTube browser inside the application layout."

  use PinchflatWeb, :controller

  def index(conn, _params) do
    render(conn, :index, page_title: "Browse YouTube")
  end
end
