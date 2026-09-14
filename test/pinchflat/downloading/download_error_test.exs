defmodule Pinchflat.Downloading.DownloadErrorTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Downloading.DownloadError

  test "classifies rate-limit errors as non-retryable without a permanent block" do
    assert DownloadError.classify("HTTP Error 429: Too Many Requests") ==
             {:rate_limited, "Stopped: rate limited by remote source"}
  end

  test "retains the smart-apostrophe bot challenge rule" do
    assert DownloadError.classify("Sign in to confirm you\u2019re not a bot") ==
             {:rate_limited, "Stopped: rate limited by remote source"}
  end

  test "classifies unavailable media as a permanent failure" do
    assert DownloadError.classify("Video unavailable") ==
             {:permanent, "Stopped: download unavailable"}
  end

  test "classifies unrelated errors as transient" do
    assert DownloadError.classify("Network is unreachable") == :transient
  end
end
