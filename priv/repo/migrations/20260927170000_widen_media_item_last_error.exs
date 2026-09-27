defmodule Pinchflat.Repo.Migrations.WidenMediaItemLastError do
  use Ecto.Migration

  def change do
    if Pinchflat.Database.postgres?() do
      alter table(:media_items) do
        modify :last_error, :text, from: :string
      end
    end
  end
end
