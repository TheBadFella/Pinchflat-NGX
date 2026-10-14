defmodule Pinchflat.Database.PostgresMigration do
  @moduledoc "Holds normal processing until the optional PostgreSQL transfer is reviewed."
  import Ecto.Query
  alias Pinchflat.Database
  alias Pinchflat.Database.PostgresMigrationRecord, as: Record
  alias Pinchflat.Database.PostgresTransfer
  alias Pinchflat.Repo

  def source_path, do: Application.get_env(:pinchflat, :sqlite_migration_source)
  def record, do: if(Database.postgres?(), do: Repo.get(Record, 1))

  def pending?,
    do:
      Application.get_env(:pinchflat, :postgres_migration_boot_held, false) or
        match?(%Record{status: status} when status != "completed", record())

  def initialize! do
    if Database.postgres?() and source_path() do
      case record() do
        nil -> Repo.insert!(%Record{id: 1, status: "pending"}, on_conflict: :nothing)
        %Record{status: "running"} -> recover_interrupted()
        _ -> :ok
      end
    end

    Application.put_env(
      :pinchflat,
      :postgres_migration_boot_held,
      match?(%Record{status: status} when status != "completed", record())
    )

    :ok
  end

  def child_spec(config) do
    config |> Oban.child_spec() |> Map.put(:start, {__MODULE__, :start_oban, [config]})
  end

  def start_oban(config) do
    Oban.start_link(prepare_oban_config(config))
  end

  def prepare_oban_config(config) do
    record = record()
    config = if pending?(), do: config, else: Pinchflat.LegacyMigration.prepare_oban_config(config)
    config = if pending?(), do: Keyword.put(config, :plugins, []), else: config
    pauses = if pending?(), do: :all, else: if(record, do: record.paused_queues, else: [])

    queues =
      Enum.map(config[:queues], fn {name, options} ->
        options = if is_integer(options), do: [limit: options], else: options

        if pauses == :all or record,
          do: {name, Keyword.put(options, :paused, pauses == :all or to_string(name) in pauses)},
          else: {name, options}
      end)

    Keyword.put(config, :queues, queues)
  end

  def kickoff do
    if Database.postgres?(), do: start_transfer(), else: {:error, :postgres_required}
  end

  defp start_transfer do
    {count, _} =
      Repo.update_all(from(r in Record, where: r.id == 1 and r.status in ["pending", "failed"]),
        set: [status: "running", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    if count == 1 do
      case Task.Supervisor.start_child(Pinchflat.MigrationTasks, &perform/0) do
        {:ok, _pid} ->
          :ok

        _ ->
          update!(record(), status: "failed", report: %{"error" => "worker_unavailable"})
          {:error, :worker_unavailable}
      end
    else
      {:error, :not_pending}
    end
  end

  def perform do
    directory =
      Application.get_env(:pinchflat, :postgres_backup_directory) ||
        Path.join(Application.fetch_env!(:pinchflat, :extras_directory), "backups")

    case PostgresTransfer.run(source_path(), directory) do
      {:ok, _report} ->
        :ok

      {:error, reason} ->
        update!(record(), status: "failed", report: %{"error" => to_string(reason), "backup_directory" => directory})
    end
  end

  def complete(paused_queues) when is_list(paused_queues) do
    if Database.postgres?(), do: confirm_transfer(paused_queues), else: {:error, :postgres_required}
  end

  def complete(_invalid), do: {:error, :invalid_queues}

  defp confirm_transfer(paused_queues) do
    allowed = Application.fetch_env!(:pinchflat, Oban)[:queues] |> Keyword.keys() |> Enum.map(&to_string/1)

    if Enum.all?(paused_queues, &(&1 in allowed)) do
      case Repo.transaction(fn ->
             record = Repo.one!(from(r in Record, where: r.id == 1, lock: "FOR UPDATE"))
             if record.status != "pending_review", do: Repo.rollback(:not_ready)
             update!(record, status: "completed", paused_queues: paused_queues)
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_queues}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :database_write_failed}
  end

  def queues, do: Application.fetch_env!(:pinchflat, Oban)[:queues] |> Keyword.keys()

  defp recover_interrupted do
    Repo.transaction(fn ->
      if Repo.query!("SELECT pg_try_advisory_xact_lock(870071)").rows == [[true]] do
        Repo.update_all(from(r in Record, where: r.id == 1 and r.status == "running"),
          set: [status: "failed", report: %{"error" => "interrupted"}]
        )
      end
    end)
  end

  defp update!(record, attrs), do: record |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
