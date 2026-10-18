defmodule PinchflatWeb.Api.AccessTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures

  setup do
    keys = [:basic_auth_username, :basic_auth_password, :oidc, :postgres_migration_boot_held]
    previous = Map.new(keys, &{&1, Application.get_env(:pinchflat, &1)})
    Enum.each(keys, &Application.delete_env(:pinchflat, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:pinchflat, key)
        {key, value} -> Application.put_env(:pinchflat, key, value)
      end)
    end)

    :ok
  end

  test "Basic Auth protects library reads and rejects writes before side effects" do
    item = media_item_fixture()
    Application.put_env(:pinchflat, :basic_auth_username, "operator")
    Application.put_env(:pinchflat, :basic_auth_password, "fixture-password")

    assert get(build_conn(), "/api/media").status == 401
    assert delete(build_conn(), "/api/media/#{item.id}").status == 401
    assert Repo.get!(Pinchflat.Media.MediaItem, item.id).prevent_download == item.prevent_download

    conn =
      build_conn()
      |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("operator", "fixture-password"))
      |> get("/api/media")

    assert json_response(conn, 200)["data"] != []
  end

  test "OIDC without API credentials fails closed without redirecting to browser login" do
    Application.put_env(:pinchflat, :oidc,
      issuer: "https://identity.example.test",
      client_id: "fixture",
      client_secret: "fixture"
    )

    assert get(build_conn(), "/api/media").status == 401
    assert post(build_conn(), "/api/sources/123/actions/index").status == 401
    assert get(build_conn(), "/healthcheck").status == 200
    assert get(build_conn(), "/api/spec").status == 200
  end

  test "an incomplete Basic Auth configuration does not leave management routes open" do
    Application.put_env(:pinchflat, :basic_auth_username, "operator")
    assert get(build_conn(), "/api/media").status == 401
  end

  test "OIDC installations can use Basic Auth for API clients without a browser session" do
    Application.put_env(:pinchflat, :oidc,
      issuer: "https://identity.example.test",
      client_id: "fixture",
      client_secret: "fixture"
    )

    Application.put_env(:pinchflat, :basic_auth_username, "operator")
    Application.put_env(:pinchflat, :basic_auth_password, "fixture-password")

    response =
      build_conn()
      |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("operator", "fixture-password"))
      |> get("/api/media")

    assert json_response(response, 200)["data"] == []
  end

  test "duplicate authorization headers and an OIDC browser session do not authorize API access" do
    Application.put_env(:pinchflat, :basic_auth_username, "operator")
    Application.put_env(:pinchflat, :basic_auth_password, "fixture-password")
    authorization = Plug.BasicAuth.encode_basic_auth("operator", "fixture-password")
    conn = %{build_conn() | req_headers: [{"authorization", authorization}, {"authorization", authorization}]}
    assert get(conn, "/api/media").status == 401
    conn = Plug.Test.init_test_session(build_conn(), %{PinchflatWeb.OIDC.session_key() => %{sub: "fixture"}})
    assert get(conn, "/api/media").status == 401
  end

  test "unconfigured trusted-network installations retain API access" do
    assert json_response(get(build_conn(), "/api/media"), 200)["data"] == []
  end

  test "PostgreSQL transfer review blocks API writes while preserving read access" do
    Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
    assert json_response(get(build_conn(), "/api/media"), 200)["data"] == []

    conn =
      post(build_conn(), "/api/media_profiles", %{
        "media_profile" => %{"name" => "Must not be created", "output_path_template" => "{{id}}.{{ext}}"}
      })

    assert json_response(conn, 423)["error"] =~ "migration review"
    assert Repo.aggregate(Pinchflat.Profiles.MediaProfile, :count) == 0
  end
end
