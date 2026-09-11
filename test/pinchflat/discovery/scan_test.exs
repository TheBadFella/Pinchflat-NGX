defmodule Pinchflat.Discovery.ScanTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Normalizer
  alias Pinchflat.Discovery.Suggestion
  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @channel_id "UC" <> String.duplicate("a", 22)
  @existing_id "UC" <> String.duplicate("b", 22)
  @dismissed_id "UC" <> String.duplicate("c", 22)

  test "deduplicates and excludes existing sources and dismissed suggestions" do
    source_fixture(%{
      collection_type: :channel,
      collection_id: @existing_id,
      original_url: "https://www.youtube.com/channel/#{@existing_id}"
    })

    {:ok, dismissed} = Discovery.upsert_suggestion(suggestion_attrs(@dismissed_id))
    {:ok, _dismissed} = Discovery.dismiss_suggestion(dismissed)

    candidates = [
      candidate(@existing_id, :featured),
      candidate(@dismissed_id, :featured),
      candidate(@channel_id, :mention),
      candidate(@channel_id, :featured)
    ]

    assert [%Candidate{external_channel_id: @channel_id, generators: ["featured", "mention"]}] =
             candidates
             |> Candidate.deduplicate()
             |> Discovery.exclude_candidates()
  end

  test "persists a validated suggestion idempotently" do
    assert [%Candidate{generators: ["featured", "mention"]} = candidate] =
             Candidate.deduplicate([candidate(@channel_id, :mention), candidate(@channel_id, :featured)])

    assert {:ok, [first]} = Discovery.persist_suggestions([candidate], now: ~U[2026-09-10 00:00:00Z])
    assert {:ok, [second]} = Discovery.persist_suggestions([candidate], now: ~U[2026-09-10 00:01:00Z])

    assert first.id == second.id
    assert first.generators == "featured,mention"
    assert Repo.get!(Suggestion, first.id).generators == "featured,mention"
    assert Repo.aggregate(Suggestion, :count, :id) == 1
    assert Repo.get!(Suggestion, first.id).state == :validated
  end

  test "does not revalidate a recently validated suggestion" do
    validated_at = ~U[2026-09-10 00:00:00Z]
    candidate = candidate(@channel_id, :mention)
    assert {:ok, [_suggestion]} = Discovery.persist_suggestions([candidate], now: validated_at)

    parent = self()

    assert {:ok, result} =
             Discovery.scan(
               enabled: true,
               mentions_enabled: true,
               featured_enabled: false,
               now: ~U[2026-09-10 01:00:00Z],
               generator_funs: %{mention: fn _opts -> [candidate] end},
               validation_opts: [
                 validate_fun: fn _candidate ->
                   send(parent, :unexpected_validation)
                   {:ok, %{channel_id: @channel_id, channel_name: "Channel"}}
                 end
               ]
             )

    assert result.candidate_count == 0
    assert result.validated_count == 0
    assert result.inserted_count == 0
    refute_received :unexpected_validation
  end

  test "a failed generator does not erase candidates from another generator" do
    Settings.set(channel_discovery_enabled: false)

    valid_candidate = candidate(@channel_id, :featured)

    assert {:ok, result} =
             Discovery.scan(
               manual: true,
               mentions_enabled: true,
               featured_enabled: true,
               generator_funs: %{
                 mention: fn _opts -> {:error, :generator_failed} end,
                 featured: fn _opts -> [valid_candidate] end
               },
               validation_opts: [
                 max_results: 10,
                 validate_fun: fn _candidate -> {:ok, %{channel_id: @channel_id, channel_name: "Featured"}} end
               ]
             )

    assert result.inserted_count == 1
    assert [%{generator: :mention, reason: :generator_failed}] = result.generator_errors
    assert [%Suggestion{external_channel_id: @channel_id}] = Repo.all(Suggestion)
  end

  test "publishes a bounded completion payload" do
    assert :ok = Discovery.subscribe()

    assert {:ok, %{status: :completed}} =
             Discovery.scan(
               enabled: true,
               mentions_enabled: false,
               featured_enabled: false,
               broadcast: true
             )

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "channel_discovery",
      event: "scan_completed",
      payload: %{status: :completed, candidate_count: 0, inserted_count: 0}
    }
  end

  defp candidate(channel_id, generator) do
    reference = Normalizer.normalize_reference(channel_id)
    Candidate.from_reference(reference, generator, %{channel_name: "Channel #{channel_id}"})
  end

  defp suggestion_attrs(channel_id) do
    %{
      external_channel_id: channel_id,
      canonical_url: "https://www.youtube.com/channel/#{channel_id}",
      channel_name: "Suggestion #{channel_id}",
      evidence: "Mentioned in local metadata",
      score: 8
    }
  end
end
