defmodule Pinchflat.AppReleaseCheckTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.AppReleaseCheck

  setup :verify_on_exit!

  setup do
    previous_check = Application.get_env(:pinchflat, :app_release_check)
    previous_track = Application.get_env(:pinchflat, :build_track)
    previous_sha = Application.get_env(:pinchflat, :build_sha)

    Application.put_env(:pinchflat, :app_release_check, true)
    Application.put_env(:pinchflat, :build_track, "stable")
    Application.delete_env(:pinchflat, :build_sha)
    AppReleaseCheck.clear_cache()

    on_exit(fn ->
      AppReleaseCheck.clear_cache()

      if previous_check == nil do
        Application.delete_env(:pinchflat, :app_release_check)
      else
        Application.put_env(:pinchflat, :app_release_check, previous_check)
      end

      if previous_track == nil do
        Application.delete_env(:pinchflat, :build_track)
      else
        Application.put_env(:pinchflat, :build_track, previous_track)
      end

      if previous_sha == nil do
        Application.delete_env(:pinchflat, :build_sha)
      else
        Application.put_env(:pinchflat, :build_sha, previous_sha)
      end
    end)

    :ok
  end

  describe "status/0" do
    test "reports latest when GitHub matches the running version" do
      current = AppReleaseCheck.current_version()

      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "TheBadFella/pinchflat-ngx/releases/latest"
        {:ok, Jason.encode!(%{"tag_name" => current})}
      end)

      assert {:latest, ^current} = AppReleaseCheck.status()
    end

    test "reports an update when GitHub is ahead of the running version" do
      expect(HTTPClientMock, :get, fn _url, _headers ->
        {:ok, Jason.encode!(%{"tag_name" => "v9999.12.31"})}
      end)

      assert {:update_available, current, "9999.12.31"} = AppReleaseCheck.status()
      assert current == AppReleaseCheck.current_version()
    end

    test "fails closed to latest when GitHub cannot be reached" do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, "boom"} end)

      current = AppReleaseCheck.current_version()
      assert {:latest, ^current} = AppReleaseCheck.status()
    end

    test "reports dev with commit sha without querying GitHub when build_track is dev" do
      Application.put_env(:pinchflat, :build_track, "dev")
      Application.put_env(:pinchflat, :build_sha, "1b7c57fe3ea7c0f0e8ad2749b342e44eced7c85c")

      assert {:dev, "1b7c57fe3ea7c0f0e8ad2749b342e44eced7c85c"} = AppReleaseCheck.status()
    end

    test "reports dev with nil sha when sha is absent or blank" do
      Application.put_env(:pinchflat, :build_track, "dev")
      Application.delete_env(:pinchflat, :build_sha)

      assert {:dev, nil} = AppReleaseCheck.status()

      Application.put_env(:pinchflat, :build_sha, "   ")
      assert {:dev, nil} = AppReleaseCheck.status()
    end
  end

  describe "display_version/0" do
    test "returns current version for stable track" do
      Application.put_env(:pinchflat, :build_track, "stable")
      assert AppReleaseCheck.display_version() == AppReleaseCheck.current_version()
    end

    test "includes dev tag and short sha when running dev build" do
      Application.put_env(:pinchflat, :build_track, "dev")
      Application.put_env(:pinchflat, :build_sha, "1b7c57fe3ea7c0f0e8ad2749b342e44eced7c85c")

      assert AppReleaseCheck.display_version() == "#{AppReleaseCheck.current_version()} (dev-1b7c57f)"
    end

    test "falls back to dev tag when sha is absent" do
      Application.put_env(:pinchflat, :build_track, "dev")
      Application.delete_env(:pinchflat, :build_sha)

      assert AppReleaseCheck.display_version() == "#{AppReleaseCheck.current_version()} (dev)"
    end
  end
end
