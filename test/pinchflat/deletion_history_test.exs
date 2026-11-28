defmodule Pinchflat.DeletionHistoryTest do
  use Pinchflat.DataCase

  import Mox
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.DeletionHistory
  alias Pinchflat.DeletionHistory.DeletionEvent
  alias Pinchflat.Media
  alias Pinchflat.Profiles
  alias Pinchflat.Sources

  setup do
    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    :ok
  end

  describe "source deletion" do
    test "records the deleted source with its URL and item count" do
      source = source_fixture(%{custom_name: "Woodworking", original_url: "https://www.youtube.com/@woodworking"})
      media_item_fixture(source_id: source.id)
      media_item_fixture(source_id: source.id)

      assert {:ok, _} = Sources.delete_source(source)

      assert [event] = Repo.all(DeletionEvent)
      assert event.kind == :source
      assert event.reason == :user
      assert event.source_name == "Woodworking"
      assert event.source_url == "https://www.youtube.com/@woodworking"
      assert event.item_count == 2
      refute event.files_deleted
    end

    test "records each source removed with its media profile" do
      media_profile = media_profile_fixture()
      source_fixture(%{media_profile_id: media_profile.id})

      assert {:ok, _} = Profiles.delete_media_profile(media_profile)

      assert [%DeletionEvent{kind: :source, reason: :media_profile_deleted}] = Repo.all(DeletionEvent)
    end
  end

  describe "media file deletion" do
    test "records the media item, its source and the cause" do
      media_item = media_item_with_attachments()

      assert {:ok, _} = Media.delete_media_files(media_item)
      assert {:ok, _} = Media.delete_media_files(media_item_with_attachments(), %{}, reason: :keep_newest)

      assert [first, second] = Repo.all(from e in DeletionEvent, order_by: e.id)
      assert first.kind == :media_files
      assert first.reason == :user
      assert first.media_item_id == media_item.id
      assert first.media_title == media_item.title
      assert first.source_id == media_item.source_id
      assert second.reason == :keep_newest
    end
  end

  describe "list_page/2" do
    test "returns newest events first with the page count" do
      for name <- ~w(a b c), do: Sources.delete_source(source_fixture(%{custom_name: name}))

      assert {[%{source_name: "c"}, %{source_name: "b"}], 2} = DeletionHistory.list_page(1, 2)
      assert {[%{source_name: "a"}], 2} = DeletionHistory.list_page(2, 2)
    end
  end
end
