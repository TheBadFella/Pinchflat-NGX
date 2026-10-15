defmodule Pinchflat.Database.PostgresMigrationApprovalTest do
  use ExUnit.Case, async: false
  @moduletag :postgres_only
  alias Pinchflat.Database.PostgresMigration, as: Migration
  alias Pinchflat.Database.PostgresMigrationRecord, as: Record
  alias Pinchflat.Repo

  test "failed approval stays held and can be retried after the database recovers" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get(Record, 1) == nil
      record = Repo.insert!(%Record{id: 1, status: "pending_review", report: %{"owned_test" => "approval_failure"}})

      try do
        Repo.query!("""
        CREATE FUNCTION lab_approval_failure() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.status = 'completed' THEN RAISE EXCEPTION 'owned approval failure'; END IF;
          RETURN NEW;
        END $$
        """)

        Repo.query!(
          "CREATE TRIGGER lab_approval_failure BEFORE UPDATE ON postgres_migration_records FOR EACH ROW EXECUTE FUNCTION lab_approval_failure()"
        )

        assert {:error, :database_write_failed} = Migration.complete(["media_fetching"])
        assert Migration.record().status == "pending_review"
        assert Migration.record().paused_queues == []
        assert Migration.pending?()
        assert Repo.query!("SELECT 1").rows == [[1]]

        Repo.query!("DROP TRIGGER lab_approval_failure ON postgres_migration_records")
        assert :ok = Migration.complete(["media_fetching"])
        assert Migration.record().status == "completed"
        assert Migration.record().paused_queues == ["media_fetching"]
      after
        Repo.query!("DROP TRIGGER IF EXISTS lab_approval_failure ON postgres_migration_records")
        Repo.query!("DROP FUNCTION IF EXISTS lab_approval_failure()")
        Repo.delete!(record)
      end
    end)
  end
end
