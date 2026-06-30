defmodule Pinchflat.Repo.Migrations.AddYtDlpUpdatePolicyToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # How the yt-dlp executable should be kept up to date. One of:
      # "stable", "nightly", "nightly_frozen", "nightly_until_stable", "pinned"
      add :yt_dlp_update_policy, :string, default: "stable", null: false
      # The exact version to install when the policy is "pinned"
      add :yt_dlp_pinned_version, :string
      # The nightly version we jumped to when the policy is "nightly_until_stable".
      # Used to decide when stable has caught up so we can revert automatically.
      add :yt_dlp_nightly_baseline, :string
    end
  end
end
