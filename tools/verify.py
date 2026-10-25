#!/usr/bin/env python3
"""Verify the public teaching package without third-party Python dependencies."""
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    manifest = json.loads((ROOT / "assets/manifest.json").read_text())
    indexed = set()
    for item in manifest:
        asset = ROOT / item["asset"]
        assert hashlib.sha256(asset.read_bytes()).hexdigest() == item["sha256"], asset
        record = json.loads((ROOT / item["provenance"]).read_text())
        assert record["asset"] == item["asset"] and record["asset_sha256"] == item["sha256"], asset
        assert (ROOT / item["prompt"]).is_file() and record["prompt"] == item["prompt"], asset
        for reference in record["style_reference"]:
            assert (ROOT / reference).is_file(), reference
        indexed.add(asset)
    assert indexed == set((ROOT / "assets").rglob("*.png")), "Unindexed or missing asset"
    raw = ROOT / "examples/meadow_02/raw.png"
    provenance = json.loads((ROOT / "prompts/overworld/meadow_02.json").read_text())
    assert hashlib.sha256(raw.read_bytes()).hexdigest() == provenance["raw_sha256"], "Raw example hash"
    # git ls-files avoids inspecting generated experiments or Git's local configuration.
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=False
    )
    files = [ROOT / path for path in listing.stdout.decode().split("\0") if path]
    assert files, "Stage the intended public files with git add before verifying"
    private_path = re.compile(r"/(?:Users|home)/[^\s/]+|[A-Z]:\\Users\\", re.I)
    key_patterns = re.compile(
        r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
        r"sk-(?:proj-)?[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"
    )
    for path in files:
        assert not path.is_symlink(), f"Symlink in public export: {path}"
        assert not (path.name == ".env" or path.name.startswith(".env.")), path
        data = path.read_bytes()
        if path.suffix == ".png":
            assert data.startswith(b"\x89PNG\r\n\x1a\n"), path
            offset = 8
            while offset < len(data):
                size = struct.unpack_from(">I", data, offset)[0]
                kind = data[offset + 4 : offset + 8]
                assert kind not in {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}, f"PNG metadata: {path}"
                offset += size + 12
        elif b"\0" not in data:
            text = data.decode("utf8")
            assert not private_path.search(text), f"Private absolute path: {path}"
            assert not key_patterns.search(text), f"Credential pattern: {path}"
            if path.suffix == ".md":
                links = re.findall(r"\]\(([^)]+)\)", text) + re.findall(r'src="([^"]+)"', text)
                for target in links:
                    if target.startswith(("http:", "https:", "#", "mailto:")):
                        continue
                    dest = target.split("#", 1)[0]
                    assert (path.parent / dest).is_file(), f"Broken link in {path}: {target}"
    print(f"PASS: {len(manifest)} assets, provenance, raw example, PNG metadata, links, and text privacy patterns")


if __name__ == "__main__":
    main()
