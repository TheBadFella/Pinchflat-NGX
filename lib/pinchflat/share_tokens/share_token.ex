defmodule Pinchflat.ShareTokens.ShareToken do
  @moduledoc """
  Schema for scoped share intake credentials.

  Tokens are bound to a specific media profile and allow unprivileged callers
  to submit single-video YouTube URLs for normal intake. The raw secret is never
  stored; only its SHA-256 digest is persisted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Profiles.MediaProfile

  @type t :: %__MODULE__{}

  schema "share_tokens" do
    field :name, :string
    field :token_digest, :string
    field :revoked_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :media_profile, MediaProfile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for inserting or updating a share token.
  """
  def changeset(share_token, attrs) do
    share_token
    |> cast(attrs, [:name, :token_digest, :media_profile_id, :revoked_at, :last_used_at, :expires_at])
    |> validate_required([:name, :token_digest, :media_profile_id])
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:media_profile_id)
    |> unique_constraint(:token_digest)
  end

  @doc """
  Predicate function checking whether the token is currently active.
  """
  def active?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true

  def active?(%__MODULE__{revoked_at: nil, expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def active?(%__MODULE__{}), do: false
end
