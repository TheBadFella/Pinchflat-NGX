defmodule Pinchflat.Reconciliation.PlanBuilderTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.PlanBuilder
  alias Pinchflat.Reconciliation.ReconcilePlanItem
  alias Pinchflat.Metadata.MetadataFileHelpers

  describe "build_plan_items/1 (moves and deletes)" do
    test "plans a move when the predicted media path differs" do
      media_item = downloaded_media_item()
      plan = create_plan(media_item.source_id)
      target = new_target_path()

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      move = fetch_item(plan, :move, "media")
      assert move.from_path == media_item.media_filepath
      assert move.to_path == target
      assert plan.move_count >= 1
    end

    test "emits no move when the path already matches" do
      media_item = downloaded_media_item()
      plan = create_plan(media_item.source_id)

      stub_prediction(media_item.media_filepath)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      refute find_item(plan, :move, "media")
    end

    test "plans deletion of sidecars whose profile toggle is off" do
      # The fixture's profile has download_thumbnail/download_subs off, but the
      # attachment fixture puts a thumbnail and a subtitle on disk
      media_item = downloaded_media_item()
      plan = create_plan(media_item.source_id)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      assert fetch_item(plan, :delete, "thumbnail").from_path == media_item.thumbnail_filepath
      assert [["en", subtitle_path]] = media_item.subtitle_filepaths
      assert fetch_item(plan, :delete, "subtitle:en").from_path == subtitle_path
      assert plan.delete_count == 2
    end

    test "plans sidecar moves alongside the media file when toggles are on" do
      media_item = downloaded_media_item(%{download_thumbnail: true})
      plan = create_plan(media_item.source_id)
      target = new_target_path()

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      thumbnail_move = fetch_item(plan, :move, "thumbnail")
      assert thumbnail_move.from_path == media_item.thumbnail_filepath
      assert thumbnail_move.to_path == Path.rootname(target) <> ".jpg"
    end
  end

  describe "build_plan_items/1 (backfills and skips)" do
    test "plans an NFO backfill from stored metadata in local mode" do
      media_item = downloaded_media_item(%{download_nfo: true})
      plan = create_plan(media_item.source_id)
      target = new_target_path()

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      backfill = fetch_item(plan, :backfill, "nfo")
      assert backfill.to_path == Path.rootname(target) <> ".nfo"
    end

    test "skips network-needing backfills in local mode" do
      media_item = downloaded_media_item(%{download_thumbnail: true})
      # Remove the thumbnail from disk and the record so a backfill is needed
      File.rm!(media_item.thumbnail_filepath)
      {:ok, _} = Media.update_media_item(media_item, %{thumbnail_filepath: nil})
      plan = create_plan(media_item.source_id)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      skip = fetch_item(plan, :skip, "thumbnail")
      assert skip.detail =~ "Online"
    end

    test "plans network backfills in online mode" do
      media_item = downloaded_media_item(%{download_thumbnail: true})
      File.rm!(media_item.thumbnail_filepath)
      {:ok, _} = Media.update_media_item(media_item, %{thumbnail_filepath: nil})
      plan = create_plan(media_item.source_id, :online)
      target = new_target_path()

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      backfill = fetch_item(plan, :backfill, "thumbnail")
      assert backfill.to_path == Path.rootname(target) <> ".jpg"
    end

    test "skips items without stored metadata in local mode" do
      media_item = media_item_fixture()
      plan = create_plan(media_item.source_id)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      skip = fetch_item(plan, :skip, "media")
      assert skip.detail =~ "No stored metadata"
      assert plan.skip_count == 1
    end

    test "skips items whose media file is missing on disk" do
      media_item = downloaded_media_item()
      File.rm!(media_item.media_filepath)
      plan = create_plan(media_item.source_id)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      skip = fetch_item(plan, :skip, "media")
      assert skip.detail =~ "Sync Files on Disk"
    end
  end

  describe "build_plan_items/1 (collisions)" do
    test "marks rows whose targets clash as collisions" do
      media_item = downloaded_media_item()
      _second_item = media_item_with_attachments(%{source_id: media_item.source_id}) |> add_stored_metadata()
      plan = create_plan(media_item.source_id)
      target = new_target_path()

      expect(YtDlpRunnerMock, :run, 2, fn _url, _action, _opts, _ot, _addl ->
        {:ok, ~s({"filename": "#{target}"})}
      end)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      collisions = list_items(plan, :collision, "media")
      assert length(collisions) == 2
      assert plan.collision_count >= 2
    end

    test "marks a move whose target already exists on disk as a collision" do
      media_item = downloaded_media_item()
      plan = create_plan(media_item.source_id)
      target = new_target_path()
      Pinchflat.Utils.FilesystemUtils.write_p!(target, "occupied by some other file")

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      collision = fetch_item(plan, :collision, "media")
      assert collision.to_path == target
      assert collision.detail =~ "already occupied"
      assert plan.collision_count == 1
    end

    test "marks a backfill whose target is occupied as a collision" do
      media_item = downloaded_media_item(%{download_nfo: true})
      plan = create_plan(media_item.source_id)
      target = new_target_path()
      # An unrelated file already sits where the NFO backfill would be written
      nfo_target = Path.rootname(target) <> ".nfo"
      Pinchflat.Utils.FilesystemUtils.write_p!(nfo_target, "someone else's nfo")

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      collision = fetch_item(plan, :collision, "nfo")
      assert collision.to_path == nfo_target
      refute find_item(plan, :backfill, "nfo")
    end
  end

  describe "build_plan_items/1 (:full mode)" do
    test "flags an audio-only profile whose file is still video, alongside the normal move plan" do
      media_item = downloaded_media_item(%{preferred_resolution: :audio})
      plan = create_plan(media_item.source_id, :full)
      target = new_target_path()

      stub_prediction(target)

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      row = fetch_item(plan, :redownload, "media")
      assert row.detail =~ "Audio Only"
      assert plan.redownload_count == 1
      # Full sync is "Online mode, plus" — the media still gets its normal move row
      move = fetch_item(plan, :move, "media")
      assert move.to_path == Path.rootname(target) <> Path.extname(media_item.media_filepath)
    end

    test "flags a container mismatch" do
      # The fixture file is .mp4; ask for .mkv
      media_item = downloaded_media_item(%{media_container: "mkv"})
      plan = create_plan(media_item.source_id, :full)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      row = fetch_item(plan, :redownload, "media")
      assert row.detail =~ "container"
      assert plan.redownload_count == 1
    end

    test "does not flag a file that already matches the profile" do
      # Default video profile with no container produces .mp4, and the fixture is .mp4
      media_item = downloaded_media_item()
      plan = create_plan(media_item.source_id, :full)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      refute find_item(plan, :redownload, "media")
      assert plan.redownload_count == 0
    end

    test "never flags re-downloads outside :full mode" do
      media_item = downloaded_media_item(%{preferred_resolution: :audio})
      plan = create_plan(media_item.source_id, :local)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      refute find_item(plan, :redownload, "media")
    end
  end

  describe "build_plan_items/1 (source-level artifacts)" do
    test "deletes leftover source artifacts when switching to a podcast profile" do
      profile = media_profile_fixture(%{podcast_enabled: true, preferred_resolution: :audio})
      source = source_fixture(%{media_profile_id: profile.id})

      series_dir =
        Path.join(Application.get_env(:pinchflat, :media_directory), "old-series-#{:rand.uniform(1_000_000)}")

      nfo = Path.join(series_dir, "tvshow.nfo")
      poster = Path.join(series_dir, "poster.jpg")
      fanart = Path.join(series_dir, "fanart.jpg")
      banner = Path.join(series_dir, "banner.jpg")
      Enum.each([nfo, poster, fanart, banner], &Pinchflat.Utils.FilesystemUtils.write_p!(&1, "x"))

      {:ok, _} =
        Pinchflat.Sources.update_source(
          source,
          %{
            series_directory: series_dir,
            nfo_filepath: nfo,
            poster_filepath: poster,
            fanart_filepath: fanart,
            banner_filepath: banner
          },
          run_post_commit_tasks: false
        )

      _media_item = media_item_with_attachments(%{source_id: source.id}) |> add_stored_metadata()
      plan = create_plan(source.id)

      stub_prediction(new_target_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      assert fetch_item(plan, :delete, "source_nfo").from_path == nfo
      assert fetch_item(plan, :delete, "source_poster").from_path == poster
      assert fetch_item(plan, :delete, "source_fanart").from_path == fanart
      assert fetch_item(plan, :delete, "source_banner").from_path == banner
    end

    test "schedules a source-image refresh when recorded artwork is missing on disk (online mode)" do
      {source, poster, _fanart} = source_with_partial_artwork()
      _media_item = media_item_with_attachments(%{source_id: source.id}) |> add_stored_metadata()
      plan = create_plan(source.id, :online)

      stub_prediction(series_style_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      # The refresh restores + relocates everything, so it supersedes per-image moves
      assert find_item(plan, :backfill, "source_images")
      refute find_item(plan, :move, "source_poster")
      assert File.exists?(poster)
    end

    test "in local mode, moves present artwork and skips the missing (no refresh)" do
      {source, _poster, _fanart} = source_with_partial_artwork()
      _media_item = media_item_with_attachments(%{source_id: source.id}) |> add_stored_metadata()
      plan = create_plan(source.id, :local)

      stub_prediction(series_style_path())

      assert {:ok, plan} = PlanBuilder.build_plan_items(plan)

      refute find_item(plan, :backfill, "source_images")
      assert find_item(plan, :move, "source_poster")
      assert find_item(plan, :skip, "source_fanart")
    end
  end

  # A source with a present poster and a recorded-but-missing-on-disk fanart
  defp source_with_partial_artwork do
    profile = media_profile_fixture(%{download_source_images: true})
    source = source_fixture(%{media_profile_id: profile.id})

    series_dir =
      Path.join(Application.get_env(:pinchflat, :media_directory), "art-series-#{:rand.uniform(1_000_000)}")

    poster = Path.join(series_dir, "poster.jpg")
    fanart = Path.join(series_dir, "fanart.jpg")
    Pinchflat.Utils.FilesystemUtils.write_p!(poster, "x")

    {:ok, source} =
      Pinchflat.Sources.update_source(
        source,
        %{series_directory: series_dir, poster_filepath: poster, fanart_filepath: fanart},
        run_post_commit_tasks: false
      )

    {source, poster, fanart}
  end

  # A predicted media path with a Season folder so the series directory resolves
  defp series_style_path do
    Path.join([
      Application.get_env(:pinchflat, :media_directory),
      "Chan-#{:rand.uniform(1_000_000)}",
      "Season 1",
      "video.mp4"
    ])
  end

  defp downloaded_media_item(profile_attrs \\ %{}) do
    profile = media_profile_fixture(profile_attrs)
    source = source_fixture(%{media_profile_id: profile.id})

    media_item_with_attachments(%{source_id: source.id})
    |> add_stored_metadata()
  end

  defp add_stored_metadata(media_item) do
    media_item = Repo.preload(media_item, :metadata)

    metadata_filepath =
      MetadataFileHelpers.compress_and_store_metadata_for(media_item, %{
        "id" => media_item.media_id,
        "title" => media_item.title,
        "upload_date" => "20240101"
      })

    {:ok, media_item} =
      Media.update_media_item(media_item, %{
        metadata: %{metadata_filepath: metadata_filepath, thumbnail_filepath: media_item.thumbnail_filepath}
      })

    media_item
  end

  defp create_plan(source_id, mode \\ :local) do
    {:ok, plan} = Reconciliation.create_plan(%{mode: mode, source_id: source_id, status: :building})

    plan
  end

  defp new_target_path do
    Path.join([Application.get_env(:pinchflat, :media_directory), "new-home-#{:rand.uniform(1_000_000)}", "video.mp4"])
  end

  defp stub_prediction(target) do
    stub(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl ->
      {:ok, ~s({"filename": "#{target}"})}
    end)
  end

  defp fetch_item(plan, action, attribute) do
    item = find_item(plan, action, attribute)
    assert item, "expected a #{action}/#{attribute} plan item"
    item
  end

  defp find_item(plan, action, attribute) do
    Repo.one(
      from(rpi in ReconcilePlanItem,
        where: rpi.reconcile_plan_id == ^plan.id and rpi.action == ^action and rpi.attribute == ^attribute,
        limit: 1
      )
    )
  end

  defp list_items(plan, action, attribute) do
    Repo.all(
      from(rpi in ReconcilePlanItem,
        where: rpi.reconcile_plan_id == ^plan.id and rpi.action == ^action and rpi.attribute == ^attribute
      )
    )
  end
end
