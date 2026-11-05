"""Run the application's indexing options against an offline yt-dlp playlist."""

import datetime
import json
import sys

sys.path.insert(0, "/usr/local/bin/yt-dlp")

from yt_dlp import YoutubeDL, parse_options
from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import RejectedVideoReached

visited = []


class CutoffFixtureIE(InfoExtractor):
    _VALID_URL = r"cutoff-fixture:channel"

    def _real_extract(self, url):
        def entries():
            today = datetime.date.today()
            for video_id, days in [("undated", None), ("recent", 0), ("old", 40), ("unvisited", 50)]:
                visited.append(video_id)
                info = {
                    "id": video_id,
                    "title": video_id,
                    "url": f"https://example.invalid/{video_id}.mp4",
                    "original_url": f"https://example.invalid/watch?v={video_id}",
                    "timestamp": int(datetime.datetime.now(datetime.timezone.utc).timestamp()),
                    "ext": "mp4",
                    "live_status": "not_live",
                }
                if days is not None:
                    info["upload_date"] = (today - datetime.timedelta(days=days)).strftime("%Y%m%d")
                yield info

        return self.playlist_result(entries(), "fixture")


options = parse_options(["--ignore-config", "--quiet", *sys.argv[1:]]).ydl_opts
with YoutubeDL(options, auto_init=False) as downloader:
    downloader.add_info_extractor(CutoffFixtureIE())
    try:
        status = downloader.download(["cutoff-fixture:channel"])
    except RejectedVideoReached:
        status = 101

print(json.dumps({"visited": visited, "status": status}))
