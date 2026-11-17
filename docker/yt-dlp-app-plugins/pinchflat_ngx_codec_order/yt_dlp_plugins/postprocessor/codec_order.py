"""Pinchflat-ngx ordered codec preferences, applied before final selection."""

import re

from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.utils import ExtractorError, FormatSorter

MAX_ITEMS = 8
MAX_BYTES = 256

_FIELD = {"video": "vcodec", "audio": "acodec"}

INCOMPATIBLE_MESSAGE = (
    "the installed yt-dlp format sorter has no resolution stage, so an ordered codec "
    "preference cannot be applied. Pinchflat-ngx did not silently ignore your preference.")

CONTRACT_MESSAGE = (
    "the installed yt-dlp format sorter changed its preference contract, so the ordered "
    "codec preference cannot be applied safely. Pinchflat-ngx did not silently ignore your "
    "preference.")

PROBE_FORMAT = {
    "format_id": "probe",
    "ext": "mp4",
    "vcodec": "avc1",
    "acodec": "mp4a",
    "height": 1080,
    "width": 1920,
    "tbr": 1,
    "url": "https://fixture.invalid/probe",
}


class CodecOrderPP(PostProcessor):
    def __init__(self, downloader=None, video="", audio=""):
        super().__init__(downloader)
        self._raw_video = video or ""
        self._raw_audio = audio or ""
        # Params are validated lazily in run() so yt-dlp can report a normal,
        # readable error instead of an unhandled constructor traceback.
        self._video = ()
        self._audio = ()
        self._validated = False

    def _validate(self):
        if self._validated:
            return
        self._video = self._parse("video", self._raw_video)
        self._audio = self._parse("audio", self._raw_audio)
        self._validated = True

    @staticmethod
    def _pattern(kind, token):
        for pattern in FormatSorter.settings[_FIELD[kind]]["order"]:
            if pattern and re.match(pattern, token):
                return pattern
        return None

    @classmethod
    def _parse(cls, kind, raw):
        text = (raw or "").strip()
        if not text:
            return ()
        if len(text) > MAX_BYTES:
            raise ExtractorError(f"{kind} codec preference list exceeds {MAX_BYTES} bytes", expected=True)
        items = []
        families = []
        for part in text.split(","):
            token = part.strip().lower()
            if not token:
                continue
            if not re.fullmatch(r"[a-z0-9._-]+", token):
                raise ExtractorError(f"unsupported {kind} codec {part!r}; use a plain codec name", expected=True)
            # Reject an unrecognized name explicitly. Without this, an unknown token would
            # silently rank nothing, and several unknown tokens would collapse to the same
            # "None family" and report a misleading duplicate error.
            family = cls._pattern(kind, token)
            if family is None:
                raise ExtractorError(
                    f"unsupported {kind} codec {token!r}; use a recognized codec name", expected=True)
            items.append(token)
            families.append(family)
        if len(items) > MAX_ITEMS:
            raise ExtractorError(f"{kind} list has {len(items)} entries; at most {MAX_ITEMS} supported", expected=True)
        if len(set(families)) != len(families):
            raise ExtractorError(f"{kind} list contains duplicate equivalent codecs", expected=True)
        return tuple(items)

    def _rank(self, kind, configured, codec):
        if not configured:
            return 0
        if codec is None:
            return -len(configured)
        value = str(codec).lower()
        for position, token in enumerate(configured):
            pattern = self._pattern(kind, token)
            if pattern and re.match(pattern, value):
                return -position
        return -len(configured)

    def _sorter(self, info):
        # Match the native invocation exactly: YoutubeDL.sort_formats passes the
        # extractor-provided hints as field_preference, and FormatSorter already reads
        # downloader.params["format_sort"] itself. Passing user params here would both
        # duplicate the user sort and discard extractor tie-breaks.
        extractor_fields = info.get("_format_sort_fields") or []
        sorter = FormatSorter(self._downloader, extractor_fields)
        order = getattr(sorter, "_order", None)
        if not isinstance(order, list) or "res" not in order:
            raise ExtractorError(INCOMPATIBLE_MESSAGE, expected=True)
        probe = sorter.calculate_preference(PROBE_FORMAT)
        if not isinstance(probe, tuple) or len(probe) != len(order):
            raise ExtractorError(CONTRACT_MESSAGE, expected=True)
        return sorter, order.index("res") + 1

    def run(self, info):
        self._validate()
        if not self._video and not self._audio:
            return [], info
        formats = info.get("formats")
        if not isinstance(formats, list) or len(formats) < 2:
            return [], info
        sorter, prefix = self._sorter(info)

        def key(fmt):
            base = sorter.calculate_preference(fmt)
            return (*base[:prefix],
                    self._rank("video", self._video, fmt.get("vcodec")),
                    self._rank("audio", self._audio, fmt.get("acodec")),
                    *base[prefix:])

        info["formats"] = sorted(formats, key=key)
        return [], info
