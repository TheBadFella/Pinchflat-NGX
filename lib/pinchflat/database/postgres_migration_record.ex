defmodule Pinchflat.Database.PostgresMigrationRecord do
  @moduledoc false
  use Ecto.Schema

  schema "postgres_migration_records" do
    field :status, :string
    field :report, :map, default: %{}
    field :paused_queues, {:array, :string}, default: []
    timestamps(type: :utc_datetime)
  end
end
