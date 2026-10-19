defmodule Pinchflat.Sources.SourceImportTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Sources.SourceImport

  @id "UCXuqSBlHAE6Xw-yeJA0Tunw"
  @other "UCBJycsmduvYEL83R_U4JriQ"
  @header "Channel Id,Channel Url,Channel Title\r\n"
  @url "https://www.youtube.com/channel/#{@id}"

  test "parses Takeout BOM, CRLF, quoted commas, escaped quotes and embedded newlines" do
    csv =
      "\uFEFF" <>
        @header <>
        "#{@id},http://www.youtube.com/channel/#{@id},\"News, \"\"today\"\"\r\ncontinued\"\r\n"

    assert {:ok, preview} = SourceImport.parse(csv, "subscriptions.CSV")
    assert preview.urls == [@url]
    assert preview.titles[@url] == "News, \"today\"\r\ncontinued"
    assert preview.channel_ids == %{@url => @id}
    assert preview.row_errors == []
    assert preview.duplicates == 0
  end

  test "deduplicates channel identity while keeping the first title and input order" do
    csv =
      @header <>
        "#{@id},http://youtube.com/channel/#{@id},First\n" <>
        "#{@id},#{@url},Duplicate\n" <>
        "#{@other},https://youtube.com/channel/#{@other},Second\n"

    assert {:ok, preview} = SourceImport.parse(csv, "subscriptions.csv")
    assert preview.urls == [@url, "https://www.youtube.com/channel/#{@other}"]
    assert preview.titles[@url] == "First"
    assert preview.duplicates == 1
  end

  test "reports invalid records and never turns a foreign or mismatched URL into an import" do
    csv =
      @header <>
        "invalid,#{@url},Invalid id\n" <>
        "#{@id},https://example.invalid/channel/#{@id},Foreign host\n" <>
        "#{@id},https://www.youtube.com/channel/#{@other},Mismatched id\n" <>
        "only,two\n#{@other},https://youtube.com/channel/#{@other},Valid\n"

    assert {:ok, preview} = SourceImport.parse(csv, "subscriptions.csv")
    assert preview.urls == ["https://www.youtube.com/channel/#{@other}"]
    assert Enum.map(preview.row_errors, & &1.row) == [2, 3, 4, 5]
  end

  test "all rejected rows remain visible rather than silently disappearing" do
    assert {:ok, preview} = SourceImport.parse(@header <> "bad,url,title\n", "subscriptions.csv")
    assert preview.urls == []
    assert [%{row: 2}] = preview.row_errors
  end

  test "rejects malformed quoting and unsupported headers" do
    for csv <- [
          @header <> "#{@id},#{@url},\"unterminated",
          "name,url\nName,#{@url}\n",
          "Kanal-ID,Kanal-URL,Kanaltitel\n#{@id},#{@url},Title\n"
        ] do
      assert {:error, message} = SourceImport.parse(csv, "subscriptions.csv")
      assert is_binary(message)
    end
  end

  test "keeps the 100-record bound without truncating an oversized export" do
    csv = @header <> String.duplicate("#{@id},#{@url},Title\n", 101)
    assert {:error, message} = SourceImport.parse(csv, "subscriptions.csv")
    assert message =~ "1 to 100"
  end

  test "rejects empty CSV, invalid UTF-8 and unsupported files" do
    for {contents, filename} <- [
          {"", "subscriptions.csv"},
          {@header, "subscriptions.csv"},
          {<<255>>, "subscriptions.csv"},
          {@header, "subscriptions.zip"}
        ] do
      assert {:error, _} = SourceImport.parse(contents, filename)
    end
  end

  test "text imports retain trimming, duplicate counts and deferred URL checks" do
    assert {:ok, preview} =
             SourceImport.parse(
               "\n https://youtube.com/@sample \nhttps://youtube.com/@sample\ninvalid\n",
               "sources.txt"
             )

    assert preview.urls == ["https://youtube.com/@sample", "invalid"]
    assert preview.duplicates == 1
    assert preview.titles == %{}
    assert preview.channel_ids == %{}
    assert preview.row_errors == []
  end
end
