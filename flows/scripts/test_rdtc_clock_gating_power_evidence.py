#!/usr/bin/env python3

import csv
import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("rdtc_clock_gating_power_evidence.py")
SPEC = importlib.util.spec_from_file_location("clock_gating_evidence", SCRIPT)
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)
REPO = SCRIPT.parents[2]
CANONICAL = REPO / EVIDENCE.PACKAGE_REL


class ClockGatingEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.package = self.root / EVIDENCE.PACKAGE_REL
        self.package.parent.mkdir(parents=True)
        shutil.copytree(CANONICAL, self.package)

    def tearDown(self):
        self.temp.cleanup()

    def refresh_hashes(self):
        rows = []
        for name in sorted(EVIDENCE.PACKAGE_FILES - {"output_hashes.sha256"}):
            digest = hashlib.sha256((self.package / name).read_bytes()).hexdigest()
            rows.append("{}  {}\n".format(digest, name))
        (self.package / "output_hashes.sha256").write_text("".join(rows), encoding="ascii", newline="\n")

    def mutate_csv(self, name, predicate, field, value):
        path = self.package / name
        with path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            fields = tuple(reader.fieldnames)
            rows = list(reader)
        changed = False
        for row in rows:
            if predicate(row):
                row[field] = value
                changed = True
                break
        self.assertTrue(changed)
        EVIDENCE.write_csv(path, fields, rows)

    def assert_rejected(self):
        with self.assertRaises(EVIDENCE.ValidationError):
            EVIDENCE.validate_package(self.root)

    def test_positive_canonical_package(self):
        result = EVIDENCE.validate_package(self.root)
        self.assertEqual(6, len(result["points"]))
        self.assertEqual(37, len(result["comparisons"]))

    def test_changed_dynamic_value(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G0_IDLE", "dynamic_mw", "66.9")
        self.assert_rejected()

    def test_changed_energy_per_block(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_BURST_IDLE", "energy_per_block_nj", "68")
        self.assert_rejected()

    def test_duplicate_point(self):
        path = self.package / "points.csv"
        lines = path.read_text(encoding="utf-8").splitlines()
        path.write_text("\n".join(lines + [lines[1]]) + "\n", encoding="utf-8", newline="\n")
        self.assert_rejected()

    def test_duplicate_json_key(self):
        path = self.package / "manifest.json"
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace('{\n  "activity_coverage"', '{\n  "schema": "duplicate",\n  "activity_coverage"'), encoding="utf-8", newline="\n")
        self.assert_rejected()

    def test_reused_saif(self):
        rows = EVIDENCE.read_csv(self.package / "points.csv", EVIDENCE.POINT_FIELDS)
        value = next(row["activity_sha256"] for row in rows if row["point_id"] == "G0_IDLE")
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_IDLE", "activity_sha256", value)
        self.assert_rejected()

    def test_wrong_icg_count(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_IDLE", "icg_count", "271")
        self.assert_rejected()

    def test_wrong_gated_bit_denominator(self):
        self.mutate_csv("clock_gating.csv", lambda row: row["metric"] == "postmap_sequential_bits", "value", "50999")
        self.assert_rejected()

    def test_low_activity_coverage(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_ACTIVE_LEGAL", "internal_leaf_pin_coverage_pct", "89.9")
        self.assert_rejected()

    def test_changed_wns(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_IDLE", "setup_wns_ns", "-0.001")
        self.assert_rejected()

    def test_electrical_violation(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_IDLE", "electrical_violations", "1")
        self.assert_rejected()

    def test_trace_mismatch(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_BURST_IDLE", "normalized_trace_sha256", "0" * 64)
        self.assert_rejected()

    def test_parser_recovery_inconsistency(self):
        path = self.package / "parser_recovery.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["eda_rerun"] = True
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        self.assert_rejected()

    def test_non_deterministic_comparison(self):
        self.mutate_csv("comparisons.csv", lambda row: row["comparison_id"] == "BURST_IDLE:dynamic_mw", "percent_change", "-61")
        self.assert_rejected()

    def test_formality_overclaim(self):
        path = self.package / "README.md"
        path.write_text(path.read_text(encoding="utf-8") + "\nFormality PASS\n", encoding="utf-8", newline="\n")
        self.refresh_hashes()
        self.assert_rejected()

    def test_postroute_overclaim(self):
        path = self.package / "README.md"
        path.write_text(path.read_text(encoding="utf-8") + "\npost-route power result\n", encoding="utf-8", newline="\n")
        self.refresh_hashes()
        self.assert_rejected()

    def test_private_path_leakage(self):
        path = self.package / "README.md"
        path.write_text(path.read_text(encoding="utf-8") + "\nD:/master/private\n", encoding="utf-8", newline="\n")
        self.refresh_hashes()
        self.assert_rejected()

    def test_bare_test_coverage_wording(self):
        path = self.package / "README.md"
        path.write_text(path.read_text(encoding="utf-8") + "\n100% test coverage\n", encoding="utf-8", newline="\n")
        self.refresh_hashes()
        self.assert_rejected()

    def test_wrong_model_definition_count(self):
        path = self.package / "model_audit.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["effective_definition_count"] = 2
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        self.assert_rejected()

    def test_missing_required_file(self):
        (self.package / "equivalence.csv").unlink()
        self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
