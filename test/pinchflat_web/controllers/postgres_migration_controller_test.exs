defmodule PinchflatWeb.PostgresMigrationControllerTest do
  use PinchflatWeb.ConnCase, async: false
  @moduletag :postgres_only
  alias Pinchflat.Database.PostgresMigrationRecord, as: Record
  alias Pinchflat.Repo

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
end
