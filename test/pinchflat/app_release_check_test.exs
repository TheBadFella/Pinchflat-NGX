defmodule Pinchflat.AppReleaseCheckTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.AppReleaseCheck

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:pinchflat, :app_release_check)
    Application.put_env(:pinchflat, :app_release_check, true)
    AppReleaseCheck.clear_cache()

    on_exit(fn ->
      AppReleaseCheck.clear_cache()

      if previous == nil do
        Application.delete_env(:pinchflat, :app_release_check)
      else
        Application.put_env(:pinchflat, :app_release_check, previous)
      end
    end)

    :ok
  end

  describe "status/0" do
    test "reports latest when GitHub matches the running version" do
      current = AppReleaseCheck.current_version()

      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "TheBadFella/PinchYT/releases/latest"
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
  end
end
