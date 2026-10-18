defmodule Pinchflat.Lifecycle.Notifications.SourceNotificationsTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Lifecycle.Notifications.SourceNotifications
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Settings

  @apprise_servers ["server_1", "server_2"]

  describe "video titles" do
    setup do
      Settings.set(notification_include_video_titles: true)
      Settings.set(external_base_url: nil)
      %{source: source_fixture()}
    end

    test "only includes newly created relevant media and preserves the callback result", %{source: source} do
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

                 media_item_fixture(%{
                   source_id: source.id,
                   media_filepath: nil,
                   title: "New pending",
                   uploaded_at: now()
                 })

                 media_item_fixture(%{source_id: source.id, title: "New downloaded", uploaded_at: now_minus(1, :days)})

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

    for change <- [:delete, :prevent_download] do
      @change change
      test "notifies about new items when an old item changes: #{change}", %{source: source} do
        existing = media_item_fixture(%{source_id: source.id, media_filepath: nil})

        expect(AppriseRunnerMock, :run, fn _, opts ->
          assert opts[:body] ==
                   "Found 1 new media item(s) for #{source.custom_name}. Downloading them now\n\n- New video"

          {:ok, ""}
        end)

        SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
          media_item_fixture(%{source_id: source.id, media_filepath: nil, title: "New video"})

          case @change do
            :delete -> Repo.delete!(existing)
            :prevent_download -> Media.update_media_item(existing, %{prevent_download: true})
          end
        end)
      end
    end

    test "does not treat an existing blocked item becoming eligible as a discovery", %{source: source} do
      existing = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        Media.update_media_item(existing, %{prevent_download: false})
      end)
    end

    test "orders new titles by upload date and breaks ties by descending ID", %{source: source} do
      uploaded_at = now()

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] ==
                 "Found 3 new media item(s) for #{source.custom_name}. Downloading them now\n\n" <>
                   "- Newest, higher ID\n- Newest, lower ID\n- Older upload"

        {:ok, ""}
      end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        media_item_fixture(%{source_id: source.id, title: "Newest, lower ID", uploaded_at: uploaded_at})
        media_item_fixture(%{source_id: source.id, title: "Older upload", uploaded_at: now_minus(1, :days)})
        media_item_fixture(%{source_id: source.id, title: "Newest, higher ID", uploaded_at: uploaded_at})
      end)
    end

    test "bounds database results for a large history and a 100-item discovery batch", %{source: source} do
      template = media_item_fixture(%{source_id: source.id})
      fields = MediaItem.__schema__(:fields) -- [:id, :uuid]
      attrs = template |> Map.from_struct() |> Map.take(fields)
      history = Enum.map(1..1999, &Map.merge(attrs, %{media_id: "history-#{&1}", title: "Old #{&1}"}))
      history |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(MediaItem, &1))
      query_ref = track_media_queries()

      expect(AppriseRunnerMock, :run, fn _, opts ->
        titles = Enum.map_join(100..91//-1, "\n", &"- New #{&1}")

        assert opts[:body] ==
                 "Found 100 new media item(s) for #{source.custom_name}. Downloading them now\n\n" <>
                   titles <> "\n… and 90 more"

        {:ok, ""}
      end)

      SourceNotifications.wrap_new_media_notification(@apprise_servers, source, fn ->
        batch = Enum.map(1..100, &Map.merge(attrs, %{media_id: "new-#{&1}", title: "New #{&1}"}))
        Repo.insert_all(MediaItem, batch)

        from(mi in MediaItem, where: mi.source_id == ^source.id and mi.id <= ^(template.id + 3))
        |> Repo.update_all(set: [media_filepath: nil, prevent_download: true])

        Repo.delete!(template)
      end)

      assert_receive {^query_ref, 1}
      assert_receive {^query_ref, 10}
      refute_received {^query_ref, _}
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

    for include_titles <- [true, false] do
      @include_titles include_titles
      test "does not query media when downloads are disabled and titles are #{@include_titles}", %{source: source} do
        Settings.set(notification_include_video_titles: @include_titles)
        query_ref = track_media_queries()

        assert :result ==
                 SourceNotifications.wrap_new_media_notification(
                   @apprise_servers,
                   %{source | download_media: false},
                   fn ->
                     :result
                   end
                 )

        refute_received {^query_ref, _}
      end
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

    for character <- ["x", "🚀", "e\u0301"] do
      @character character
      test "budgets the complete body and counts omitted titles with #{@character}", %{source: source} do
        Settings.set(external_base_url: "https://pinchflat.example.com/")
        title = String.duplicate(@character, 201)
        media = Enum.map(1..100, &%{title: title, media_id: "#{&1}"})

        expect(AppriseRunnerMock, :run, fn _, opts ->
          body = opts[:body]
          assert length(String.codepoints(body)) <= 1024
          assert body =~ "Found 100 new media item(s)"
          assert length(Regex.scan(~r/^- /m, body)) == 4
          assert body =~ "… and 96 more"
          assert String.ends_with?(body, "\n\nhttps://pinchflat.example.com/sources/#{source.id}")
          {:ok, ""}
        end)

        SourceNotifications.send_new_media_notification(@apprise_servers, source, 100, media)
      end
    end

    test "keeps a pathological source name and URL within the body budget", %{source: source} do
      Settings.set(external_base_url: "https://pinchflat.example.com/" <> String.duplicate("path/", 300))
      source = %{source | custom_name: String.duplicate("e\u0301", 2000)}

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert length(String.codepoints(opts[:body])) <= 1024
        assert String.valid?(opts[:body])
        assert opts[:body] =~ "Found 1 new media item(s)"
        refute opts[:body] =~ "https://"
        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification(@apprise_servers, source, 1, [%{title: "Video", media_id: "id"}])
    end

    test "includes the final title when the complete body fits exactly without a remainder", %{source: source} do
      fixed_header = "Found 1 new media item(s) for . Downloading them now"
      title = String.duplicate("x", 200)
      title_line = "\n\n- " <> title
      name = String.duplicate("s", 1024 - String.length(fixed_header) - String.length(title_line))
      source = %{source | custom_name: name}

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] == "Found 1 new media item(s) for #{name}. Downloading them now" <> title_line
        assert String.length(opts[:body]) == 1024
        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification(@apprise_servers, source, 1, [%{title: title, media_id: "id"}])
    end

    test "preserves unmatched Markdown delimiters as plain text", %{source: source} do
      title = "*unmatched _underscore [link]( `code <tag> & text"

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] ==
                 "Found 1 new media item(s) for #{source.custom_name}. Downloading them now\n\n- #{title}"

        refute Keyword.has_key?(opts, :input_format)
        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification(@apprise_servers, source, 1, [%{title: title, media_id: "id"}])
    end

    test "sorts titles provided by fast indexing by upload date", %{source: source} do
      media = [
        %{id: 3, title: "Older", uploaded_at: now_minus(1, :days), media_id: "old"},
        %{id: 1, title: "Newer", uploaded_at: now(), media_id: "new"}
      ]

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert String.ends_with?(opts[:body], "\n\n- Newer\n- Older")
        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification(@apprise_servers, source, 2, media)
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

  defp track_media_queries do
    ref = make_ref()
    caller = self()

    :telemetry.attach(
      ref,
      [:pinchflat, :repo, :query],
      fn _, _, metadata, _ ->
        if metadata.source == "media_items" and String.starts_with?(metadata.query, "SELECT") do
          {:ok, result} = metadata.result
          send(caller, {ref, result.num_rows})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end
end
