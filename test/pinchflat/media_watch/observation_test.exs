defmodule Pinchflat.MediaWatch.ObservationTest do
  use ExUnit.Case, async: true

  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  test "normalizes yt-dlp metadata without trusting unknown availability" do
    media = %YtDlpMedia{
      media_id: "abc",
      title: "t",
      description: "",
      original_url: "https://example.invalid/abc",
      livestream: false,
      short_form_content: false,
      uploaded_at: nil,
      duration_seconds: 130,
      predicted_media_filepath: "/tmp/a.mp4",
      availability: :unlisted
    }

    observation = Observation.from_yt_dlp(media)

    assert observation.availability == :unlisted
    assert observation.duration_seconds == 130
    assert observation.backend == :yt_dlp
    assert Observation.from_yt_dlp(%{media | availability: :needs_auth}).availability == :unavailable
    assert Observation.from_yt_dlp(%{media | availability: nil}).availability == :unknown
  end

  test "normalizes YouTube API items and ISO-8601 durations" do
    item = %{
      "status" => %{"privacyStatus" => "private"},
      "contentDetails" => %{"duration" => "PT1H2M3S"},
      "snippet" => %{"liveBroadcastContent" => "none"}
    }

    observation = Observation.from_youtube_api(item)

    assert observation.availability == :private
    assert observation.duration_seconds == 3723
    assert observation.livestream == false

    assert Observation.parse_iso8601_duration("PT2M") == 120
    assert Observation.parse_iso8601_duration("P1DT1S") == 86_401
    assert Observation.parse_iso8601_duration("not-a-duration") == nil
    assert Observation.parse_iso8601_duration(nil) == nil
  end

  test "compares against the immutable upstream baseline with a two-second tolerance" do
    watch = watch(%{baseline_upstream_duration_seconds: 120, baseline_visibility: "public"})

    assert :unchanged = Observation.classify(watch, observation(122, :public))
    assert {:duration, 120, 124} = Observation.classify(watch, observation(124, :public))
    assert {:visibility, "public", "unlisted"} = Observation.classify(watch, observation(120, :unlisted))
    assert {:unavailable, "public", "private"} = Observation.classify(watch, observation(120, :private))
    assert {:unknown, :timeout} = Observation.classify(watch, Observation.unknown(:yt_dlp, :timeout))
  end

  test "does not treat missing duration or active livestreams as a change" do
    watch = watch(%{baseline_upstream_duration_seconds: nil, baseline_visibility: "public"})

    assert :unchanged = Observation.classify(watch, observation(90, :public))

    live = %{observation(300, :public) | livestream: true}
    assert :unchanged = Observation.classify(watch, live)
  end

  test "a title or description edit alone is not a content change" do
    watch = watch(%{baseline_upstream_duration_seconds: 120, baseline_visibility: "public"})

    media = %YtDlpMedia{
      media_id: "abc",
      title: "original title",
      description: "original description",
      original_url: "https://example.invalid/abc",
      livestream: false,
      short_form_content: false,
      uploaded_at: nil,
      duration_seconds: 120,
      predicted_media_filepath: "/tmp/a.mp4",
      availability: :public
    }

    edited = %{media | title: "renamed by the uploader", description: "new description"}

    assert :unchanged = Observation.classify(watch, Observation.from_yt_dlp(media))
    assert :unchanged = Observation.classify(watch, Observation.from_yt_dlp(edited))
  end

  test "reports a restore after an unavailable state" do
    watch =
      watch(%{baseline_upstream_duration_seconds: 120, baseline_visibility: "public", current_visibility: "private"})

    assert {:restored, "private", "public"} = Observation.classify(watch, observation(120, :public))
  end

  defp watch(attrs) do
    struct(
      %Watch{
        id: 1,
        baseline_upstream_duration_seconds: nil,
        baseline_visibility: nil,
        current_visibility: nil,
        confirmed_state: "unchanged"
      },
      attrs
    )
  end

  defp observation(duration, availability) do
    %Observation{
      backend: :test,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      availability: availability,
      duration_seconds: duration,
      livestream: false,
      reason: nil
    }
  end
end
