defmodule Pinchflat.TranslatedTitlesWorkflowTest do
  use Pinchflat.DataCase

  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  setup do
    stub_backend()
    stub_side_effects()
    :ok
  end

  describe "translated titles end-to-end workflow" do
    test "indexes translated titles, enqueues downloads, and names files with them" do
      source = translated_titles_source()

      perform_job(MediaCollectionIndexingWorker, %{"id" => source.id})

      item_1 = media_item_for(source, "vid_1")
      item_2 = media_item_for(source, "vid_2")

      assert item_1.title == "Original Title One"
      assert item_1.translated_title == "Translated Title One"
      assert item_2.title == "Original Title Two"
      assert item_2.translated_title == nil

      assert length(all_enqueued(worker: MediaDownloadWorker)) == 2
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => item_1.id})
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => item_2.id})

      assert :ok = perform_job(MediaDownloadWorker, %{"id" => item_1.id})
      assert_received {:download_output, "vid_1", output_1}
      assert output_1 =~ "Translated Title One"
      refute output_1 =~ "Original Title One"

      item_1 = Repo.reload!(item_1)
      assert item_1.title == "Original Title One"
      assert item_1.translated_title == "Translated Title One"
      assert item_1.media_filepath == expected_media_path("Translated Title One")

      assert :ok = perform_job(MediaDownloadWorker, %{"id" => item_2.id})
      assert_received {:download_output, "vid_2", output_2}
      assert output_2 =~ "Original Title Two"
      refute output_2 =~ "Translated Title"

      item_2 = Repo.reload!(item_2)
      assert item_2.translated_title == nil
      assert item_2.media_filepath == expected_media_path("Original Title Two")
    end

    test "keeps using the stored translated title after title_language is cleared before download" do
      source = translated_titles_source()

      perform_job(MediaCollectionIndexingWorker, %{"id" => source.id})

      item_1 = media_item_for(source, "vid_1")
      assert item_1.translated_title == "Translated Title One"

      assert {:ok, updated_source} = Sources.update_source(source, %{title_language: nil})
      assert updated_source.title_language == nil

      assert :ok = perform_job(MediaDownloadWorker, %{"id" => item_1.id})
      assert_received {:download_output, "vid_1", output}
      assert output =~ "Translated Title One"

      item_1 = Repo.reload!(item_1)
      assert item_1.translated_title == "Translated Title One"
      assert item_1.media_filepath == expected_media_path("Translated Title One")
    end
  end

  defp translated_titles_source do
    profile =
      media_profile_fixture(%{
        output_path_template: "{{ source_custom_name }}/{{ translated_title }}.{{ ext }}"
      })

    source_fixture(%{
      collection_type: :channel,
      title_language: "en",
      download_media: true,
      media_profile_id: profile.id
    })
  end

  defp media_item_for(source, media_id) do
    Repo.get_by!(MediaItem, source_id: source.id, media_id: media_id)
  end

  defp expected_media_path(title) do
    Path.join([
      Application.fetch_env!(:pinchflat, :media_directory),
      "Cool and good internal name!",
      "#{title}.mp4"
    ])
  end

  defp stub_backend do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_translated_titles, _opts, _template, _addl ->
        {:ok, json_lines(translated_titles())}

      _url, :get_media_attributes_for_collection, _opts, _template, _addl ->
        {:ok, json_lines(collection_attributes())}

      url, :download, opts, _template, _addl ->
        media_id = media_id_for(url)
        output = Keyword.fetch!(opts, :output)

        send(self(), {:download_output, media_id, output})

        {:ok, Phoenix.json_library().encode!(download_attributes(media_id, output))}

      _url, :download_thumbnail, _opts, _template, _addl ->
        {:ok, ""}
    end)
  end

  defp stub_side_effects do
    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    stub(AppriseRunnerMock, :run, fn _servers, _opts -> {:ok, ""} end)
  end

  defp translated_titles do
    [
      %{"id" => "vid_1", "title" => "Translated Title One"},
      %{"id" => "vid_2", "title" => "Original Title Two"}
    ]
  end

  defp collection_attributes do
    [
      collection_attributes_for("vid_1", "Original Title One"),
      collection_attributes_for("vid_2", "Original Title Two")
    ]
  end

  defp collection_attributes_for(media_id, title) do
    %{
      "id" => media_id,
      "title" => title,
      "original_url" => "https://www.youtube.com/watch?v=#{media_id}",
      "live_status" => "not_live",
      "description" => "Description for #{media_id}",
      "aspect_ratio" => 1.78,
      "duration" => 600,
      "upload_date" => recent_upload_date()
    }
  end

  defp download_attributes(media_id, output) do
    %{
      "id" => media_id,
      "title" => canonical_title(media_id),
      "original_url" => "https://www.youtube.com/watch?v=#{media_id}",
      "live_status" => "not_live",
      "description" => "Description for #{media_id}",
      "aspect_ratio" => 1.78,
      "duration" => 600,
      "upload_date" => recent_upload_date(),
      "filepath" => String.replace(output, "%(ext)S", "mp4")
    }
  end

  defp canonical_title("vid_1"), do: "Original Title One"
  defp canonical_title("vid_2"), do: "Original Title Two"

  defp media_id_for(url) when is_binary(url) do
    cond do
      String.contains?(url, "vid_1") -> "vid_1"
      String.contains?(url, "vid_2") -> "vid_2"
    end
  end

  defp recent_upload_date do
    Date.utc_today() |> Date.add(-1) |> Calendar.strftime("%Y%m%d")
  end

  defp json_lines(items) do
    Enum.map_join(items, "\n", &Phoenix.json_library().encode!/1)
  end
end
