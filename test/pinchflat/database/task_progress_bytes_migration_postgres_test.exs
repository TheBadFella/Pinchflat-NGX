defmodule Pinchflat.Database.TaskProgressBytesMigrationPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres_only
  @moduletag :migration_schema

  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task

  @version 20_261_106_020_000
  @migration {@version, Pinchflat.Repo.Migrations.WidenTaskProgressBytes}

  setup_all do
    Code.require_file("priv/repo/migrations/20261106020000_widen_task_progress_bytes.exs")
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.delete_all(Task)
      Repo.delete_all(Oban.Job)
      Repo.delete_all(Pinchflat.Media.MediaItem)
      Repo.delete_all(Pinchflat.Sources.Source)
      Repo.delete_all(Pinchflat.Profiles.MediaProfile)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  setup do
    task =
      Pinchflat.TasksFixtures.task_fixture(%{
        progress_downloaded_bytes: 77,
        progress_total_bytes: 77,
        progress_speed_bytes_per_second: 77
      })

    on_exit(fn ->
      Repo.delete_all(Task)
      Repo.delete_all(Oban.Job)
      Repo.delete_all(Pinchflat.Media.MediaItem)
      Repo.delete_all(Pinchflat.Sources.Source)
      Repo.delete_all(Pinchflat.Profiles.MediaProfile)
    end)

    %{task: task}
  end

  test "upgrades a populated integer column without losing byte counters", %{task: task} do
    assert [@version] = Ecto.Migrator.run(Repo, [@migration], :down, step: 1)

    try do
      assert column_type("progress_downloaded_bytes") == "integer"
      assert column_type("progress_total_bytes") == "integer"
      assert column_type("progress_speed_bytes_per_second") == "integer"

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE tasks SET progress_downloaded_bytes = 2147483648 WHERE id = $1", [task.id])
      end
    after
      Ecto.Migrator.run(Repo, [@migration], :up, step: 1)
    end

    assert column_type("progress_downloaded_bytes") == "bigint"
    assert column_type("progress_total_bytes") == "bigint"
    assert column_type("progress_speed_bytes_per_second") == "bigint"
    assert downloaded_size(task.id) == "77"

    Repo.query!(
      "UPDATE tasks SET progress_downloaded_bytes = 5998903849, progress_total_bytes = 5998903849, progress_speed_bytes_per_second = 2500000000 WHERE id = $1",
      [task.id]
    )

    assert downloaded_size(task.id) == "5998903849"
  end

  test "unsafe rollback retains the byte counters and migration", %{task: task} do
    Repo.query!("UPDATE tasks SET progress_downloaded_bytes = 5998903849 WHERE id = $1", [task.id])

    assert_raise RuntimeError, ~r/cannot narrow task progress byte counters/, fn ->
      Ecto.Migrator.run(Repo, [@migration], :down, step: 1)
    end

    assert column_type("progress_downloaded_bytes") == "bigint"
    assert downloaded_size(task.id) == "5998903849"
    assert @version in Ecto.Migrator.migrated_versions(Repo)
  end

  defp column_type(column_name) do
    [[type]] =
      Repo.query!(
        """
        SELECT data_type FROM information_schema.columns
        WHERE table_name = 'tasks' AND column_name = $1 AND table_schema = current_schema()
        """,
        [column_name]
      ).rows

    type
  end

  defp downloaded_size(task_id) do
    [[size]] = Repo.query!("SELECT progress_downloaded_bytes::text FROM tasks WHERE id = $1", [task_id]).rows
    size
  end
end
