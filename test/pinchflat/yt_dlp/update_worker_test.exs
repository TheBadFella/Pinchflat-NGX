defmodule Pinchflat.YtDlp.UpdateWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateWorker

  describe "perform/1 with the default (stable) policy" do
    test "updates to the exact latest stable version so yt-dlp will downgrade if needed" do
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn "2025.07.01" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "falls back to a channel update when the stable lookup fails" do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, "boom"} end)
      expect(YtDlpRunnerMock, :update, fn "stable" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "saves the new version to the database" do
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn "2025.07.01" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
    end

    test "keeps going when the yt-dlp update fails but version lookup still works" do
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn _target -> {:error, "tls eof"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      assert :ok = perform_job(UpdateWorker, %{})
      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
    end

    test "returns ok when both update and version lookup fail" do
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn _target -> {:error, "tls eof"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:error, "still broken"} end)

      assert :ok = perform_job(UpdateWorker, %{})
    end
  end

  describe "perform/1 for scheduled runs" do
    test "tracks nightly when the policy is nightly" do
      Settings.set(yt_dlp_update_policy: "nightly")
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "re-asserts the frozen nightly build when a baseline is recorded" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      Settings.set(yt_dlp_nightly_baseline: "2025.06.28.123456")
      expect(YtDlpRunnerMock, :update, fn "nightly@2025.06.28.123456" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "does not update when the policy is nightly_frozen with no known baseline" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "re-asserts the pinned version when the policy is pinned" do
      pin_to_version("2025.01.01")
      expect(YtDlpRunnerMock, :update, fn "2025.01.01" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end
  end

  describe "perform/1 with the nightly_until_stable policy" do
    setup do
      Settings.set(yt_dlp_update_policy: "nightly_until_stable")
      Settings.set(yt_dlp_nightly_baseline: "2025.06.28.123456")
      :ok
    end

    test "reverts to stable and updates when stable has caught up" do
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn "2025.07.01" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.07.01"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "stable"} = Settings.get(:yt_dlp_update_policy)
      assert {:ok, nil} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "holds on nightly and re-asserts the baseline build when stable has not caught up" do
      stub_latest_stable("2025.06.01")
      # re-asserts the held nightly so an image swap can't strand us on the baked-in stable
      expect(YtDlpRunnerMock, :update, fn "nightly@2025.06.28.123456" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.06.28.123456"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "nightly_until_stable"} = Settings.get(:yt_dlp_update_policy)
    end

    test "stays on nightly and re-asserts the baseline build when the stable lookup fails" do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, "boom"} end)
      expect(YtDlpRunnerMock, :update, fn "nightly@2025.06.28.123456" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.06.28.123456"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "nightly_until_stable"} = Settings.get(:yt_dlp_update_policy)
    end
  end

  describe "perform/1 when applying a policy (one-shot jump)" do
    test "jumps to nightly for nightly_until_stable and records the baseline" do
      Settings.set(yt_dlp_update_policy: "nightly_until_stable")
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:ok, ""} end)
      # once for the baseline capture, once for the version refresh
      expect(YtDlpRunnerMock, :version, 2, fn -> {:ok, "2025.06.28.123456"} end)

      perform_job(UpdateWorker, %{"apply_policy" => true})

      assert {:ok, "2025.06.28.123456"} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "jumps to nightly for nightly_frozen and records the frozen baseline" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:ok, ""} end)
      # once for the baseline capture, once for the version refresh
      expect(YtDlpRunnerMock, :version, 2, fn -> {:ok, "2025.06.28.123456"} end)

      perform_job(UpdateWorker, %{"apply_policy" => true})

      assert {:ok, "2025.06.28.123456"} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "installs the pinned version for the pinned policy" do
      pin_to_version("2025.01.01")
      expect(YtDlpRunnerMock, :update, fn "2025.01.01" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.01.01"} end)

      perform_job(UpdateWorker, %{"apply_policy" => true})
    end
  end

  defp stub_latest_stable(version) do
    expect(HTTPClientMock, :get, fn _url, _headers -> {:ok, Jason.encode!(%{"tag_name" => version})} end)
  end

  # The policy and version are validated together, mirroring how the settings
  # form submits both fields in a single changeset.
  defp pin_to_version(version) do
    Settings.update_setting(Settings.record(), %{
      yt_dlp_update_policy: "pinned",
      yt_dlp_pinned_version: version
    })
  end
end
