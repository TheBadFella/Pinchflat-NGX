defmodule PinchflatWeb.Sources.SourceControllerApiTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.MediaFixtures
  import Mox

  alias Pinchflat.Sources

  setup :verify_on_exit!

  describe "index/2 JSON API" do
    test "returns list of sources as JSON", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, "/sources", _format: "json")

      response = json_response(conn, 200)
      assert is_list(response["data"])
      refute response["data"] == []
      assert List.first(response["data"])["id"] == source.id
    end
  end

  describe "show/2 JSON API" do
    test "returns source details as JSON", %{conn: conn} do
      source = source_fixture() |> Repo.preload(:media_profile)

      conn = get(conn, "/sources/#{source.id}", _format: "json")

      response = json_response(conn, 200)
      assert response["id"] == source.id
      assert response["uuid"] == source.uuid
      assert response["custom_name"] == source.custom_name
      assert response["custom_name_locked"] == false
      assert response["description_locked"] == false
    end

    test "returns 404 for non-existent source", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/sources/999999", _format: "json")
      end
    end
  end

  describe "create/2 JSON API" do
    test "creates source and returns JSON", %{conn: conn} do
      media_profile = media_profile_fixture()

      # Mock the YtDlpRunner to avoid external API calls
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Test Channel",
           channel_id: "UC_test_channel_id",
           playlist_id: "UC_test_channel_id",
           playlist_title: "Test Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UCxxxxxxxxxxxx",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Test Channel"
        },
        "_format" => "json"
      }

      conn = post(conn, "/sources", attrs)

      # Should return 201 Created for successful JSON creation
      assert conn.status == 201
    end
  end

  describe "update/2 JSON API" do
    test "updates source and returns JSON", %{conn: conn} do
      source = source_fixture()

      attrs = %{
        "source" => %{
          "custom_name" => "Updated Name",
          "description" => "Updated description",
          "custom_name_locked" => "true",
          "description_locked" => "true"
        },
        "_format" => "json"
      }

      conn = put(conn, "/sources/#{source.id}", attrs)

      # Should return 200 for JSON
      assert conn.status == 200

      # Verify the source was updated
      updated_source = Sources.get_source!(source.id)
      assert updated_source.custom_name == "Updated Name"
      assert updated_source.description == "Updated description"
      assert updated_source.custom_name_locked
      assert updated_source.description_locked
    end
  end

  describe "title language over JSON API" do
    test "creates a source with a title language and round-trips it", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Language Channel",
           channel_id: "UC_language_channel",
           playlist_id: "UC_language_channel",
           playlist_title: "Language Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_language_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Language Channel",
          "title_language" => "en"
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["title_language"] == "en"

      source_id = response["id"]
      get_response = conn |> recycle() |> get("/sources/#{source_id}?_format=json") |> json_response(200)
      assert get_response["title_language"] == "en"
    end

    test "updates a source title language and round-trips it", %{conn: conn} do
      source = source_fixture()

      attrs = %{"source" => %{"title_language" => "ja"}, "_format" => "json"}

      response = conn |> put("/sources/#{source.id}", attrs) |> json_response(200)
      assert response["title_language"] == "ja"

      assert Sources.get_source!(source.id).title_language == "ja"

      show = conn |> recycle() |> get("/sources/#{source.id}?_format=json") |> json_response(200)
      assert show["title_language"] == "ja"
    end

    test "returns a validation error for an invalid title language", %{conn: conn} do
      source = source_fixture()

      response =
        conn
        |> put("/sources/#{source.id}", %{"source" => %{"title_language" => "nope!"}, "_format" => "json"})
        |> json_response(422)

      assert response["errors"]["title_language"] == ["must be a YouTube language code such as en, ja, pt-PT or zh-CN"]
      assert Sources.get_source!(source.id).title_language == nil
    end
  end

  describe "keep newest over JSON API" do
    test "creates a source with a keep_newest_count and round-trips it", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Keep Newest Channel",
           channel_id: "UC_keep_newest_channel",
           playlist_id: "UC_keep_newest_channel",
           playlist_title: "Keep Newest Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_keep_newest_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Keep Newest Channel",
          "keep_newest_count" => 4
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["keep_newest_count"] == 4

      show = conn |> recycle() |> get("/sources/#{response["id"]}?_format=json") |> json_response(200)
      assert show["keep_newest_count"] == 4
    end

    test "updates a keep_newest_count without the HTML confirmation", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: 5, download_media: false})

      for offset <- 0..4 do
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: "/video/#{offset}.mp4",
          uploaded_at: DateTime.add(~U[2026-11-20 00:00:00Z], offset, :day)
        })
      end

      attrs = %{"source" => %{"keep_newest_count" => 2}, "_format" => "json"}

      response = conn |> put("/sources/#{source.id}", attrs) |> json_response(200)
      assert response["keep_newest_count"] == 2

      assert Sources.get_source!(source.id).keep_newest_count == 2
    end
  end

  describe "SponsorBlock overrides over JSON API" do
    test "creates a source that inherits the profile lists", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Inherit Channel",
           channel_id: "UC_inherit_channel",
           playlist_id: "UC_inherit_channel",
           playlist_title: "Inherit Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_inherit_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Inherit Channel",
          "sponsorblock_mark_categories" => nil,
          "sponsorblock_remove_categories" => nil
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["sponsorblock_mark_categories"] == nil
      assert response["sponsorblock_remove_categories"] == nil

      stored = Sources.get_source!(response["id"])
      assert stored.sponsorblock_mark_categories == nil
      assert stored.sponsorblock_remove_categories == nil
    end

    test "creates a source that disables both actions with empty lists", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Disabled Channel",
           channel_id: "UC_disabled_channel",
           playlist_id: "UC_disabled_channel",
           playlist_title: "Disabled Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_disabled_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Disabled Channel",
          "sponsorblock_mark_categories" => [],
          "sponsorblock_remove_categories" => []
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["sponsorblock_mark_categories"] == []
      assert response["sponsorblock_remove_categories"] == []

      stored = Sources.get_source!(response["id"])
      assert stored.sponsorblock_mark_categories == []
      assert stored.sponsorblock_remove_categories == []
    end

    test "creates a source with custom categories", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Custom Channel",
           channel_id: "UC_custom_channel",
           playlist_id: "UC_custom_channel",
           playlist_title: "Custom Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_custom_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Custom Channel",
          "sponsorblock_mark_categories" => ["intro"],
          "sponsorblock_remove_categories" => ["sponsor"]
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["sponsorblock_mark_categories"] == ["intro"]
      assert response["sponsorblock_remove_categories"] == ["sponsor"]

      stored = Sources.get_source!(response["id"])
      assert stored.sponsorblock_mark_categories == ["intro"]
      assert stored.sponsorblock_remove_categories == ["sponsor"]
    end

    test "updates a source through all three states", %{conn: conn} do
      source = source_fixture()

      custom =
        conn
        |> put("/sources/#{source.id}", %{
          "source" => %{
            "sponsorblock_mark_categories" => ["intro"],
            "sponsorblock_remove_categories" => ["sponsor"]
          },
          "_format" => "json"
        })
        |> json_response(200)

      assert custom["sponsorblock_mark_categories"] == ["intro"]
      assert custom["sponsorblock_remove_categories"] == ["sponsor"]

      disabled =
        conn
        |> recycle()
        |> put("/sources/#{source.id}", %{
          "source" => %{
            "sponsorblock_mark_categories" => [],
            "sponsorblock_remove_categories" => []
          },
          "_format" => "json"
        })
        |> json_response(200)

      assert disabled["sponsorblock_mark_categories"] == []
      assert disabled["sponsorblock_remove_categories"] == []
      assert Sources.get_source!(source.id).sponsorblock_mark_categories == []
      assert Sources.get_source!(source.id).sponsorblock_remove_categories == []

      inherited =
        conn
        |> recycle()
        |> put("/sources/#{source.id}", %{
          "source" => %{
            "sponsorblock_mark_categories" => nil,
            "sponsorblock_remove_categories" => nil
          },
          "_format" => "json"
        })
        |> json_response(200)

      assert inherited["sponsorblock_mark_categories"] == nil
      assert inherited["sponsorblock_remove_categories"] == nil
      assert Sources.get_source!(source.id).sponsorblock_mark_categories == nil
      assert Sources.get_source!(source.id).sponsorblock_remove_categories == nil
    end

    test "rejects an unknown category", %{conn: conn} do
      source = source_fixture()

      response =
        conn
        |> put("/sources/#{source.id}", %{
          "source" => %{"sponsorblock_remove_categories" => ["not_a_category"]},
          "_format" => "json"
        })
        |> json_response(422)

      assert response["errors"]["sponsorblock_remove_categories"] != []
      assert Sources.get_source!(source.id).sponsorblock_remove_categories == nil
    end

    test "rejects overlapping mark and remove categories", %{conn: conn} do
      source = source_fixture()

      response =
        conn
        |> put("/sources/#{source.id}", %{
          "source" => %{
            "sponsorblock_remove_categories" => ["sponsor", "intro"],
            "sponsorblock_mark_categories" => ["intro"]
          },
          "_format" => "json"
        })
        |> json_response(422)

      assert "can't mark and remove the same category: intro" in response["errors"]["sponsorblock_mark_categories"]
    end
  end

  describe "download cutoff over JSON API" do
    test "creates a source with rolling cutoff days", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Rolling Channel",
           channel_id: "UC_rolling_channel",
           playlist_id: "UC_rolling_channel",
           playlist_title: "Rolling Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_rolling_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Rolling Channel",
          "download_cutoff_days" => 30
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)

      assert response["download_cutoff_days"] == 30
      assert response["download_cutoff_date"] == nil
      assert Sources.get_source!(response["id"]).download_cutoff_days == 30
    end

    test "updates rolling days and clears the fixed date", %{conn: conn} do
      source = source_fixture(download_cutoff_date: ~D[2026-07-01])

      attrs = %{
        "source" => %{"download_cutoff_date" => "", "download_cutoff_days" => 30},
        "_format" => "json"
      }

      response = conn |> put("/sources/#{source.id}", attrs) |> json_response(200)

      assert response["download_cutoff_days"] == 30
      assert is_nil(response["download_cutoff_date"])

      updated = Sources.get_source!(source.id)
      assert updated.download_cutoff_days == 30
      assert is_nil(updated.download_cutoff_date)
    end

    test "rejects a source that sets both cutoff forms", %{conn: conn} do
      source = source_fixture()

      attrs = %{
        "source" => %{"download_cutoff_date" => "2026-07-01", "download_cutoff_days" => 30},
        "_format" => "json"
      }

      response = conn |> put("/sources/#{source.id}", attrs) |> json_response(422)

      assert response["errors"]["download_cutoff_days"] == ["must be blank when a download cutoff date is set"]
      assert is_nil(Sources.get_source!(source.id).download_cutoff_days)
    end
  end

  describe "delete/2 JSON API" do
    test "a protected source returns JSON conflict without scheduling deletion", %{conn: conn} do
      profile = media_profile_fixture() |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
      source = source_fixture(media_profile_id: profile.id)
      path = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "blocked-#{Ecto.UUID.generate()}.mp4")
      File.write!(path, "original")
      item = media_item_fixture(source_id: source.id, media_filepath: path)
      {:ok, _watch} = Pinchflat.MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))

      for delete_files <- ["false", "true"] do
        response = delete(conn, "/sources/#{source.id}?delete_files=#{delete_files}&_format=json")
        assert json_response(response, 409)["error"] =~ "End watch protection"
        refute Repo.reload!(source).marked_for_deletion_at
        refute_enqueued(worker: Pinchflat.Sources.SourceDeletionWorker)
      end
    end

    test "deletes source and returns JSON", %{conn: conn} do
      source = source_fixture()

      conn = delete(conn, "/sources/#{source.id}?delete_files=false&_format=json")

      # Should return 200 for JSON
      assert conn.status == 200

      # Verify source is marked for deletion
      updated_source = Sources.get_source!(source.id)
      assert updated_source.marked_for_deletion_at != nil
    end
  end
end
