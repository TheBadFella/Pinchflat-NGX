defmodule Pinchflat.Sources.PlaylistMembership do
  @moduledoc """
  The playlist a channel source's video is filed under when the source sorts
  downloads into playlist subfolders. A video has one row for each of the
  channel's playlists that contains it; `position` orders them as the channel
  does, and the lowest decides the subfolder.
  """

  use Ecto.Schema

  alias Pinchflat.Sources.Source

  schema "playlist_memberships" do
    field :media_id, :string
    field :playlist_id, :string
    field :playlist_title, :string
    field :position, :integer
    # The video's place within its playlist, for playlist files.
    field :entry_index, :integer

    belongs_to :source, Source

    timestamps(type: :utc_datetime)
  end
end
