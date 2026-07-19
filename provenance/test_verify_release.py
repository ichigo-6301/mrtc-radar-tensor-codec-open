#!/usr/bin/env python3
"""Tests for canonical Git-object release verification."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_checksums import render, tracked_entries
from verify_release import verify_checksum_manifest, verify_release_identity


class ReleaseVerifierTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "release-test@example.com"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Release Test"], cwd=self.root, check=True)
        (self.root / "a.txt").write_bytes(b"alpha\n")
        (self.root / "b.sh").write_bytes(b"#!/bin/sh\necho test\n")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "update-index", "--chmod=+x", "b.sh"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=self.root, check=True)
        self.base = self.git("rev-parse", "HEAD")
        (self.root / "provenance").mkdir()
        self.manifest = self.root / "provenance/checksums.sha256"
        self.manifest.write_text(render(tracked_entries(self.root, "HEAD")), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root)] + list(args), text=True).strip()

    def lines(self):
        return self.manifest.read_text(encoding="utf-8").splitlines()

    def write_lines(self, lines):
        self.manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_valid_manifest_passes(self):
        self.assertEqual(verify_checksum_manifest(self.root, "HEAD", self.manifest), 2)

    def test_missing_tracked_file_fails(self):
        self.write_lines(self.lines()[1:])
        with self.assertRaisesRegex(RuntimeError, "missing"):
            verify_checksum_manifest(self.root, "HEAD", self.manifest)

    def test_extra_manifest_row_fails(self):
        self.write_lines(self.lines() + ["100644 " + "0" * 64 + "  z.txt"])
        with self.assertRaisesRegex(RuntimeError, "extra"):
            verify_checksum_manifest(self.root, "HEAD", self.manifest)

    def test_content_hash_mismatch_fails(self):
        lines = self.lines()
        lines[0] = lines[0][:7] + "0" * 64 + lines[0][71:]
        self.write_lines(lines)
        with self.assertRaisesRegex(RuntimeError, "changed"):
            verify_checksum_manifest(self.root, "HEAD", self.manifest)

    def test_mode_mismatch_fails(self):
        lines = self.lines()
        lines[1] = "100644" + lines[1][6:]
        self.write_lines(lines)
        with self.assertRaisesRegex(RuntimeError, "changed"):
            verify_checksum_manifest(self.root, "HEAD", self.manifest)

    def test_duplicate_path_fails(self):
        lines = self.lines()
        self.write_lines([lines[0], lines[0], lines[1]])
        with self.assertRaisesRegex(RuntimeError, "duplicate"):
            verify_checksum_manifest(self.root, "HEAD", self.manifest)

    def test_unsorted_manifest_fails(self):
        self.write_lines(list(reversed(self.lines())))
        with self.assertRaisesRegex(RuntimeError, "not bytewise"):
            verify_checksum_manifest(self.root, "HEAD", self.manifest)

    def test_release_tag_mismatch_fails(self):
        (self.root / "provenance/release.yaml").write_text(
            "\n".join([
                "schema_version: 1.1.0",
                "repository_name: mrtc-radar-tensor-codec-open",
                "profile: rdtc_v1_public_release",
                "release_version: register550-rc2",
                "release_tag: rdtc-v1-register550-rc2",
                "rtl_source_commit: 41b33f7057c341cc4b952f51b00eb886f42c5fe2",
                "private_delivery_commit: 273e41e99ad90c04de68ca0c420d4f8260b181ca",
                "public_release_base_commit: " + self.base,
                "supersedes: register550-rc1",
                "functional_change: false",
                "evidence_change: false",
                "packaging_change: true",
                "license: MIT",
                "bundle_type: public-ip",
                "",
            ]), encoding="utf-8"
        )
        subprocess.run(["git", "add", "provenance/release.yaml"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "release manifest"], cwd=self.root, check=True)
        subprocess.run(["git", "tag", "-a", "rdtc-v1-register550-rc2", "-m", "test"], cwd=self.root, check=True)
        (self.root / "later.txt").write_text("later\n", encoding="utf-8")
        subprocess.run(["git", "add", "later.txt"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "later"], cwd=self.root, check=True)
        with self.assertRaisesRegex(RuntimeError, "release tag mismatch"):
            verify_release_identity(self.root, "HEAD")


if __name__ == "__main__":
    unittest.main()
