defmodule Pinchflat.YtDlp.TransientMediaTest do
  use ExUnit.Case, async: true

  alias Pinchflat.YtDlp.TransientMedia

  describe "error?/1" do
    test "recognizes upcoming live events" do
      assert TransientMedia.error?("ERROR: [youtube] abc: This live event will begin in a few moments.\n")
    end

    test "recognizes offline live events" do
      assert TransientMedia.error?("ERROR: [youtube] abc: Offline.\n")
    end

    test "ignores other errors" do
      refute TransientMedia.error?("ERROR: [youtube] abc: Video unavailable")
    end
  end

  describe "matched_reason/1" do
    test "returns the matched phrase" do
      assert TransientMedia.matched_reason("ERROR: [youtube] abc: Offline.") == "Offline."
    end
  end
end
