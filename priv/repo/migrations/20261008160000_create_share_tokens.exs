defmodule Pinchflat.Repo.Migrations.CreateShareTokens do
  use Ecto.Migration

  def change do
    create table(:share_tokens) do
      add :name, :string, null: false
      add :token_digest, :string, null: false
      add :media_profile_id, references(:media_profiles, on_delete: :nilify_all)
      add :revoked_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:share_tokens, [:token_digest])
    create index(:share_tokens, [:media_profile_id])
  end
end
