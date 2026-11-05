defmodule PinchflatWeb.PostgresMigrationControllerTest do
  use PinchflatWeb.ConnCase, async: false
  @moduletag :postgres_only
  alias Pinchflat.Database.PostgresMigrationRecord, as: Record
  alias Pinchflat.Repo

  test "failed validation shows diagnostics, safe recovery guidance and a retry", %{conn: conn} do
    Repo.delete_all(Record)

    Repo.insert!(%Record{
      id: 1,
      status: "failed",
      report: %{
        "error" => "validation_mismatch",
        "table" => "media_items",
        "source_count" => 502,
        "target_count" => 501,
        "mismatch_type" => "count"
      }
    })

    html = conn |> get("/postgres_migration") |> html_response(200)
    assert html =~ "media_items"
    assert html =~ "Source rows: 502"
    assert html =~ "Target rows: 501"
    assert html =~ "Do not edit the source or delete rows"
    assert html =~ "Retry migration"
    assert html =~ "Checks run automatically before copying"
    assert html =~ "removes older sqlite-before-postgres-*.db snapshots"
  end

  test "older failure reports show the relevant next action without requiring table details", %{conn: conn} do
    Repo.delete_all(Record)
    Repo.insert!(%Record{id: 1, status: "failed", report: %{"error" => "backup_space_unavailable"}})
    html = conn |> get("/postgres_migration") |> html_response(200)
    assert html =~ "Free space on the config filesystem"
    assert html =~ "Retry migration"
    refute html =~ "Source rows:"
  end

  test "recovery actions distinguish source, target, worker and connection failures" do
    for {error, action} <- [
          {"source_unavailable", "Check SQLITE_MIGRATION_SOURCE"},
          {"unsupported_source_version", "Use matching SQLite and PostgreSQL image versions"},
          {"source_foreign_keys", "Do not delete rows to bypass this check"},
          {"target_not_empty", "Existing target data will not be overwritten"},
          {"migration_busy", "Wait and refresh"},
          {"interrupted", "retry here"},
          {"worker_unavailable", "Restart the PostgreSQL container"},
          {"transfer_failed", "PostgreSQL availability, server storage and permissions"}
        ] do
      assert PinchflatWeb.PostgresMigrationHTML.recovery_guidance(error) =~ action
    end
  end

  test "completed migration stops requesting a restart after its boot hold clears", %{conn: conn} do
    old = Application.get_env(:pinchflat, :postgres_migration_boot_held, false)
    on_exit(fn -> Application.put_env(:pinchflat, :postgres_migration_boot_held, old) end)
    Repo.delete_all(Record)

    record =
      Repo.insert!(%Record{id: 1, status: "completed", report: %{"tables" => %{}, "backup" => "/owned/snapshot.db"}})

    Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
    before_restart = conn |> get("/postgres_migration") |> html_response(200)
    assert before_restart =~ "Restart the container to finish."
    assert before_restart =~ "Normal processing is held"
    Application.put_env(:pinchflat, :postgres_migration_boot_held, false)
    after_restart = conn |> get("/postgres_migration") |> html_response(200)
    assert after_restart =~ "Migration is complete."
    refute after_restart =~ "Restart the container to finish."
    refute after_restart =~ "Normal processing is held"
    Repo.update!(Ecto.Changeset.change(record, status: "pending_review"))
    pending = conn |> get("/postgres_migration") |> html_response(200)
    assert pending =~ "Normal processing is held"
    assert pending =~ "Confirm Library and Queue Choices"
  end

  test "every non-completed transfer state holds ordinary browser routes", %{conn: _conn} do
    old = Application.get_env(:pinchflat, :postgres_migration_boot_held, false)
    on_exit(fn -> Application.put_env(:pinchflat, :postgres_migration_boot_held, old) end)
    Application.put_env(:pinchflat, :postgres_migration_boot_held, false)
    Repo.delete_all(Record)
    record = Repo.insert!(%Record{id: 1, status: "pending", report: %{}})

    for status <- ["pending", "running", "failed", "pending_review"] do
      Repo.update!(Ecto.Changeset.change(record, status: status))
      assert redirected_to(get(build_conn(), ~p"/")) == ~p"/postgres_migration"
      assert redirected_to(get(build_conn(), ~p"/sources")) == ~p"/postgres_migration"
    end

    Repo.update!(Ecto.Changeset.change(record, status: "completed"))
    Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
    assert redirected_to(get(build_conn(), ~p"/")) == ~p"/postgres_migration"

    Application.put_env(:pinchflat, :postgres_migration_boot_held, false)
    Pinchflat.Settings.set(onboarding: false)
    assert html_response(get(build_conn(), ~p"/"), 200) =~ "MENU"
    Repo.delete_all(Record)
  end

  test "show is reachable and missing confirmations do not start a transfer", %{conn: conn} do
    old = Application.get_env(:pinchflat, :postgres_migration_boot_held, false)
    on_exit(fn -> Application.put_env(:pinchflat, :postgres_migration_boot_held, old) end)
    Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
    Repo.delete_all(Record)
    Repo.insert!(%Record{id: 1, status: "pending", report: %{}})

    assert html_response(get(conn, ~p"/postgres_migration"), 200) =~ "Migrate to Postgres"

    response = post(build_conn(), ~p"/postgres_migration/start")
    assert redirected_to(response) == ~p"/postgres_migration"
    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "back up"
    assert Repo.get!(Record, 1).status == "pending"
    Repo.delete_all(Record)
  end
end
