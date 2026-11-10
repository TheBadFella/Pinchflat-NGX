import Ecto.Query, warn: false

# Explicitly opt into synthetic data in a disposable MIX_ENV=test container.
mode = System.get_env("LIBRARY_UI_FIXTURE")

unless Mix.env() == :test and mode in ["1", "empty"] do
  raise "Use a disposable test container with LIBRARY_UI_FIXTURE=1 or LIBRARY_UI_FIXTURE=empty"
end

Application.put_env(
  :pinchflat,
  PinchflatWeb.Endpoint,
  Keyword.merge(Application.fetch_env!(:pinchflat, PinchflatWeb.Endpoint),
    http: [ip: {0, 0, 0, 0}, port: 4004],
    check_origin: ["//localhost", "//127.0.0.1"],
    server: true
  )
)

{:ok, _} = Application.ensure_all_started(:pinchflat)
Faker.start()

unless Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count) == 0 do
  raise "The browser fixture requires an empty disposable test database"
end

alias Pinchflat.Media.MediaItem
alias Pinchflat.Profiles.MediaProfile
alias Pinchflat.Repo
alias Pinchflat.Sources.Source

Pinchflat.TestingHelperMethods.create_platform_directories()
Pinchflat.Settings.set(onboarding: false)

now = DateTime.utc_now() |> DateTime.truncate(:second)
media_directory = Application.fetch_env!(:pinchflat, :media_directory)
metadata_directory = Application.fetch_env!(:pinchflat, :metadata_directory)

File.mkdir_p!(Path.join(metadata_directory, "library-ui"))

profile_a =
  Pinchflat.ProfilesFixtures.media_profile_fixture(%{
    name: "[UI test] Library profile"
  })

profile_b =
  Pinchflat.ProfilesFixtures.media_profile_fixture(%{
    name: "[UI test] Profile with a deliberately long descriptive name that wraps safely"
  })

poster_path = Path.join([metadata_directory, "library-ui", "channel-poster.jpg"])
File.cp!(Pinchflat.MediaFixtures.thumbnail_filepath_fixture(), poster_path)

channel_with_poster =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile_a.id,
    collection_type: "channel",
    custom_name: "[UI test] Channel with poster",
    original_url: "https://www.youtube.com/@library-ui-poster",
    poster_filepath: poster_path,
    enabled: false,
    download_media: false
  })

channel_without_poster =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile_a.id,
    collection_type: "channel",
    custom_name: "[UI test] Channel without poster",
    original_url: "https://www.youtube.com/@library-ui-no-poster",
    enabled: false,
    download_media: false
  })

long_playlist_name =
  "[UI test] Playlist " <> String.duplicate("with a very long descriptive name ", 4)

long_playlist =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile_b.id,
    collection_type: "playlist",
    selection_mode: :all,
    custom_name: long_playlist_name,
    original_url: "https://www.youtube.com/playlist?list=PLlibraryui0000000000000000000000",
    enabled: false,
    download_media: false
  })

video_source =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile_b.id,
    collection_type: "video",
    custom_name: "[UI test] Single video source",
    original_url: "https://www.youtube.com/watch?v=library-ui-video",
    enabled: false,
    download_media: false
  })

real_sources = [channel_with_poster, channel_without_poster, long_playlist, video_source]
real_source_ids = Enum.map(real_sources, & &1.id)
real_profile_ids = [profile_a.id, profile_b.id]

create_item = fn source, title, attrs ->
  attrs
  |> Map.merge(%{source_id: source.id, title: title})
  |> Pinchflat.MediaFixtures.media_item_fixture()
end

update_indexed_at = fn item, datetime ->
  Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [inserted_at: datetime])
  item
end

recent_item = fn seconds_ago -> DateTime.add(now, -seconds_ago, :second) end
recent_hours_ago = fn hours -> DateTime.add(now, -hours, :hour) end
old_days_ago = fn days -> DateTime.add(now, -days, :day) end

long_title =
  String.duplicate("[UI test] A deliberately long media title that must wrap without pushing the thumbnail ", 2)

build_manifest = fn extra ->
  Map.merge(
    %{
      mode: mode,
      channel_id: channel_with_poster.id,
      channel_without_poster_id: channel_without_poster.id,
      long_playlist_id: long_playlist.id,
      video_source_id: video_source.id,
      long_playlist_name: long_playlist_name
    },
    extra
  )
end

if mode == "empty" do
  # One source, no media indexed in the last 24 hours. Used by the P3 empty state check.
  item =
    create_item.(channel_with_poster, "[UI test] Older indexed item", %{
      media_filepath: "/library-ui/older.mp4",
      media_downloaded_at: old_days_ago.(10),
      media_size_bytes: 2_000_000,
      uploaded_at: old_days_ago.(12)
    })

  update_indexed_at.(item, old_days_ago.(10))

  Repo.delete_all(from(s in Source, where: s.id != ^channel_with_poster.id))
  Repo.delete_all(from(p in MediaProfile, where: p.id != ^profile_a.id))

  manifest = build_manifest.(%{older_item_id: item.id})

  File.write!("/tmp/pinchflat-library-ui.json", Jason.encode!(manifest))
  IO.puts("LIBRARY_UI_READY")
  Process.sleep(:infinity)
else
  # Create the non-thumbnail items first so the thumbnail-bearing items have the
  # highest IDs and appear on the first page of the Downloaded tab.
  pending_items =
    for index <- 1..8 do
      title =
        if index == 1 do
          long_title
        else
          "[UI test] Pending media #{index}"
        end

      create_item.(Enum.at(real_sources, rem(index, 4)), title, %{
        media_filepath: nil,
        uploaded_at: recent_hours_ago.(index + 1)
      })
    end

  running_item = Enum.at(pending_items, 0)

  transient_items =
    for index <- 1..3 do
      create_item.(channel_with_poster, "[UI test] Transient failure #{index}", %{
        media_filepath: nil,
        last_error: "HTTP Error 429: Too Many Requests",
        error_type: :transient,
        uploaded_at: recent_hours_ago.(index + 2)
      })
    end

  permanent_items =
    for index <- 1..3 do
      create_item.(channel_without_poster, "[UI test] Permanent failure #{index}", %{
        media_filepath: nil,
        last_error: "Video unavailable",
        error_type: :permanent,
        prevent_download: true,
        download_prevented_reason: :error,
        uploaded_at: recent_hours_ago.(index + 3)
      })
    end

  downloaded_mix =
    for index <- 1..6 do
      create_item.(Enum.at(real_sources, rem(index, 4)), "[UI test] Downloaded media #{index}", %{
        media_filepath: "/library-ui/downloaded-#{index}.mp4",
        media_downloaded_at: recent_hours_ago.(index),
        media_size_bytes: 10_000_000 + index,
        uploaded_at: old_days_ago.(index)
      })
    end

  missing_thumb_items =
    for index <- 1..3 do
      create_item.(channel_without_poster, "[UI test] Missing thumbnail #{index}", %{
        media_filepath: "/library-ui/missing-thumb-#{index}.mp4",
        media_downloaded_at: now,
        media_size_bytes: 3_000_000 + index,
        thumbnail_filepath: Path.join(metadata_directory, "library-ui/missing-thumb-#{index}.jpg"),
        uploaded_at: old_days_ago.(index + 2)
      })
    end

  nil_thumb_items =
    for index <- 1..3 do
      create_item.(long_playlist, "[UI test] No thumbnail #{index}", %{
        media_filepath: "/library-ui/no-thumb-#{index}.mp4",
        media_downloaded_at: now,
        media_size_bytes: 4_000_000 + index,
        thumbnail_filepath: nil,
        uploaded_at: old_days_ago.(index + 3)
      })
    end

  real_thumb_items =
    for {source, index} <- Enum.with_index(real_sources) do
      thumbnail_path = Path.join(media_directory, "library-ui-thumb-#{index + 1}.jpg")
      File.cp!(Pinchflat.MediaFixtures.thumbnail_filepath_fixture(), thumbnail_path)

      create_item.(source, "[UI test] Downloaded with thumbnail #{index + 1}", %{
        media_filepath: "/library-ui/with-thumb-#{index + 1}.mp4",
        media_downloaded_at: now,
        media_size_bytes: 5_000_000 + index,
        thumbnail_filepath: thumbnail_path,
        uploaded_at: old_days_ago.(index + 1)
      })
    end

  # The first page of Latest is ordered by indexed time descending. Keep the
  # running task and representative thumbnail states in the top ten.
  running_item = update_indexed_at.(running_item, recent_item.(30))
  real_item = update_indexed_at.(Enum.at(real_thumb_items, 0), recent_item.(60))
  missing_item = update_indexed_at.(Enum.at(missing_thumb_items, 0), recent_item.(120))
  nil_item = update_indexed_at.(Enum.at(nil_thumb_items, 0), recent_item.(180))

  extra_recent =
    Enum.drop(real_thumb_items, 1) ++
      Enum.drop(missing_thumb_items, 1) ++
      Enum.drop(nil_thumb_items, 1)

  for {item, index} <- Enum.with_index(extra_recent, 4) do
    update_indexed_at.(item, recent_item.(index * 60))
  end

  for {item, index} <- Enum.with_index(pending_items, 1) do
    if item.id != running_item.id do
      update_indexed_at.(item, recent_hours_ago.(index))
    end
  end

  for {item, index} <- Enum.with_index(transient_items, 1) do
    update_indexed_at.(item, if(index == 3, do: old_days_ago.(8), else: recent_hours_ago.(index)))
  end

  for {item, index} <- Enum.with_index(permanent_items, 1) do
    update_indexed_at.(item, if(index == 1, do: recent_hours_ago.(index), else: old_days_ago.(7 + index)))
  end

  for {item, index} <- Enum.with_index(downloaded_mix, 1) do
    update_indexed_at.(item, if(index <= 3, do: recent_hours_ago.(index + 4), else: old_days_ago.(index + 4)))
  end

  # One running download makes the Action column appear.
  {:ok, _task} = Pinchflat.Downloading.MediaDownloadWorker.kickoff_with_task(running_item)

  # source_fixture/1 and media_item_fixture/1 eagerly create default profiles and
  # sources even when explicit associations are supplied. Remove those strays so
  # the library only contains the four intended sources.
  Repo.delete_all(from(s in Source, where: s.id not in ^real_source_ids))
  Repo.delete_all(from(p in MediaProfile, where: p.id not in ^real_profile_ids))

  manifest =
    build_manifest.(%{
      running_item_id: running_item.id,
      real_thumbnail_item_id: real_item.id,
      real_thumbnail_uuid: real_item.uuid,
      missing_thumbnail_item_id: missing_item.id,
      nil_thumbnail_item_id: nil_item.id,
      long_title_item_id: hd(pending_items).id
    })

  File.write!("/tmp/pinchflat-library-ui.json", Jason.encode!(manifest))
  IO.puts("LIBRARY_UI_READY")
  Process.sleep(:infinity)
end
