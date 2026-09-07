defmodule PinchflatWeb.OIDCTestHTTPAdapter do
  @moduledoc """
  Offline `Assent.HTTPAdapter` for OIDC callback tests.

  Serves a canned token response for the stub provider's token endpoint.
  The `id_token` is read from the process dictionary (set by the test),
  which works because assent performs its HTTP request in the same
  process as the controller dispatch.
  """

  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.HTTPResponse

  @impl Assent.HTTPAdapter
  def request(:post, "https://sso.test/token", _body, _headers, _opts) do
    id_token = Process.get(:oidc_test_id_token)

    unless id_token do
      raise "expected :oidc_test_id_token to be set in the process dictionary before dispatch"
    end

    body =
      Jason.encode!(%{
        "access_token" => "test_access_token",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "id_token" => id_token
      })

    {:ok, %HTTPResponse{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def request(_method, _url, _body, _headers, _opts) do
    # Unknown endpoints (e.g. discovery when the test config omits the
    # static document) surface as transport errors, which assent wraps
    # into an {:error, _} result for the controller to handle.
    {:error, :unexpected_request}
  end
end
