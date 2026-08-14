defmodule Pinchflat.YtDlp.ResponseDecoderTest do
  use Pinchflat.DataCase

  alias Pinchflat.YtDlp.ResponseDecoder

  describe "decode/2" do
    test "returns the parsed JSON for a valid response" do
      assert {:ok, %{"title" => "test"}} = ResponseDecoder.decode(~s({"title": "test"}), :get_source_metadata)
    end

    test "returns a clean error tuple for an unparseable response" do
      assert {:error, "Error decoding JSON response"} = ResponseDecoder.decode("Not JSON", :get_source_metadata)
      assert {:error, "Error decoding JSON response"} = ResponseDecoder.decode("", :get_source_details)
    end
  end

  describe "decode_error?/1" do
    test "returns true for errors produced by decode/2" do
      assert ResponseDecoder.decode_error?(ResponseDecoder.decode("", :get_source_details))
    end

    test "returns false for other errors" do
      refute ResponseDecoder.decode_error?({:error, "Some other error"})
      refute ResponseDecoder.decode_error?({:error, "Some runner error", 1})
      refute ResponseDecoder.decode_error?(:ok)
    end
  end
end
