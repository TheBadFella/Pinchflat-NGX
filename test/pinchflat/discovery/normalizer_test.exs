defmodule Pinchflat.Discovery.NormalizerTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Discovery.Normalizer

  @channel_id "UC" <> String.duplicate("a", 22)

  test "normalizes channel IDs, handles, URLs, and duplicate references" do
    text =
      """
      https://www.youtube.com/@Mixed_Handle/videos,
      https://youtube.com/@mixed_handle
      https://www.youtube.com/channel/#{@channel_id}
      #{@channel_id}
      """

    references = Normalizer.normalize(text)

    assert Enum.map(references, & &1.key) == ["handle:mixed_handle", "channel_id:#{@channel_id}"]

    assert Enum.find(references, &(&1.kind == :handle)).canonical_url ==
             "https://www.youtube.com/@mixed_handle"
  end

  test "rejects malformed references and video URLs" do
    text =
      "https://youtu.be/video-id https://www.youtube.com/watch?v=video-id " <>
        "https://www.youtube.com/channel/UCshort https://www.youtube.com/@a " <>
        "https://www.youtube.com/featured"

    assert Normalizer.normalize(text) == []
    assert is_nil(Normalizer.normalize_reference(%{key: "not-a-reference"}))
    assert Normalizer.normalize(nil) == []
  end

  test "rejects overlong channel IDs" do
    overlong_channel_id = "UC" <> String.duplicate("a", 23)

    refute Normalizer.valid_channel_id?(overlong_channel_id)
    assert Normalizer.normalize(overlong_channel_id) == []
    assert is_nil(Normalizer.normalize_reference(overlong_channel_id))
  end

  test "removes self references by ID, handle, or URL" do
    text = "#{@channel_id} https://www.youtube.com/@Other_Handle @other_handle @third_channel"

    assert [%{key: "handle:third_channel"}] =
             Normalizer.normalize(text, self_references: [@channel_id, "@other_handle"])
  end

  test "does not treat email-like text as a handle mention" do
    assert Normalizer.normalize("contact person@example.com for details") == []
  end
end
