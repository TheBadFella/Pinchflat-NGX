defmodule Pinchflat.MediaServers.JellyfinConnectionSecurityTest do
  use ExUnit.Case, async: false

  defmodule JellyfinFixture do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, agent) do
      Agent.update(agent, &[{conn.method, conn.request_path} | &1])

      if get_req_header(conn, "authorization") == [~s(MediaBrowser Token="owned-valid-token")] do
        send_resp(conn, if(conn.method == "POST", do: 204, else: 200), "")
      else
        send_resp(conn, 401, "Unauthorized")
      end
    end
  end

  test "authenticates protected connection and refresh endpoints without legacy headers" do
    previous = Application.fetch_env!(:pinchflat, :http_client)
    Application.put_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
    on_exit(fn -> Application.put_env(:pinchflat, :http_client, previous) end)
    requests = start_supervised!({Agent, fn -> [] end})
    server = start_supervised!({Bandit, plug: {JellyfinFixture, requests}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    settings = %{jellyfin_url: "http://127.0.0.1:#{port}", jellyfin_api_key: "owned-valid-token"}

    assert {:ok, :connected} = Pinchflat.MediaServers.Jellyfin.test_connection(settings)
    assert :ok = Pinchflat.MediaServers.Jellyfin.refresh(settings)

    assert {:error, "HTTP request failed with status code 401"} =
             Pinchflat.MediaServers.Jellyfin.test_connection(%{settings | jellyfin_api_key: "owned-invalid-token"})

    assert Enum.reverse(Agent.get(requests, & &1)) == [
             {"GET", "/System/Info"},
             {"POST", "/Library/Refresh"},
             {"GET", "/System/Info"}
           ]
  end
end
