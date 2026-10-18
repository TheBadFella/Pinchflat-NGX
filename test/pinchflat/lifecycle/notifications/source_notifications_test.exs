defmodule Pinchflat.Lifecycle.Notifications.SourceNotificationsTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Lifecycle.Notifications.SourceNotifications
  alias Pinchflat.Settings

  @apprise_servers ["server_1", "server_2"]

  describe "video titles" do
    setup do
      Settings.set(notification_include_video_titles: true)
      Settings.set(external_base_url: nil)
      %{source: source_fixture()}
    end

    test "only includes newly relevant media and preserves the callback result", %{source: source} do
      existing = media_item_fixture(%{source_id: source.id, media_filepath: nil, title: "Already pending"})
      media_item_fixture(%{source_id: source.id, title: "Already downloaded"})

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] ==
                 "Found 2 new media item(s) for #{source.custom_name}. Downloading them now\n\n" <>
                   "- New pending\n- New downloaded"

        {:ok, ""}
      end)

      assert :callback_result ==
               SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
                 Pinchflat.Media.update_media_item(existing, %{media_filepath: "downloaded.mp4"})
                 media_item_fixture(%{source_id: source.id, media_filepath: nil, title: "New pending"})
                 media_item_fixture(%{source_id: source.id, title: "New downloaded"})

                 media_item_fixture(%{
                   source_id: source.id,
                   media_filepath: nil,
                   prevent_download: true,
                   title: "Blocked"
                 })

                 media_item_fixture(%{title: "Another source"})
                 :callback_result
               end)

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)
      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn -> :unchanged end)
    end

    test "completing an existing download does not send a notification", %{source: source} do
      existing = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        Pinchflat.Media.update_media_item(existing, %{media_filepath: "downloaded.mp4"})
      end)
    end

    test "does not notify for sources without downloads", %{source: source} do
      source = %{source | download_media: false}
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        media_item_fixture(%{source_id: source.id, media_filepath: nil})
        media_item_fixture(%{source_id: source.id})
      end)
    end

    test "normalizes titles, falls back to media IDs, and preserves the source link", %{source: source} do
      Settings.set(external_base_url: "https://pinchflat.example.com/")

      media = [
        %{title: "  Grüße & <Video>\r\n第二行  ", media_id: "one"},
        %{title: nil, media_id: "missing-title"},
        %{title: " \n ", media_id: "blank-title"},
        %{title: String.duplicate("ä", 201), media_id: "long-title"}
      ]

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] ==
                 "Found 4 new media item(s) for #{source.custom_name}. Downloading them now\n\n" <>
                   "- Grüße & <Video> 第二行\n- missing-title\n- blank-title\n- " <>
                   String.duplicate("ä", 199) <>
                   "…\n\nhttps://pinchflat.example.com/sources/#{source.id}"

        {:ok, ""}
      end)

      assert :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 4, media)
    end

    test "limits title lists and summarizes remaining videos", %{source: source} do
      media = Enum.map(1..12, &%{title: "Video #{&1}", media_id: "#{&1}"})

      expect(AppriseRunnerMock, :run, fn _, opts ->
        titles = Enum.map_join(1..10, "\n", &"- Video #{&1}")

        assert opts[:body] ==
                 "Found 12 new media item(s) for #{source.custom_name}. Downloading them now\n\n" <>
                   titles <> "\n… and 2 more"

        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification(@apprise_servers, source, 12, media)
    end

    test "retains the previous body when the option is disabled", %{source: source} do
      Settings.set(notification_include_video_titles: false)

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] == "Found 1 new media item(s) for #{source.custom_name}. Downloading them now"
        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification(@apprise_servers, source, 1, [%{title: "Hidden", media_id: "id"}])
    end
  end

  test "optionally includes new video titles in the existing notification" do
    source = source_fixture()
    Settings.set(external_base_url: nil)
    Settings.set(notification_include_video_titles: true)

    expect(AppriseRunnerMock, :run, fn servers, opts ->
      assert servers == @apprise_servers
      assert opts[:title] == "[Pinchflat-ngx] New media found"

      assert opts[:body] ==
               "Found 1 new media item(s) for #{source.custom_name}. Downloading them now\n\n- Neues Video"

      {:ok, ""}
    end)

    SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
      media_item_fixture(%{source_id: source.id, media_filepath: nil, title: "Neues Video"})
    end)
  end

  describe "wrap_new_media_notification/3" do
    setup do
      Settings.set(external_base_url: nil)
      :ok
    end

    test "sends a notification when the pending count changes" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat-ngx] New media found",
                 body: "Found 1 new media item(s) for #{source.custom_name}. Downloading them now"
               ]

        {:ok, ""}
      end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        media_item_fixture(%{source_id: source.id, media_filepath: nil})
      end)
    end

    test "sends a notification when the downloaded count changes" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat-ngx] New media found",
                 body: "Found 1 new media item(s) for #{source.custom_name}. Downloading them now"
               ]

        {:ok, ""}
      end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        media_item_fixture(%{source_id: source.id, media_filepath: "file.mp4"})
      end)
    end

    test "does not send a notification when the count does not change" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        media_item_fixture(%{source_id: source.id, prevent_download: true, media_filepath: nil})
      end)
    end

    test "does not send a notification if the source is set to not download media" do
      source = source_fixture(%{download_media: false})

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        media_item_fixture(%{source_id: source.id, media_filepath: nil})
        media_item_fixture(%{source_id: source.id, media_filepath: "file.mp4"})
      end)
    end

    test "returns the value of the function" do
      source = source_fixture()
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      retval = SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn -> "value" end)

      assert retval == "value"
    end
  end

  describe "send_new_media_notification/3" do
    setup do
      Settings.set(external_base_url: nil)
      :ok
    end

    test "sends a notification when count is positive" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat-ngx] New media found",
                 body: "Found 1 new media item(s) for #{source.custom_name}. Downloading them now"
               ]

        {:ok, ""}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 1)
    end

    test "includes a source link when external base url is configured" do
      source = source_fixture()
      Settings.set(external_base_url: "https://pinchflat.example.com/")

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat-ngx] New media found",
                 body:
                   "Found 2 new media item(s) for #{source.custom_name}. Downloading them now\n\n" <>
                     "https://pinchflat.example.com/sources/#{source.id}"
               ]

        {:ok, ""}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 2)
    end

    test "does not send a notification when count not positive" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 0)
      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, -1)
    end
  end
end
