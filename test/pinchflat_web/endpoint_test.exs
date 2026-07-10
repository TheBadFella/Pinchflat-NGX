defmodule PinchflatWeb.EndpointTest do
  use PinchflatWeb.ConnCase, async: false

  describe "static file serving" do
    test "serves digested top-level icon filenames instead of routing them", %{conn: conn} do
      # In prod, `~p"/apple-touch-icon.png"` resolves to the digested filename,
      # which Plug.Static's `only:` (literal segment match) rejected — every
      # browser icon request fell through and 404'd in the router. The
      # `only_matching:` prefixes must let these through.
      static_dir = Application.app_dir(:pinchflat, "priv/static")
      digested_filename = "apple-touch-icon-0123456789abcdef.png"
      digested_path = Path.join(static_dir, digested_filename)
      File.cp!(Path.join(static_dir, "apple-touch-icon.png"), digested_path)
      on_exit(fn -> File.rm(digested_path) end)

      conn = get(conn, "/#{digested_filename}")

      assert conn.status == 200
    end
  end
end
