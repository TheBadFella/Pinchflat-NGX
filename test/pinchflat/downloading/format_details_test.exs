defmodule Pinchflat.Downloading.FormatDetailsTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Downloading.FormatDetails

  @formats [
    %{"height" => 2160, "vcodec" => "vp09.00.51.08"},
    %{"height" => 1440, "vcodec" => "av01.0.12M.08"},
    %{"height" => 1080, "vcodec" => "avc1.640028"},
    %{"height" => 720, "vcodec" => "avc1.4d401f"},
    %{"vcodec" => "none", "acodec" => "opus"},
    %{"height" => 90, "vcodec" => "none"}
  ]

  test "reads the downloaded format and what YouTube offered" do
    info = %{"height" => 1080, "vcodec" => "avc1.640028", "acodec" => "mp4a.40.2", "formats" => @formats}

    assert FormatDetails.from_info(info) == %{
             video_height: 1080,
             video_codec: "avc1.640028",
             audio_codec: "mp4a.40.2",
             max_available_height: 2160,
             available_video_codecs: "av01,avc1,vp09"
           }
  end

  test "leaves video fields empty for audio-only downloads" do
    info = %{"vcodec" => "none", "acodec" => "opus", "formats" => [%{"vcodec" => "none", "acodec" => "opus"}]}

    assert %{video_height: nil, video_codec: nil, audio_codec: "opus", max_available_height: nil} =
             FormatDetails.from_info(info)
  end

  test "picks the tallest offered height within the target" do
    assert FormatDetails.best_height_within(@formats, 4320) == 2160
    # A 4K preference on a video offering 1440p at most still finds 1440p.
    assert FormatDetails.best_height_within(Enum.drop(@formats, 1), 2160) == 1440
    assert FormatDetails.best_height_within(@formats, 1080) == 1080
    assert FormatDetails.best_height_within(@formats, 480) == nil
  end
end
