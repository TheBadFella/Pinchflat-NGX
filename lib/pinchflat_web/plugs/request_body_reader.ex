defmodule PinchflatWeb.Plugs.RequestBodyReader do
  @moduledoc """
  Custom body reader for Plug.Parsers that enforces strict request body byte limits
  before parsing payloads on bounded endpoints like /api/share/intake.
  """

  @share_intake_max_bytes 8192

  @doc """
  Reads the request body, restricting /api/share/intake to 8KiB on raw stream bytes
  prior to JSON decoding.
  """
  def read_body(conn, opts) do
    if share_intake_request?(conn) do
      case Plug.Conn.read_body(conn, Keyword.put(opts, :length, @share_intake_max_bytes + 1)) do
        {:ok, body, conn} ->
          if byte_size(body) > @share_intake_max_bytes do
            {:more, body, conn}
          else
            {:ok, body, conn}
          end

        {:more, body, conn} ->
          {:more, body, conn}

        other ->
          other
      end
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  @doc "Recognizes sharing routes, including prefixes and the endpoint's format suffixes."
  def share_intake_request?(conn) do
    case Enum.take(conn.path_info, -3) do
      ["api", "share", action] -> action == "intake" or Path.rootname(action) == "intake"
      _ -> false
    end
  end
end
