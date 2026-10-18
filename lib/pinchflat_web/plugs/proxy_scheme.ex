defmodule PinchflatWeb.Plugs.ProxyScheme do
  @moduledoc "Applies forwarded schemes from explicitly trusted proxy addresses."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    forwarded =
      case get_req_header(conn, "x-forwarded-proto") do
        [scheme] when scheme in ["http", "https"] -> scheme
        _ -> nil
      end

    case Application.get_env(:pinchflat, :trusted_proxy_ips) do
      nil ->
        # Preserve legacy generated URLs without trusting headers for session security.
        put_private(conn, :router_scheme, forwarded || Atom.to_string(conn.scheme))

      addresses ->
        conn =
          if conn.remote_ip in addresses and forwarded do
            %{conn | scheme: String.to_existing_atom(forwarded)}
          else
            conn
          end

        put_private(conn, :router_scheme, Atom.to_string(conn.scheme))
    end
  end
end
