#!/usr/bin/env python3
"""Tests for the bounded Direct-AXIS RTL identity gate."""

import csv
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "bounded_direct_rtl_identity", SCRIPT_DIR / "bounded_direct_rtl_identity.py"
)
IDENTITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTITY)


class BoundedDirectRtlIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "flows/manifests").mkdir(parents=True)
        (self.root / "rtl").mkdir()
        (self.root / "evidence/data").mkdir(parents=True)
        (self.root / "rtl/a.sv").write_bytes(b"module a; endmodule\n")
        (self.root / "rtl/b.sv").write_bytes(b"module b; endmodule\n")
        (self.root / IDENTITY.DEFAULT_MANIFEST).write_text(
            "+incdir+rtl\nrtl/b.sv\nrtl/a.sv\n", encoding="utf-8"
        )
        self.ref = "1" * 40
        self.write_valid_rows()

    def tearDown(self):
        self.temp.cleanup()

    def digest(self, path):
        return hashlib.sha256((self.root / path).read_bytes()).hexdigest()

    def write_valid_rows(self):
        rows = []
        for path in ("rtl/a.sv", "rtl/b.sv"):
            digest = self.digest(path)
            rows.append(
                {
                    "path": path,
                    "source_ref": self.ref,
                    "source_sha256": digest,
                    "published_sha256": digest,
                    "relationship": "identical",
                }
            )
        IDENTITY.write_rows(self.root / IDENTITY.DEFAULT_OUTPUT, rows)

    def test_complete_identity_passes(self):
        self.assertEqual(
            2,
            IDENTITY.check_rows(
                self.root,
                self.ref,
                IDENTITY.DEFAULT_MANIFEST,
                IDENTITY.DEFAULT_OUTPUT,
            ),
        )

    def test_manifest_change_fails_closed(self):
        (self.root / "rtl/c.sv").write_bytes(b"module c; endmodule\n")
        with (self.root / IDENTITY.DEFAULT_MANIFEST).open("a", encoding="utf-8") as stream:
            stream.write("rtl/c.sv\n")
        with self.assertRaisesRegex(RuntimeError, "path set/order is stale"):
            IDENTITY.check_rows(
                self.root, self.ref, IDENTITY.DEFAULT_MANIFEST, IDENTITY.DEFAULT_OUTPUT
            )

    def test_rtl_change_fails_closed(self):
        (self.root / "rtl/a.sv").write_bytes(b"module changed; endmodule\n")
        with self.assertRaisesRegex(RuntimeError, "changed after evidence freeze"):
            IDENTITY.check_rows(
                self.root, self.ref, IDENTITY.DEFAULT_MANIFEST, IDENTITY.DEFAULT_OUTPUT
            )

    def test_source_hash_mismatch_fails_closed(self):
        path = self.root / IDENTITY.DEFAULT_OUTPUT
        with path.open("r", encoding="utf-8", newline="") as stream:
            rows = list(csv.DictReader(stream))
        rows[0]["source_sha256"] = "0" * 64
        IDENTITY.write_rows(path, rows)
        with self.assertRaisesRegex(RuntimeError, "source/published identity mismatch"):
            IDENTITY.check_rows(
                self.root, self.ref, IDENTITY.DEFAULT_MANIFEST, IDENTITY.DEFAULT_OUTPUT
            )


if __name__ == "__main__":
    unittest.main()
