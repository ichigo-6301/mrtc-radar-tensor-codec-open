#!/usr/bin/env python3
"""Verify RDTC release identity, canonical Git checksums, and public schemas."""

from __future__ import print_function

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "flows/scripts"))
from generate_checksums import CHECKSUM_PATH, tracked_entries
from scan_public_release import scan
from validate_profile import validate_repository


LINE_PATTERN = re.compile(r"^([0-7]{6}) ([0-9a-f]{64})  (.+)$")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root)] + list(args), text=True).strip()


def load_manifest(path):
    with path.open("r", encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def parse_checksum_manifest(path):
    rows = []
    seen = set()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = LINE_PATTERN.match(line)
        if not match:
            raise RuntimeError("invalid checksum row {}: {}".format(number, line))
        mode, digest, item_path = match.groups()
        if item_path in seen:
            raise RuntimeError("duplicate checksum path: {}".format(item_path))
        seen.add(item_path)
        rows.append((item_path, mode, digest))
    sorted_rows = sorted(rows, key=lambda item: item[0].encode("utf-8"))
    if rows != sorted_rows:
        raise RuntimeError("checksum manifest is not bytewise path-sorted")
    return rows


def verify_checksum_manifest(root, ref, manifest_path=None):
    path = manifest_path or root / CHECKSUM_PATH
    actual = parse_checksum_manifest(path)
    expected = tracked_entries(root, ref)
    if actual != expected:
        actual_by_path = {item[0]: item[1:] for item in actual}
        expected_by_path = {item[0]: item[1:] for item in expected}
        missing = sorted(set(expected_by_path) - set(actual_by_path))
        extra = sorted(set(actual_by_path) - set(expected_by_path))
        changed = sorted(
            item for item in set(actual_by_path) & set(expected_by_path)
            if actual_by_path[item] != expected_by_path[item]
        )
        raise RuntimeError(
            "checksum mismatch: missing={} extra={} changed={}".format(
                missing[:5], extra[:5], changed[:5]
            )
        )
    return len(actual)


def verify_release_identity(root, ref, allow_untagged=False):
    release = load_manifest(root / "provenance/release.yaml")
    required = {
        "repository_name", "profile", "release_version", "release_tag",
        "rtl_source_commit", "private_delivery_commit",
        "public_release_base_commit", "supersedes", "functional_change",
        "evidence_change", "packaging_change", "license", "bundle_type",
    }
    missing = sorted(required - set(release))
    if missing:
        raise RuntimeError("release manifest missing fields: {}".format(", ".join(missing)))
    if release.get("schema_version") != "1.1.0":
        raise RuntimeError("release schema_version must be 1.1.0")
    if release["rtl_source_commit"] != "41b33f7057c341cc4b952f51b00eb886f42c5fe2":
        raise RuntimeError("unexpected RTL source commit")
    if release["private_delivery_commit"] != "273e41e99ad90c04de68ca0c420d4f8260b181ca":
        raise RuntimeError("unexpected private delivery commit")
    ref_commit = git(root, "rev-parse", "{}^{{commit}}".format(ref))
    base_commit = git(root, "rev-parse", "{}^{{commit}}".format(release["public_release_base_commit"]))
    if subprocess.call(["git", "-C", str(root), "merge-base", "--is-ancestor", base_commit, ref_commit]) != 0:
        raise RuntimeError("public release base is not an ancestor of the tested commit")
    tag = release["release_tag"]
    try:
        tag_commit = git(root, "rev-list", "-n", "1", tag)
    except subprocess.CalledProcessError:
        if allow_untagged:
            return release, ref_commit, "not-found"
        raise RuntimeError("release tag does not exist: {}".format(tag))
    if tag_commit != ref_commit:
        raise RuntimeError("release tag mismatch: tag={} ref={}".format(tag_commit, ref_commit))
    if ref == "HEAD" and git(root, "rev-parse", "HEAD") != tag_commit:
        raise RuntimeError("working HEAD does not equal the release tag target")
    return release, ref_commit, tag_commit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[1])
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--allow-untagged", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    try:
        release, commit, tag_commit = verify_release_identity(root, args.ref, args.allow_untagged)
        count = verify_checksum_manifest(root, args.ref)
        summary = validate_repository(root)
        findings = scan(root, args.ref)
        if findings:
            raise RuntimeError("public leakage findings: {}".format("; ".join(findings[:10])))
        if args.ref == "HEAD" and git(root, "status", "--porcelain", "--untracked-files=no"):
            raise RuntimeError("tracked working tree is not clean")
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("release verification: FAIL: {}".format(error), file=sys.stderr)
        return 2
    print(
        "release verification: PASS version={} tag={} commit={} checksums={} profiles={} claims={} evidence={}".format(
            release["release_version"], release["release_tag"], commit, count,
            summary["profiles"], summary["claims"], summary["evidence"],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

