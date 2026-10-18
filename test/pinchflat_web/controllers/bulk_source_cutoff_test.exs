defmodule PinchflatWeb.BulkSourceCutoffTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  test "preview is read-only and confirmation uses the signed selection", %{conn: conn} do
    source = source_fixture()
    other = source_fixture()

    html =
      post(conn, "/sources/cutoff/preview", %{source_ids: ["#{source.id}"], cutoff_date: "2026-01-02"})
      |> html_response(200)

    assert html =~ "Confirm cutoff change"
    assert html =~ "scheduled retention"
    assert is_nil(Repo.reload!(source).download_cutoff_date)
    [_, token] = Regex.run(~r/name="token" value="([^"]+)"/, html)

    response =
      post(conn, "/sources/cutoff/apply", %{token: token, source_ids: ["#{other.id}"], cutoff_date: "2025-01-01"})

    assert redirected_to(response) == "/sources"
    assert Repo.reload!(source).download_cutoff_date == ~D[2026-01-02]
    assert is_nil(Repo.reload!(other).download_cutoff_date)
  end

  test "unsigned or expired confirmations cannot update sources", %{conn: conn} do
    source = source_fixture()

    for params <- [%{}, %{token: "forged"}] do
      response = post(conn, "/sources/cutoff/apply", params)
      assert redirected_to(response) == "/sources"
      assert Phoenix.Flash.get(response.assigns.flash, :error)
    end

    token =
      Phoenix.Token.sign(PinchflatWeb.Endpoint, "bulk-source-cutoff", {["#{source.id}"], "2026-01-01", "old"},
        signed_at: System.system_time(:second) - 1000
      )

    response = post(conn, "/sources/cutoff/apply", %{token: token})
    assert Phoenix.Flash.get(response.assigns.flash, :error)
    assert is_nil(Repo.reload!(source).download_cutoff_date)
  end
end
