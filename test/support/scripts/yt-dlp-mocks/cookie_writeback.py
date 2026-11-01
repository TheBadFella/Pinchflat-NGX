#!/usr/bin/env python3
"""Model yt-dlp saving server-side cookie deletions without contacting YouTube."""

import json
from pathlib import Path
import stat
import sys
from urllib.parse import parse_qs, urlsplit

args = sys.argv[1:]
if "--cookies" not in args:
    print("Sign in to confirm your age")
    sys.exit(1)

cookie_path = Path(args[args.index("--cookies") + 1])
result = {
    "id": parse_qs(urlsplit(args[0]).query)["v"][0],
    "availability": "needs_auth",
    "cookie_path": str(cookie_path),
    "cookie_contents": cookie_path.read_text(),
    "cookie_mode": stat.S_IMODE(cookie_path.stat().st_mode),
}
cookie_path.write_text("# Authentication cookies removed by the server\n")
output = json.dumps(result)
Path(args[args.index("--print-to-file") + 2]).write_text(output)
print(output)
sys.exit(1 if "cookie_failure" in args[0] else 0)
