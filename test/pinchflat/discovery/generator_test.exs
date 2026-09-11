defmodule Pinchflat.Discovery.GeneratorTest do
  use Pinchflat.DataCase

  import Mox

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.FeaturedGenerator
  alias Pinchflat.Discovery.MentionGenerator
  alias Pinchflat.Discovery.Normalizer

  defmodule TimeoutRunner do
    @moduledoc false

    def run(url, :channel_discovery_featured, _command_opts, _output_template, _addl_opts) do
      if String.contains?(url, "UCaaaaaaaaaaaaaaaaaaaaaa") do
        Process.sleep(100)
      end

      channel_id = url |> String.split("/channel/") |> List.last() |> String.trim_trailing("/featured")
      {:ok, Jason.encode!(%{"entries" => [%{"id" => channel_id}]})}
    end
  end

  @channel_id "UC" <> String.duplicate("a", 22)
  @other_channel_id "UC" <> String.duplicate("b", 22)

  describe "MentionGenerator" do
    test "mines bounded local descriptions and stored metadata without retaining text" do
      metadata_path = Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "discovery-metadata.json.gz")
      File.mkdir_p!(Path.dirname(metadata_path))

      File.open!(metadata_path, [:write, :compressed, :binary], fn device ->
        :ok = IO.binwrite(device, Phoenix.json_library().encode!(%{"description" => "See @metadata_channel"}))
      end)

      on_exit(fn -> File.rm(metadata_path) end)

      source = %{
        id: 1,
        collection_id: @channel_id,
        original_url: "https://www.youtube.com/channel/#{@channel_id}",
        description: "See https://www.youtube.com/@description_channel",
        metadata_filepath: metadata_path
      }

      assert {:ok, candidates} = MentionGenerator.generate(sources: [source], max_sources: 1, max_candidates: 2)
      assert Enum.map(candidates, & &1.reference.key) == ["handle:description_channel", "handle:metadata_channel"]
      refute Enum.any?(candidates, &String.contains?(inspect(&1), "See"))
    end

    test "bounds the number of sources and candidates" do
      sources =
        for index <- 1..4 do
          %{id: index, collection_id: nil, original_url: nil, description: "@channel_#{index}"}
        end

      assert {:ok, candidates} = MentionGenerator.generate(sources: sources, max_sources: 2, max_candidates: 1)
      assert length(candidates) == 1
    end
  end

  describe "FeaturedGenerator" do
    test "keeps valid candidates when one subscribed channel fails" do
      sources = [
        %{id: 1, collection_id: @channel_id, original_url: "https://www.youtube.com/channel/#{@channel_id}"},
        %{id: 2, collection_id: @other_channel_id, original_url: "https://www.youtube.com/channel/#{@other_channel_id}"}
      ]

      fetch_fun = fn
        %{id: 1}, _opts -> {:error, :runner_failed}
        %{id: 2}, _opts -> [Normalizer.normalize_reference("@featured_channel") |> Candidate.from_reference(:featured)]
      end

      result = FeaturedGenerator.generate_with_errors(sources: sources, fetch_fun: fetch_fun, max_sources: 2)

      assert [%Candidate{}] = result.candidates
      assert [%{source_id: 1, reason: :runner_failed}] = result.errors
    end

    test "uses the configured runner without cookies and parses bounded output" do
      source = %{
        id: 1,
        collection_id: @channel_id,
        original_url: "https://www.youtube.com/channel/#{@channel_id}"
      }

      expect(YtDlpRunnerMock, :run, fn url, :channel_discovery_featured, command_opts, "playlist:%()j", addl_opts ->
        assert url == "https://www.youtube.com/channel/#{@channel_id}/featured"
        assert :skip_download in command_opts
        assert Keyword.get(addl_opts, :use_cookies) == false
        assert Keyword.get(addl_opts, :timeout) == 15_000
        refute Keyword.has_key?(addl_opts, :cookies)

        {:ok,
         Phoenix.json_library().encode!(%{
           "entries" => [%{"id" => @other_channel_id, "title" => "Featured channel"}]
         })}
      end)

      assert {:ok, [%Candidate{external_channel_id: @other_channel_id, channel_name: "Featured channel"}]} =
               FeaturedGenerator.generate(sources: [source], max_entries: 1)
    end

    test "rejects malformed or oversized runner responses without returning output" do
      source = %{id: 1, collection_id: @channel_id, original_url: "https://www.youtube.com/channel/#{@channel_id}"}

      assert {:error, :featured_unavailable} =
               FeaturedGenerator.generate(
                 sources: [source],
                 fetch_fun: fn _source, _opts -> {:error, String.duplicate("secret-output", 100)} end
               )

      assert %{candidates: [], errors: [%{reason: :runner_failed}]} =
               FeaturedGenerator.generate_with_errors(
                 sources: [source],
                 fetch_fun: fn _source, _opts -> {:error, String.duplicate("secret-output", 100)} end
               )
    end

    test "times out the default fetch per source and keeps later partial results" do
      sources = [
        %{id: 1, collection_id: @channel_id, original_url: "https://www.youtube.com/channel/#{@channel_id}"},
        %{id: 2, collection_id: @other_channel_id, original_url: "https://www.youtube.com/channel/#{@other_channel_id}"}
      ]

      assert %{
               candidates: [%Candidate{external_channel_id: @other_channel_id}],
               errors: [%{source_id: 1, reason: :timeout}]
             } =
               FeaturedGenerator.generate_with_errors(
                 sources: sources,
                 timeout: 25,
                 max_sources: 2,
                 runner: TimeoutRunner
               )
    end
  end
end
