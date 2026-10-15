defmodule Pinchflat.CookieHealth.HealthCheckWorkerTest do
  use Pinchflat.DataCase, async: false

  alias Pinchflat.CookieHealth.HealthCheckWorker
  alias Pinchflat.Settings
  alias Pinchflat.Settings.CookieFile

  setup do
    base_dir =
      Path.join([
        System.tmp_dir!(),
        "cookie_worker_test",
        Integer.to_string(:erlang.unique_integer([:positive]))
      ])

    File.mkdir_p!(base_dir)
    original = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir}
  end

  describe "kickoff_manual/1" do
    test "inserts a manual job into Oban" do
      assert {:ok, job} = HealthCheckWorker.kickoff_manual()
      assert job.args == %{"manual" => true}
      assert job.queue == "default"
    end
  end

  describe "perform/1" do
    test "performs manual check regardless of monitoring enabled setting" do
      Settings.update_setting(Settings.record(), %{cookie_health_monitoring_enabled: false})
      File.write!(CookieFile.filepath(), "")

      job = %Oban.Job{args: %{"manual" => true}}
      assert :ok = HealthCheckWorker.perform(job)

      setting = Settings.record()
      assert setting.cookie_health_status == "not_configured"
      assert %DateTime{} = setting.cookie_health_last_checked_at
    end

    test "cancels scheduled job if monitoring is disabled" do
      Settings.update_setting(Settings.record(), %{cookie_health_monitoring_enabled: false})

      job = %Oban.Job{args: %{}}
      assert {:cancel, reason} = HealthCheckWorker.perform(job)
      assert reason =~ "disabled"
    end

    test "executes and schedules next job when monitoring is enabled" do
      Settings.update_setting(Settings.record(), %{
        cookie_health_monitoring_enabled: true,
        cookie_health_check_interval_hours: 12
      })

      File.write!(CookieFile.filepath(), "")

      job = %Oban.Job{args: %{}}
      assert :ok = HealthCheckWorker.perform(job)

      setting = Settings.record()
      assert setting.cookie_health_status == "not_configured"
    end

    test "a scheduled cookie check cannot swallow an immediate manual check" do
      {:ok, _} = Settings.update_setting(Settings.record(), %{cookie_health_monitoring_enabled: true})
      {:ok, _} = HealthCheckWorker.schedule_next(3600)
      {:ok, manual} = HealthCheckWorker.kickoff_manual()
      assert manual.args["manual"] == true
    end

    test "executing periodic cookie job schedules a successor" do
      {:ok, _} = Settings.update_setting(Settings.record(), %{cookie_health_monitoring_enabled: true})
      File.write!(CookieFile.filepath(), "")
      {:ok, job} = HealthCheckWorker.schedule_next(1)
      {:ok, job} = job |> Ecto.Changeset.change(state: "executing") |> Repo.update()
      assert :ok = HealthCheckWorker.perform(job)
      import Ecto.Query
      assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker and j.state == "scheduled"), :count) == 1
    end

    test "cookie probe has a bounded worker lifetime" do
      timeout = HealthCheckWorker.timeout(%Oban.Job{args: %{}})
      assert is_integer(timeout) and timeout <= 60_000
    end

    test "executing manual health job blocks repeated manual requests" do
      import Ecto.Query
      {:ok, job} = HealthCheckWorker.kickoff_manual()
      {:ok, _} = job |> Ecto.Changeset.change(state: "executing") |> Repo.update()
      {:ok, _} = HealthCheckWorker.kickoff_manual()
      assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 1
    end
  end
end
