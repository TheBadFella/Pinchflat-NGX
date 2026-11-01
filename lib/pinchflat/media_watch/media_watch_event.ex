defmodule Pinchflat.MediaWatch.MediaWatchEvent do
  @moduledoc """
  A confirmed watch transition event with notification delivery state.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "media_watch_events" do
    field :media_watch_id, :integer
    field :kind, :string
    field :fingerprint, :string
    field :observed_at, :utc_datetime
    field :old_value, :string
    field :new_value, :string
    field :delivery_state, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :error_summary, :string

    timestamps(type: :utc_datetime)
  end

  @allowed_fields ~w(
    media_watch_id kind fingerprint observed_at old_value new_value
    delivery_state attempts next_attempt_at error_summary
  )a

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, @allowed_fields)
    |> validate_required([:media_watch_id, :kind, :fingerprint, :observed_at])
    |> unique_constraint([:media_watch_id, :kind, :fingerprint])
  end
end
