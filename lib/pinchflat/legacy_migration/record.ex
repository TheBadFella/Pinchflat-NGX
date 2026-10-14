defmodule Pinchflat.LegacyMigration.Record do
  @moduledoc false
  use Ecto.Schema

  schema "legacy_migration_records" do
    field :provenance, :string
    field :status, :string
    field :original_max_version, :integer
    field :original_source_count, :integer
    field :confirmed_at, :utc_datetime
    field :queue_pauses, :map
    field :artwork_repairs, :map
    timestamps(type: :utc_datetime)
  end
end
