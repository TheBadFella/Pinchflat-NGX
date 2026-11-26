defmodule PinchflatWeb.BrowserUserscriptController do
  use PinchflatWeb, :controller

  @spec youtube_quick_add(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def youtube_quick_add(conn, _params) do
    base_url = PinchflatWeb.DeploymentUrl.base_url(conn)
    body = PinchflatWeb.BrowserUserscripts.youtube_quick_add_source(base_url)

    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, body)
  end
end
