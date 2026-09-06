# Seeds dummy pending / failed / downloaded / excluded items for UI smoke tests.
# Safe to re-run: tagged custom_name / titles are unique per run via a suffix.

alias Pinchflat.Repo
alias Pinchflat.Settings
alias Pinchflat.Profiles
alias Pinchflat.Sources.Source
alias Pinchflat.Media
alias Pinchflat.Media.MediaItem

Settings.set(onboarding: false)

suffix = DateTime.utc_now() |> DateTime.to_unix() |> to_string()

{:ok, profile} =
  case Repo.get_by(Pinchflat.Profiles.MediaProfile, name: "UI Smoke Profile") do
    nil -> Profiles.create_media_profile(%{name: "UI Smoke Profile", output_path_template: "{{title}}.{{ext}}"})
    existing -> {:ok, existing}
  end

source =
  case Repo.get_by(Source, custom_name: "UI Smoke Source") do
    nil ->
      {:ok, source} =
        %Source{}
        |> Source.changeset(
          %{
            enabled: true,
            collection_name: "UI Smoke Channel",
            collection_id: "UIsmoke#{suffix}",
            collection_type: "channel",
            custom_name: "UI Smoke Source",
            description: "Dummy source for UI smoke tests",
            original_url: "https://www.youtube.com/@uismoke#{suffix}",
            media_profile_id: profile.id,
            index_frequency_minutes: 0,
            download_media: true
          },
          :pre_insert
        )
        |> Repo.insert()

      source

    existing ->
      existing
  end

insert_item = fn attrs ->
  defaults = %{
    source_id: source.id,
    livestream: false,
    short_form_content: false,
    uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second),
    original_url: "https://www.youtube.com/watch?v=#{Map.fetch!(attrs, :media_id)}"
  }

  {:ok, item} = Media.create_media_item(Map.merge(defaults, attrs))
  item
end

pending =
  insert_item.(%{
    media_id: "pend#{suffix}",
    title: "UI Smoke Pending Episode #{suffix}",
    media_filepath: nil
  })

failed =
  insert_item.(%{
    media_id: "fail#{suffix}",
    title: "UI Smoke Failed Episode #{suffix}",
    media_filepath: nil,
    last_error: "ERROR: [download] Got error: [Errno 101] Network is unreachable. Giving up after 10 retries"
  })

downloaded =
  insert_item.(%{
    media_id: "done#{suffix}",
    title: "UI Smoke Downloaded Episode #{suffix}",
    media_filepath: "/downloads/UI Smoke/#{suffix}.mp4",
    media_downloaded_at: DateTime.utc_now() |> DateTime.truncate(:second),
    media_size_bytes: 18_874_368
  })

excluded =
  insert_item.(%{
    media_id: "skip#{suffix}",
    title: "UI Smoke Excluded Episode #{suffix}",
    media_filepath: nil,
    prevent_download: true
  })

IO.puts("Seeded source ##{source.id}")
IO.puts("pending=#{pending.id} failed=#{failed.id} downloaded=#{downloaded.id} excluded=#{excluded.id}")
