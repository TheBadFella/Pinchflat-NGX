defmodule Pinchflat.Repo.Migrations.RestoreUnsavedAcceptedDiscoverySuggestions do
  use Ecto.Migration

  # Accept used to mark a suggestion accepted before New Source was saved, so
  # closing the form hid the channel from every later scan. Restore accepted
  # suggestions that never became a channel source.
  def up do
    execute("""
    UPDATE channel_discovery_suggestions
    SET state = 'validated'
    WHERE state = 'accepted'
      AND external_channel_id NOT IN (
        SELECT collection_id FROM sources
        WHERE collection_type = 'channel' AND collection_id IS NOT NULL
      )
    """)
  end

  def down, do: :ok
end
