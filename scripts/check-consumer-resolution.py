#!/usr/bin/env python3
"""Check the version and optional immutable revision SwiftPM actually resolved."""

import json
import sys
from pathlib import Path

resolved, version, revision = sys.argv[1:]
pins = json.loads(Path(resolved).read_text())["pins"]
matches = [pin for pin in pins if pin["identity"].lower() == "innorouter"]
if len(matches) != 1:
    raise SystemExit("[consumer-resolution] Expected exactly one InnoRouter pin")
state = matches[0]["state"]
if state.get("version") != version or not state.get("revision"):
    raise SystemExit(f"[consumer-resolution] Wrong version or missing revision: {state}")
if revision and state["revision"] != revision:
    raise SystemExit(f"[consumer-resolution] Revision {state['revision']} does not match {revision}")
print(f"[consumer-resolution] Exact InnoRouter {version} at {state['revision']}")
