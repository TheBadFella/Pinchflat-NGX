defmodule Pinchflat.Discovery.Suggestion do
  @moduledoc """
  A validated channel suggestion produced by channel discovery.

  The external channel ID is the durable identity. URLs, names, artwork, and
  evidence are refreshed when a later scan sees the same channel.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states [:candidate, :validated, :dismissed, :accepted]

  schema "channel_discovery_suggestions" do
    field :external_channel_id, :string
    field :canonical_url, :string
    field :channel_name, :string
    field :artwork_url, :string
    field :evidence, :string, default: ""
    field :generators, :string, default: ""
    field :score, :integer, default: 0
    field :validated_at, :utc_datetime
    field :state, Ecto.Enum, values: @states, default: :validated

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [
      :external_channel_id,
      :canonical_url,
      :channel_name,
      :artwork_url,
      :evidence,
      :generators,
      :score,
      :validated_at,
      :state
    ])
    |> validate_required([:external_channel_id, :canonical_url, :channel_name, :state])
    |> validate_number(:score, greater_than_or_equal_to: 0)
    |> unique_constraint(:external_channel_id)
  end

  @doc """
  Returns whether the suggestion is hidden from normal discovery results.
  """
  def excluded?(%__MODULE__{state: state}), do: state in [:dismissed, :accepted]

  @doc """
  Returns the states used by persisted discovery suggestions.
  """
  def states, do: @states
end
