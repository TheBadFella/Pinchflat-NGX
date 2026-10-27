defmodule Pinchflat.MediaWatch.ObservationFlowTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.DispatcherWorker
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.MediaWatchEvent, as: Event
  alias Pinchflat.MediaWatch.NotificationWorker
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.MediaWatch.ObservationWorker
  alias Pinchflat.Repo
  alias Pinchflat.Settings

  setup do
    profile = media_profile_fixture()

    profile =
      profile
      |> Ecto.Changeset.change(watch_window_days: 14)
      |> Repo.update!()

    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_with_attachments(%{source_id: source.id})

    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))

    {:ok, watch} =
      watch
      |> Ecto.Changeset.change(
        baseline_upstream_duration_seconds: 120,
        baseline_visibility: "public",
        current_visibility: "public",
        next_check_at: now_minus(1, :minute) |> DateTime.truncate(:second)
      )
      |> Repo.update()

    %{watch: watch, item: Repo.reload(item), source: source, profile: profile}
  end

  test "a first suspicion holds the item and a compatible later observation confirms one event", %{
    watch: watch
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{watch: suspected, event: nil}} =
             MediaWatch.record_observation(watch, observation(now, 130), jitter_seconds: 0)

    assert suspected.confirmed_state == "suspected"
    assert suspected.suspected_kind == "duration"
    assert suspected.suspected_count == 1
    assert suspected.hold_reason == "watch change: duration"
    assert DateTime.diff(suspected.next_check_at, now) == 15 * 60

    later = DateTime.add(now, 20 * 60)

    assert {:ok, %{watch: confirmed, event: event}} =
             MediaWatch.record_observation(watch, observation(later, 131), jitter_seconds: 0)

    assert confirmed.confirmed_state == "confirmed"
    assert confirmed.hold_reason == "watch change: duration"
    assert event.kind == "duration"
    assert event.old_value == "120"
    assert event.new_value == "131"
    assert event.delivery_state == "pending"
    assert_enqueued(worker: NotificationWorker, args: %{"id" => event.id})

    assert {:ok, %{event: nil}} =
             MediaWatch.record_observation(watch, observation(DateTime.add(later, 6 * 60 * 60), 131))

    assert Repo.aggregate(Event, :count) == 1
  end

  test "successive edits each require compatible confirmation and keep the original baseline", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, %{event: nil}} = MediaWatch.record_observation(watch, observation(now, 130))
    {:ok, %{event: first}} = MediaWatch.record_observation(watch, observation(DateTime.add(now, 1200), 130))
    assert first.new_value == "130"

    {:ok, %{event: nil}} = MediaWatch.record_observation(watch, observation(DateTime.add(now, 2400), 150))

    {:ok, %{watch: restarted, event: nil}} =
      MediaWatch.record_observation(watch, observation(DateTime.add(now, 3600), 160))

    assert restarted.suspected_count == 1

    {:ok, %{watch: confirmed, event: second}} =
      MediaWatch.record_observation(watch, observation(DateTime.add(now, 4800), 160))

    assert second.old_value == "130"
    assert second.new_value == "160"
    assert confirmed.baseline_upstream_duration_seconds == 120
    assert confirmed.current_upstream_duration_seconds == 160
    assert confirmed.confirmed_upstream_duration_seconds == 160
    assert Repo.aggregate(Event, :count) == 2
  end

  test "a later reverted suspicion preserves protection from an earlier confirmed change", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = MediaWatch.record_observation(watch, observation(now, 130))
    {:ok, _} = MediaWatch.record_observation(watch, observation(DateTime.add(now, 1200), 130))
    {:ok, _} = MediaWatch.record_observation(watch, observation(DateTime.add(now, 2400), 150))

    {:ok, %{watch: reverted, event: nil}} =
      MediaWatch.record_observation(watch, observation(DateTime.add(now, 2500), 130))

    assert reverted.confirmed_state == "confirmed"
    assert reverted.hold_reason
    assert reverted.confirmed_change_at
    assert Repo.aggregate(Event, :count) == 1
  end

  test "a suspected private visibility is displayed and filtered without changing confirmed comparison", %{watch: watch, item: item} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    private = %{observation(now, 120) | availability: :private}
    assert {:ok, %{watch: suspected, event: nil}} = MediaWatch.record_observation(watch, private)
    assert suspected.current_visibility == "public"
    assert suspected.observed_visibility == "private"
    assert MediaWatch.to_api_map(suspected).current_visibility == "private"
    assert Enum.any?(
             Repo.all(where(Pinchflat.Media.MediaQuery.new(), ^Pinchflat.Media.MediaQuery.watch_filter(:unavailable))),
             &(&1.id == item.id)
           )
    assert {:ok, %{watch: confirmed, event: %Event{}}} =
             MediaWatch.record_observation(watch, %{private | observed_at: DateTime.add(now, 1200)})
    assert confirmed.current_visibility == "private"
    assert confirmed.observed_visibility == "private"
  end

  test "repeated private and public transitions produce distinct events after confirmation", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {availability, index} <- Enum.with_index([:private, :public, :private, :public]) do
      first = %{observation(DateTime.add(now, index * 2400), 120) | availability: availability}
      second = %{first | observed_at: DateTime.add(first.observed_at, 1200)}
      assert {:ok, %{event: nil}} = MediaWatch.record_observation(watch, first)
      assert {:ok, %{event: %Event{}}} = MediaWatch.record_observation(watch, second)
    end

    assert Repo.aggregate(Event, :count) == 4
    assert Repo.get!(Watch, watch.id).hold_reason
  end

  test "private and unavailable to unlisted each require confirmation and emit events", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {availability, index} <- Enum.with_index([:private, :unlisted, :unavailable, :unlisted]) do
      first = %{observation(DateTime.add(now, index * 2400), 120) | availability: availability}
      second = %{first | observed_at: DateTime.add(first.observed_at, 1200)}
      assert {:ok, %{watch: suspected, event: nil}} = MediaWatch.record_observation(watch, first)
      assert suspected.confirmed_state == "suspected"
      assert {:ok, %{event: %Event{} = event}} = MediaWatch.record_observation(watch, second)
      assert event.new_value == to_string(availability)
      assert Repo.get!(Watch, watch.id).current_visibility == to_string(availability)
      assert {:ok, %{event: nil}} = MediaWatch.record_observation(watch, second)
    end

    assert Repo.aggregate(Event, :count) == 4
  end

  test "a trusted first observation fills the immutable remote baseline once", %{source: source} do
    item = media_item_with_attachments(%{source_id: source.id})
    {:ok, fresh} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{watch: observed}} =
             MediaWatch.record_observation(fresh, observation(now, 120), jitter_seconds: 0)

    assert observed.baseline_upstream_duration_seconds == 120
    assert observed.baseline_visibility == "public"

    assert {:ok, %{watch: later}} =
             MediaWatch.record_observation(fresh, observation(DateTime.add(now, 6 * 60 * 60), 130), jitter_seconds: 0)

    assert later.baseline_upstream_duration_seconds == 120
    assert later.suspected_kind == "duration"
  end

  test "a queued notification survives explicit release and removal of the media record", %{watch: watch, item: item} do
    {:ok, event} =
      MediaWatch.record_event(watch, "duration", "pending-before-release", %{
        old_value: "120",
        new_value: "130"
      })

    {:ok, token} = MediaWatch.release_confirmation(watch)
    {:ok, _} = MediaWatch.release_watch(item, token)
    {:ok, _} = Pinchflat.Media.delete_media_item(item)
    assert Repo.get!(Watch, watch.id).media_item_id == nil
    {:ok, _} = Settings.update_setting(Settings.record(), %{apprise_server: "json://notify.example.invalid"})

    expect(AppriseRunnerMock, :run, fn _servers, opts ->
      assert opts[:body] =~ watch.media_id
      assert opts[:body] =~ "local media record removed"
      refute opts[:body] =~ "/sources/"
      {:ok, "sent"}
    end)

    assert :ok = NotificationWorker.perform(%Oban.Job{args: %{"id" => event.id}})
    assert Repo.get!(Event, event.id).delivery_state == "sent"
  end

  test "a late observation cannot rewind a newer confirmed transition", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    first = %{observation(now, 120) | availability: :private}
    {:ok, _} = MediaWatch.record_observation(watch, first)

    {:ok, %{watch: confirmed}} =
      MediaWatch.record_observation(
        watch,
        %{first | observed_at: DateTime.add(now, 1200)}
      )

    {:ok, %{watch: unchanged, event: nil}} =
      MediaWatch.record_observation(
        watch,
        observation(DateTime.add(now, 60), 120)
      )

    assert unchanged.observation_version == confirmed.observation_version
    assert unchanged.current_visibility == "private"
    assert unchanged.confirmed_state == "confirmed"
  end

  test "current duration advances without drifting the confirmed comparison", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, %{watch: within_tolerance, event: nil}} = MediaWatch.record_observation(watch, observation(now, 122))
    assert within_tolerance.current_upstream_duration_seconds == 122
    assert within_tolerance.baseline_upstream_duration_seconds == 120
    {:ok, %{watch: suspected}} = MediaWatch.record_observation(watch, observation(DateTime.add(now, 100), 124))
    assert suspected.confirmed_state == "suspected"
    assert suspected.current_upstream_duration_seconds == 124
    assert suspected.confirmed_upstream_duration_seconds == nil
  end

  @tag :sqlite_only
  test "notification job failure rolls the confirmed event and state back", %{watch: watch} do
    Repo.query!("""
    CREATE TRIGGER reject_watch_notification BEFORE INSERT ON oban_jobs
    BEGIN SELECT RAISE(FAIL, 'notification unavailable'); END
    """)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, _} = MediaWatch.record_observation(watch, observation(now, 130))

    result =
      try do
        MediaWatch.record_observation(watch, observation(DateTime.add(now, 1200), 130))
      rescue
        error -> {:error, Exception.message(error)}
      end

    assert match?({:error, _}, result)

    assert Repo.aggregate(Event, :count) == 0
    assert Repo.get!(Watch, watch.id).confirmed_state == "suspected"
  end

  @tag :sqlite_only
  test "worker retries when a notification insert rolls back the observation", %{watch: watch} do
    {:ok, _} = Settings.update_setting(Settings.record(), %{youtube_api_key: nil, apprise_server: nil})
    previous = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-1200)
    assert {:ok, _} = MediaWatch.record_observation(watch, observation(previous, 130))

    stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _output, _addl ->
      {:ok, Jason.encode!(%{"id" => watch.media_id, "duration" => 130, "availability" => "public"})}
    end)

    Repo.query!("""
    CREATE TRIGGER reject_watch_notification_worker BEFORE INSERT ON oban_jobs
    BEGIN SELECT RAISE(FAIL, 'notification unavailable'); END
    """)

    assert {:error, _} = ObservationWorker.perform(%Oban.Job{args: %{"id" => watch.id}})
    assert Repo.aggregate(Event, :count) == 0
    assert Repo.get!(Watch, watch.id).confirmed_state == "suspected"
    Repo.query!("DROP TRIGGER reject_watch_notification_worker")
    assert :ok = ObservationWorker.perform(%Oban.Job{args: %{"id" => watch.id}})
    assert Repo.aggregate(Event, :count) == 1
  end

  test "a missing public duration cannot refresh replacement eligibility or erase the last trusted value", %{
    watch: watch,
    item: item
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, %{watch: trusted}} = MediaWatch.record_observation(watch, observation(now, 122), jitter_seconds: 0)
    assert trusted.current_upstream_duration_seconds == 122
    refute MediaWatch.replacement_blocked?(item.id)

    {:ok, %{watch: unknown, event: nil}} =
      MediaWatch.record_observation(watch, observation(DateTime.add(now, 60), nil), jitter_seconds: 0)

    assert unknown.last_success_at == trusted.last_success_at
    assert unknown.current_upstream_duration_seconds == 122
    assert unknown.last_error_at
    assert unknown.confirmed_state == "unchanged"
    assert MediaWatch.replacement_blocked?(item.id)

    {:ok, %{watch: unlisted, event: nil}} =
      MediaWatch.record_observation(watch, %{observation(DateTime.add(now, 120), nil) | availability: :unlisted})

    assert unlisted.confirmed_state == "suspected"
    assert unlisted.suspected_kind == "visibility"
    assert unlisted.last_success_at == trusted.last_success_at
    assert unlisted.current_upstream_duration_seconds == 122
    assert MediaWatch.replacement_blocked?(item.id)

    {:ok, %{watch: repeated, event: nil}} =
      MediaWatch.record_observation(watch, %{observation(DateTime.add(now, 180), nil) | availability: :unlisted})

    assert repeated.current_upstream_duration_seconds == 122
    assert repeated.last_error_at
    assert MediaWatch.replacement_blocked?(item.id)

    {:ok, %{watch: confirmed, event: event}} =
      MediaWatch.record_observation(watch, %{observation(DateTime.add(now, 1320), nil) | availability: :unlisted})

    assert event.kind == "visibility"
    assert confirmed.last_error_at
    assert confirmed.current_upstream_duration_seconds == 122
    assert MediaWatch.replacement_blocked?(item.id)
  end

  test "the worker does not turn missing public duration into a successful check", %{watch: watch, item: item} do
    {:ok, _} = Settings.update_setting(Settings.record(), %{youtube_api_key: nil, apprise_server: nil})

    stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _output, _addl ->
      {:ok, Jason.encode!(%{"id" => watch.media_id, "availability" => "public"})}
    end)

    assert :ok = ObservationWorker.perform(%Oban.Job{args: %{"id" => watch.id}})
    updated = Repo.get!(Watch, watch.id)
    assert updated.last_error_at
    refute updated.last_success_at
    assert MediaWatch.replacement_blocked?(item.id)
  end

  test "missing duration and a livestream do not clear an existing suspicion", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = MediaWatch.record_observation(watch, observation(now, 130))

    for candidate <- [
          observation(DateTime.add(now, 60), nil),
          %{observation(DateTime.add(now, 120), 120) | livestream: true}
        ] do
      {:ok, %{watch: preserved, event: nil}} = MediaWatch.record_observation(watch, candidate)
      assert preserved.confirmed_state == "suspected"
      assert preserved.hold_reason
      assert preserved.current_upstream_duration_seconds == 130
    end
  end

  test "an unknown observation backs off without clearing a suspicion or changing the baseline", %{
    watch: watch
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = MediaWatch.record_observation(watch, observation(now, 130), jitter_seconds: 0)

    assert {:ok, %{watch: updated, event: nil}} =
             MediaWatch.record_observation(
               watch,
               Observation.unknown(:yt_dlp, :timeout, DateTime.add(now, 5 * 60)),
               jitter_seconds: 0
             )

    assert updated.error_count == 1
    assert updated.last_error_at
    assert updated.suspected_kind == "duration"
    assert updated.hold_reason == "watch change: duration"
    assert updated.baseline_upstream_duration_seconds == 120
    assert DateTime.diff(updated.next_check_at, DateTime.add(now, 5 * 60)) == 15 * 60
  end

  test "an unchanged observation clears an unconfirmed suspicion and its watcher hold", %{watch: watch} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = MediaWatch.record_observation(watch, observation(now, 130), jitter_seconds: 0)

    assert {:ok, %{watch: updated, event: nil}} =
             MediaWatch.record_observation(watch, observation(DateTime.add(now, 60), 120), jitter_seconds: 0)

    assert updated.confirmed_state == "unchanged"
    assert updated.suspected_kind == nil
    assert updated.hold_reason == nil
  end

  test "dispatches only due, unexpired watches with an enabled policy", %{
    watch: watch,
    source: source,
    profile: profile
  } do
    disabled_source = source_fixture(%{media_profile_id: profile.id})
    other_item = media_item_with_attachments(%{source_id: disabled_source.id})
    {:ok, disabled} = MediaWatch.enroll_on_first_completion(other_item, Repo.preload(disabled_source, :media_profile))

    {:ok, _} =
      Pinchflat.Sources.update_source(disabled_source, %{watch_window_days: 0}, run_post_commit_tasks: false)

    expired =
      watch
      |> Ecto.Changeset.change(ends_at: now_minus(1, :day) |> DateTime.truncate(:second))
      |> Repo.update!()

    assert expired.media_item_id == watch.media_item_id

    due =
      watch
      |> Ecto.Changeset.change(ends_at: now_plus(2880, :minutes) |> DateTime.truncate(:second))
      |> Repo.update!()

    assert :ok = DispatcherWorker.perform(%Oban.Job{})
    assert_enqueued(worker: ObservationWorker, args: %{"id" => due.id})
    refute_enqueued(worker: ObservationWorker, args: %{"id" => disabled.id})
    assert Repo.get!(Watch, watch.id).ends_at == due.ends_at
    assert source.id
  end

  test "the observation worker records a successful metadata check", %{watch: watch} do
    {:ok, _} = Settings.update_setting(Settings.record(), %{youtube_api_key: nil, apprise_server: nil})

    stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _output, _addl ->
      {:ok,
       Jason.encode!(%{
         "id" => watch.media_id,
         "duration" => 120,
         "availability" => "public",
         "live_status" => "not_live"
       })}
    end)

    assert :ok = ObservationWorker.perform(%Oban.Job{args: %{"id" => watch.id}})

    updated = Repo.get!(Watch, watch.id)
    assert updated.last_success_at
    assert updated.next_check_at > now_plus(300, :minutes)
    assert Repo.aggregate(Event, :count) == 0
  end

  test "an expired worker makes no external request", %{watch: watch} do
    {:ok, expired} =
      watch
      |> Ecto.Changeset.change(ends_at: now_minus(1, :day) |> DateTime.truncate(:second))
      |> Repo.update()

    expect(YtDlpRunnerMock, :run, 0, fn _, _, _, _, _ -> {:ok, "{}"} end)

    assert :ok = ObservationWorker.perform(%Oban.Job{args: %{"id" => expired.id}})
    assert is_nil(Repo.get!(Watch, watch.id).last_observed_at)
  end

  test "notification delivery marks the event sent and does not send it twice", %{watch: watch, item: item} do
    {:ok, _} =
      Settings.update_setting(Settings.record(), %{
        apprise_server: "json://test",
        external_base_url: "https://pinch.example/base"
      })

    {:ok, event} =
      MediaWatch.record_event(watch, "duration", "duration:120->130", %{old_value: "120", new_value: "130"})

    expect(AppriseRunnerMock, :run, fn servers, opts ->
      assert servers == "json://test"
      assert opts[:title] =~ "edited"
      assert opts[:body] =~ item.title
      refute opts[:body] =~ "**"
      refute Keyword.has_key?(opts, :input_format)
      assert opts[:body] =~ "/sources/#{item.source_id}/media/#{item.id}"
      {:ok, ""}
    end)

    assert :ok = NotificationWorker.perform(%Oban.Job{args: %{"id" => event.id}})
    assert Repo.get!(Event, event.id).delivery_state == "sent"

    assert :ok = NotificationWorker.perform(%Oban.Job{args: %{"id" => event.id}})
  end

  test "a failed notification is recorded for retry", %{watch: watch} do
    {:ok, _} = Settings.update_setting(Settings.record(), %{apprise_server: "json://test"})

    {:ok, event} =
      MediaWatch.record_event(watch, "duration", "duration:120->131", %{old_value: "120", new_value: "131"})

    stub(AppriseRunnerMock, :run, fn _servers, _opts -> {:error, "destination unavailable"} end)

    assert {:error, "destination unavailable"} = NotificationWorker.perform(%Oban.Job{args: %{"id" => event.id}})

    updated = Repo.get!(Event, event.id)
    assert updated.attempts == 1
    assert updated.delivery_state == "pending"
    assert updated.next_attempt_at
    assert updated.error_summary =~ "destination unavailable"
  end

  test "no configured notification servers marks the event skipped", %{watch: watch} do
    {:ok, _} = Settings.update_setting(Settings.record(), %{apprise_server: nil})
    {:ok, event} = MediaWatch.record_event(watch, "unlisted", "unlisted:public->unlisted")

    assert :ok = NotificationWorker.perform(%Oban.Job{args: %{"id" => event.id}})
    assert Repo.get!(Event, event.id).delivery_state == "skipped"
  end

  defp observation(observed_at, duration) do
    %Observation{
      backend: :test,
      observed_at: observed_at,
      availability: :public,
      duration_seconds: duration,
      livestream: false,
      reason: nil
    }
  end
end
