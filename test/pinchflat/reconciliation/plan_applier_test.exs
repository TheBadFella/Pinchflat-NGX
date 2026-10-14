defmodule Pinchflat.Reconciliation.PlanApplierTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.PlanApplier
  alias Pinchflat.Reconciliation.ReconcilePlanItem
  alias Pinchflat.Metadata.MetadataFileHelpers

  describe "apply_plan/1 (moves)" do
    test "moves the file, updates the column, and marks the row done" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = new_target_path()

      create_row(plan, media_item, :move, "media", from_path: media_item.media_filepath, to_path: target)

      assert {:ok, applied} = PlanApplier.apply_plan(plan)

      assert applied.status == :applied
      assert File.exists?(target)
      refute File.exists?(media_item.media_filepath)
      assert Repo.reload(media_item).media_filepath == target
      assert [%{status: :done}] = list_rows(plan)
    end

    test "moves subtitle files and updates the language entry" do
      media_item = downloaded_media_item()
      [["en", subtitle_path]] = media_item.subtitle_filepaths
      plan = ready_plan(media_item.source_id)
      target = Path.rootname(new_target_path()) <> ".en.srt"

      create_row(plan, media_item, :move, "subtitle:en", from_path: subtitle_path, to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert File.exists?(target)
      assert Repo.reload(media_item).subtitle_filepaths == [["en", target]]
    end

    test "skips a move whose destination became occupied after planning" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = new_target_path()
      # Something landed at the target between the dry run and apply
      Pinchflat.Utils.FilesystemUtils.write_p!(target, "someone else's file")

      create_row(plan, media_item, :move, "media", from_path: media_item.media_filepath, to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert [%{status: :skipped, detail: detail}] = list_rows(plan)
      assert detail =~ "occupied"
      # Neither the occupant nor the source file was touched
      assert File.read!(target) == "someone else's file"
      assert File.exists?(media_item.media_filepath)
      assert Repo.reload(media_item).media_filepath == media_item.media_filepath
    end

    test "skips rows that have gone stale" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)

      create_row(plan, media_item, :move, "media",
        from_path: "/somewhere/else/entirely.mp4",
        to_path: new_target_path()
      )

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert [%{status: :skipped, detail: detail}] = list_rows(plan)
      assert detail =~ "Stale"
      assert Repo.reload(media_item).media_filepath == media_item.media_filepath
    end
  end

  describe "apply_plan/1 (deletes and backfills)" do
    test "deletes now-unwanted sidecars and nils the column" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)

      create_row(plan, media_item, :delete, "thumbnail", from_path: media_item.thumbnail_filepath)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      refute File.exists?(media_item.thumbnail_filepath)
      assert Repo.reload(media_item).thumbnail_filepath == nil
    end

    test "backfills an NFO from stored metadata without any network calls" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = Path.rootname(new_target_path()) <> ".nfo"

      create_row(plan, media_item, :backfill, "nfo", to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert File.exists?(target)
      assert File.read!(target) =~ "<episodedetails>"
      assert Repo.reload(media_item).nfo_filepath == target
    end

    test "backfills the info.json from stored metadata" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = Path.rootname(new_target_path()) <> ".info.json"

      create_row(plan, media_item, :backfill, "metadata", to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert File.exists?(target)
      assert Phoenix.json_library().decode!(File.read!(target))["id"] == media_item.media_id
      assert Repo.reload(media_item).metadata_filepath == target
    end

    test "backfills subtitles that yt-dlp writes and records the language entry" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = Path.rootname(new_target_path()) <> ".en.srt"

      # yt-dlp names the sub off the media output template — write the file it would
      expect(YtDlpRunnerMock, :run, fn _url, :download_subtitles, opts, _ot, _addl ->
        srt = opts |> Keyword.fetch!(:output) |> String.replace_suffix(".%(ext)s", ".en.srt")
        Pinchflat.Utils.FilesystemUtils.write_p!(srt, "1\n00:00 --> 00:01\nhi\n")
        {:ok, ""}
      end)

      create_row(plan, media_item, :backfill, "subtitles", to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert [%{status: :done}] = list_rows(plan)
      assert [["en", srt_path]] = Media.get_media_item!(media_item.id).subtitle_filepaths
      assert srt_path =~ ".en.srt"
      assert File.exists?(srt_path)
    end

    test "skips the subtitle backfill when yt-dlp writes nothing" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = Path.rootname(new_target_path()) <> ".en.srt"

      # Video only has auto-captions and the profile wants manual subs — exit 0, no file
      expect(YtDlpRunnerMock, :run, fn _url, :download_subtitles, _opts, _ot, _addl -> {:ok, ""} end)

      create_row(plan, media_item, :backfill, "subtitles", to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert [%{status: :skipped, detail: detail}] = list_rows(plan)
      assert detail =~ "auto-generated subtitles"
    end

    test "records failures without aborting the run" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = new_target_path()

      # An unknown attribute fails its row; the valid move still applies
      create_row(plan, media_item, :backfill, "bogus", to_path: "/tmp/whatever")
      create_row(plan, media_item, :move, "media", from_path: media_item.media_filepath, to_path: target)

      assert {:ok, applied} = PlanApplier.apply_plan(plan)

      assert applied.error_count == 1
      assert File.exists?(target)
      statuses = plan |> list_rows() |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == [:done, :failed]
    end
  end

  describe "apply_plan/1 (re-downloads)" do
    test "schedules a forced re-download and leaves filepaths untouched" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)

      create_row(plan, media_item, :redownload, "media", from_path: media_item.media_filepath)

      assert {:ok, applied} = PlanApplier.apply_plan(plan)

      assert applied.status == :applied
      assert [%{status: :done}] = list_rows(plan)
      assert [_job] = all_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker)
      # The download job (not the applier) updates paths, so the file is untouched here
      assert File.exists?(media_item.media_filepath)
      assert Repo.reload(media_item).media_filepath == media_item.media_filepath
    end
  end

  describe "apply_plan/1 (safety enhancements)" do
    test "copies rather than moves when source artwork is shared by another source" do
      shared_poster =
        Path.join(Application.get_env(:pinchflat, :media_directory), "shared_poster_#{:rand.uniform(1_000_000)}.jpg")

      Pinchflat.Utils.FilesystemUtils.write_p!(shared_poster, "shared poster data")

      source1 = source_fixture(%{poster_filepath: shared_poster})
      source2 = source_fixture(%{poster_filepath: shared_poster})

      plan = ready_plan(source1.id)

      target =
        Path.join(Application.get_env(:pinchflat, :media_directory), "source1_poster_#{:rand.uniform(1_000_000)}.jpg")

      Reconciliation.create_plan_items([
        %{
          reconcile_plan_id: plan.id,
          source_id: source1.id,
          action: :move,
          attribute: "source_poster",
          from_path: shared_poster,
          to_path: target,
          status: :planned
        }
      ])

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert File.exists?(target)
      assert Repo.reload(source1).poster_filepath == target
      assert File.exists?(shared_poster)
      assert Repo.reload(source2).poster_filepath == shared_poster
    end

    test "copies rather than moves when thumbnail is shared by another media item" do
      shared_thumb =
        Path.join(Application.get_env(:pinchflat, :media_directory), "shared_thumb_#{:rand.uniform(1_000_000)}.jpg")

      Pinchflat.Utils.FilesystemUtils.write_p!(shared_thumb, "shared thumb data")

      item1 = downloaded_media_item()
      {:ok, item1} = Media.update_media_item(item1, %{thumbnail_filepath: shared_thumb})

      item2 = downloaded_media_item()
      {:ok, item2} = Media.update_media_item(item2, %{thumbnail_filepath: shared_thumb})

      plan = ready_plan(item1.source_id)

      target =
        Path.join(Application.get_env(:pinchflat, :media_directory), "item1_thumb_#{:rand.uniform(1_000_000)}.jpg")

      create_row(plan, item1, :move, "thumbnail", from_path: shared_thumb, to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert File.exists?(target)
      assert Repo.reload(item1).thumbnail_filepath == target
      assert File.exists?(shared_thumb)
      assert Repo.reload(item2).thumbnail_filepath == shared_thumb
    end

    test "discovers subtitle files with brackets in rootname" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      bracket_root = Path.join(Path.dirname(media_item.media_filepath), "[20240101] Video [XYZ]")
      target = bracket_root <> ".en.srt"

      expect(YtDlpRunnerMock, :run, fn _url, :download_subtitles, opts, _ot, _addl ->
        output_template = Keyword.fetch!(opts, :output)
        srt_file = String.replace_suffix(output_template, ".%(ext)s", ".en.srt")
        Pinchflat.Utils.FilesystemUtils.write_p!(srt_file, "1\n00:00 --> 00:01\ntest\n")
        {:ok, ""}
      end)

      create_row(plan, media_item, :backfill, "subtitles", to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert [%{status: :done}] = list_rows(plan)
      assert [["en", path]] = Media.get_media_item!(media_item.id).subtitle_filepaths
      assert File.exists?(path)
    end

    test "relocates relative symlinks without breaking link target" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)

      media_dir = Application.get_env(:pinchflat, :media_directory)
      real_target = Path.join(media_dir, "real_target_#{:rand.uniform(1_000_000)}.mp4")
      Pinchflat.Utils.FilesystemUtils.write_p!(real_target, "video contents")

      source_dir = Path.join(media_dir, "sym_src_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(source_dir)
      symlink_source = Path.join(source_dir, "link.mp4")
      relative_target = Path.relative_to(real_target, source_dir)
      File.ln_s(relative_target, symlink_source)

      {:ok, media_item} = Media.update_media_item(media_item, %{media_filepath: symlink_source})

      dest_dir = Path.join(media_dir, "sym_dest_#{:rand.uniform(1_000_000)}")
      destination = Path.join(dest_dir, "link.mp4")

      create_row(plan, media_item, :move, "media", from_path: symlink_source, to_path: destination)

      assert {:ok, _} = PlanApplier.apply_plan(plan)

      assert File.exists?(destination)
      assert File.read!(destination) == "video contents"
      refute File.exists?(symlink_source)
    end

    test "copies rather than moves when subtitle is shared by another media item" do
      first = downloaded_media_item()
      second = downloaded_media_item()
      [["en", old_path]] = first.subtitle_filepaths
      {:ok, second} = Media.update_media_item(second, %{subtitle_filepaths: [["en", old_path]]})
      target = old_path <> ".relocated"
      plan = ready_plan(first.source_id)

      create_row(plan, first, :move, "subtitle:en", from_path: old_path, to_path: target)

      assert {:ok, _} = PlanApplier.apply_plan(plan)
      assert File.exists?(target)
      assert Repo.reload!(second).subtitle_filepaths == [["en", old_path]]
      assert File.exists?(old_path)
    end

    test "preserves file on disk when deleting shared thumbnail" do
      first = downloaded_media_item()
      second = downloaded_media_item()
      old_path = first.thumbnail_filepath
      {:ok, second} = Media.update_media_item(second, %{thumbnail_filepath: old_path})
      plan = ready_plan(first.source_id)

      create_row(plan, first, :delete, "thumbnail", from_path: old_path)

      assert {:ok, _} = PlanApplier.apply_plan(plan)
      assert Repo.reload!(second).thumbnail_filepath == old_path
      assert File.exists?(old_path)
      assert Repo.reload!(first).thumbnail_filepath == nil
    end

    @tag :sqlite_only
    test "restores moved file when database update raises an exception" do
      Application.put_env(:pinchflat, :reconcile_backfill_concurrency, 1)
      item = downloaded_media_item()
      old_path = item.media_filepath
      target = old_path <> ".relocated"
      plan = ready_plan(item.source_id)

      create_row(plan, item, :move, "media", from_path: old_path, to_path: target)

      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TRIGGER test_fail_update BEFORE UPDATE OF media_filepath ON media_items BEGIN SELECT RAISE(ABORT, 'forced test failure'); END",
        []
      )

      try do
        assert {:ok, applied} = PlanApplier.apply_plan(plan)
        assert applied.error_count == 1
        assert Repo.reload!(item).media_filepath == old_path
        assert File.exists?(old_path)
        refute File.exists?(target)
      after
        Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER IF EXISTS test_fail_update", [])
      end
    end

    test "completes interrupted move where file was already moved on disk" do
      media_item = downloaded_media_item()
      plan = ready_plan(media_item.source_id)
      target = new_target_path()

      # Simulate mid-group crash: file is already at destination, old path gone
      File.rename(media_item.media_filepath, target)

      create_row(plan, media_item, :move, "media", from_path: media_item.media_filepath, to_path: target)

      assert {:ok, applied} = PlanApplier.apply_plan(plan)
      assert applied.status == :applied
      assert [%{status: :done}] = list_rows(plan)
      assert Repo.reload!(media_item).media_filepath == target
      assert File.exists?(target)
    end
  end

  defp downloaded_media_item do
    media_item = Repo.preload(media_item_with_attachments(), :metadata)

    metadata_filepath =
      MetadataFileHelpers.compress_and_store_metadata_for(media_item, %{
        "id" => media_item.media_id,
        "title" => media_item.title,
        "description" => "a description",
        "upload_date" => "20240101"
      })

    {:ok, media_item} =
      Media.update_media_item(media_item, %{
        metadata: %{metadata_filepath: metadata_filepath, thumbnail_filepath: media_item.thumbnail_filepath}
      })

    media_item
  end

  defp ready_plan(source_id) do
    {:ok, plan} = Reconciliation.create_plan(%{mode: :local, source_id: source_id, status: :ready})

    plan
  end

  defp create_row(plan, media_item, action, attribute, opts) do
    Reconciliation.create_plan_items([
      %{
        reconcile_plan_id: plan.id,
        media_item_id: media_item.id,
        source_id: media_item.source_id,
        action: action,
        attribute: attribute,
        from_path: Keyword.get(opts, :from_path),
        to_path: Keyword.get(opts, :to_path),
        status: :planned
      }
    ])
  end

  defp list_rows(plan) do
    Repo.all(from(rpi in ReconcilePlanItem, where: rpi.reconcile_plan_id == ^plan.id, order_by: rpi.id))
  end

  defp new_target_path do
    Path.join([Application.get_env(:pinchflat, :media_directory), "new-home-#{:rand.uniform(1_000_000)}", "video.mp4"])
  end
end
