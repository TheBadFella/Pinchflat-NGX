defmodule Pinchflat.TestingHelperMethods do
  @moduledoc false

  use ExUnit.CaseTemplate

  def now do
    DateTime.utc_now()
  end

  def now_plus(offset, unit) when unit in [:minute, :minutes] do
    DateTime.add(now(), offset, :minute)
  end

  def now_minus(offset, unit) when unit in [:minute, :minutes] do
    DateTime.add(now(), -offset, :minute)
  end

  def now_minus(offset, unit) when unit in [:day, :days] do
    DateTime.add(now(), -offset, :day)
  end

  def assert_changed(checker_fun, action_fn) do
    before_res = checker_fun.()
    action_fn.()
    after_res = checker_fun.()

    assert before_res != after_res
  end

  def assert_changed([from: from, to: to], checker_fun, action_fn) do
    before_res = checker_fun.()
    action_fn.()
    after_res = checker_fun.()

    assert before_res == from
    assert after_res == to
  end

  def render_metadata(metadata_name) do
    json_filepath =
      Path.join([
        File.cwd!(),
        "test",
        "support",
        "files",
        "#{metadata_name}.json"
      ])

    File.read!(json_filepath)
  end

  def render_parsed_metadata(metadata_name) do
    metadata_name
    |> render_metadata()
    |> Phoenix.json_library().decode!()
  end

  @doc """
  Damages the FTS5 search index the way a real fault does — by mangling the
  inverted index behind it — so integrity checks have something genuine to
  report. Rolled back with the test's sandbox transaction.

  The explicit 'rebuild' first is load-bearing: FTS5 buffers index writes in
  memory, so without it the shadow table may hold nothing to corrupt yet and
  the damage silently doesn't happen. The assertion catches that case rather
  than letting a test pass against an intact index.
  """
  def corrupt_search_index do
    Pinchflat.Repo.query!("INSERT INTO media_items_search_index(media_items_search_index) VALUES('rebuild')")

    result = Pinchflat.Repo.query!("UPDATE media_items_search_index_data SET block = zeroblob(8) WHERE id > 1")

    assert result.num_rows > 0, "expected the search index to have shadow rows to corrupt"

    :ok
  end

  def create_platform_directories do
    File.mkdir_p!(Application.get_env(:pinchflat, :media_directory))
    File.mkdir_p!(Application.get_env(:pinchflat, :metadata_directory))
    File.mkdir_p!(Application.get_env(:pinchflat, :extras_directory))
    File.mkdir_p!(Application.get_env(:pinchflat, :tmpfile_directory))
  end
end
