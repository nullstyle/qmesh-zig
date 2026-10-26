#!/usr/bin/env python3
"""Canonical byte identity for an observed source package, without Zig fetch."""
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
names = sorted((p.relative_to(root).as_posix() for p in root.rglob("*")
                if p.is_file() and not {".git", ".zig-cache", ".zig-global-cache", "__pycache__"}.intersection(p.relative_to(root).parts)),
               key=os.fsencode)
digest = hashlib.sha256()
for name in names:
    encoded = os.fsencode(name)
    data = (root / name).read_bytes()
    digest.update(len(encoded).to_bytes(8, "big"))
    digest.update(encoded)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)
print(json.dumps({"path": str(root), "tree_sha256": digest.hexdigest(), "file_count": len(names)}))
