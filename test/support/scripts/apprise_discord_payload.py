"""Exercise the installed Apprise plugins without contacting notification endpoints."""
import json
from unittest.mock import patch

import apprise
import requests


calls = []


def capture_request(session, method, url, **kwargs):
    calls.append((method, url, kwargs))
    response = requests.Response()
    response.status_code = 204
    response.url = url
    return response


with patch.object(requests.Session, "request", capture_request):
    discord = apprise.Apprise()
    assert discord.add("discord://123/abc?format=markdown")
    assert discord.notify(title="New media found", body="Found 1 new media item(s)\n\n- Example")

    ordinary = apprise.Apprise()
    assert ordinary.add("json://receiver.invalid")
    assert ordinary.notify(title="Plain title", body="*unmatched _underscore")

posts = [(url, kwargs) for method, url, kwargs in calls if method.upper() == "POST"]
assert len(posts) == 2, [(method, url) for method, url, _ in calls]


def payload(kwargs):
    data = kwargs.get("data") or kwargs.get("json")
    return json.loads(data) if isinstance(data, (str, bytes)) else data


discord_post = next((url, kwargs) for url, kwargs in posts if "discord.com/api/webhooks/" in url)
discord_payload = payload(discord_post[1])
assert discord_post[0].startswith("https://discord.com/api/webhooks/123/abc"), discord_post[0]
assert discord_payload["embeds"], discord_payload
assert "Found 1 new media item(s)" in discord_payload["embeds"][0]["description"], discord_payload

ordinary_payload = payload(next(kwargs for url, kwargs in posts if "receiver.invalid" in url))
assert "*unmatched _underscore" in json.dumps(ordinary_payload), ordinary_payload
assert "embeds" not in ordinary_payload, ordinary_payload
print("Installed Apprise produced a Discord embed and an independent plain-text JSON notification")
