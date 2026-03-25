defmodule Pinchflat.SourcesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Pinchflat.Sources` context.
  """

  alias Pinchflat.Repo
  alias Pinchflat.MediaFixtures
  alias Pinchflat.Sources.Source
  alias Pinchflat.ProfilesFixtures
  alias Pinchflat.Utils.FilesystemUtils

  @doc """
  Generate a source.
  """
  def source_fixture(attrs \\ %{}) do
    {:ok, source} =
      %Source{}
      |> Source.changeset(
        Enum.into(
          attrs,
          %{
            enabled: true,
            collection_name: "Source ##{:rand.uniform(1_000_000)}",
            collection_id: Base.encode16(:crypto.hash(:md5, "#{:rand.uniform(1_000_000)}")),
            collection_type: "channel",
            custom_name: "Cool and good internal name!",
            description: "This is a description",
            original_url: "https://www.youtube.com/@#{youtube_handle_fixture()}",
            media_profile_id: ProfilesFixtures.media_profile_fixture().id,
            index_frequency_minutes: 60
          }
        ),
        :pre_insert
      )
      |> Repo.insert()

    source
  end

  @doc """
  Generate a source with metadata.
  """
  def source_with_metadata(attrs \\ %{}) do
    merged_attrs =
      Map.merge(attrs, %{
        metadata: %{
          metadata_filepath: Application.get_env(:pinchflat, :metadata_directory) <> "/metadata.json.gz"
        }
      })

    source_fixture(merged_attrs)
  end

  def source_with_metadata_attachments(attrs \\ %{}) do
    metadata_dir =
      Path.join(Application.get_env(:pinchflat, :metadata_directory), "#{:rand.uniform(1_000_000)}")

    json_gz_filepath = Path.join(metadata_dir, "metadata.json.gz")
    poster_filepath = Path.join(metadata_dir, "poster.jpg")
    fanart_filepath = Path.join(metadata_dir, "fanart.jpg")

    FilesystemUtils.cp_p!(MediaFixtures.media_metadata_filepath_fixture(), json_gz_filepath)
    FilesystemUtils.cp_p!(MediaFixtures.thumbnail_filepath_fixture(), poster_filepath)
    FilesystemUtils.cp_p!(MediaFixtures.thumbnail_filepath_fixture(), fanart_filepath)

    merged_attrs =
      Map.merge(attrs, %{
        metadata: %{
          metadata_filepath: json_gz_filepath,
          poster_filepath: poster_filepath,
          fanart_filepath: fanart_filepath
        }
      })

    source_fixture(merged_attrs)
  end

  def source_attributes_return_fixture do
    # Use recent dates to ensure media items pass the download_cutoff_date filter
    today = Date.utc_today()
    date1 = Date.add(today, -1) |> Calendar.strftime("%Y%m%d")
    date2 = Date.add(today, -2) |> Calendar.strftime("%Y%m%d")
    date3 = Date.add(today, -3) |> Calendar.strftime("%Y%m%d")

    source_attributes = [
      %{
        id: "video1",
        title: "Video 1",
        original_url: "https://example.com/video1",
        live_status: "not_live",
        description: "desc1",
        aspect_ratio: 1.67,
        duration: 12.34,
        upload_date: date1
      },
      %{
        id: "video2",
        title: "Video 2",
        original_url: "https://example.com/video2",
        live_status: "is_live",
        description: "desc2",
        aspect_ratio: 1.67,
        duration: 345.67,
        upload_date: date2
      },
      %{
        id: "video3",
        title: "Video 3",
        original_url: "https://example.com/video3",
        live_status: "not_live",
        description: "desc3",
        aspect_ratio: 1.0,
        duration: 678.90,
        upload_date: date3
      }
    ]

    source_attributes
    |> Enum.map_join("\n", &Phoenix.json_library().encode!(&1))
  end

  def source_details_return_fixture(attrs \\ %{}) do
    channel_id = Faker.String.base64(12)

    %{
      channel_id: channel_id,
      channel: "Channel Name",
      playlist_id: channel_id,
      playlist_title: "Channel Name",
      filename: Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])
    }
    |> Map.merge(attrs)
    |> Phoenix.json_library().encode!()
  end

  defp youtube_handle_fixture do
    "fixture-#{System.unique_integer([:positive])}"
  end
end
