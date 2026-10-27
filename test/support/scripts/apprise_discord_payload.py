"""Exercise application-generated argv through the installed Apprise CLI without network I/O."""
import contextlib
import io
import json
import sys
from unittest.mock import patch

from apprise.cli import main
import requests


cases = json.loads(sys.argv[1])
body = "*unmatched _underscore"


def capture_request(session, method, url, **kwargs):
    calls.append((method, url, kwargs))
    response = requests.Response()
    response.status_code = 204
    response.url = url
    return response


def payload(kwargs):
    data = kwargs.get("data") or kwargs.get("json")
    return json.loads(data) if isinstance(data, (str, bytes)) else data


for name, argv in cases.items():
    calls = []
    with patch.object(requests.Session, "request", capture_request):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            main(args=argv, standalone_mode=False)

    assert len(calls) == 1, (name, [(method, url) for method, url, _ in calls])
    method, url, kwargs = calls[0]
    assert method.upper() == "POST", (name, method)
    data = payload(kwargs)
    assert data is not None, name

    if name == "plain":
        assert "receiver.invalid" in url, (name, url)
        assert body in json.dumps(data), (name, data)
        assert "embeds" not in data, (name, data)
    else:
        assert url.startswith("https://discord.com/api/webhooks/123/abc"), (name, url)
        if name == "explicit_text":
            assert "embeds" not in data, (name, data)
            assert body in data["content"], (name, data)
        else:
            assert data["embeds"][0]["description"] == r"\*unmatched \_underscore", (name, data)
            assert data["embeds"][0]["title"] == "New media found", (name, data)

print("Installed Apprise CLI produced Discord embeds and plain text")
