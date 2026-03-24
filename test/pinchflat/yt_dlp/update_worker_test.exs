defmodule Pinchflat.YtDlp.UpdateWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateWorker

  describe "perform/1" do
    test "calls the yt-dlp runner to update yt-dlp" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, ""} end)

      perform_job(UpdateWorker, %{})
    end

    test "saves the new version to the database" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      perform_job(UpdateWorker, %{})

      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
    end

    test "keeps going when the yt-dlp update fails but version lookup still works" do
      expect(YtDlpRunnerMock, :update, fn -> {:error, "tls eof"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "1.2.3"} end)

      assert :ok = perform_job(UpdateWorker, %{})
      assert {:ok, "1.2.3"} = Settings.get(:yt_dlp_version)
    end

    test "returns ok when both update and version lookup fail" do
      expect(YtDlpRunnerMock, :update, fn -> {:error, "tls eof"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:error, "still broken"} end)

      assert :ok = perform_job(UpdateWorker, %{})
    end
  end
end
