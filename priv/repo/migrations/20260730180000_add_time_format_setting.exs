defmodule Pinchflat.Repo.Migrations.AddTimeFormatSetting do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Clock used when rendering timestamps in the UI: "24h" | "12h".
      # 12h/24h is a locale convention, but the container's locale is fixed, so
      # this is a user choice rather than something derived from the environment
      add :time_format, :string, default: "24h", null: false
    end
  end
end
