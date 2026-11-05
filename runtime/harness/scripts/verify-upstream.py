#!/usr/bin/env python3
"""Verify copied runtime source against the GitHub blob IDs pinned in SOURCE.json."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1] / 'upstream'
source = json.loads((root / 'SOURCE.json').read_text())
for entry in source['files']:
    data = (root / entry['path']).read_bytes()
    blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    if blob != entry['gitBlob'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise SystemExit('Upstream source differs from pinned commit: ' + entry['path'])
print(f"PASS: {len(source['files'])} upstream files pinned to {source['commit']}")
