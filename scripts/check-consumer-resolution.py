#!/usr/bin/env python3
"""Check the version and optional immutable revision SwiftPM actually resolved."""

import json
import sys
from pathlib import Path
from urllib.parse import urlsplit


def repository_identity(location):
    if not isinstance(location, str):
        return None
    url = urlsplit(location)
    if url.scheme != "https" or url.username or url.password or url.query or url.fragment:
        return None
    return url.netloc.lower(), url.path.rstrip("/").removesuffix(".git").casefold()


resolved, version, revision, repository = sys.argv[1:]
pins = json.loads(Path(resolved).read_text())["pins"]
matches = [pin for pin in pins if pin["identity"].lower() == "innorouter"]
if len(matches) != 1:
    raise SystemExit("[consumer-resolution] Expected exactly one InnoRouter pin")
expected_repository = repository_identity(repository)
if expected_repository is None or repository_identity(matches[0].get("location")) != expected_repository:
    raise SystemExit("[consumer-resolution] InnoRouter pin does not match the expected repository")
state = matches[0]["state"]
if state.get("version") != version or not state.get("revision"):
    raise SystemExit(f"[consumer-resolution] Wrong version or missing revision: {state}")
if revision and state["revision"] != revision:
    raise SystemExit(f"[consumer-resolution] Revision {state['revision']} does not match {revision}")
print(f"[consumer-resolution] Exact InnoRouter {version} at {state['revision']}")
