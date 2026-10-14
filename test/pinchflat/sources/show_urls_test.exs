defmodule Pinchflat.Sources.ShowUrlsTest do
  use Pinchflat.DataCase

  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  @playlist_id "PLRWvNQVqAeWIH8s4IZfWLylrMoIO379df"
  @playlist_url "https://www.youtube.com/playlist?list=#{@playlist_id}"
  @show_url "https://www.youtube.com/show/VL#{@playlist_id}?sbp=tracking"

  test "creates a playlist source from the canonical URL without changing download choices" do
    expect(YtDlpRunnerMock, :run, fn @playlist_url, :get_source_details, _opts, _template, _runner_opts ->
      {:ok, source_details_return_fixture(%{playlist_id: @playlist_id, playlist_title: "Taskmaster"})}
    end)

    assert {:ok, source} =
             Sources.create_source(%{
               original_url: @show_url,
               media_profile_id: media_profile_fixture().id,
               source_type: :playlist,
               download_media: false
             })

    assert source.collection_type == :playlist
    assert source.collection_id == @playlist_id
    assert source.original_url == @playlist_url
    refute source.download_media
  end

  test "normalizes show links on edit and discards tracking parameters and fragments" do
    source = source_fixture()

    for host <- ["youtube.com", "www.youtube.com"] do
      changeset = Sources.change_source(source, %{original_url: "https://#{host}/show/VL#{@playlist_id}#episodes"})
      assert Ecto.Changeset.get_change(changeset, :original_url) == @playlist_url
    end
  end

  test "does not rewrite other domains, malformed IDs or ordinary source URLs" do
    for url <- [
          "https://youtube.com.example/show/VL#{@playlist_id}",
          "https://www.youtube.com/show/VLbad",
          "https://www.youtube.com/show/VLPLbad/extra",
          "https://www.youtube.com/show/VLPLbad%3Flist=other",
          @playlist_url
        ] do
      changeset = Source.changeset(%Source{}, %{original_url: url}, :initial)
      assert Ecto.Changeset.get_change(changeset, :original_url) == url
    end
  end

  test "clearing a source URL returns validation errors instead of raising" do
    changeset = Sources.change_source(source_fixture(), %{original_url: nil})
    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:original_url]
  end
end
