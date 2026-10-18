defmodule PinchflatWeb.Helpers.JobActionHelpers do
  @moduledoc "Presents queue acceptance separately from download completion."

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  @doc "Returns %{type: :info | :error, message: String.t()} for an enqueue result or batch."
  def feedback(result, success_message \\ "Download queued.")
  def feedback({:ok, _task}, message), do: %{type: :info, message: message}
  def feedback({:error, :duplicate_job}, _message), do: %{type: :info, message: "Already queued."}

  def feedback(results, _message) when is_list(results) do
    queued = Enum.count(results, &match?({:ok, _}, &1))
    duplicates = Enum.count(results, &(&1 == {:error, :duplicate_job}))
    failed = length(results) - queued - duplicates
    message = "#{queued} queued, #{duplicates} already queued, #{failed} failed."
    %{type: if(failed > 0, do: :error, else: :info), message: message}
  end

  def feedback(_error, _message),
    do: %{type: :error, message: "Could not queue this action. Check diagnostics and try again."}

  @doc "Returns a JSON connection with 200 for accepted/duplicate work or 503 for a failed enqueue."
  def respond(conn, result, success_message) do
    case feedback(result, success_message) do
      %{type: :info, message: message} -> json(conn, %{message: message})
      %{type: :error, message: message} -> conn |> put_status(:service_unavailable) |> json(%{error: message})
    end
  end
end
