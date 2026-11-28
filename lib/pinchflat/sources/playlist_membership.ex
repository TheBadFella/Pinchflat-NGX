defmodule Pinchflat.Sources.PlaylistMembership do
  @moduledoc """
  The playlist a channel source's video is filed under when the source sorts
  downloads into playlist subfolders. Each video has at most one row: the first
  of the channel's playlists that contains it.
  """

  use Ecto.Schema

  alias Pinchflat.Sources.Source

  schema "playlist_memberships" do
    field :media_id, :string
    field :playlist_id, :string
    field :playlist_title, :string

    belongs_to :source, Source

    timestamps(type: :utc_datetime)
  end
end
