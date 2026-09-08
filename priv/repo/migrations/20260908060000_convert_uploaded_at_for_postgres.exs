defmodule Pinchflat.Repo.Migrations.ConvertUploadedAtForPostgres do
  use Ecto.Migration

  def up do
    if Pinchflat.Database.postgres?() do
      execute """
      ALTER TABLE media_items
      ALTER COLUMN uploaded_at TYPE timestamp(0) without time zone
      USING uploaded_at::timestamp(0) without time zone
      """
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      execute """
      ALTER TABLE media_items
      ALTER COLUMN uploaded_at TYPE date
      USING uploaded_at::date
      """
    end
  end
end
