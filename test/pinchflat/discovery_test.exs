defmodule Pinchflat.DiscoveryTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Suggestion
  alias Pinchflat.Repo

  @channel_id "UC" <> String.duplicate("a", 22)
  @other_channel_id "UC" <> String.duplicate("b", 22)

  describe "list_suggestions/1" do
    test "excludes dismissed and accepted suggestions by default" do
      {:ok, visible} = Discovery.upsert_suggestion(suggestion_attrs(@channel_id))
      {:ok, dismissed} = Discovery.upsert_suggestion(suggestion_attrs(@other_channel_id))
      {:ok, dismissed} = Discovery.dismiss_suggestion(dismissed)

      accepted_id = "UC" <> String.duplicate("c", 22)
      {:ok, accepted} = Discovery.upsert_suggestion(suggestion_attrs(accepted_id))
      {:ok, accepted} = Discovery.accept_suggestion(accepted)

      assert [visible] == Discovery.list_suggestions()

      assert Enum.map(Discovery.list_suggestions(include_terminal: true), & &1.id) ==
               Enum.sort([visible.id, dismissed.id, accepted.id])
    end
  end

  describe "upsert_suggestion/1" do
    test "is idempotent by external channel ID and bounds persisted values" do
      attrs = Map.put(suggestion_attrs(@channel_id), :generators, [:mention, :featured])

      assert {:ok, first} =
               Discovery.upsert_suggestion(Map.merge(attrs, %{score: 999, evidence: String.duplicate("x", 600)}))

      assert {:ok, second} =
               Discovery.upsert_suggestion(%{
                 external_channel_id: @channel_id,
                 canonical_url: attrs.canonical_url,
                 channel_name: "Updated name",
                 evidence: "updated evidence",
                 score: 4
               })

      assert second.id == first.id
      assert second.channel_name == "Updated name"
      assert second.evidence == "updated evidence"
      assert second.generators == "featured,mention"
      assert second.score == 4
      assert second.validated_at
      assert Repo.aggregate(Suggestion, :count, :id) == 1
    end

    test "bounds generator provenance and carries it through sampled candidates" do
      attrs = Map.put(suggestion_attrs(@channel_id), :generators, Enum.map(1..100, &"generator-#{&1}"))

      assert {:ok, suggestion} = Discovery.upsert_suggestion(attrs)
      assert String.length(suggestion.generators) <= Discovery.max_generators_length()

      attrs = Map.put(suggestion_attrs(@other_channel_id), :generators, [:mention, :featured])
      assert {:ok, persisted} = Discovery.upsert_suggestion(attrs)
      assert persisted.generators == "featured,mention"

      assert [%Candidate{generators: ["featured", "mention"]}] =
               Discovery.sample_suggestions(sample_size: 2, pool_size: 2, random_fun: fn pool, _size -> pool end)
               |> Enum.filter(&(&1.external_channel_id == @other_channel_id))
    end
  end

  describe "excluded_channel_ids/0" do
    test "includes subscribed channel sources and terminal suggestions" do
      source_id = "UC" <> String.duplicate("d", 22)

      source_fixture(%{
        collection_type: :channel,
        collection_id: source_id,
        original_url: "https://www.youtube.com/channel/#{source_id}"
      })

      {:ok, suggestion} = Discovery.upsert_suggestion(suggestion_attrs(@channel_id))
      {:ok, _suggestion} = Discovery.dismiss_suggestion(suggestion)

      excluded = Discovery.excluded_channel_ids()
      assert source_id in excluded
      assert @channel_id in excluded
    end

    test "does not persist a suggestion for an existing channel source" do
      source_fixture(%{collection_type: :channel, collection_id: @channel_id})

      assert {:error, :existing_source} = Discovery.upsert_suggestion(suggestion_attrs(@channel_id))
      assert Repo.aggregate(Suggestion, :count, :id) == 0
    end
  end

  defp suggestion_attrs(external_channel_id) do
    %{
      external_channel_id: external_channel_id,
      canonical_url: "https://www.youtube.com/channel/#{external_channel_id}",
      channel_name: "Suggested #{external_channel_id}",
      evidence: "Mentioned in local metadata",
      score: 8
    }
  end
end
