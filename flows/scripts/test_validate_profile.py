#!/usr/bin/env python3
"""Unit tests for profile and claim/evidence schema validation."""

import shutil
import tempfile
import unittest
from pathlib import Path

import yaml

from flows.scripts.validate_profile import validate_repository


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class ProfileValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        shutil.copytree(SOURCE_ROOT / "flows/profiles", self.root / "flows/profiles")
        (self.root / "provenance").mkdir(parents=True)
        shutil.copy2(SOURCE_ROOT / "provenance/claims.yaml", self.root / "provenance/claims.yaml")
        shutil.copy2(SOURCE_ROOT / "provenance/evidence.yaml", self.root / "provenance/evidence.yaml")
        shutil.copytree(SOURCE_ROOT / "evidence", self.root / "evidence")

    def tearDown(self):
        self.temp.cleanup()

    def load(self, relative):
        return yaml.safe_load((self.root / relative).read_text(encoding="utf-8"))

    def save(self, relative, data):
        (self.root / relative).write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")

    def test_current_repository_schema_passes(self):
        summary = validate_repository(self.root)
        self.assertGreaterEqual(summary["profiles"], 3)

    def test_unknown_maturity_fails(self):
        path = "flows/profiles/rdtc_v1_register_nangate45_550.yaml"
        data = self.load(path)
        data["maturity"] = "mystery"
        self.save(path, data)
        with self.assertRaisesRegex(RuntimeError, "unknown maturity"):
            validate_repository(self.root)

    def test_claim_to_missing_evidence_fails(self):
        data = self.load("provenance/claims.yaml")
        data["claims"][0]["evidence"] = ["missing_evidence"]
        self.save("provenance/claims.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "nonexistent evidence"):
            validate_repository(self.root)

    def test_evidence_to_missing_claim_fails(self):
        data = self.load("provenance/evidence.yaml")
        data["evidence"][0]["claims"].append("missing_claim")
        self.save("provenance/evidence.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "nonexistent claim"):
            validate_repository(self.root)

    def test_verified_claim_with_only_experimental_evidence_fails(self):
        data = self.load("provenance/evidence.yaml")
        data["evidence"][0]["maturity"] = "experimental"
        self.save("provenance/evidence.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "linked only to experimental evidence"):
            validate_repository(self.root)

    def test_physical_claim_without_caveat_fails(self):
        data = self.load("provenance/claims.yaml")
        claim = next(item for item in data["claims"] if item["id"].endswith("pnr550_pt"))
        claim["caveat"] = ""
        self.save("provenance/claims.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "missing a caveat"):
            validate_repository(self.root)

    def test_missing_required_provenance_fields_fail(self):
        claims = self.load("provenance/claims.yaml")
        del claims["claims"][0]["source_ref"]
        self.save("provenance/claims.yaml", claims)
        evidence = self.load("provenance/evidence.yaml")
        del evidence["evidence"][0]["tool"]
        del evidence["evidence"][0]["public"]
        self.save("provenance/evidence.yaml", evidence)
        with self.assertRaisesRegex(RuntimeError, "missing fields"):
            validate_repository(self.root)


if __name__ == "__main__":
    unittest.main()
