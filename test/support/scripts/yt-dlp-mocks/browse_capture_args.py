#!/usr/bin/env python3
import json
import os
import sys

capture = os.environ.get("BROWSE_ARGS_FILE")
if capture:
    with open(capture, "w", encoding="utf-8") as handle:
        handle.write("\n".join(sys.argv))

print(json.dumps({"entries": []}))