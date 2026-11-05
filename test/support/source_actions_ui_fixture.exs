import Ecto.Query, warn: false
# Explicitly opt into synthetic data in a disposable MIX_ENV=test container.
unless Mix.env() == :test and System.get_env("SOURCE_ACTIONS_UI_FIXTURE") == "1" do
  raise "Use a disposable test container with SOURCE_ACTIONS_UI_FIXTURE=1"
end

Application.put_env(
  :pinchflat,
  PinchflatWeb.Endpoint,
  Keyword.merge(Application.fetch_env!(:pinchflat, PinchflatWeb.Endpoint),
    http: [ip: {0, 0, 0, 0}, port: 4003],
    check_origin: ["//localhost", "//127.0.0.1"],
    server: true
  )
)

{:ok, _} = Application.ensure_all_started(:pinchflat)

unless Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count) == 0 and
         Pinchflat.Repo.aggregate(Pinchflat.Profiles.MediaProfile, :count) == 0 do
  raise "The browser fixture requires an empty disposable test database"
end

Pinchflat.TestingHelperMethods.create_platform_directories()
Pinchflat.Settings.set(onboarding: false)

profile =
  Pinchflat.ProfilesFixtures.media_profile_fixture(%{
    name: "[UI test] Profile with an exceptionally long descriptive name that must wrap safely",
    retention_period_days: 30
  })

short =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile.id,
    enabled: false,
    download_media: false,
    custom_name: "[UI test] Short action source"
  })

long =
  Pinchflat.SourcesFixtures.source_fixture(%{
    media_profile_id: profile.id,
    enabled: false,
    download_media: false,
    custom_name:
      "[UI test] A very long source name that spans several lines so the action controls must stay aligned and visible"
  })

# source_fixture/1 evaluates its default media_profile_fixture even when the
# caller supplies an explicit profile, leaving unreferenced profiles behind.
# Remove them so the browse profile selector has a single unambiguous default.
Pinchflat.Repo.delete_all(from p in Pinchflat.Profiles.MediaProfile, where: p.id != ^profile.id)

File.write!(
  "/tmp/pinchflat-source-actions-ui.json",
  Jason.encode!(%{profile_id: profile.id, source_ids: [short.id, long.id]})
)

IO.puts("SOURCE_ACTIONS_UI_READY")
Process.sleep(:infinity)
