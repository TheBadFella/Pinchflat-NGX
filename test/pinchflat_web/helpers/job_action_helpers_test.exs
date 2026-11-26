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

  test "a disabled source is presented as informational rather than an error" do
    assert %{type: :info, message: "Downloads are disabled for this source. No jobs were queued."} =
             JobActionHelpers.feedback(:downloads_disabled, "Download job created")
  end

  test "a disabled source responds with 200 and the same explanation" do
    conn = JobActionHelpers.respond(build_conn(), :downloads_disabled, "Download job created")

    assert json_response(conn, 200)["message"] ==
             "Downloads are disabled for this source. No jobs were queued."
  end

  test "an empty enabled batch keeps the existing no-op summary" do
    conn = JobActionHelpers.respond(build_conn(), [], "Download job created")

    assert json_response(conn, 200)["message"] == "0 queued, 0 already queued, 0 failed."
  end
end
