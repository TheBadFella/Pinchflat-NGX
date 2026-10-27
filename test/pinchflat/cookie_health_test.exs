defmodule Pinchflat.CookieHealthTest do
  use Pinchflat.DataCase, async: false

  import Mox

  alias Pinchflat.CookieHealth
  alias Pinchflat.Settings
  alias Pinchflat.Settings.CookieFile

  setup :verify_on_exit!

  setup do
    base_dir =
      Path.join([
        System.tmp_dir!(),
        "cookie_health_test",
        Integer.to_string(:erlang.unique_integer([:positive]))
      ])

    File.mkdir_p!(base_dir)
    original = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir}
  end

  defp write_cookies(contents) do
    File.write!(CookieFile.filepath(), contents)
  end

  defp valid_cookie_line(name \\ "SESSION", expiry \\ 9_999_999_999) do
    ".youtube.com\tTRUE\t/\tTRUE\t#{expiry}\t#{name}\tsecret_val_123"
  end

  describe "cookie_digest/0" do
    test "returns nil when cookies file is missing or blank" do
      assert is_nil(CookieHealth.cookie_digest())

      write_cookies("   \n ")
      assert is_nil(CookieHealth.cookie_digest())
    end

    test "returns sha256 hex digest when cookies file has contents" do
      write_cookies(valid_cookie_line())
      digest = CookieHealth.cookie_digest()

      assert is_binary(digest)
      assert String.length(digest) == 64
    end
  end

  describe "with_cookie_snapshot/1" do
    test "returns {:error, :not_configured} when cookies file is missing" do
      assert {:error, :not_configured} = CookieHealth.with_cookie_snapshot(fn _path -> :ok end)
    end

    test "creates an isolated mode 0600 snapshot and deletes it after execution" do
      cookie_content = valid_cookie_line()
      write_cookies(cookie_content)

      captured_path =
        CookieHealth.with_cookie_snapshot(fn tmp_path ->
          assert File.exists?(tmp_path)
          assert File.read!(tmp_path) == cookie_content

          {:ok, %{mode: mode}} = File.stat(tmp_path)
          assert Bitwise.band(mode, 0o777) == 0o600

          # Mutate the snapshot to verify the original file is preserved
          File.write!(tmp_path, "mutated_contents_by_ytdlp")

          tmp_path
        end)

      # Snapshot must be deleted
      refute File.exists?(captured_path)

      # Original file must remain byte-identical
      assert File.read!(CookieFile.filepath()) == cookie_content
    end

    test "cleans up snapshot even if the callback raises" do
      write_cookies(valid_cookie_line())
      ref = make_ref()

      assert_raise RuntimeError, "boom", fn ->
        CookieHealth.with_cookie_snapshot(fn tmp_path ->
          Process.put(ref, tmp_path)
          raise "boom"
        end)
      end

      tmp_path = Process.get(ref)
      assert is_binary(tmp_path)
      refute File.exists?(tmp_path)
    end
  end

  describe "check_health/1 offline states" do
    test "returns not_configured when no cookies file exists or file is empty" do
      assert {:ok, %{status: "not_configured"}} = CookieHealth.check_health()

      write_cookies("")
      assert {:ok, %{status: "not_configured"}} = CookieHealth.check_health()
    end

    test "returns malformed when cookies file contains invalid format" do
      write_cookies("this is definitely not netscape cookie format\nno tabs")
      assert {:ok, %{status: "malformed", error: err}} = CookieHealth.check_health()
      assert is_binary(err)
    end

    test "returns expired when all cookies are past expiry" do
      write_cookies(valid_cookie_line("EXPIRED", 1_000_000_000))
      assert {:ok, %{status: "expired", error: err}} = CookieHealth.check_health()
      assert err =~ "expired"
    end

    test "returns auth_unverified when unexpired cookies exist without a canary URL" do
      write_cookies(valid_cookie_line("ACTIVE", 9_999_999_999))
      assert {:ok, %{status: "auth_unverified", error: nil}} = CookieHealth.check_health(canary_url: nil)
    end
  end

  describe "check_health/1 truthful canary probing" do
    test "never treats public canary success as authenticated health" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=public123"

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes, _cmd_opts, _template, addl_opts ->
        assert url == canary
        assert Keyword.has_key?(addl_opts, :cookies_filepath)

        json =
          Jason.encode!(%{
            "id" => "public123",
            "title" => "Public Video",
            "availability" => "public"
          })

        {:ok, json}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "auth_unverified"
      assert result.details =~ "public/unlisted"
    end

    test "treats unlisted canary success as auth_unverified" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=unlisted123"

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes, _cmd_opts, _template, _addl_opts ->
        assert url == canary

        json =
          Jason.encode!(%{
            "id" => "unlisted123",
            "title" => "Unlisted Video",
            "availability" => "unlisted"
          })

        {:ok, json}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "auth_unverified"
    end

    test "marks authenticated when canary is auth-gated (subscriber_only/members-only)" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=members123"

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes, _cmd_opts, _template, _addl_opts ->
        assert url == canary

        json =
          Jason.encode!(%{
            "id" => "members123",
            "title" => "Members Only Video",
            "availability" => "subscriber_only"
          })

        {:ok, json}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "authenticated"
      assert result.details =~ "subscriber_only"
    end

    test "probes without cookies when availability is not provided in metadata" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=noavail123"

      # First call with cookies succeeds
      expect(YtDlpRunnerMock, :run, fn ^canary, :get_media_attributes, _opts, _tmpl, addl ->
        assert Keyword.has_key?(addl, :cookies_filepath)
        {:ok, Jason.encode!(%{"id" => "noavail123", "title" => "Unknown Availability"})}
      end)

      # Second call without cookies fails (proving authentication was required)
      expect(YtDlpRunnerMock, :run, fn ^canary, :get_media_attributes, _opts, _tmpl, addl ->
        assert addl[:use_cookies] == false
        {:error, "Sign in to confirm", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "authenticated"
    end

    test "marks auth_unverified if probe without cookies also succeeds" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=noavail123"

      # First call with cookies succeeds
      expect(YtDlpRunnerMock, :run, fn ^canary, :get_media_attributes, _opts, _tmpl, _addl ->
        {:ok, Jason.encode!(%{"id" => "noavail123", "title" => "Unknown Availability"})}
      end)

      # Second call without cookies also succeeds -> public video
      expect(YtDlpRunnerMock, :run, fn ^canary, :get_media_attributes, _opts, _tmpl, addl ->
        assert addl[:use_cookies] == false
        {:ok, Jason.encode!(%{"id" => "noavail123"})}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "auth_unverified"
    end

    test "handles explicit YouTube authentication rejection" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=rejected123"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:error, "cookies are expired", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "authentication_rejected"
      assert result.error =~ "authentication rejected"
    end

    test "bot challenge does not diagnose expired or rejected account cookies" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=bot123"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:error, "ERROR: Sign in to confirm you're not a bot", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      refute result.status == "authentication_rejected"
      assert result.status == "canary_unavailable"
    end

    test "membership entitlement does not diagnose rejected authentication" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=members123"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:error, "Join this channel to get access to members-only content", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      refute result.status == "authentication_rejected"
      assert result.status == "canary_unavailable"
    end

    test "private metadata for wrong video cannot prove configured canary" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=abcdefghijk"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:ok, Jason.encode!(%{"id" => "wrongvideo1", "title" => "Wrong", "availability" => "private"})}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      refute result.status == "authenticated"
      assert result.status == "auth_unverified"
    end

    test "without-cookie network failure does not prove authentication" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=abcdefghijk"

      expect(YtDlpRunnerMock, :run, fn ^canary, :get_media_attributes, _opts, _tmpl, _addl ->
        {:ok, Jason.encode!(%{"id" => "abcdefghijk", "title" => "Unknown"})}
      end)

      expect(YtDlpRunnerMock, :run, fn ^canary, :get_media_attributes, _opts, _tmpl, addl ->
        assert addl[:use_cookies] == false
        {:error, "Network is unreachable", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      refute result.status == "authenticated"
      assert result.status == "auth_unverified"
    end

    test "unknown provider errors cannot export private canary query secrets" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=abcdefghijk"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:error, "Extractor failed at https://www.youtube.com/watch?v=abcdefghijk&credential=PRIVATE_CANARY_SECRET", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      refute result.error =~ "PRIVATE_CANARY_SECRET"
    end

    test "handles unavailable or deleted canary" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=missing123"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:error, "ERROR: Video unavailable. This video has been removed by the uploader", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "canary_unavailable"
    end

    test "handles network error or HTTP 429 rate limit" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=rate123"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:error, "HTTP Error 429: Too Many Requests", 1}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: canary)
      assert result.status == "network_error"
    end
  end

  describe "perform_check_and_update/1 and Apprise deduplication" do
    test "persists status and timestamps to Settings and deduplicates Apprise alerts" do
      write_cookies(valid_cookie_line("EXP", 1_000_000_000))
      Settings.update_setting(Settings.record(), %{apprise_server: "https://notify.example.com"})

      # First run: alert must be sent
      expect(AppriseRunnerMock, :run, 1, fn ["https://notify.example.com"], opts ->
        assert opts[:title] =~ "Cookie Issue"
        assert opts[:body] =~ "expired"
        refute Keyword.has_key?(opts, :input_format)
        refute opts[:body] =~ "**"
        {:ok, "sent"}
      end)

      assert {:ok, setting1, result1} = CookieHealth.perform_check_and_update()
      assert setting1.cookie_health_status == "expired"
      assert result1.status == "expired"
      assert setting1.cookie_health_alert_sent_for_digest == CookieHealth.cookie_digest()

      # Second run with same cookie digest: NO alert must be sent
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      assert {:ok, setting2, result2} = CookieHealth.perform_check_and_update()
      assert setting2.cookie_health_status == "expired"
      assert result2.status == "expired"

      # Update cookies with fresh (different) expired cookies: new alert CAN be sent
      write_cookies(valid_cookie_line("EXP2", 1_000_000_001))
      new_digest = CookieHealth.cookie_digest()
      assert new_digest != setting2.cookie_health_cookie_digest

      expect(AppriseRunnerMock, :run, 1, fn ["https://notify.example.com"], _opts ->
        {:ok, "sent"}
      end)

      assert {:ok, setting3, _result3} = CookieHealth.perform_check_and_update()
      assert setting3.cookie_health_alert_sent_for_digest == new_digest
    end

    test "records last_authenticated_at when status is authenticated" do
      write_cookies(valid_cookie_line())
      canary = "https://www.youtube.com/watch?v=members123"

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _tmpl, _addl ->
        {:ok, Jason.encode!(%{"id" => "members123", "availability" => "subscriber_only"})}
      end)

      assert {:ok, setting, _result} = CookieHealth.perform_check_and_update(canary_url: canary)
      assert setting.cookie_health_status == "authenticated"
      assert %DateTime{} = setting.cookie_health_last_authenticated_at
      assert %DateTime{} = setting.cookie_health_last_checked_at
    end

    test "replacing cookies during probe discards the old result" do
      write_cookies(valid_cookie_line("OLD", 9_999_999_999))

      expect(YtDlpRunnerMock, :run, fn _, _, _, _, _ ->
        write_cookies(valid_cookie_line("NEW", 9_999_999_999))
        {:error, "cookies are expired", 1}
      end)

      CookieHealth.perform_check_and_update(canary_url: "https://www.youtube.com/watch?v=abcdefghijk")
      refute Settings.record().cookie_health_status == "authentication_rejected"
    end

    test "missing video ID does not authenticate a canary" do
      write_cookies(valid_cookie_line())

      expect(YtDlpRunnerMock, :run, fn _, _, _, _, _ ->
        {:ok, Jason.encode!(%{"availability" => "private", "title" => "Incomplete response"})}
      end)

      assert {:ok, result} = CookieHealth.check_health(canary_url: "https://www.youtube.com/watch?v=abcdefghijk")
      refute result.status == "authenticated"
      assert result.status == "auth_unverified"
    end

    test "snapshot owner cleanup survives a brutally killed probe" do
      write_cookies(valid_cookie_line())
      parent = self()

      task =
        Task.async(fn ->
          CookieHealth.with_cookie_snapshot(fn path ->
            send(parent, {:snapshot, path})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:snapshot, path}, 1000
      on_exit(fn -> File.rm(path) end)
      Task.shutdown(task, :brutal_kill)
      refute File.exists?(path)
    end

    test "sanitizes canary url and output containing secrets" do
      url_with_secret = "https://www.youtube.com/watch?v=abcdefghijk&credential=SUPER_SECRET_TOKEN"
      sanitized_url = CookieHealth.sanitize_canary_url(url_with_secret)
      refute sanitized_url =~ "SUPER_SECRET_TOKEN"
      assert sanitized_url =~ "v=abcdefghijk"
      assert sanitized_url =~ "credential=[REDACTED]"

      output_with_secret = "Failed at #{url_with_secret} with file pinchflat_cookie_probe_12345.txt"
      sanitized_out = CookieHealth.sanitize_canary_output(output_with_secret)
      refute sanitized_out =~ "SUPER_SECRET_TOKEN"
      assert sanitized_out =~ "[REDACTED]"
    end
  end
end
