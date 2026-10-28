defmodule PinchflatWeb.WatchLaterSourceTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.ProfilesFixtures
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  @url "https://www.youtube.com/playlist?list=WL"

  setup do
    Settings.set(onboarding: false)
    profile = media_profile_fixture(%{download_source_images: true, download_nfo: true})
    original = Application.get_env(:pinchflat, :extras_directory)
    directory = Path.join(System.tmp_dir!(), "watch-later-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    Application.put_env(:pinchflat, :extras_directory, directory)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
      File.rm_rf!(directory)
    end)

    {:ok, profile: profile, directory: directory}
  end

  test "empty Watch Later is created through HTML and completes metadata and indexing", %{
    conn: conn,
    profile: profile,
    directory: directory
  } do
    File.write!(Path.join(directory, "cookies.txt"), "fixture-cookie-file")
    stub_empty_playlist()
    conn = post(conn, ~p"/sources", source: attrs(profile))
    assert %{id: id} = redirected_params(conn)
    source = Sources.get_source!(id)
    assert source.collection_id == "WL"
    assert source.collection_name == "Watch Later"
    assert source.cookie_behaviour == :all_operations
    assert_enqueued(worker: SourceMetadataStorageWorker, args: %{id: source.id})
    assert :ok = perform_job(SourceMetadataStorageWorker, %{id: source.id})
    assert :ok = perform_job(MediaCollectionIndexingWorker, %{id: source.id})
    source = Repo.reload(source)
    assert source.series_directory == nil
    assert source.last_indexed_at
    assert Repo.aggregate(Pinchflat.Media.MediaItem, :count) == 0
  end

  test "JSON creation accepts an identified empty Watch Later with Automatic selected", %{
    conn: conn,
    profile: profile,
    directory: directory
  } do
    File.write!(Path.join(directory, "cookies.txt"), "fixture-cookie-file")
    stub_empty_playlist()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/sources", source: Map.put(attrs(profile), :source_type, "automatic"))

    body = json_response(conn, 201)
    assert body["collection_id"] == "WL"
    assert Repo.get!(Source, body["id"]).collection_name == "Watch Later"
  end

  test "missing cookies produce actionable HTML guidance without inspecting the private playlist", %{
    conn: conn,
    profile: profile
  } do
    conn = post(conn, ~p"/sources", source: attrs(profile))
    html = html_response(conn, 200)
    assert html =~ "Watch Later is private"
    assert html =~ "All Operations"
    assert Repo.aggregate(Source, :count) == 0
  end

  test "When Needed does not silently attach cookies during source inspection", %{
    conn: conn,
    profile: profile,
    directory: directory
  } do
    File.write!(Path.join(directory, "cookies.txt"), "fixture-cookie-file")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/sources", source: Map.put(attrs(profile), :cookie_behaviour, "when_needed"))

    body = json_response(conn, 422)
    assert inspect(body["errors"]) =~ "All Operations"
    assert Repo.aggregate(Source, :count) == 0
  end

  test "an authentication failure explains Watch Later without exposing raw output", %{
    conn: conn,
    profile: profile,
    directory: directory
  } do
    File.write!(Path.join(directory, "cookies.txt"), "fixture-cookie-file")

    expect(YtDlpRunnerMock, :run, fn @url, :get_source_details, _opts, _template, addl ->
      assert addl[:use_cookies]
      {:error, "ERROR: private playlist; fixture-sensitive-diagnostic", 1}
    end)

    html = conn |> post(~p"/sources", source: attrs(profile)) |> html_response(200)
    assert html =~ "Watch Later"
    assert html =~ "refresh the cookies"
    assert html =~ "add a video and try again"
    refute html =~ "fixture-sensitive-diagnostic"
    assert Repo.aggregate(Source, :count) == 0
  end

  test "a standalone video with a Watch Later query does not require private-playlist cookies", %{
    conn: conn,
    profile: profile
  } do
    url = "https://www.youtube.com/watch?v=72maj9FLQZI&list=WL"

    expect(YtDlpRunnerMock, :run, fn ^url, :get_source_details, opts, _template, addl ->
      assert :no_playlist in opts
      refute addl[:use_cookies]
      {:ok, Jason.encode!(%{id: "72maj9FLQZI", title: "A public video"})}
    end)

    body =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/sources", source: %{media_profile_id: profile.id, original_url: url})
      |> json_response(201)

    assert body["collection_type"] == "video"
  end

  defp attrs(profile) do
    %{
      media_profile_id: profile.id,
      original_url: @url,
      source_type: "playlist",
      cookie_behaviour: "all_operations",
      index_frequency_minutes: 0
    }
  end

  defp stub_empty_playlist do
    stub(YtDlpRunnerMock, :run, fn
      @url, :get_source_details, _opts, _template, addl ->
        assert addl[:use_cookies]
        {:ok, ""}

      @url, :get_source_metadata, opts, "playlist:%()j", addl ->
        assert addl[:use_cookies]
        assert Keyword.fetch!(opts, :playlist_items) in [0, 1]
        {:ok, Jason.encode!(%{_type: "playlist", id: "WL", title: "Watch Later", entries: []})}

      @url, :get_media_attributes_for_collection, _opts, _template, _addl ->
        {:ok, ""}
    end)
  end
end
