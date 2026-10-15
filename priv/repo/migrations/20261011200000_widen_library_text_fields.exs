defmodule Pinchflat.Repo.Migrations.WidenLibraryTextFields do
  use Ecto.Migration

  @columns [
    media_profiles: ~w(name output_path_template sub_langs audio_track)a,
    sources:
      ~w(custom_name collection_name original_url series_directory nfo_filepath poster_filepath fanart_filepath banner_filepath output_path_template_override title_filter_regex)a,
    media_items:
      ~w(title original_url media_filepath thumbnail_filepath metadata_filepath nfo_filepath predicted_media_filepath unavailable_reason)a,
    source_metadata: ~w(metadata_filepath fanart_filepath poster_filepath banner_filepath)a,
    media_metadata: ~w(metadata_filepath thumbnail_filepath)a,
    settings: ~w(apprise_server external_base_url youtube_api_key)a,
    settings_backup: ~w(value)a,
    channel_discovery_suggestions: ~w(channel_name)a
  ]

  def up do
    if Pinchflat.Database.postgres?() do
      with_search_trigger(fn ->
        for {table, columns} <- @columns do
          alter table(table) do
            for column <- columns, do: modify(column, :text)
          end
        end

        alter table(:media_items) do
          modify :subtitle_filepaths, {:array, {:array, :text}}
        end
      end)
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      # Check every table before narrowing any column, while concurrent writes are blocked.
      tables = Enum.map_join(@columns, ", ", fn {table, _} -> to_string(table) end)
      repo().query!("LOCK TABLE #{tables} IN ACCESS EXCLUSIVE MODE")

      for {table, columns} <- @columns do
        condition = Enum.map_join(columns, " OR ", &"char_length(#{&1}) > 255")
        %{rows: [[count]]} = repo().query!("SELECT COUNT(*) FROM #{table} WHERE #{condition}")

        if count > 0,
          do:
            raise(
              "cannot narrow library text fields in #{table}: #{count} row(s) exceed varchar(255)"
            )
      end

      %{rows: [[count]]} =
        repo().query!(
          "SELECT COUNT(*) FROM media_items WHERE EXISTS (SELECT 1 FROM unnest(subtitle_filepaths) AS value WHERE char_length(value) > 255)"
        )

      if count > 0, do: raise("cannot narrow subtitle paths: #{count} row(s) exceed varchar(255)")

      with_search_trigger(fn ->
        for {table, columns} <- @columns do
          alter table(table) do
            for column <- columns, do: modify(column, :string)
          end
        end

        alter table(:media_items) do
          modify :subtitle_filepaths, {:array, {:array, :string}}
        end
      end)
    end
  end

  defp with_search_trigger(callback) do
    %{rows: [[definition]]} =
      repo().query!("""
      SELECT pg_get_triggerdef(oid) FROM pg_trigger
      WHERE tgrelid = 'media_items'::regclass AND tgname = 'media_items_search_vector_update'
      """)

    execute("DROP TRIGGER media_items_search_vector_update ON media_items")
    flush()
    callback.()
    flush()
    execute(definition)
  end
end
