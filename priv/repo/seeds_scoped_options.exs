# Synthetic state for scoped yt-dlp options browser acceptance.
#
# Run inside the dev container:
#   mix run priv/repo/seeds_scoped_options.exs
#
# The seed is intentionally idempotent for its own deterministic demo records.
# It overwrites only the config files it owns and does not delete unrelated data.

defmodule Pinchflat.Seeds.ScopedOptions do
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Settings.YtDlpConfigFile
  alias Pinchflat.Sources.Source

  def run do
    profile_name = "Scoped Options Demo"
    plain_profile_name = "Scoped Options Plain"
    source_name = "Scoped Options Demo Source"
    item_one_media_id = "scopedDemo01"
    item_two_media_id = "scopedDemo02"

    {:ok, false} = Settings.set(onboarding: false)
    Repo.delete_all(Oban.Job)
    :ok = YtDlpConfigFile.save("--verbose\n")

    profile = ensure_profile(profile_name)
    plain_profile = ensure_profile(plain_profile_name)

    source = ensure_source(source_name, profile.id)
    item_one = ensure_item(source, item_one_media_id, "Scoped Options Demo Video One")
    item_two = ensure_item(source, item_two_media_id, "Scoped Options Demo Video Two")

    :ok = YtDlpConfigFile.save_scope(:profile, profile.id, "--retries 5\n", :any)
    :ok = YtDlpConfigFile.clear_scope(:profile, plain_profile.id, :any)
    :ok = YtDlpConfigFile.save_scope(:source, source.id, "--sub-format srt\n", :any)
    :ok = YtDlpConfigFile.save_scope(:media_item, item_one.id, "--embed-chapters\n", :any)
    :ok = YtDlpConfigFile.clear_scope(:media_item, item_two.id, :any)

    {:ok, profile_path} = YtDlpConfigFile.scope_path(:profile, profile.id)
    {:ok, plain_profile_path} = YtDlpConfigFile.scope_path(:profile, plain_profile.id)
    {:ok, source_path} = YtDlpConfigFile.scope_path(:source, source.id)
    {:ok, item_one_path} = YtDlpConfigFile.scope_path(:media_item, item_one.id)
    {:ok, item_two_path} = YtDlpConfigFile.scope_path(:media_item, item_two.id)

    IO.puts("""
    Scoped yt-dlp options seed complete.

    Profiles:
      #{profile_name} (id=#{profile.id}) -> #{profile_path}
      #{plain_profile_name} (id=#{plain_profile.id}) -> #{plain_profile_path}

    Source:
      #{source_name} (id=#{source.id}) -> #{source_path}

    Media items:
      #{item_one.title} (id=#{item_one.id}, media_id=#{item_one.media_id}) -> #{item_one_path}
      #{item_two.title} (id=#{item_two.id}, media_id=#{item_two.media_id}) -> #{item_two_path}

    Base config:
      #{YtDlpConfigFile.filepath()}

    Open http://localhost:4008 after starting the server.
    """)
  end

  defp ensure_profile(name) do
    case Repo.get_by(MediaProfile, name: name) do
      nil ->
        {:ok, profile} = Profiles.create_media_profile(%{name: name})
        profile

      profile ->
        profile
    end
  end

  defp ensure_source(source_name, media_profile_id) do
    case Repo.get_by(Source, custom_name: source_name) do
      nil ->
        attrs = %{
          custom_name: source_name,
          collection_name: "Scoped Options Demo Channel",
          collection_id: "scoped-options-demo-channel",
          collection_type: :channel,
          original_url: "https://www.youtube.com/@ScopedOptionsDemo",
          index_frequency_minutes: 1440,
          fast_index: false,
          download_media: false,
          media_profile_id: media_profile_id
        }

        {:ok, source} =
          %Source{}
          |> Source.changeset(attrs)
          |> Repo.insert()

        source

      source ->
        {:ok, source} =
          source
          |> Ecto.Changeset.change(media_profile_id: media_profile_id)
          |> Repo.update()

        source
    end
  end

  defp ensure_item(source, media_id, title) do
    case Repo.get_by(MediaItem, source_id: source.id, media_id: media_id) do
      nil ->
        attrs = %{
          uuid: Ecto.UUID.generate(),
          title: title,
          media_id: media_id,
          original_url: "https://www.youtube.com/watch?v=#{media_id}",
          livestream: false,
          short_form_content: false,
          availability: :public,
          uploaded_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          duration_seconds: 120,
          source_id: source.id
        }

        {:ok, item} = Media.create_media_item(attrs)
        item

      item ->
        item
    end
  end
end

Pinchflat.Seeds.ScopedOptions.run()
