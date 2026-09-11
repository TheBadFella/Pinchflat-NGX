defmodule Pinchflat.Discovery.ValidatorTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Normalizer
  alias Pinchflat.Discovery.Validator

  @channel_id "UC" <> String.duplicate("a", 22)

  test "returns validation success, missing, timeout, and malformed outcomes" do
    candidates = Enum.map(~w(good missing slow malformed), &candidate/1)

    validate_fun = fn %Candidate{reference: %{handle: handle}} ->
      case handle do
        "good" -> {:ok, %{channel_id: @channel_id, channel_name: "Good channel"}}
        "missing" -> {:error, :missing}
        "slow" -> :timeout
        "malformed" -> {:ok, %{channel_id: "not-a-channel"}}
      end
    end

    result = Validator.validate(candidates, max_results: 4, max_concurrency: 2, validate_fun: validate_fun)

    assert [%Candidate{external_channel_id: @channel_id, channel_name: "Good channel"}] = result.validated
    assert Enum.sort(Enum.map(result.rejected, & &1.reason)) == [:malformed, :missing, :timeout]
    refute Enum.any?(result.rejected, &is_binary(&1.reason))
  end

  test "enforces the validation timeout and result bound" do
    candidates = Enum.map(~w(first second third), &candidate/1)
    parent = self()

    validate_fun = fn candidate ->
      send(parent, {:validated, candidate.reference.handle})
      Process.sleep(40)
      {:ok, %{channel_id: @channel_id, channel_name: candidate.reference.handle}}
    end

    result = Validator.validate(candidates, max_results: 2, max_concurrency: 1, timeout: 5, validate_fun: validate_fun)

    assert result.validated == []
    assert length(result.rejected) == 2
    assert Enum.all?(result.rejected, &(&1.reason == :timeout))
    refute_received {:validated, "third"}
  end

  defp candidate(handle) do
    reference = Normalizer.normalize_reference("@#{handle}")
    Candidate.from_reference(reference, :mention)
  end
end
