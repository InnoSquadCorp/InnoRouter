#!/usr/bin/env python3
"""Check the visionOS-only wrapper contract missing from host symbol graphs."""
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
if re.search(r"RouterImmersive(?:Activation|AppearanceObserver)", source):
    raise SystemExit("Immersive transport or debug observer leaked into the public interface")

# Qualifying module names and actor spelling vary with the Swift toolchain.
text = re.sub(r"(?:[A-Za-z_]\w*(?:\.|::))+", "", source)
match = re.search(r"public struct RouterImmersiveSpaceScene<R>\s*:\s*Scene\s+where\s+R\s*:\s*DestinationRoute,\s*R\s*:\s*RouterSceneRoute\s*\{", text)
if match is None:
    raise SystemExit("Missing the canonical immersive Scene wrapper and route constraints")
start = match.end()
depth = 1
end = start
while depth and end < len(text):
    depth += (text[end] == "{") - (text[end] == "}")
    end += 1
if depth:
    raise SystemExit("Incomplete immersive Scene public interface")
body = " ".join(text[start:end - 1].split())
initializers = re.findall(r"public init\(([^)]*)\)", body)
expected = (
    "id: String, store: RouterStore<R>, rendering: RouterHostViewDescriptor<R>? = nil, "
    "presentations: RouterPresentationViewCatalog<R> = .stack"
)
if initializers != [expected]:
    raise SystemExit(f"Immersive Scene initializer drift: {initializers}")
if not re.search(r"public var body: some Scene\s*\{\s*get\s*\}", body):
    raise SystemExit("Missing the immersive Scene body contract")
members = re.findall(r"public (?:static )?(?:var|let|func|typealias)\s+(\w+)", body)
if members.count("body") != 1 or any(name not in {"body", "Body"} for name in members):
    raise SystemExit(f"Unexpected immersive Scene public members: {members}")
print("[platform-interface] visionOS immersive Scene initializer, body, and opaque transport passed")
