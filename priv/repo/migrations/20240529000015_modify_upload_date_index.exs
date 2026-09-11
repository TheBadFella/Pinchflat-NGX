defmodule Pinchflat.Repo.Migrations.ModifyUploadDateIndex do
  use Ecto.Migration

  def up do
    drop index("media_items", [:upload_date])
    create index("media_items", [:uploaded_at])
  end

  def down do
    # This migration is rolled back before the preceding column rename. At
    # this point the column is still named `uploaded_at`, so restore the
    # original index name on that column and let the rename migration update
    # the indexed column afterward.
    drop index("media_items", [:uploaded_at])
    create index("media_items", [:uploaded_at], name: "media_items_upload_date_index")
  end
end
