defmodule Pinchflat.MediaServers.PlexConnectionSecurityTest do
  use ExUnit.Case, async: false

  defmodule PlexFixture do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      if conn.request_path == "/identity" or get_req_header(conn, "x-plex-token") == ["owned-valid-token"] do
        send_resp(conn, 200, "<MediaContainer/>")
      else
        send_resp(conn, 401, "Unauthorized")
      end
    end
  end

  test "rejects invalid credentials even when Plex identity is public" do
    previous = Application.fetch_env!(:pinchflat, :http_client)
    Application.put_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
    on_exit(fn -> Application.put_env(:pinchflat, :http_client, previous) end)
    server = start_supervised!({Bandit, plug: PlexFixture, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    settings = %{plex_url: "http://127.0.0.1:#{port}", plex_token: "owned-invalid-token"}

    assert {:error, "HTTP request failed with status code 401"} =
             Pinchflat.MediaServers.Plex.test_connection(settings)

    assert {:ok, :connected} =
             Pinchflat.MediaServers.Plex.test_connection(%{settings | plex_token: "owned-valid-token"})
  end
end
