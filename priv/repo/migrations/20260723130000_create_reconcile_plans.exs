defmodule Pinchflat.Repo.Migrations.CreateReconcilePlans do
  use Ecto.Migration

  def change do
    create table(:reconcile_plans) do
      # local: zero-network (moves + backfills possible from stored metadata)
      # online: additionally backfills missing thumbnails/subtitles via light yt-dlp fetches
      # full: additionally re-downloads format-mismatched media
      add :mode, :string, null: false
      # Null source means the plan covers every source
      add :source_id, references(:sources, on_delete: :delete_all), null: true
      add :status, :string, null: false, default: "building"
      add :move_count, :integer, null: false, default: 0
      add :backfill_count, :integer, null: false, default: 0
      add :delete_count, :integer, null: false, default: 0
      add :skip_count, :integer, null: false, default: 0
      add :collision_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :redownload_count, :integer, null: false, default: 0
      add :applied_at, :utc_datetime, null: true
      add :error_message, :text, null: true

      timestamps(type: :utc_datetime)
    end

    create table(:reconcile_plan_items) do
      add :reconcile_plan_id, references(:reconcile_plans, on_delete: :delete_all), null: false
      # Null for source-level artifact rows (series NFO/images)
      add :media_item_id, references(:media_items, on_delete: :delete_all), null: true
      add :source_id, references(:sources, on_delete: :delete_all), null: true
      add :action, :string, null: false
      add :attribute, :string, null: false
      add :from_path, :text, null: true
      add :to_path, :text, null: true
      add :status, :string, null: false, default: "planned"
      add :detail, :text, null: true

      timestamps(type: :utc_datetime)
    end

    create index(:reconcile_plans, [:source_id])
    create index(:reconcile_plan_items, [:reconcile_plan_id, :action])
    create index(:reconcile_plan_items, [:media_item_id])
    create index(:reconcile_plan_items, [:source_id])
  end
end
