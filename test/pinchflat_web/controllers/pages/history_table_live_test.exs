defmodule PinchflatWeb.Pages.HistoryTableLiveTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.HistoryTableLive
  alias Pinchflat.Downloading.MediaDownloadWorker

  describe "pending ordering" do
    test "shows executing downloads before later queued pending items across pages", %{conn: conn} do
      source = source_fixture()

      older_executing_item =
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          uploaded_at: ~U[2024-01-01 00:00:00Z]
        )

      for day <- 2..12 do
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          uploaded_at: DateTime.add(~U[2024-01-01 00:00:00Z], day * 86_400, :second)
        )
      end

      {:ok, task} = MediaDownloadWorker.kickoff_with_task(older_executing_item)

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "executing"])

      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "pending"})

      assert html =~ older_executing_item.title
    end
  end
end
