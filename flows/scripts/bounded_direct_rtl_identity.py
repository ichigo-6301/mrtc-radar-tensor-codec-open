#!/usr/bin/env python3
"""Generate or verify the bounded Direct-AXIS RTL source identity table."""

from __future__ import print_function

import argparse
import csv
import hashlib
import subprocess
import sys
from pathlib import Path


DEFAULT_MANIFEST = "flows/manifests/rdtc_v1_bounded_direct.f"
DEFAULT_OUTPUT = "evidence/data/rdtc_v1_bounded_direct_rtl_identity.csv"
DEFAULT_SOURCE_REF = "7fa7f554246f34cc474a123cfed68d070688412d"
FIELDS = (
    "path",
    "source_ref",
    "source_sha256",
    "published_sha256",
    "relationship",
)


def sha256_bytes(content):
    return hashlib.sha256(content).hexdigest()


def rtl_paths(root, manifest):
    paths = []
    for raw in (root / manifest).read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("+incdir+"):
            continue
        if not line.endswith((".sv", ".v")):
            continue
        path = line.replace("\\", "/")
        if not path.startswith("rtl/"):
            raise RuntimeError("non-RTL source in Direct manifest: {}".format(path))
        if path in paths:
            raise RuntimeError("duplicate Direct RTL source: {}".format(path))
        if not (root / path).is_file():
            raise RuntimeError("missing published Direct RTL source: {}".format(path))
        paths.append(path)
    if not paths:
        raise RuntimeError("Direct manifest contains no RTL sources")
    return sorted(paths, key=lambda item: item.encode("utf-8"))


def git_blob(repo, ref, path):
    process = subprocess.run(
        ["git", "-C", str(repo), "show", "{}:{}".format(ref, path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError("cannot read fixed source {}:{}: {}".format(ref, path, detail))
    return process.stdout


def generate_rows(root, source_repo, source_ref, manifest):
    rows = []
    for path in rtl_paths(root, manifest):
        source_hash = sha256_bytes(git_blob(source_repo, source_ref, path))
        published_hash = sha256_bytes((root / path).read_bytes())
        relationship = "identical" if source_hash == published_hash else "changed"
        if relationship != "identical":
            raise RuntimeError("published RTL differs from fixed evidence source: {}".format(path))
        rows.append(
            {
                "path": path,
                "source_ref": source_ref,
                "source_sha256": source_hash,
                "published_sha256": published_hash,
                "relationship": relationship,
            }
        )
    return rows


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def read_rows(path):
    if not path.is_file():
        raise RuntimeError("missing Direct RTL identity table: {}".format(path))
    with path.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise RuntimeError("unexpected Direct RTL identity columns")
        rows = list(reader)
    return rows


def check_rows(root, source_ref, manifest, output):
    expected_paths = rtl_paths(root, manifest)
    rows = read_rows(root / output)
    actual_paths = [row.get("path", "") for row in rows]
    if actual_paths != expected_paths:
        raise RuntimeError("Direct RTL identity path set/order is stale")
    for row in rows:
        path = row["path"]
        if row["source_ref"] != source_ref:
            raise RuntimeError("fixed source ref mismatch for {}".format(path))
        if row["relationship"] != "identical":
            raise RuntimeError("non-identical source relationship for {}".format(path))
        if row["source_sha256"] != row["published_sha256"]:
            raise RuntimeError("source/published identity mismatch for {}".format(path))
        actual = sha256_bytes((root / path).read_bytes())
        if actual != row["published_sha256"]:
            raise RuntimeError("published Direct RTL changed after evidence freeze: {}".format(path))
    return len(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2])
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--source-ref", default=DEFAULT_SOURCE_REF)
    parser.add_argument("--source-repo")
    parser.add_argument("--generate", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    try:
        if args.generate:
            if args.check:
                raise RuntimeError("--generate and --check are mutually exclusive")
            if not args.source_repo:
                raise RuntimeError("--source-repo is required with --generate")
            rows = generate_rows(
                root,
                Path(args.source_repo).resolve(),
                args.source_ref,
                args.manifest,
            )
            write_rows(root / args.output, rows)
            print("Direct RTL identity: WROTE files={} source_ref={}".format(len(rows), args.source_ref))
        else:
            count = check_rows(root, args.source_ref, args.manifest, args.output)
            print("Direct RTL identity: PASS files={} source_ref={}".format(count, args.source_ref))
    except RuntimeError as error:
        print("Direct RTL identity: FAIL: {}".format(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
