# Explicitly opt into synthetic data in a disposable MIX_ENV=test container.
unless Mix.env() == :test and System.get_env("RETENTION_UI_FIXTURE") == "1" do
  raise "Use a disposable test container with RETENTION_UI_FIXTURE=1"
end

Application.put_env(
  :pinchflat,
  PinchflatWeb.Endpoint,
  Keyword.merge(Application.fetch_env!(:pinchflat, PinchflatWeb.Endpoint),
    http: [ip: {0, 0, 0, 0}, port: 4002],
    check_origin: ["//localhost", "//127.0.0.1"],
    server: true
  )
)

{:ok, _} = Application.ensure_all_started(:pinchflat)

unless Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count) == 0 do
  raise "The browser fixture requires an empty disposable test database"
end

Pinchflat.TestingHelperMethods.create_platform_directories()
Pinchflat.Settings.set(onboarding: false)

profile = Pinchflat.ProfilesFixtures.media_profile_fixture(%{name: "[UI test] 30 days", retention_period_days: 30})
Pinchflat.ProfilesFixtures.media_profile_fixture(%{name: "[UI test] 7 days", retention_period_days: 7})
Pinchflat.ProfilesFixtures.media_profile_fixture(%{name: "[UI test] No age cleanup", retention_period_days: nil})

source =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile.id,
    enabled: false,
    download_media: false,
    custom_name: "[UI test] Retention inheritance"
  })

for {name, days} <- [{"[UI test] Explicit zero", 0}, {"[UI test] One day with a long source name for wrapping", 1}] do
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile.id,
    enabled: false,
    download_media: false,
    custom_name: name,
    retention_period_days: days
  })
end

File.write!("/tmp/pinchflat-retention-ui.json", Jason.encode!(%{source_id: source.id}))
IO.puts("RETENTION_UI_READY")
Process.sleep(:infinity)
