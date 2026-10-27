defmodule Pinchflat.MediaWatch.MediaWatch do
  @moduledoc """
  A watch record for a downloaded media item.

  Enrolled prospectively on the first completed local download while the
  configured watch window is enabled. Baseline and identity fields are
  immutable once enrolled.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @archive_states ~w(none preparing published needs_recovery)
  @confirmed_states ~w(unchanged suspected confirmed)

  schema "media_watches" do
    field :media_item_id, :integer
    field :media_item_uuid, Ecto.UUID
    field :media_id, :string
    field :source_id, :integer
    field :source_uuid, Ecto.UUID

    field :started_at, :utc_datetime
    field :ends_at, :utc_datetime

    field :baseline_upstream_duration_seconds, :integer
    field :baseline_visibility, :string

    field :next_check_at, :utc_datetime
    field :last_observed_at, :utc_datetime
    field :last_success_at, :utc_datetime
    field :last_error_at, :utc_datetime
    field :error_count, :integer, default: 0

    field :current_visibility, :string
    field :current_upstream_duration_seconds, :integer
    field :confirmed_change_at, :utc_datetime
    field :released_at, :utc_datetime
    field :release_manifest_sha256, :string
    field :current_reason, :string

    field :suspected_kind, :string
    field :suspected_value, :string
    field :suspected_first_seen_at, :utc_datetime
    field :suspected_count, :integer, default: 0

    field :confirmed_state, :string, default: "unchanged"

    field :observation_version, :integer, default: 0

    field :hold_reason, :string
    field :hold_at, :utc_datetime

    field :original_manifest_path, :string
    field :archive_state, :string, default: "none"

    field :operation_kind, :string
    field :operation_id, Ecto.UUID
    field :lease_owner, :string
    field :lease_generation, :integer, default: 0
    field :lease_expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @allowed_fields ~w(
    media_item_id media_item_uuid media_id source_id source_uuid
    started_at ends_at baseline_upstream_duration_seconds baseline_visibility
    next_check_at last_observed_at last_success_at last_error_at error_count
    current_visibility current_reason current_upstream_duration_seconds confirmed_change_at released_at release_manifest_sha256
    suspected_kind suspected_value suspected_first_seen_at suspected_count
    confirmed_state observation_version
    hold_reason hold_at original_manifest_path archive_state
    operation_kind operation_id lease_owner lease_generation lease_expires_at
  )a

  @doc false
  def changeset(watch, attrs) do
    watch
    |> cast(attrs, @allowed_fields)
    |> validate_required([:media_item_uuid, :media_id, :started_at, :ends_at])
    |> validate_inclusion(:archive_state, @archive_states)
    |> validate_inclusion(:confirmed_state, @confirmed_states)
    |> unique_constraint(:media_item_id)
    |> check_constraint(:archive_state, name: :media_watches_archive_state_check)
    |> check_constraint(:confirmed_state, name: :media_watches_confirmed_state_check)
  end
end
