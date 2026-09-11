defmodule Pinchflat.Repo.Migrations.AddExtractorSleepIntervalToSettings do
  use Ecto.Migration

  def change do
    column_type = if Pinchflat.Database.postgres?(), do: :integer, else: :number

    alter table(:settings) do
      add :extractor_sleep_interval_seconds, column_type, null: false, default: 0
    end
  end
end
