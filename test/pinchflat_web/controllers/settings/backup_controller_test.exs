defmodule PinchflatWeb.Settings.BackupControllerTest do
  use PinchflatWeb.ConnCase

  @moduletag :sqlite_only

  describe "authorization boundary" do
    setup do
      original_username = Application.get_env(:pinchflat, :basic_auth_username)
      original_password = Application.get_env(:pinchflat, :basic_auth_password)

      Application.put_env(:pinchflat, :basic_auth_username, "backup-user")
      Application.put_env(:pinchflat, :basic_auth_password, "backup-password")

      on_exit(fn ->
        Application.put_env(:pinchflat, :basic_auth_username, original_username)
        Application.put_env(:pinchflat, :basic_auth_password, original_password)
      end)

      :ok
    end

    test "uses the authenticated browser pipeline", %{conn: conn} do
      conn =
        get(
          conn,
          ~p"/settings/backups/pinchyt-postgres-20260911-120000-000001-0000000000000001.dump"
        )

      assert response(conn, 401) == "Unauthorized"
    end
  end
end
