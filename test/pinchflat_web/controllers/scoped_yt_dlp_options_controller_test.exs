defmodule PinchflatWeb.ScopedYtDlpOptionsControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Profiles
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Settings.YtDlpConfigFile
  alias Pinchflat.Sources

  setup do
    Settings.set(onboarding: false)

    extras_directory =
      Path.join(System.tmp_dir!(), "scoped-options-controller-#{System.unique_integer([:positive])}")

    original_extras = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, extras_directory)
    File.mkdir_p!(extras_directory)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original_extras)
      File.rm_rf!(extras_directory)
    end)

    {:ok, extras_directory: extras_directory}
  end

  test "U01: profile create and update save only that profile's options", %{conn: conn} do
    name = "Scoped Profile #{System.unique_integer([:positive])}"
    attrs = %{name: name, output_path_template: "{{ title }}.%(ext)s"}

    conn = post(conn, ~p"/media_profiles", media_profile: attrs, yt_dlp_options: "--retries 5\n")
    assert %{id: id} = redirected_params(conn)
    profile = Profiles.get_media_profile!(id)

    assert {:ok, %{contents: "--retries 5\n", version: version}} =
             YtDlpConfigFile.read_scope(:profile, profile.id)

    conn =
      put(conn, ~p"/media_profiles/#{profile.id}",
        media_profile: attrs,
        yt_dlp_options: "--retries 7\n",
        yt_dlp_options_version: version
      )

    assert redirected_to(conn) == ~p"/media_profiles/#{profile.id}"

    assert {:ok, %{contents: "--retries 7\n"}} = YtDlpConfigFile.read_scope(:profile, profile.id)

    source_a = source_fixture(%{media_profile_id: profile.id})
    source_b = source_fixture(%{media_profile_id: profile.id})
    other_profile = media_profile_fixture()
    other_source = source_fixture(%{media_profile_id: other_profile.id})

    item_a = Repo.preload(media_item_fixture(%{source_id: source_a.id}), source: :media_profile)
    item_b = Repo.preload(media_item_fixture(%{source_id: source_b.id}), source: :media_profile)

    item_other =
      Repo.preload(media_item_fixture(%{source_id: other_source.id}), source: :media_profile)

    profile_path = Path.join([extras_directory(), "yt-dlp-configs", "media-profile-#{profile.id}-config.txt"])

    for item <- [item_a, item_b] do
      assert {:ok, options} = DownloadOptionBuilder.build(item)
      assert {:config_locations, profile_path} in options
    end

    assert {:ok, other_options} = DownloadOptionBuilder.build(item_other)
    refute {:config_locations, profile_path} in other_options
  end

  test "U02: source create and update save only that source's options", %{conn: conn} do
    profile = media_profile_fixture()
    suffix = System.unique_integer([:positive])

    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
      {:ok,
       Jason.encode!(%{
         playlist_channel: "Scoped Channel",
         playlist_channel_id: "UCscoped#{suffix}",
         playlist_id: "UCscoped#{suffix}",
         playlist_title: "Scoped Channel"
       })}
    end)

    conn =
      post(conn, ~p"/sources",
        source: %{
          media_profile_id: profile.id,
          collection_type: "channel",
          original_url: "https://www.youtube.com/@scoped#{suffix}"
        },
        yt_dlp_options: "--source-created\n"
      )

    assert %{id: id} = redirected_params(conn)
    source = Sources.get_source!(id)

    assert {:ok, %{contents: "--source-created\n", version: version}} =
             YtDlpConfigFile.read_scope(:source, source.id)

    sibling = source_fixture(%{media_profile_id: profile.id})

    assert {:ok, %{version: :missing}} = YtDlpConfigFile.read_scope(:source, sibling.id)

    conn =
      put(conn, ~p"/sources/#{source.id}",
        source: %{custom_name: "Scoped Updated"},
        yt_dlp_options: "--source-updated\n",
        yt_dlp_options_version: version
      )

    assert redirected_to(conn) == ~p"/sources/#{source.id}"
    assert {:ok, %{contents: "--source-updated\n"}} = YtDlpConfigFile.read_scope(:source, source.id)
    assert {:ok, %{version: :missing}} = YtDlpConfigFile.read_scope(:source, sibling.id)
  end

  test "U03 and U06: item edits stay item-scoped and omitted options preserve the file", %{conn: conn} do
    source = source_fixture()
    item = media_item_fixture(%{source_id: source.id})
    other_source = source_fixture()
    other_item = media_item_fixture(%{source_id: other_source.id, media_id: item.media_id})

    conn =
      put(conn, ~p"/sources/#{source.id}/media/#{item}",
        media_item: %{prevent_download: false},
        yt_dlp_options: "--item\n"
      )

    assert redirected_to(conn) == ~p"/sources/#{source.id}/media/#{item}"
    assert {:ok, %{contents: "--item\n", version: version}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert {:ok, %{version: :missing}} = YtDlpConfigFile.read_scope(:media_item, other_item.id)

    conn =
      put(conn, ~p"/sources/#{source.id}/media/#{item}",
        media_item: %{prevent_download: false},
        yt_dlp_options: "--item-2\n",
        yt_dlp_options_version: version
      )

    assert redirected_to(conn) == ~p"/sources/#{source.id}/media/#{item}"
    assert {:ok, %{contents: "--item-2\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)

    put(conn, ~p"/sources/#{source.id}/media/#{item}", media_item: %{prevent_download: false})

    assert {:ok, %{contents: "--item-2\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)
  end

  test "U08: saving options alone does not enqueue work", %{conn: conn} do
    profile = media_profile_fixture()
    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_fixture(%{source_id: source.id})

    job_count = Repo.aggregate(Oban.Job, :count, :id)

    put(conn, ~p"/media_profiles/#{profile.id}",
      media_profile: %{name: profile.name, output_path_template: profile.output_path_template},
      yt_dlp_options: "--profile-only\n"
    )

    put(conn, ~p"/sources/#{source.id}", source: %{custom_name: source.custom_name}, yt_dlp_options: "--source-only\n")

    put(conn, ~p"/sources/#{source.id}/media/#{item}",
      media_item: %{prevent_download: item.prevent_download},
      yt_dlp_options: "--item-only\n"
    )

    assert Repo.aggregate(Oban.Job, :count, :id) == job_count
  end

  test "U09: clear only the local source file and show inherited status after profile reassignment", %{conn: conn} do
    assert :ok = YtDlpConfigFile.save("--base\n")

    profile_a = media_profile_fixture()
    profile_b = media_profile_fixture()

    assert :ok = YtDlpConfigFile.save_scope(:profile, profile_b.id, "--profile-b\n", :missing)

    source = source_fixture(%{media_profile_id: profile_a.id})

    assert :ok = YtDlpConfigFile.save_scope(:source, source.id, "--source\n", :missing)
    assert {:ok, %{version: version}} = YtDlpConfigFile.read_scope(:source, source.id)

    conn =
      put(conn, ~p"/sources/#{source.id}",
        source: %{media_profile_id: profile_b.id},
        yt_dlp_options_clear: "1",
        yt_dlp_options_version: version
      )

    assert redirected_to(conn) == ~p"/sources/#{source.id}"

    assert {:ok, %{contents: "", present?: false}} = YtDlpConfigFile.read_scope(:source, source.id)
    assert {:ok, %{contents: "--profile-b\n"}} = YtDlpConfigFile.read_scope(:profile, profile_b.id)

    html = conn |> get(~p"/sources/#{source.id}/edit") |> html_response(200)
    assert html =~ "Base config active"
    assert html =~ "Media profile config active"
    assert html =~ "No local options"
  end

  test "F10: stale profile save preserves the draft and newer file, then retry succeeds", %{conn: conn} do
    profile = media_profile_fixture()
    attrs = %{name: profile.name, output_path_template: profile.output_path_template}

    assert :ok = YtDlpConfigFile.save_scope(:profile, profile.id, "original\n", :missing)
    assert {:ok, %{version: old_version}} = YtDlpConfigFile.read_scope(:profile, profile.id)
    assert :ok = YtDlpConfigFile.save_scope(:profile, profile.id, "newer\n", :any)

    conn =
      put(conn, ~p"/media_profiles/#{profile.id}",
        media_profile: attrs,
        yt_dlp_options: "--draft\n",
        yt_dlp_options_version: old_version
      )

    html = html_response(conn, 200)
    assert html =~ "--draft"
    assert html =~ "Someone else changed this config file"

    assert {:ok, %{contents: "newer\n", version: current_version}} =
             YtDlpConfigFile.read_scope(:profile, profile.id)

    assert html =~ current_version

    conn =
      put(conn, ~p"/media_profiles/#{profile.id}",
        media_profile: attrs,
        yt_dlp_options: "--draft\n",
        yt_dlp_options_version: current_version
      )

    assert redirected_to(conn) == ~p"/media_profiles/#{profile.id}"
    assert {:ok, %{contents: "--draft\n"}} = YtDlpConfigFile.read_scope(:profile, profile.id)
  end

  test "F10: stale source clear preserves the newer file, then explicit retry clears", %{conn: conn} do
    source = source_fixture()

    assert :ok = YtDlpConfigFile.save_scope(:source, source.id, "original\n", :missing)
    assert {:ok, %{version: old_version}} = YtDlpConfigFile.read_scope(:source, source.id)
    assert :ok = YtDlpConfigFile.save_scope(:source, source.id, "newer\n", :any)

    conn =
      put(conn, ~p"/sources/#{source.id}",
        source: %{custom_name: source.custom_name},
        yt_dlp_options_clear: "1",
        yt_dlp_options_version: old_version
      )

    html = html_response(conn, 200)
    assert html =~ "Someone else changed this config file"

    assert {:ok, %{contents: "newer\n", version: current_version}} =
             YtDlpConfigFile.read_scope(:source, source.id)

    assert html =~ current_version

    conn =
      put(conn, ~p"/sources/#{source.id}",
        source: %{custom_name: source.custom_name},
        yt_dlp_options_clear: "1",
        yt_dlp_options_version: current_version
      )

    assert redirected_to(conn) == ~p"/sources/#{source.id}"
    assert {:ok, %{contents: "", present?: false}} = YtDlpConfigFile.read_scope(:source, source.id)
  end

  test "F10: stale item save preserves the draft and newer file, then retry succeeds", %{conn: conn} do
    source = source_fixture()
    item = media_item_fixture(%{source_id: source.id})

    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "original\n", :missing)
    assert {:ok, %{version: old_version}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "newer\n", :any)

    conn =
      put(conn, ~p"/sources/#{source.id}/media/#{item}",
        media_item: %{prevent_download: item.prevent_download},
        yt_dlp_options: "--draft\n",
        yt_dlp_options_version: old_version
      )

    html = html_response(conn, 200)
    assert html =~ "--draft"
    assert html =~ "Someone else changed this config file"

    assert {:ok, %{contents: "newer\n", version: current_version}} =
             YtDlpConfigFile.read_scope(:media_item, item.id)

    assert html =~ current_version

    conn =
      put(conn, ~p"/sources/#{source.id}/media/#{item}",
        media_item: %{prevent_download: item.prevent_download},
        yt_dlp_options: "--draft\n",
        yt_dlp_options_version: current_version
      )

    assert redirected_to(conn) == ~p"/sources/#{source.id}/media/#{item}"
    assert {:ok, %{contents: "--draft\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)
  end

  test "S05: JSON source updates ignore the HTML-only options field", %{conn: conn} do
    source = source_fixture()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put(~p"/sources/#{source.id}",
        source: %{custom_name: source.custom_name},
        yt_dlp_options: "--json-must-not-save\n"
      )

    assert %{"id" => _} = json_response(conn, 200)
    assert {:ok, %{version: :missing}} = YtDlpConfigFile.read_scope(:source, source.id)
  end

  defp extras_directory do
    Application.get_env(:pinchflat, :extras_directory)
  end
end
