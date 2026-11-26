Mox.defmock(YtDlpRunnerMock, for: Pinchflat.YtDlp.YtDlpCommandRunner)
Application.put_env(:pinchflat, :yt_dlp_runner, YtDlpRunnerMock)

Mox.defmock(AppriseRunnerMock, for: Pinchflat.Lifecycle.Notifications.AppriseCommandRunner)
Application.put_env(:pinchflat, :apprise_runner, AppriseRunnerMock)

Mox.defmock(HTTPClientMock, for: Pinchflat.HTTP.HTTPBehaviour)
Application.put_env(:pinchflat, :http_client, HTTPClientMock)

Mox.defmock(UserScriptRunnerMock, for: Pinchflat.Lifecycle.UserScripts.UserScriptCommandRunner)
Application.put_env(:pinchflat, :user_script_runner, UserScriptRunnerMock)

Mox.defmock(YoutubeApiMock, for: Pinchflat.FastIndexing.YoutubeBehaviour)
Application.put_env(:pinchflat, :youtube_api, YoutubeApiMock)

Mox.defmock(DiskSpaceCheckerMock, for: Pinchflat.Diagnostics.DiskSpaceBehaviour)
Application.put_env(:pinchflat, :disk_space_checker, DiskSpaceCheckerMock)

Mox.defmock(YoutubeBrowserProviderMock, for: Pinchflat.YoutubeBrowser.Provider)
Application.put_env(:pinchflat, :youtube_browser_provider, YoutubeBrowserProviderMock)
# These tests temporarily change PostgreSQL column types. Keep them out of the
# normal suite so cached Postgrex plans cannot observe a changed result type;
# the dedicated PostgreSQL migration job opts back in with --include.
adapter_exclude = if Pinchflat.Database.postgres?(), do: [sqlite_only: true], else: [postgres_only: true]
# The M2 safety review approved the fenced replacement, archive and recovery
# paths, so the synthetic `:destructive_watch` fault tests now run in the normal
# suite. The tag stays for documentation and selective reruns.
exclude = [migration_schema: true] ++ adapter_exclude

# CI runs the suite as parallel partitions (tooling/test_partitions.sh) on shared CPUs, so
# allow waits such as assert_receive and render_async longer than the 100ms default.
# This only delays a failing assertion; refute_receive keeps its own short timeout.
ExUnit.start(exclude: exclude, assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Pinchflat.Repo, :manual)
Faker.start()

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Application.get_env(:pinchflat, :media_directory))
  File.rm_rf!(Application.get_env(:pinchflat, :metadata_directory))
  File.rm_rf!(Application.get_env(:pinchflat, :extras_directory))
  File.rm_rf!(Application.get_env(:pinchflat, :tmpfile_directory))

  File.mkdir_p!(Application.get_env(:pinchflat, :media_directory))
  File.mkdir_p!(Application.get_env(:pinchflat, :metadata_directory))
  File.mkdir_p!(Application.get_env(:pinchflat, :extras_directory))
  File.mkdir_p!(Application.get_env(:pinchflat, :tmpfile_directory))
end)
