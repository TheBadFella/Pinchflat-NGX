defmodule Pinchflat.ReconciliationTest do
  use Pinchflat.DataCase

  alias Pinchflat.Reconciliation

  describe "apply_progress/1" do
    test "reports 100% for a plan with nothing applyable" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :ready})

      assert %{processed: 0, total: 0, percent: 100} = Reconciliation.apply_progress(plan)
    end

    test "counts only applyable rows and ignores skip/collision rows" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :applying})

      Reconciliation.create_plan_items([
        row(plan, :move, :done),
        row(plan, :backfill, :done),
        row(plan, :delete, :planned),
        row(plan, :redownload, :planned),
        # Not applyable — must not inflate the total
        row(plan, :skip, :planned),
        row(plan, :collision, :planned)
      ])

      assert %{processed: 2, total: 4, percent: 50} = Reconciliation.apply_progress(plan)
    end

    test "treats skipped and failed rows as processed" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :applying})

      Reconciliation.create_plan_items([
        row(plan, :move, :done),
        row(plan, :move, :skipped),
        row(plan, :backfill, :failed),
        row(plan, :backfill, :planned)
      ])

      assert %{processed: 3, total: 4, percent: 75} = Reconciliation.apply_progress(plan)
    end
  end

  defp row(plan, action, status) do
    %{
      reconcile_plan_id: plan.id,
      action: action,
      attribute: "media",
      status: status
    }
  end
end
