defmodule Pinchflat.YtDlp.UnavailableMediaTest do
  use ExUnit.Case, async: true

  alias Pinchflat.YtDlp.UnavailableMedia

  describe "error?/1" do
    test "returns true for known unavailable-media errors" do
      assert UnavailableMedia.error?("ERROR: [youtube] abc: This video is available to this channel's members")
      assert UnavailableMedia.error?("Video unavailable")
      assert UnavailableMedia.error?("Private video. Sign in if you've been granted access")
    end

    test "returns false for unrelated errors" do
      refute UnavailableMedia.error?("Some unrelated error")
      refute UnavailableMedia.error?("Unable to communicate with SponsorBlock")
    end

    test "coerces non-string messages" do
      refute UnavailableMedia.error?(nil)
    end
  end

  describe "matched_reason/1" do
    test "returns the matched substring" do
      assert UnavailableMedia.matched_reason("ERROR: [youtube] abc: Video unavailable") == "Video unavailable"

      assert UnavailableMedia.matched_reason("Join this channel to get access to members-only content like this") ==
               "Join this channel to get access to members-only content"
    end

    test "returns nil when nothing matches" do
      assert UnavailableMedia.matched_reason("Some unrelated error") == nil
    end
  end
end
