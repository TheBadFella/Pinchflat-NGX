defmodule Pinchflat.Settings.MediaItemOptionHandoff do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinchflat.Sources.Source

  schema "media_item_option_handoffs" do
    belongs_to :source, Source
    field :media_id, :string
    field :contents, :string
    field :generation, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [:source_id, :media_id, :contents, :generation])
    |> validate_required([:source_id, :media_id, :contents, :generation])
    |> validate_length(:media_id, max: 64)
    |> validate_number(:generation, greater_than: 0)
    |> unique_constraint(:source_id)
  end
end
