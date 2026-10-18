defmodule Pinchflat.Repo.Migrations.AddNotificationIncludeVideoTitles do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :notification_include_video_titles, :boolean, default: false, null: false
    end
  end
end
