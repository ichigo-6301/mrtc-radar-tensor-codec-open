#!/usr/bin/env python3
"""Fail-closed scan of tracked public Git objects for private/local leakage."""

from __future__ import print_function

import argparse
import re
import subprocess
import sys
from pathlib import Path


FORBIDDEN_EXTENSIONS = {
    ".bit", ".db", ".dcp", ".dlib", ".gds", ".lef", ".lib", ".ndm",
    ".oas", ".spef",
}
FORBIDDEN_PATH_PARTS = {"build", "work", "obj_dir", "reports", "raw_reports", "flows/local"}
CONTENT_PATTERNS = {
    "windows_absolute_path": re.compile(r"(?<![A-Za-z0-9_])[A-Za-z]:\\[^\\\r\n]+\\"),
    "unix_home_path": re.compile(r"/(?:home|mnt)/[^\s`'\"]+"),
    "synopsys_install_path": re.compile(r"/opt/synopsys/[^\s`'\"]*"),
    "license_variable": re.compile(r"\b(?:LM_LICENSE_FILE|SNPSLMD_LICENSE_FILE)\b"),
    "private_repository": re.compile(r"(?:github\.com[/:]ichigo-6301/mrtc-radar-tensor-codec(?:\.git)?)(?!-open)"),
}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root)] + list(args))


def tracked_blobs(root, ref):
    output = git(root, "ls-tree", "-r", "-z", "--full-tree", ref)
    objects = []
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        _, object_type, object_id = metadata.decode("ascii").split()
        if object_type == "blob":
            objects.append((raw_path.decode("utf-8"), object_id))
    process = subprocess.Popen(
        ["git", "-C", str(root), "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    request = "".join(object_id + "\n" for _, object_id in objects).encode("ascii")
    output, _ = process.communicate(request)
    if process.returncode:
        raise RuntimeError("git cat-file --batch failed")
    offset = 0
    for path, object_id in objects:
        end = output.index(b"\n", offset)
        header = output[offset:end].decode("ascii").split()
        if len(header) != 3 or header[0] != object_id or header[1] != "blob":
            raise RuntimeError("unexpected git cat-file response for {}".format(path))
        size = int(header[2])
        start = end + 1
        content = output[start:start + size]
        offset = start + size + 1
        yield path, content


def line_is_documented_placeholder(line):
    return "REPLACE_WITH_LOCAL_" in line or "/path/to/" in line


def scan(root, ref):
    findings = []
    for path, content in tracked_blobs(root, ref):
        lower = path.lower()
        suffix = Path(lower).suffix
        parts = lower.split("/")
        if suffix in FORBIDDEN_EXTENSIONS:
            findings.append("forbidden extension: {}".format(path))
        if any(part in FORBIDDEN_PATH_PARTS for part in parts) or lower.startswith("flows/local/"):
            findings.append("forbidden generated/local path: {}".format(path))
        if b"\0" in content:
            continue
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if line_is_documented_placeholder(line):
                continue
            if "re.compile(" in line:
                continue
            for name, pattern in CONTENT_PATTERNS.items():
                if pattern.search(line):
                    findings.append("{}:{}: {}".format(path, number, name))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2])
    parser.add_argument("--ref", default="HEAD")
    args = parser.parse_args()
    findings = scan(Path(args.root).resolve(), args.ref)
    if findings:
        print("public leakage scan: FAIL", file=sys.stderr)
        for finding in findings:
            print("  " + finding, file=sys.stderr)
        return 2
    print("public leakage scan: PASS ref={}".format(args.ref))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
