defmodule Pinchflat.DeletionHistory.DeletionEvent do
  @moduledoc """
  A record of a deleted source or of media files deleted from a media item.
  Names and URLs are copied at deletion time so the record outlives them.
  """

  use Ecto.Schema

  @reasons [:user, :retention, :download_cutoff, :keep_newest, :media_profile_deleted]

  schema "deletion_events" do
    field :kind, Ecto.Enum, values: [:source, :media_files]
    field :reason, Ecto.Enum, values: @reasons
    field :source_id, :integer
    field :source_name, :string
    field :source_url, :string
    field :collection_type, :string
    field :media_item_id, :integer
    field :media_id, :string
    field :media_title, :string
    field :item_count, :integer
    field :files_deleted, :boolean, default: false

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Returns the reasons a deletion can be recorded with.
  """
  def reasons, do: @reasons
end
