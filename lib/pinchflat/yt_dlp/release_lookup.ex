defmodule Pinchflat.YtDlp.ReleaseLookup do
  @moduledoc """
  Looks up yt-dlp release information from the GitHub API.

  Used to discover the latest stable release (so the `nightly_until_stable`
  update policy knows when stable has caught up) and to validate that a
  user-supplied pinned version actually exists before saving it.
  """

  @repo_api "https://api.github.com/repos/yt-dlp/yt-dlp"
  @headers [{"User-Agent", "Pinchflat"}, {"Accept", "application/vnd.github+json"}]

  @doc """
  Returns the tag name of the latest stable yt-dlp release.

  Returns `{:ok, binary()} | {:error, term()}`
  """
  def latest_stable_version do
    case http_client().get("#{@repo_api}/releases/latest", @headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"tag_name" => tag}} -> {:ok, tag}
          _ -> {:error, :unexpected_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true if the given version exists as a release on the yt-dlp repo.

  This is the same repo `--update-to yt-dlp/yt-dlp@<version>` installs from, so a
  positive result means the pinned version is actually installable.

  Returns boolean()
  """
  def version_available?(version) when is_binary(version) and version != "" do
    case http_client().get("#{@repo_api}/releases/tags/#{version}", @headers) do
      {:ok, _body} -> true
      {:error, _reason} -> false
    end
  end

  def version_available?(_version), do: false

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
