defmodule Pinchflat.ShareTokens.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Pinchflat.ShareTokens.RateLimiter

  setup do
    RateLimiter.reset!()
    :ok
  end

  describe "intake rate limiting" do
    test "allows up to 10 requests within a 60-second window" do
      digest = "test_digest_abc123"

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_intake(digest)
      end

      # 11th request triggers rate limit
      assert {:error, :rate_limited, retry_after} = RateLimiter.check_intake(digest)
      assert is_integer(retry_after)
      assert retry_after >= 1 and retry_after <= 60
    end

    test "tracks different tokens independently" do
      digest1 = "digest_1"
      digest2 = "digest_2"

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_intake(digest1)
      end

      assert {:error, :rate_limited, _} = RateLimiter.check_intake(digest1)
      # digest2 is still allowed
      assert :ok = RateLimiter.check_intake(digest2)
    end
  end

  describe "invalid authentication rate limiting" do
    test "allows up to 20 failed attempts per IP before rate limiting" do
      client_ip = {192, 168, 1, 100}

      for _i <- 1..19 do
        assert :ok = RateLimiter.check_invalid_auth(client_ip)
        RateLimiter.record_invalid_auth(client_ip)
      end

      # 20th record
      RateLimiter.record_invalid_auth(client_ip)

      # 21st attempt is blocked
      assert {:error, :rate_limited, retry_after} = RateLimiter.check_invalid_auth(client_ip)
      assert retry_after >= 1 and retry_after <= 60
    end

    test "different IPs track separately" do
      ip1 = {10, 0, 0, 1}
      ip2 = {10, 0, 0, 2}

      for _i <- 1..20 do
        RateLimiter.record_invalid_auth(ip1)
      end

      assert {:error, :rate_limited, _} = RateLimiter.check_invalid_auth(ip1)
      assert :ok = RateLimiter.check_invalid_auth(ip2)
    end
  end

  describe "pruning and reset" do
    test "reset! clears all entries" do
      digest = "digest_to_reset"

      for _i <- 1..10 do
        RateLimiter.check_intake(digest)
      end

      assert {:error, :rate_limited, _} = RateLimiter.check_intake(digest)

      RateLimiter.reset!()
      assert :ok = RateLimiter.check_intake(digest)
    end

    test "prune_stale_entries/0 succeeds without errors" do
      assert :ok = RateLimiter.ensure_table()
      assert is_integer(RateLimiter.prune_stale_entries())
    end
  end
end
