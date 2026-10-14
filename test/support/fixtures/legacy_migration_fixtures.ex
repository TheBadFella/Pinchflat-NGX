defmodule Pinchflat.LegacyMigrationFixtures do
  @moduledoc false
  alias Pinchflat.LegacyMigration.Record
  alias Pinchflat.Repo

  def pending_migration_fixture do
    record = Repo.one!(Record)

    record
    |> Ecto.Changeset.change(
      provenance: "legacy_pinchflat",
      status: "pending_review",
      confirmed_at: nil,
      queue_pauses: nil,
      artwork_repairs: nil
    )
    |> Repo.update!()
  end
end
