defmodule PinchflatWeb.Settings.BackupControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Backups
  alias Pinchflat.Settings

  setup do
    previous = Application.get_env(:pinchflat, :postgres_backup_directory)
    directory = Path.join(System.tmp_dir!(), "backup-page-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    Application.put_env(:pinchflat, :postgres_backup_directory, directory)

    on_exit(fn ->
      Application.put_env(:pinchflat, :postgres_backup_directory, previous)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "has a standalone page with the appropriate database state", %{conn: conn} do
    html = conn |> get(~p"/backups") |> html_response(200)
    assert html =~ "PostgreSQL Backups"
    assert html =~ ~s(href="/backups")
    refute html =~ "Editing Mode:"

    if Pinchflat.Database.postgres?() do
      assert html =~ "Backups to Keep"
      assert html =~ "Create and Download Backup"
    else
      assert html =~ "this installation uses SQLite"
      refute html =~ ~s(action="/backups/retention")
      refute html =~ "Create and Download Backup"
    end
  end

  @tag :postgres_only
  test "lists and downloads completed backups from its own routes", %{conn: conn, directory: directory} do
    filename = "pinchflat-ngx-postgres-20261026-120000-000001-0000000000000001.dump"
    File.write!(Path.join(directory, filename), "synthetic backup for route verification")
    html = conn |> get(~p"/backups") |> html_response(200)
    assert html =~ filename
    assert html =~ ~p"/backups/#{filename}"
    download = get(recycle(conn), ~p"/backups/#{filename}")
    assert response(download, 200) == "synthetic backup for route verification"

    legacy_download = get(recycle(conn), ~p"/settings/backups/#{filename}")
    assert response(legacy_download, 200) == "synthetic backup for route verification"

    extensionless = String.trim_trailing(filename, ".dump")
    assert response(get(recycle(conn), "/backups/#{extensionless}"), 200) == "synthetic backup for route verification"
    assert response(get(recycle(conn), "/settings/backups/#{extensionless}"), 200) ==
             "synthetic backup for route verification"
    assert Backups.download_path(extensionless) == {:error, :invalid_filename}
    assert Backups.download_path("../#{filename}") == {:error, :invalid_filename}
    assert get(recycle(conn), "/backups/../#{filename}") |> redirected_to() == ~p"/backups"
    assert get(recycle(conn), "/settings/backups/../#{filename}") |> redirected_to() == ~p"/backups"
  end

  @tag :postgres_only
  test "saves only retention settings and returns to backups", %{conn: conn} do
    titles = Settings.get!(:notification_include_video_titles)

    result =
      put(conn, ~p"/backups/retention",
        setting: %{
          postgres_backup_retention_count: "2",
          notification_include_video_titles: to_string(!titles)
        }
      )

    assert redirected_to(result) == ~p"/backups"
    assert Settings.get!(:postgres_backup_retention_count) == 2
    assert Settings.get!(:notification_include_video_titles) == titles
  end

  @tag :postgres_only
  test "invalid retention stays on the backup form without changing its value", %{conn: conn} do
    previous = Settings.get!(:postgres_backup_retention_count)
    result = put(conn, ~p"/backups/retention", setting: %{postgres_backup_retention_count: "0"})
    assert html_response(result, 422) =~ "Backups to Keep"
    assert Settings.get!(:postgres_backup_retention_count) == previous
    missing = put(conn, ~p"/backups/retention", setting: %{postgres_backup_retention_count: ""})
    assert redirected_to(missing) == ~p"/backups"
    assert Settings.get!(:postgres_backup_retention_count) == previous
  end

  test "unavailable downloads return to the backup page", %{conn: conn} do
    filename = "pinchflat-ngx-postgres-20261026-120000-000001-0000000000000002.dump"
    result = get(conn, ~p"/backups/#{filename}")
    assert redirected_to(result) == ~p"/backups"

    legacy_result = get(recycle(conn), ~p"/settings/backups/#{filename}")
    assert redirected_to(legacy_result) == ~p"/backups"
  end

  test "rejects invalid or traversal filenames", %{conn: conn} do
    assert conn |> get(~p"/backups/invalid_backup_name.dump") |> redirected_to() == ~p"/backups"
    assert conn |> recycle() |> get(~p"/settings/backups/invalid_backup_name.dump") |> redirected_to() == ~p"/backups"
  end

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

    test "protects the standalone page and backup creation", %{conn: conn} do
      assert conn |> get(~p"/backups") |> response(401) == "Unauthorized"
      assert conn |> recycle() |> post(~p"/backups") |> response(401) == "Unauthorized"
    end
  end
end
