defmodule Pinchflat.Repo.Migrations.AddDownloadFormatDetailsToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :video_height, :integer
      add :video_codec, :string
      add :audio_codec, :string
      add :max_available_height, :integer
      add :available_video_codecs, :string
    end
  end
end
