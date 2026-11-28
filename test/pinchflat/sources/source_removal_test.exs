defmodule Pinchflat.Sources.SourceRemovalTest do
  use Pinchflat.DataCase

  import Mox
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Sources
  alias Pinchflat.Sources.SourceRemoval

  setup :verify_on_exit!

  @terminated "ERROR: [youtube:tab] UCaaaaaaaaaaaaaaaaaaaaaa: This channel does not exist."

  describe "removal_message/1" do
    test "recognizes YouTube's removed-content errors and keeps only the message" do
      assert SourceRemoval.removal_message({:error, @terminated, 1}) == "This channel does not exist."

      assert SourceRemoval.removal_message(
               {:error,
                "WARNING: something\nERROR: [youtube] abc123def45: Video unavailable. This video is no longer available because the uploader has closed their YouTube account.",
                1}
             ) ==
               "Video unavailable. This video is no longer available because the uploader has closed their YouTube account."

      assert SourceRemoval.removal_message("ERROR: [youtube:tab] PLx: The playlist does not exist.") ==
               "The playlist does not exist."

      assert SourceRemoval.removal_message(
               "This account has been terminated for a violation of YouTube's Terms of Service."
             )
    end

    test "ignores temporary and access errors" do
      for message <- [
            "ERROR: [youtube] x: HTTP Error 429: Too Many Requests",
            "ERROR: [youtube] x: Private video. Sign in if you've been granted access to this video",
            "ERROR: [youtube] x: Sign in to confirm you're not a bot",
            "ERROR: HTTP Error 404: Not Found",
            "This channel does not have a shorts tab"
          ] do
        refute SourceRemoval.removal_message({:error, message, 1}), message
      end

      refute SourceRemoval.removal_message(:timeout)
    end
  end

  describe "an index that finds the source removed" do
    setup do
      Settings.set(apprise_server: "json://localhost")
      {:ok, source: source_fixture(%{collection_type: :channel, index_frequency_minutes: 60, fast_index: true})}
    end

    test "turns the source off, records why, notifies and stops rescheduling", %{source: source} do
      stub(YtDlpRunnerMock, :run, fn _url, _action, _opts, _template, _addl -> {:error, @terminated, 1} end)

      expect(AppriseRunnerMock, :run, fn "json://localhost", opts ->
        assert opts[:title] == "[Pinchflat-ngx] Source removed from YouTube"
        assert opts[:body] =~ "This channel does not exist."
        {:ok, ""}
      end)

      assert {:ok, :source_removed} = perform_job(MediaCollectionIndexingWorker, %{id: source.id})

      source = Sources.get_source!(source.id)
      refute source.enabled
      assert %DateTime{} = source.removed_at
      assert source.removed_reason == "This channel does not exist."
      refute_enqueued(worker: MediaCollectionIndexingWorker, args: %{id: source.id})
      refute_enqueued(worker: Pinchflat.FastIndexing.FastIndexingWorker, args: %{id: source.id})
    end

    test "keeps retrying on other errors without turning the source off", %{source: source} do
      stub(YtDlpRunnerMock, :run, fn _url, _action, _opts, _template, _addl -> {:error, "HTTP Error 429", 1} end)

      assert_raise MatchError, fn -> perform_job(MediaCollectionIndexingWorker, %{id: source.id}) end
      assert Sources.get_source!(source.id).enabled
      refute Sources.get_source!(source.id).removed_at
    end
  end

  describe "turning a removed source back on" do
    setup do
      stub(AppriseRunnerMock, :run, fn _servers, _opts -> {:error, :no_servers} end)
      :ok
    end

    test "clears the removal and indexes it again" do
      source = source_fixture(%{collection_type: :channel, index_frequency_minutes: 60})
      {:ok, source} = SourceRemoval.mark_removed(source, "This channel does not exist.")

      assert {:ok, source} = SourceRemoval.check_again(source)
      assert source.enabled
      refute source.removed_at
      refute source.removed_reason
      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{id: source.id, force: true})
    end

    test "enabling it from the form also clears the removal" do
      source = source_fixture()
      {:ok, source} = SourceRemoval.mark_removed(source, "This channel does not exist.")

      assert {:ok, source} = Sources.update_source(source, %{enabled: true})
      refute source.removed_at
    end
  end
end
