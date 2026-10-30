defmodule PinchflatWeb.SourceHostsTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  @playlist_id "OLAK5uy_lI9vPUbopTdtIK2GuuhjkaKFKJKDq5-WU"
  @playlist_url "https://www.youtube.com/playlist?list=#{@playlist_id}&si=tracking#songs"

  setup do
    Settings.set(onboarding: false)
    stub(AppriseRunnerMock, :run, fn _, _ -> {:ok, ""} end)
    :ok
  end

  for host <- ["music.youtube.com", "m.youtube.com"], type <- ["automatic", "playlist"] do
    test "creates a #{type} playlist from #{host}", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn @playlist_url, :get_source_details, _opts, _template, _runner_opts ->
        {:ok, source_details_return_fixture(%{playlist_id: @playlist_id, playlist_title: "Album"})}
      end)

      profile =
        media_profile_fixture(
          download_source_images: false,
          download_nfo: false,
          output_path_template: "{{ source_custom_name }}/{{ title }}.{{ ext }}"
        )

      conn =
        post(conn, ~p"/sources",
          source: %{
            original_url: "https://#{unquote(host)}/playlist?list=#{@playlist_id}&si=tracking#songs",
            source_type: unquote(type),
            media_profile_id: profile.id,
            index_frequency_minutes: 0
          }
        )

      assert %{id: id} = redirected_params(conn)
      source = Sources.get_source!(id)
      assert source.original_url == @playlist_url
      assert source.collection_type == :playlist
      assert source.collection_id == @playlist_id
      assert source.collection_name == "Album"
      assert_enqueued(worker: Pinchflat.SlowIndexing.MediaCollectionIndexingWorker, args: %{"id" => source.id})

      filepath = "/tmp/test/media/Album/Track.mp4"

      metadata = %{
        id: "dQw4w9WgXcQ",
        title: "Track",
        original_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        live_status: "not_live",
        upload_date: "20261029",
        filename: filepath,
        filepath: filepath,
        ext: "mp4"
      }

      expect(YtDlpRunnerMock, :run, fn @playlist_url, :get_media_attributes_for_collection, opts, _, runner_opts ->
        assert Keyword.fetch!(opts, :output) == "/tmp/test/media/Album/%(title)S.%(ext)S"
        output = Jason.encode!(metadata)
        File.write!(Keyword.fetch!(runner_opts, :output_filepath), output <> "\n")
        {:ok, output}
      end)

      assert :ok = perform_job(Pinchflat.SlowIndexing.MediaCollectionIndexingWorker, %{id: source.id})
      item = Repo.get_by!(Pinchflat.Media.MediaItem, source_id: source.id, media_id: "dQw4w9WgXcQ")
      assert item.predicted_media_filepath == filepath
      assert_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker, args: %{"id" => item.id})

      stub(UserScriptRunnerMock, :run, fn _, _ -> {:ok, "", 0} end)

      stub(YtDlpRunnerMock, :run, fn
        _, :get_downloadable_status, _, _, _ ->
          {:ok, "{}"}

        _, :download_thumbnail, _, _, _ ->
          {:ok, ""}

        _, :download, opts, _, _ ->
          assert Keyword.fetch!(opts, :output) == "/tmp/test/media/Album/%(title)S.%(ext)S"
          File.mkdir_p!(Path.dirname(filepath))
          File.write!(filepath, "fixture media")
          {:ok, Jason.encode!(metadata)}
      end)

      assert :ok = perform_job(Pinchflat.Downloading.MediaDownloadWorker, %{id: item.id})
      downloaded = Repo.reload!(item)
      assert downloaded.media_filepath == filepath
      assert downloaded.media_downloaded_at
      assert File.read!(filepath) == "fixture media"
      File.rm!(filepath)
    end
  end

  test "classifies Music and mobile video links before Automatic inspection" do
    for host <- ["music.youtube.com", "m.youtube.com"] do
      url = "https://#{host}/watch?v=dQw4w9WgXcQ&list=#{@playlist_id}"
      assert Source.youtube_video_url?(url)
      assert Source.supported_youtube_url?(url)
    end
  end

  for host <- ["music.youtube.com", "m.youtube.com"], type <- ["automatic", "video"] do
    test "creates a #{type} video from #{host} without treating its list parameter as a playlist", %{conn: conn} do
      canonical_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=#{@playlist_id}"

      expect(YtDlpRunnerMock, :run, fn ^canonical_url, :get_source_details, opts, _, _ ->
        assert :no_playlist in opts
        {:ok, Jason.encode!(%{id: "dQw4w9WgXcQ", title: "Track", filename: "/tmp/test/media/Track.mp4"})}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            original_url: "https://#{unquote(host)}/watch?v=dQw4w9WgXcQ&list=#{@playlist_id}",
            source_type: unquote(type),
            media_profile_id: media_profile_fixture().id
          }
        )

      assert %{id: id} = redirected_params(conn)
      source = Sources.get_source!(id)
      assert source.original_url == canonical_url
      assert source.collection_type == :video
      assert source.collection_id == "dQw4w9WgXcQ"
    end
  end

  test "normalizes channel and show links while retaining existing path rules" do
    for host <- ["music.youtube.com", "m.youtube.com"] do
      for path <- ["channel/UC123", "@channel/videos", "c/channel", "user/channel"] do
        changeset = Sources.change_source(%Source{}, %{original_url: "https://#{host}/#{path}"})
        assert Ecto.Changeset.get_change(changeset, :original_url) == "https://www.youtube.com/#{path}"
        refute Keyword.has_key?(changeset.errors, :original_url)
      end

      changeset = Sources.change_source(%Source{}, %{original_url: "https://#{host}/show/VLPL123?tracking=1"})
      assert Ecto.Changeset.get_change(changeset, :original_url) == "https://www.youtube.com/playlist?list=PL123"

      changeset = Sources.change_source(%Source{}, %{original_url: "https://#{host}/feed/subscriptions"})
      assert Keyword.has_key?(changeset.errors, :original_url)
    end
  end

  test "does not normalize misleading hosts, credentials or non-default ports" do
    for url <- [
          "https://music.youtube.com.example/playlist?list=abc",
          "https://example.youtube.com/playlist?list=abc",
          "https://notyoutube.com/playlist?list=abc",
          "https://music.youtube.com@evil.example/playlist?list=abc",
          "https://user@music.youtube.com/playlist?list=abc",
          "https://music.youtube.com:444/playlist?list=abc"
        ] do
      changeset = Sources.change_source(%Source{}, %{original_url: url})
      assert Ecto.Changeset.get_change(changeset, :original_url) == url
      assert Keyword.has_key?(changeset.errors, :original_url)
      refute Source.supported_youtube_url?(url)
    end
  end

  test "legacy Music sources allow unrelated edits and normalize a changed URL" do
    source = source_fixture()

    source =
      source
      |> Ecto.Changeset.change(original_url: "https://music.youtube.com/playlist?list=old")
      |> Repo.update!()

    assert {:ok, edited} = Sources.update_source(source, %{custom_name: "My album"})
    assert edited.original_url == source.original_url

    expect(YtDlpRunnerMock, :run, fn @playlist_url, :get_source_details, _opts, _template, _runner_opts ->
      {:ok, source_details_return_fixture(%{playlist_id: @playlist_id, playlist_title: "Album"})}
    end)

    assert {:ok, edited} =
             Sources.update_source(edited, %{
               original_url: "https://music.youtube.com/playlist?list=#{@playlist_id}&si=tracking#songs"
             })

    assert edited.original_url == @playlist_url
    assert edited.collection_id == @playlist_id
  end
end
