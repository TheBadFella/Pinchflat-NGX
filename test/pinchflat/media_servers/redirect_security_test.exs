defmodule Pinchflat.MediaServers.RedirectSecurityTest do
  use ExUnit.Case, async: false

  defmodule RedirectFixture do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, agent) do
      Agent.update(agent, &[{conn.request_path, get_req_header(conn, "x-plex-token")} | &1])

      case conn.request_path do
        "/redirect" -> conn |> put_resp_header("location", "/sink") |> send_resp(302, "redirect")
        "/sink" -> send_resp(conn, 200, "sink")
      end
    end
  end

  test "redirect responses are not followed with media-server credentials" do
    agent = start_supervised!({Agent, fn -> [] end})
    server = start_supervised!({Bandit, plug: {RedirectFixture, agent}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert {:error, "HTTP request failed with status code 302"} =
             Pinchflat.HTTP.HTTPClient.get("http://127.0.0.1:#{port}/redirect", [{"X-Plex-Token", "owned-test-token"}],
               receive_timeout: 10_000
             )

    assert Agent.get(agent, & &1) == [{"/redirect", ["owned-test-token"]}]
  end
end
