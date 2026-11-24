defmodule Pinchflat.Sources.SavedTitleFilter do
  @moduledoc """
  A named title filter regex, stored so that any source's title filter can load it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @name_max_length 80
  @regex_max_length 10_000

  schema "saved_title_filters" do
    field :name, :string
    field :regex, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(saved_title_filter, attrs) do
    saved_title_filter
    |> cast(attrs, [:name, :regex])
    |> update_change(:name, &String.trim/1)
    |> update_change(:regex, &String.trim/1)
    |> validate_required([:name, :regex])
    |> validate_length(:name, max: @name_max_length)
    |> validate_length(:regex, max: @regex_max_length)
    |> unique_constraint(:name, message: "is already used by another stored filter")
  end
end
