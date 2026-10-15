defmodule PinchflatWeb.ApiDocsController do
  @moduledoc """
  Controller for serving the Scalar API documentation UI.
  """

  use PinchflatWeb, :controller

  # sobelow_skip ["XSS.SendResp"]
  def index(conn, _params) do
    base_route_path = Application.get_env(:pinchflat, :base_route_path, "/")
    spec_url = Path.join(base_route_path, "/api/spec")

    html = """
    <!DOCTYPE html>
    <html>
      <head>
        <title>Pinchflat-ngx API Documentation</title>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
      </head>
      <body>
        <script
          id="api-reference"
          type="application/json"
          data-url="#{spec_url}"
          data-configuration='{"proxyUrl":""}'
          data-theme="default"
        ></script>
        <script
          src="https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.73.0/dist/browser/standalone.js"
          integrity="sha384-OKyMdsDX84ypSZEhVun8YElXk5c2GQaH3EXPOc6ItmVcLDUAvKHYwvDLvAgsqVtB"
          crossorigin="anonymous"
        ></script>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
