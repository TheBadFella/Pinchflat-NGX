defmodule PinchflatWeb.Api.ShareControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.ShareTokens
  alias Pinchflat.ShareTokens.RateLimiter

  setup %{conn: conn} do
    RateLimiter.reset!()
    profile = media_profile_fixture()
    {:ok, token, secret} = ShareTokens.create_token(%{name: "Test Token", media_profile_id: profile.id})

    %{conn: put_req_header(conn, "content-type", "application/json"), profile: profile, token: token, secret: secret}
  end

  for {kind, duration, ratio, shorts?} <- [{"regular video", 600, 1.7, false}, {"Short", 45, 0.56, true}] do
    @index_duration duration
    @index_ratio ratio
    @index_shorts shorts?
    test "intake resolves the title and template for #{kind}, with artwork disabled", context do
      %{conn: conn, profile: profile, secret: secret} = context

      {:ok, _} =
        Pinchflat.Profiles.update_media_profile(profile, %{
          output_path_template: "{{ source_custom_name }}/{{ title }}.{{ ext }}",
          output_path_template_shorts: "{{ source_custom_name }}/Shorts/{{ title }}.{{ ext }}",
          download_source_images: false,
          retention_period_days: 2
        })

      response =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{"url" => "https://youtu.be/dQw4w9WgXcQ"})

      assert json_response(response, 202)["status"] == "indexing"
      source = Repo.get_by!(Pinchflat.Sources.Source, collection_id: "dQw4w9WgXcQ", media_profile_id: profile.id)
      assert source.retention_period_days == nil
      assert Pinchflat.Sources.Source.effective_retention_period_days(Repo.preload(source, :media_profile)) == 2

      metadata = %{
        "id" => source.collection_id,
        "title" => "Recognisable video",
        "ext" => "mp4",
        "original_url" => source.original_url,
        "upload_date" => "20261019",
        "duration" => @index_duration,
        "aspect_ratio" => @index_ratio,
        "filename" => "/tmp/test/media/YouTube Video dQw4w9WgXcQ/Recognisable video.mp4"
      }

      stub(AppriseRunnerMock, :run, fn _, _ -> {:ok, ""} end)

      folder =
        if @index_shorts, do: "/tmp/test/media/Recognisable video/Shorts", else: "/tmp/test/media/Recognisable video"

      expected = folder <> "/Recognisable video.mp4"
      expected_output = folder <> "/%(title)S.%(ext)S"
      Process.put(:combined_prediction_calls, 0)

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_media_attributes_for_collection, _opts, _template, _extra ->
          {:ok, Jason.encode!(metadata)}

        _url, :get_downloadable_status, _opts, _template, _extra ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _template, _extra ->
          {:ok, ""}

        _url, :download, opts, _template, _extra ->
          assert List.keyfind(opts, :output, 0) == {:output, expected_output}
          File.mkdir_p!(Path.dirname(expected))
          File.write!(expected, "fixture media")

          downloaded_metadata =
            render_parsed_metadata(:media_metadata)
            |> Map.merge(metadata)
            |> Map.put("filepath", expected)

          {:ok, Jason.encode!(downloaded_metadata)}

        _url, :predict_filepath_from_metadata, opts, _template, _extra ->
          Process.put(:combined_prediction_calls, Process.get(:combined_prediction_calls) + 1)
          assert Keyword.fetch!(opts, :output) == expected_output
          assert File.exists?(Keyword.fetch!(opts, :load_info_json))
          {:ok, Jason.encode!(%{"filename" => expected})}
      end)

      assert :ok = perform_job(Pinchflat.SlowIndexing.MediaCollectionIndexingWorker, %{id: source.id})
      assert Repo.reload!(source).custom_name == "Recognisable video"
      item = Repo.get_by!(Pinchflat.Media.MediaItem, source_id: source.id)
      assert item.predicted_media_filepath == expected
      assert item.short_form_content == @index_shorts
      assert Process.get(:combined_prediction_calls) == 1
      assert_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker, args: %{"id" => item.id})
      item = Repo.preload(item, source: :media_profile)

      assert Pinchflat.Downloading.DownloadOptionBuilder.build_output_path_for(item) ==
               expected_output

      stub(UserScriptRunnerMock, :run, fn _, _ -> {:ok, "", 0} end)
      stub(HTTPClientMock, :get, fn _, _, _ -> {:ok, ""} end)
      on_exit(fn -> File.rm(expected) end)
      assert :ok = perform_job(Pinchflat.Downloading.MediaDownloadWorker, %{id: item.id})
      downloaded = Repo.reload!(item)
      assert downloaded.media_filepath == expected
      assert downloaded.short_form_content == @index_shorts
      assert downloaded.media_downloaded_at
      assert File.read!(expected) == "fixture media"
    end
  end

  describe "POST /api/share/intake - Authentication" do
    test "API docs expose bearer authentication for sharing", %{conn: conn} do
      spec = conn |> get("/api/spec") |> json_response(200)
      assert spec["components"]["securitySchemes"]["shareToken"]["scheme"] == "bearer"
      assert spec["paths"]["/api/share/intake"]["post"]["security"] == [%{"shareToken" => []}]
      assert spec["paths"]["/api/share/intake"]["post"]["responses"]["415"]
    end

    test "rejects multipart before buffering it", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("content-type", "multipart/form-data; boundary=owned")
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", String.duplicate("x", 8193))

      assert json_response(conn, 415)["error"] == "unsupported_media_type"
    end

    test "format-suffixed routes cannot bypass the raw body limit", %{conn: conn} do
      payload = Jason.encode!(%{"url" => "https://youtu.be/dQw4w9WgXcQ", "padding" => String.duplicate("x", 9000)})

      for path <- ["/api/share/intake.json", "/api/share/intake.foo"] do
        response = post(conn, path, payload)
        assert json_response(response, 413)["error"] == "payload_too_large"
      end
    end

    test "expired token creates no source or job", %{conn: conn, token: token, secret: secret} do
      token
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second))
      |> Pinchflat.Repo.update!()

      before_counts =
        {Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count), Pinchflat.Repo.aggregate(Oban.Job, :count)}

      response =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{"url" => "https://youtu.be/dQw4w9WgXcQ"})

      assert json_response(response, 401)["error"] == "expired_token"

      assert {Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count), Pinchflat.Repo.aggregate(Oban.Job, :count)} ==
               before_counts
    end

    test "rejects request without Authorization header", %{conn: conn} do
      conn =
        post(conn, "/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects request with invalid token secret", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_secret_12345")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects request with revoked token", %{conn: conn, token: token, secret: secret} do
      {:ok, _} = ShareTokens.revoke_token(token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      response = json_response(conn, 401)
      assert response["error"] == "revoked_token"
    end

    test "rejects request when bound media profile is deleted", %{conn: conn, profile: profile, secret: secret} do
      {:ok, _} = Pinchflat.Profiles.delete_media_profile(profile)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert json_response(conn, 422)["error"] == "invalid_profile"
    end
  end

  describe "POST /api/share/intake - Validation and Overrides" do
    test "rejects profile override attempts", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "profile_id" => 999
        })

      assert json_response(conn, 400)["error"] == "override_rejected"
    end

    test "rejects force download overrides", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "force" => true
        })

      assert json_response(conn, 400)["error"] == "override_rejected"
    end

    test "rejects missing or empty url", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{"url" => ""})

      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "rejects channel and playlist URLs with informative message", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/channel/UC1234567890123456789012"
        })

      response = json_response(conn, 422)
      assert response["error"] == "channel_or_playlist_not_supported"
    end

    test "rejects malformed or non-YouTube URLs", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://vimeo.com/12345678"
        })

      assert json_response(conn, 422)["error"] == "invalid_url"
    end

    test "rejects request bodies larger than 8KiB", %{conn: conn, secret: secret} do
      oversized_padding = String.duplicate("x", 8500)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> put_req_header("content-length", "8550")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "padding" => oversized_padding
        })

      assert json_response(conn, 413)["error"] == "payload_too_large"
    end

    test "rejects request bodies larger than 8KiB without Content-Length header", %{conn: conn, secret: secret} do
      oversized_padding = String.duplicate("x", 9000)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/share/intake", Jason.encode!(%{"url" => oversized_padding}))

      assert conn.status == 413
      assert json_response(conn, 413)["error"] == "payload_too_large"
    end

    test "rejects duplicate authorization headers", %{conn: conn, secret: secret} do
      conn = %{
        conn
        | req_headers: [
            {"authorization", "Bearer #{secret}"},
            {"authorization", "Bearer duplicate_token"} | conn.req_headers
          ]
      }

      conn =
        conn
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects malformed authorization header with empty bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer    ")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  describe "POST /api/share/intake - Rate Limiting" do
    test "enforces 10 requests per minute limit per credential", %{conn: conn, secret: secret} do
      # 10 allowed requests
      for _i <- 1..10 do
        post_conn =
          conn
          |> put_req_header("authorization", "Bearer #{secret}")
          |> post("/api/share/intake", %{
            "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          })

        assert post_conn.status in [202, 409]
      end

      # 11th request triggers 429
      blocked_conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert blocked_conn.status == 429
      response = json_response(blocked_conn, 429)
      assert response["error"] == "rate_limited"
      assert [retry_after] = get_resp_header(blocked_conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "enforces invalid auth flooding limits per client IP", %{conn: conn} do
      for _i <- 1..20 do
        RateLimiter.record_invalid_auth(conn.remote_ip)
      end

      blocked_conn =
        conn
        |> put_req_header("authorization", "Bearer wrong_token")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert blocked_conn.status == 429
      assert json_response(blocked_conn, 429)["error"] == "rate_limited"
    end
  end

  describe "POST /api/share/intake - Execution and States" do
    test "successfully queues video and returns 202 Accepted", %{conn: conn, profile: profile, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert conn.status == 202
      response = json_response(conn, 202)
      assert response["status"] in ["queued", "queued_paused", "indexing"]
      assert response["video_id"] == "dQw4w9WgXcQ"
      assert response["canonical_url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      assert response["media_profile_id"] == profile.id
    end

    test "returns 409 Conflict when item is already present in library", %{conn: conn, profile: profile, secret: secret} do
      media_dir = Application.fetch_env!(:pinchflat, :media_directory)
      File.mkdir_p!(media_dir)
      file_path = Path.join(media_dir, "vid_present_#{System.unique_integer([:positive])}.mp4")
      File.write!(file_path, "present bytes")
      on_exit(fn -> File.rm(file_path) end)

      source = source_fixture(%{media_profile_id: profile.id})

      _item =
        media_item_fixture(%{
          source_id: source.id,
          media_id: "dQw4w9WgXcQ",
          media_filepath: file_path
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      assert conn.status == 409
      assert json_response(conn, 409)["error"] == "already_present"
    end

    test "raw secret is absent from response and database", %{conn: conn, secret: secret} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> post("/api/share/intake", %{
          "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        })

      refute conn.resp_body =~ secret
      tokens = Pinchflat.Repo.all(Pinchflat.ShareTokens.ShareToken)

      for t <- tokens do
        refute t.token_digest == secret
      end
    end
  end
end
