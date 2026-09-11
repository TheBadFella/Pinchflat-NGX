defmodule Pinchflat.Discovery.CandidateScoringSampleTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Sample
  alias Pinchflat.Discovery.Scoring

  @channel_id "UC" <> String.duplicate("a", 22)

  test "deduplicates evidence deterministically" do
    reference = %{
      kind: :handle,
      key: "handle:example",
      handle: "example",
      external_channel_id: nil,
      canonical_url: "https://www.youtube.com/@example"
    }

    first = Candidate.from_reference(reference, :mention)
    second = Candidate.from_reference(reference, :featured, %{channel_name: "Example"})

    assert [%Candidate{generators: ["featured", "mention"], mentions: 1, channel_name: "Example"}] =
             Candidate.deduplicate([second, first])
  end

  test "scores evidence without randomness" do
    candidate = %Candidate{
      external_channel_id: @channel_id,
      channel_name: "Example",
      generators: ["mention", "featured", "mention"],
      mentions: 9
    }

    assert Scoring.score(candidate) == 17
    assert Scoring.score(candidate) == Scoring.score(candidate)
  end

  test "selects a bounded random sample from a bounded pool" do
    candidates =
      for index <- 1..100 do
        %Candidate{
          external_channel_id: @channel_id <> Integer.to_string(index),
          channel_name: "Channel #{index}",
          generators: ["featured"]
        }
      end

    random_fun = fn pool, size -> Enum.take(pool, size) end
    sample = Sample.select(candidates, 100, max_pool: 7, random_fun: random_fun)

    assert length(sample) == 7
    assert length(Enum.uniq_by(sample, &Candidate.key/1)) == 7
  end
end
