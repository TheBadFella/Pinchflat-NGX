defmodule PinchflatWeb.Helpers.JobActionHelpersTest do
  use PinchflatWeb.ConnCase

  alias PinchflatWeb.Helpers.JobActionHelpers

  test "rejected enqueue returns a failure response without exposing internal details" do
    conn = JobActionHelpers.respond(build_conn(), {:error, :private_database_detail}, "Download job created")
    assert json_response(conn, 503)["error"] == "Could not queue this action. Check diagnostics and try again."
    refute conn.resp_body =~ "private_database_detail"
  end

  test "partial batches report accepted, duplicate and rejected work" do
    conn =
      JobActionHelpers.respond(build_conn(), [{:ok, %{}}, {:error, :duplicate_job}, {:error, :unavailable}], "Queued")

    assert json_response(conn, 503)["error"] == "1 queued, 1 already queued, 1 failed."
  end
end
