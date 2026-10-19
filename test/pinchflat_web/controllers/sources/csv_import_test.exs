defmodule PinchflatWeb.Sources.CsvImportTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources.Source
  alias PinchflatWeb.Sources.ImportLive

  @id "UCXuqSBlHAE6Xw-yeJA0Tunw"
  @url "https://www.youtube.com/channel/#{@id}"
  @header "Channel Id,Channel Url,Channel Title\n"

  setup do
    Pinchflat.Settings.set(onboarding: false)
    %{profile: media_profile_fixture()}
  end

  test "CSV preview reports rejected rows, escapes titles and performs no provider or database writes", %{
    conn: conn,
    profile: profile
  } do
    csv = @header <> "#{@id},#{@url},<script>alert(1)</script>\nbad,url,title\n"
    html = upload(conn, profile.id, csv) |> html_response(200)
    assert html =~ "Review sources"
    assert html =~ "downloads paused"
    assert html =~ "Row 3"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert(1)</script>"
    assert Repo.aggregate(Source, :count) == 0
  end

  test "all rejected rows have no import action", %{conn: conn, profile: profile} do
    html = upload(conn, profile.id, @header <> "bad,url,title\n") |> html_response(200)
    assert html =~ "Row 2"
    refute html =~ ~s(id="confirm-import")
  end

  test "oversized files and exports fail without silently truncating", %{conn: conn, profile: profile} do
    for csv <- [String.duplicate("x", 100_001), @header <> String.duplicate("#{@id},#{@url},Title\n", 101)] do
      html = upload(conn, profile.id, csv) |> html_response(200)
      assert html =~ ~s(role="alert")
      refute html =~ ~s(id="confirm-import")
      assert Repo.aggregate(Source, :count) == 0
    end
  end

  test "invalid and deleting profiles produce a form error", %{conn: conn} do
    deleting = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())

    for id <- ["", "not-an-id", "9999999999999999999999999999", %{"id" => "1"}, "#{deleting.id}"] do
      html = upload(conn, id, @header <> "#{@id},#{@url},Title\n") |> html_response(200)
      assert html =~ ~s(role="alert")
      refute html =~ ~s(id="confirm-import")
    end
  end

  test "CSV creates a monitored source with downloads paused", %{conn: conn, profile: profile} do
    expect(YtDlpRunnerMock, :run, fn @url, :get_source_details, _opts, _output, _system_opts ->
      {:ok, source_details_return_fixture(%{channel_id: @id, playlist_id: @id})}
    end)

    {:ok, view, _} = live_isolated(conn, ImportLive, session: csv_session(profile.id))
    view |> element("#confirm-import") |> render_click()
    assert render_async(view) =~ "1 added"
    source = Repo.one!(Source)
    assert source.enabled
    refute source.download_media
    assert source.media_profile_id == profile.id
  end

  test "existing paused sources in another profile are shown and kept unchanged", %{conn: conn, profile: profile} do
    source = source_fixture(collection_id: @id, enabled: false, download_media: false)
    item = media_item_with_attachments(%{source_id: source.id})
    bytes = File.read!(item.media_filepath)
    {:ok, view, html} = live_isolated(conn, ImportLive, session: csv_session(profile.id))
    assert html =~ "Already exists"
    refute has_element?(view, "#confirm-import")
    assert Repo.reload!(source) == source
    assert File.read!(item.media_filepath) == bytes
  end

  test "existing channels are rechecked after preview without contacting the provider", %{conn: conn, profile: profile} do
    {:ok, view, _} = live_isolated(conn, ImportLive, session: csv_session(profile.id))
    source = source_fixture(collection_id: @id, download_media: false)
    view |> element("#confirm-import") |> render_click()
    assert render_async(view) =~ "1 already exist"
    assert Repo.reload!(source) == source
    assert Repo.aggregate(Source, :count) == 1
  end

  test "deleting the selected profile after preview stops the import", %{conn: conn, profile: profile} do
    {:ok, view, _} = live_isolated(conn, ImportLive, session: csv_session(profile.id))

    profile
    |> Ecto.Changeset.change(marked_for_deletion_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!()

    view |> element("#confirm-import") |> render_click()
    assert render(view) =~ "profile is no longer available"
    assert Repo.aggregate(Source, :count) == 0
  end

  defp csv_session(profile_id) do
    %{
      "urls" => [@url],
      "profile_id" => profile_id,
      "duplicates" => 0,
      "titles" => %{@url => "Fixture channel"},
      "channel_ids" => %{@url => @id},
      "row_errors" => [],
      "download_media" => false
    }
  end

  defp upload(conn, profile_id, contents) do
    profile_id = if is_integer(profile_id), do: Integer.to_string(profile_id), else: profile_id
    path = Path.join(System.tmp_dir!(), "csv-import-#{System.unique_integer([:positive])}.csv")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    post(conn, ~p"/sources/import",
      import: %{
        file: %Plug.Upload{path: path, filename: "subscriptions.csv", content_type: "text/csv"},
        media_profile_id: profile_id
      }
    )
  end
end
