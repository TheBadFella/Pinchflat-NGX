defmodule Pinchflat.Repo.Migrations.AddCookieHealthMonitoringSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :cookie_health_monitoring_enabled, :boolean, default: false
      add :cookie_health_check_interval_hours, :integer, default: 6
      add :cookie_health_canary_url, :string
      add :cookie_health_status, :string, default: "not_configured"
      add :cookie_health_last_checked_at, :utc_datetime
      add :cookie_health_last_authenticated_at, :utc_datetime
      add :cookie_health_last_error, :text
      add :cookie_health_cookie_digest, :string
      add :cookie_health_alert_sent_for_digest, :string
    end
  end
end
