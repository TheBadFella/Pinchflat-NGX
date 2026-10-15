defmodule PinchflatWeb.Plugs.ResponseHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PinchflatWeb.Plugs.ResponseHeaders

  test "rejects raw headers inserted after registration for regular and chunked responses" do
    for value <- ["safe\r\nx-smuggled: injected", "safe\nunsafe"], mode <- [:body, :chunks] do
      conn = conn(:get, "/") |> ResponseHeaders.call([])
      conn = %{conn | resp_headers: [{"x-owned-test", value}]}

      assert_raise Plug.Conn.InvalidHeaderError, fn ->
        case mode do
          :body -> send_resp(conn, 200, "body")
          :chunks -> send_chunked(conn, 200)
        end
      end
    end
  end

  test "validates after later callbacks without changing valid repeated headers" do
    conn = conn(:get, "/") |> ResponseHeaders.call([])
    conn = register_before_send(conn, &%{&1 | resp_headers: [{"x-owned-test", "safe\r\ninjected"}]})
    assert_raise Plug.Conn.InvalidHeaderError, fn -> send_resp(conn, 200, "body") end

    headers = [{"set-cookie", "one=1"}, {"set-cookie", "two=2"}, {"x-owned-test", "safe"}]
    conn = conn(:get, "/") |> ResponseHeaders.call([])
    conn = send_resp(%{conn | resp_headers: headers}, 200, "body")
    assert conn.resp_headers == headers
  end
end
