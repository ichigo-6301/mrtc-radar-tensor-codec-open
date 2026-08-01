#!/usr/bin/env python3
"""Tests for the published Bitpacker pipeline A/B evidence validator."""

import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

import yaml


SCRIPT_DIR = Path(__file__).resolve().parent
SOURCE_ROOT = SCRIPT_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_bitpacker_pipeline_ab",
    SCRIPT_DIR / "validate_bitpacker_pipeline_ab.py",
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class BitpackerPipelineAbEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for relative in (
            VALIDATOR.EVIDENCE_PATH,
            VALIDATOR.CSV_PATH,
            "provenance/claims.yaml",
            "provenance/evidence.yaml",
        ) + tuple(VALIDATOR.EXPECTED_FILE_HASHES):
            source = SOURCE_ROOT / relative
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    def tearDown(self):
        self.temp.cleanup()

    def test_published_evidence_passes(self):
        result = VALIDATOR.validate(self.root)
        self.assertEqual(2, result["rows"])
        self.assertAlmostEqual(10.669902912621358, result["speedup"])

    def test_inclusive_interval_mutation_fails(self):
        path = self.root / VALIDATOR.CSV_PATH
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace(",1169,8861,7693,", ",1169,8861,7692,"), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "curated CSV hash mismatch"):
            VALIDATOR.validate(self.root)

    def test_workload_mutation_fails(self):
        path = self.root / "vectors/rdtc_v1/smoke_zero_sparse/axis_raw_in.hex"
        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "workload file hash mismatch"):
            VALIDATOR.validate(self.root)

    def test_claim_link_mutation_fails(self):
        path = self.root / "provenance/claims.yaml"
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        claim = next(item for item in data["claims"] if item["id"] == VALIDATOR.CLAIM_ID)
        claim["evidence"] = []
        path.write_text(yaml.safe_dump(data), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "claim evidence link mismatch"):
            VALIDATOR.validate(self.root)


if __name__ == "__main__":
    unittest.main()
