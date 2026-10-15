defmodule PinchflatWeb.Plugs.ResponseHeaders do
  @moduledoc "Validates final response headers before the HTTP adapter serializes them."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      Enum.each(conn.resp_headers, fn {key, value} -> put_resp_header(conn, key, value) end)
      conn
    end)
  end
end
