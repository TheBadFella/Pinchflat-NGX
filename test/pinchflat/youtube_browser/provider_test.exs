defmodule Pinchflat.YoutubeBrowser.ProviderTest do
  use ExUnit.Case, async: false

  alias Pinchflat.YoutubeBrowser.Provider.YtDlp

  setup do
    previous = Application.get_env(:pinchflat, :yt_dlp_executable)
    path = Path.join(System.tmp_dir!(), "browse-provider-#{System.unique_integer([:positive])}.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, sys, time
    query = sys.argv[-1]
    if query == 'drip':
        for _ in range(50):
            print(' ', flush=True)
            time.sleep(0.02)
    elif query == 'https://www.youtube.com/watch?v=dQw4w9WgXcQ':
        print(json.dumps({'id': 'dQw4w9WgXcQ', 'title': 'Exact video'}))
    elif query.endswith(':array'):
        print('[]')
    elif query.endswith(':bad_entries'):
        print('{"entries": "invalid"}')
    else:
        print(json.dumps({'entries': []}))
    """)

    File.chmod!(path, 0o755)
    Application.put_env(:pinchflat, :yt_dlp_executable, path)

    on_exit(fn ->
      Application.put_env(:pinchflat, :yt_dlp_executable, previous)
      File.rm(path)
    end)

    :ok
  end

  test "fetches video details from its canonical URL rather than a text search" do
    assert {:ok, %{id: "dQw4w9WgXcQ", title: "Exact video"}} =
             YtDlp.get_video_details("dQw4w9WgXcQ")
  end

  test "continuous output cannot extend the overall deadline" do
    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = YtDlp.execute_cmd(["drip"], timeout: 100)
    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "JSON arrays are rejected without raising" do
    assert {:error, :malformed_json_output} = YtDlp.search_videos("array")
  end

  test "malformed entry containers are rejected without raising" do
    assert {:error, :malformed_json_output} = YtDlp.search_videos("bad_entries")
  end

  test "channel preview rejects unrelated URLs and malformed canonical identities" do
    for input <- [
          "https://localhost/private",
          "https://www.youtube.com/redirect?q=http://localhost",
          "UCbad/../../redirect",
          "@bad?url=http://localhost",
          "https://user:pass@www.youtube.com/channel/UCvalid"
        ] do
      assert {:error, :invalid_channel} = YtDlp.get_channel_preview(input)
    end
  end
end
