defmodule PinchflatWeb.BanditAuthorityTest do
  use ExUnit.Case, async: false

  defmodule HostFixture do
    import Plug.Conn
    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, conn.host)
  end

  test "rejects invalid absolute request authorities while accepting valid ones" do
    server = start_supervised!({Bandit, plug: HostFixture, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert request(port, "http://good.example/") =~ "200 OK"
    assert request(port, "http://good.example@evil.example/") =~ "400 Bad Request"
    assert request(port, "http://ex#am.com/") =~ "400 Bad Request"
  end

  defp request(port, target) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, "GET #{target} HTTP/1.1\r\nHost: good.example\r\nConnection: close\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    response
  end
end
