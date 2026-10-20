defmodule Pinchflat.ShortsOutputTemplateTest do
  use Pinchflat.DataCase

  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  setup do
    profile =
      media_profile_fixture(%{
        output_path_template: "main/{{ title }}.{{ ext }}",
        output_path_template_shorts: "shorts/{{ title }}.{{ ext }}"
      })

    source = source_fixture(%{media_profile_id: profile.id})
    {:ok, source: source}
  end

  test "Shorts template precedence and primary fallback", %{source: source} do
    source = Pinchflat.Repo.preload(source, :media_profile)
    short = %Pinchflat.Media.MediaItem{short_form_content: true}
    assert Sources.output_path_template(source, short) == "shorts/{{ title }}.{{ ext }}"
    assert Sources.output_path_template(source) == "main/{{ title }}.{{ ext }}"
    source = %{source | output_path_template_override: "custom/{{ title }}.{{ ext }}"}
    assert Sources.output_path_template(source, true) == "shorts/{{ title }}.{{ ext }}"
    source = %{source | output_path_template_shorts_override: "own-shorts/{{ title }}.{{ ext }}"}
    assert Sources.output_path_template(source, true) == "own-shorts/{{ title }}.{{ ext }}"
    assert Sources.output_path_template(source, false) == "custom/{{ title }}.{{ ext }}"

    source = %{
      source
      | output_path_template_shorts_override: nil,
        media_profile: %{source.media_profile | output_path_template_shorts: nil}
    }

    assert Sources.output_path_template(source, true) == "custom/{{ title }}.{{ ext }}"
  end

  test "optional templates validate extensions and blank values clear existing values", %{source: source} do
    profile = Pinchflat.Repo.preload(source, :media_profile).media_profile

    for value <- ["", "  ", nil] do
      cs = MediaProfile.changeset(profile, %{output_path_template_shorts: value})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :output_path_template_shorts) == nil
      cs = Source.changeset(source, %{output_path_template_shorts_override: value})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :output_path_template_shorts_override) == nil
    end

    refute MediaProfile.changeset(profile, %{output_path_template_shorts: "bad.mp4"}).valid?
    refute Source.changeset(source, %{output_path_template_shorts_override: "bad.mp4"}).valid?
    assert Source.changeset(source, %{output_path_template_shorts_override: "ok.{{ ext }}"}).valid?
  end

  test "download output and staging use the Shorts template", %{source: source} do
    item = media_item_fixture(%{source_id: source.id, short_form_content: true})
    item = Pinchflat.Repo.preload(item, source: :media_profile)
    assert DownloadOptionBuilder.build_output_path_for(item) == "/tmp/test/media/shorts/%(title)S.%(ext)S"
    assert {:ok, opts} = DownloadOptionBuilder.build(item)
    assert opts[:output] == "/tmp/test/media/shorts/%(title)S.%(ext)S"
    assert {:ok, opts} = DownloadOptionBuilder.build(item, staging_directory: "/tmp/shorts-staging")
    assert opts[:output] == "/tmp/shorts-staging/shorts/%(title)S.%(ext)S"
    assert DownloadOptionBuilder.build_output_path_for(source) == "/tmp/test/media/main/%(title)S.%(ext)S"
  end

  test "fast indexing persists the corrected Shorts prediction", %{source: source} do
    expect(HTTPClientMock, :get, fn _ -> {:ok, "<yt:videoId>short-id</yt:videoId>"} end)

    expect(YtDlpRunnerMock, :run, fn _, :get_media_attributes, _, template, opts ->
      assert template == "%()j"
      refute Keyword.has_key?(opts, :source)

      {:ok,
       Jason.encode!(%{
         "id" => "short-id",
         "title" => "A short",
         "original_url" => "https://www.youtube.com/shorts/short-id",
         "upload_date" => "20260101",
         "filename" => "/tmp/test/media/main/A short.mp4"
       })}
    end)

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, opts, _, _ ->
      assert opts[:output] == "/tmp/test/media/shorts/%(title)S.%(ext)S"
      {:ok, ~s({"filename":"/tmp/test/media/shorts/A short.mp4"})}
    end)

    assert [%{short_form_content: true, predicted_media_filepath: "/tmp/test/media/shorts/A short.mp4"}] =
             Pinchflat.FastIndexing.FastIndexingHelpers.index_and_kickoff_downloads(source)
  end

  test "channel indexing selects Shorts output only for the shorts tab", %{source: source} do
    expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, opts, _, _ ->
      folder = if String.ends_with?(url, "/shorts"), do: "shorts", else: "main"
      assert opts[:output] == "/tmp/test/media/#{folder}/%(title)S.%(ext)S"
      {:ok, ""}
    end)

    assert [] = Pinchflat.SlowIndexing.SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
  end

  test "playlist indexing persists a Short's corrected prediction", %{source: source} do
    source = %{source | collection_type: :playlist}

    expect(YtDlpRunnerMock, :run, fn _, :get_media_attributes_for_collection, opts, template, _ ->
      assert opts[:output] == "/tmp/test/media/main/%(title)S.%(ext)S"
      assert template == "%()j"

      {:ok,
       Jason.encode!(%{
         "id" => "short-id",
         "title" => "A short",
         "original_url" => "https://www.youtube.com/shorts/short-id",
         "upload_date" => "20260101",
         "filename" => "/tmp/test/media/main/A short.mp4"
       })}
    end)

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, _, _, _ ->
      {:ok, ~s({"filename":"/tmp/test/media/shorts/A short.mp4"})}
    end)

    assert [%{predicted_media_filepath: "/tmp/test/media/shorts/A short.mp4"}] =
             Pinchflat.SlowIndexing.SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
  end

  test "Shorts prediction retains audio profile format options", %{source: source} do
    source = Repo.preload(source, :media_profile)
    source = %{source | media_profile: %{source.media_profile | preferred_resolution: :audio}}

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, opts, _, _ ->
      assert :extract_audio in opts
      assert opts[:format] == "bestaudio/best"
      assert opts[:audio_format] == "best"
      {:ok, ~s({"filename":"/tmp/test/media/shorts/A short.m4a"})}
    end)

    response = %{"original_url" => "https://www.youtube.com/shorts/short-id", "filename" => "main/A short.m4a"}

    assert %{predicted_media_filepath: "/tmp/test/media/shorts/A short.m4a"} =
             YtDlpMedia.response_to_struct(response, source)
  end

  test "streaming conversion defers mixed-playlist rendering to the final result", %{source: source} do
    response = %{"original_url" => "https://www.youtube.com/shorts/short-id", "filename" => "main/A short.mp4"}

    assert %{short_form_content: true, predicted_media_filepath: nil} =
             YtDlpMedia.response_to_struct(response, source, render_shorts: false)

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, _, _, _ ->
      {:ok, ~s({"filename":"/tmp/test/media/shorts/A short.mp4"})}
    end)

    assert %{predicted_media_filepath: "/tmp/test/media/shorts/A short.mp4"} =
             YtDlpMedia.response_to_struct(response, source)
  end

  test "known channel tabs use compact metadata and no correction processes", %{source: source} do
    response = %{
      "original_url" => "https://www.youtube.com/watch?v=vertical",
      "duration" => 30,
      "aspect_ratio" => 0.5,
      "filename" => "already-rendered.mp4"
    }

    for tab <- [:videos, :shorts, :streams] do
      assert YtDlpMedia.indexing_output_template(source, content_type: tab) == YtDlpMedia.indexing_output_template()

      for _ <- 1..1000 do
        result = YtDlpMedia.response_to_struct(response, source, content_type: tab)
        assert result.short_form_content == (tab == :shorts)
        assert result.predicted_media_filepath == "already-rendered.mp4"
      end
    end
  end

  test "streaming and final playlist processing render each Short only once", %{source: source} do
    source = %{source | collection_type: :playlist}

    response =
      Jason.encode!(%{
        "id" => "streamed-short",
        "title" => "A short",
        "upload_date" => "20260101",
        "original_url" => "https://www.youtube.com/shorts/streamed-short",
        "filename" => "main/short.mp4"
      })

    expect(YtDlpRunnerMock, :run, fn _, :get_media_attributes_for_collection, _, _, opts ->
      File.write!(opts[:output_filepath], response <> "\n")

      item =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case Repo.get_by(Pinchflat.Media.MediaItem, source_id: source.id, media_id: "streamed-short") do
            nil ->
              Process.sleep(20)
              {:cont, nil}

            item ->
              {:halt, item}
          end
        end)

      assert item
      assert item.short_form_content
      assert is_nil(item.predicted_media_filepath)
      {:ok, response}
    end)

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, _, _, _ ->
      {:ok, ~s({"filename":"/tmp/test/media/shorts/short.mp4"})}
    end)

    assert [%{predicted_media_filepath: "/tmp/test/media/shorts/short.mp4"}] =
             Pinchflat.SlowIndexing.SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
  end

  test "a failed local render leaves the prediction unknown", %{source: source} do
    response = %{
      "id" => "short-id",
      "title" => "A short",
      "original_url" => "https://www.youtube.com/shorts/short-id",
      "filename" => "/tmp/test/media/main/A short.mp4"
    }

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, opts, _, _ ->
      send(self(), {:prediction_tmpfile, opts[:load_info_json]})
      {:error, "cannot render", 1}
    end)

    assert %{predicted_media_filepath: nil} = YtDlpMedia.response_to_struct(response, source)
    assert_received {:prediction_tmpfile, filepath}
    refute File.exists?(filepath)
  end

  test "regular media keeps its backend prediction without another render", %{source: source} do
    response = %{
      "original_url" => "https://www.youtube.com/watch?v=regular",
      "duration" => 600,
      "filename" => "/tmp/test/media/main/regular.mp4"
    }

    assert %{short_form_content: false, predicted_media_filepath: "/tmp/test/media/main/regular.mp4"} =
             YtDlpMedia.response_to_struct(response, source)
  end

  test "metadata conversion corrects a Short's predicted path offline", %{source: source} do
    response = %{
      "id" => "short-id",
      "title" => "A short",
      "original_url" => "https://www.youtube.com/shorts/short-id",
      "upload_date" => "20260101",
      "ext" => "mp4",
      "filename" => "/tmp/test/media/main/A short.mp4"
    }

    expect(YtDlpRunnerMock, :run, fn _, :predict_filepath_from_metadata, opts, _, _ ->
      assert opts[:output] == "/tmp/test/media/shorts/%(title)S.%(ext)S"
      assert {:ok, json} = File.read(opts[:load_info_json])
      assert Jason.decode!(json)["id"] == "short-id"
      {:ok, ~s({"filename":"/tmp/test/media/shorts/A short.mp4"})}
    end)

    assert %{short_form_content: true, predicted_media_filepath: "/tmp/test/media/shorts/A short.mp4"} =
             YtDlpMedia.response_to_struct(response, source)
  end
end
