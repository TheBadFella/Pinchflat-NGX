defmodule Pinchflat.Repo.Migrations.ClearVideoSourceCutoffs do
  use Ecto.Migration

  # Single video sources never index, and a cutoff can only block the one video
  # the source was added for. The form hid these fields without clearing them.
  def up do
    execute("""
    UPDATE sources
    SET index_cutoff_date = NULL, download_cutoff_date = NULL, download_cutoff_days = NULL
    WHERE collection_type = 'video'
      AND (index_cutoff_date IS NOT NULL OR download_cutoff_date IS NOT NULL OR download_cutoff_days IS NOT NULL)
    """)
  end

  def down, do: :ok
end
