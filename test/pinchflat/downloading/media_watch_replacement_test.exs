defmodule Pinchflat.Downloading.MediaWatchReplacementTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media
  alias Pinchflat.MediaWatch
  alias Pinchflat.Repo

  setup do
    profile = media_profile_fixture()

    profile =
      profile
      |> Ecto.Changeset.change(watch_window_days: 14)
      |> Repo.update!()

    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_with_attachments(%{source_id: source.id})
    File.write!(item.media_filepath, "first artifact")

    {:ok, _watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
    {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(1, :day)})

    stub(UserScriptRunnerMock, :run, fn _event, _item -> {:ok, "", 0} end)
    stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 10_000_000_000} end)

    %{item: Repo.reload(item)}
  end

  test "a quality upgrade of a watched item is skipped before any download", %{item: item} do
    assert :ok =
             MediaDownloadWorker.perform(%Oban.Job{
               args: %{"id" => item.id, "quality_upgrade?" => true}
             })

    assert File.read!(item.media_filepath) == "first artifact"
  end

  test "force retry cannot bypass the watched-replacement gate", %{item: item} do
    assert :ok =
             MediaDownloadWorker.perform(%Oban.Job{
               args: %{"id" => item.id, "force" => true, "reset_last_error" => true}
             })

    assert File.read!(item.media_filepath) == "first artifact"
  end

  test "the downloader refuses a watched replacement before transfer and keeps the original", %{item: item} do
    Application.put_env(:pinchflat, :media_watch_destructive_enabled, false)
    on_exit(fn -> Application.delete_env(:pinchflat, :media_watch_destructive_enabled) end)
    staged_file = Path.join(Application.fetch_env!(:pinchflat, :tmpfile_directory), "watch-#{item.id}.mp4")

    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _opts, _output, _addl ->
        {:ok, "{}"}

      _url, :download_thumbnail, _opts, _output, _addl ->
        {:ok, ""}

      _url, :download, _opts, _output, _addl ->
        File.mkdir_p!(Path.dirname(staged_file))
        File.write!(staged_file, "staged replacement")
        {:ok, metadata(staged_file)}
    end)

    assert {:error, :watch_hold, message} =
             Pinchflat.Downloading.MediaDownloader.download_for_media_item(item)

    assert message =~ "preservation is approved"
    assert File.read!(item.media_filepath) == "first artifact"
  end

  defp metadata(path) do
    :media_metadata
    |> render_metadata()
    |> Jason.decode!()
    |> Map.merge(%{"filepath" => path, "duration" => 90, "availability" => nil})
    |> Jason.encode!()
  end
end
