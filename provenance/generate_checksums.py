#!/usr/bin/env python3
"""Generate deterministic SHA256 records from Git object contents."""

from __future__ import print_function

import argparse
import hashlib
import subprocess
from pathlib import Path


CHECKSUM_PATH = "provenance/checksums.sha256"
EXCLUDED_PREFIXES = (".git/", "build/", "work/", "obj_dir/")


def git(root, *args, **kwargs):
    command = ["git", "-C", str(root)] + list(args)
    return subprocess.check_output(command, **kwargs)


def tracked_entries(root, ref):
    output = git(root, "ls-tree", "-r", "-z", "--full-tree", ref)
    objects = []
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        if object_type != "blob":
            raise RuntimeError("unsupported Git object type {} at {}".format(object_type, path))
        if path == CHECKSUM_PATH or path.startswith(EXCLUDED_PREFIXES):
            continue
        objects.append((path, mode, object_id))
    process = subprocess.Popen(
        ["git", "-C", str(root), "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    request = "".join(object_id + "\n" for _, _, object_id in objects).encode("ascii")
    output, _ = process.communicate(request)
    if process.returncode:
        raise RuntimeError("git cat-file --batch failed")
    offset = 0
    entries = []
    for path, mode, object_id in objects:
        end = output.index(b"\n", offset)
        header = output[offset:end].decode("ascii").split()
        if len(header) != 3 or header[0] != object_id or header[1] != "blob":
            raise RuntimeError("unexpected git cat-file response for {}".format(path))
        size = int(header[2])
        start = end + 1
        content = output[start:start + size]
        offset = start + size + 1
        entries.append((path, mode, hashlib.sha256(content).hexdigest()))
    return sorted(entries, key=lambda item: item[0].encode("utf-8"))


def render(entries):
    return "".join("{} {}  {}\n".format(mode, digest, path) for path, mode, digest in entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[1])
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--output", default=CHECKSUM_PATH)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    output = root / args.output
    text = render(tracked_entries(root, args.ref))
    if args.check:
        actual = output.read_text(encoding="utf-8") if output.is_file() else ""
        if actual != text:
            raise SystemExit("canonical checksum manifest is stale")
        print("canonical checksums: PASS ref={}".format(args.ref))
        return 0
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8", newline="\n")
    print("wrote {} entries to {}".format(len(text.splitlines()), output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
