defmodule Pinchflat.YoutubeBrowser.ProviderCoordinatorTest do
  use ExUnit.Case, async: false

  alias Pinchflat.YoutubeBrowser.ProviderCoordinator

  setup do
    # Cancel any running operations for this test process
    ProviderCoordinator.cancel(self())
    :ok
  end

  describe "concurrency limit" do
    test "B06: allows 2 concurrent operations and returns {:error, :busy} for the 3rd" do
      test_pid = self()

      # Caller 1 starts slow task
      _p1 =
        spawn(fn ->
          res =
            ProviderCoordinator.execute(fn ->
              Process.sleep(200)
              :done_p1
            end)

          send(test_pid, {:p1_res, res})
        end)

      # Caller 2 starts slow task
      _p2 =
        spawn(fn ->
          res =
            ProviderCoordinator.execute(fn ->
              Process.sleep(200)
              :done_p2
            end)

          send(test_pid, {:p2_res, res})
        end)

      # Give callers a moment to acquire slots
      Process.sleep(30)

      # Caller 3 attempts execution
      _p3 =
        spawn(fn ->
          res =
            ProviderCoordinator.execute(fn ->
              :done_p3
            end)

          send(test_pid, {:p3_res, res})
        end)

      # Caller 3 should immediately be rejected with busy
      assert_receive {:p3_res, {:error, :busy}}, 500

      # Callers 1 and 2 should finish successfully
      assert_receive {:p1_res, :done_p1}, 1000
      assert_receive {:p2_res, :done_p2}, 1000
    end
  end

  describe "rate limiting" do
    test "B06: returns {:error, :rate_limited} after 5 calls within a minute for the same caller" do
      # 5 quick successful calls
      for _ <- 1..5 do
        assert :ok ==
                 ProviderCoordinator.execute(fn ->
                   :ok
                 end)
      end

      # 6th call should be rate limited
      assert {:error, :rate_limited} ==
               ProviderCoordinator.execute(fn ->
                 :ok
               end)
    end
  end

  describe "cancellation and cleanup" do
    test "B05: cancels previous operation if caller starts a new one" do
      test_pid = self()

      _caller =
        spawn(fn ->
          # Start first slow task asynchronously
          caller_inner = self()

          spawn(fn ->
            res =
              ProviderCoordinator.execute(
                fn ->
                  Process.sleep(500)
                  :first_done
                end,
                caller: caller_inner
              )

            send(test_pid, {:first_result, res})
          end)

          Process.sleep(30)

          # Start second task from the same caller
          res2 =
            ProviderCoordinator.execute(
              fn ->
                :second_done
              end,
              caller: caller_inner
            )

          send(test_pid, {:second_result, res2})
        end)

      assert_receive {:second_result, :second_done}, 1000
      assert_receive {:first_result, {:error, :cancelled}}, 1000
    end

    test "B05: releases slot if caller crashes or exits" do
      caller =
        spawn(fn ->
          ProviderCoordinator.execute(fn ->
            Process.sleep(1000)
            :never
          end)
        end)

      Process.sleep(30)
      assert ProviderCoordinator.get_stats().active_slots >= 1

      # Kill caller
      Process.exit(caller, :kill)
      Process.sleep(50)

      # Slot should be released
      assert ProviderCoordinator.get_stats().active_slots == 0
    end

    test "times out when operation exceeds deadline" do
      result =
        ProviderCoordinator.execute(
          fn ->
            Process.sleep(200)
            :done
          end,
          timeout: 50
        )

      assert result == {:error, :timeout}
    end

    test "abrupt coordinator restart terminates worker process" do
      owner = self()

      caller =
        spawn(fn ->
          ProviderCoordinator.execute(fn ->
            send(owner, {:worker_pid, self()})
            Process.sleep(30_000)
          end)
        end)

      assert_receive {:worker_pid, worker}, 2000
      old_coord = Process.whereis(ProviderCoordinator)
      monitor = Process.monitor(old_coord)
      Process.exit(old_coord, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_coord, :killed}, 2000
      Process.sleep(100)
      refute Process.alive?(worker), "Worker process must not survive abrupt coordinator death"
      Process.exit(caller, :kill)
    end
  end
end
