defmodule PinchflatWeb.BulkSourceCutoffTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
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

  test "the sources list applies a cutoff straight away and reports it", %{conn: conn} do
    source = source_fixture()
    other = source_fixture()

    response =
      post(conn, "/sources/cutoff/apply_now", %{
        "source_ids" => ["#{source.id}"],
        "cutoff_date" => "2026-01-02",
        "return_to" => "/sources?type=videos"
      })

    assert redirected_to(response) == "/sources?type=videos"
    assert Phoenix.Flash.get(response.assigns.flash, :info) == "Download cutoff set to 2026-01-02 for 1 source."
    assert Repo.reload!(source).download_cutoff_date == ~D[2026-01-02]
    assert is_nil(Repo.reload!(other).download_cutoff_date)

    response = post(conn, "/sources/cutoff/apply_now", %{"source_ids" => ["#{source.id}"], "cutoff_date" => ""})
    assert Phoenix.Flash.get(response.assigns.flash, :info) == "Download cutoff removed for 1 source."
    assert is_nil(Repo.reload!(source).download_cutoff_date)
  end

  test "asks for confirmation when downloaded items would become eligible for removal", %{conn: conn} do
    source = source_fixture()
    media_item_fixture(source_id: source.id, uploaded_at: ~U[2025-06-01 00:00:00Z])

    html =
      post(conn, "/sources/cutoff/apply_now", %{"source_ids" => ["#{source.id}"], "cutoff_date" => "2026-01-02"})
      |> html_response(200)

    assert html =~ "Confirm cutoff change"
    assert html =~ "Eligible for removal by scheduled retention"
    assert is_nil(Repo.reload!(source).download_cutoff_date)
    [_, token] = Regex.run(~r/name="token" value="([^"]+)"/, html)

    response = post(conn, "/sources/cutoff/apply", %{token: token})
    assert redirected_to(response) == "/sources"
    assert Repo.reload!(source).download_cutoff_date == ~D[2026-01-02]
  end

  test "a cutoff earlier than a source's index cutoff names the source and changes nothing", %{conn: conn} do
    fine = source_fixture(custom_name: "Fine source")
    conflict = source_fixture(custom_name: "Indexed later", index_cutoff_date: ~D[2026-02-01])

    response =
      post(conn, "/sources/cutoff/apply_now", %{
        "source_ids" => ["#{fine.id}", "#{conflict.id}"],
        "cutoff_date" => "2026-01-01"
      })

    assert Phoenix.Flash.get(response.assigns.flash, :error) ==
             "Nothing changed. The download cutoff can't be earlier than a source's index cutoff: " <>
               "Indexed later (2026-02-01). Choose 2026-02-01 or later, or change those index cutoffs first."

    assert is_nil(Repo.reload!(fine).download_cutoff_date)
    assert is_nil(Repo.reload!(conflict).download_cutoff_date)
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
