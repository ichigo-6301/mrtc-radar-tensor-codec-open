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

    def mutate_json(self, name, mutation):
        path = self.package / name
        value = json.loads(path.read_text(encoding="utf-8"))
        mutation(value)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")

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

    def test_ring_coverage_is_recomputed_from_bit_counts(self):
        self.mutate_csv(
            "clock_gating.csv",
            lambda row: row["metric"] == "ring_coverage_pct",
            "value",
            "1",
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_manifest_mapped_power_classification_is_bound(self):
        self.mutate_json(
            "manifest.json",
            lambda value: value.__setitem__("mapped_power_classification", "CG_MAPPED_POWER_NEGATIVE"),
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_low_activity_coverage(self):
        self.mutate_csv("points.csv", lambda row: row["point_id"] == "G1_ACTIVE_LEGAL", "internal_leaf_pin_coverage_pct", "89.9")
        self.assert_rejected()

    def test_unknown_activity_category_with_complete_row_count(self):
        self.mutate_csv(
            "activity_coverage.csv",
            lambda row: row["point_id"] == "G0_IDLE" and row["category"] == "clocks",
            "category",
            "bogus_category",
        )
        self.refresh_hashes()
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

    def test_equivalence_hash_must_match_verification_record(self):
        self.mutate_csv(
            "equivalence.csv",
            lambda row: row["workload"] == "BURST_IDLE",
            "packet_trace_sha256",
            "0" * 64,
        )
        self.refresh_hashes()
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

    def test_model_functional_test_enable_is_bound(self):
        self.mutate_json("model_audit.json", lambda value: value.__setitem__("functional_test_enable", 1))
        self.refresh_hashes()
        self.assert_rejected()

    def test_model_diagnostic_test_enable_is_bound(self):
        self.mutate_json("model_audit.json", lambda value: value.__setitem__("diagnostic_test_enable", 0))
        self.refresh_hashes()
        self.assert_rejected()

    def test_model_diagnostic_result_is_bound(self):
        self.mutate_json("model_audit.json", lambda value: value.__setitem__("diagnostic_test_enable_result", "PASS"))
        self.refresh_hashes()
        self.assert_rejected()

    def test_formality_classification_is_bound(self):
        self.mutate_csv(
            "classifications.csv",
            lambda row: row["classification_id"] == "direct_clock_gating_mapped_dc315",
            "formality_status",
            "FORMAL_PASS",
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_equivalence_method_classification_is_bound(self):
        self.mutate_csv(
            "classifications.csv",
            lambda row: row["classification_id"] == "direct_clock_gating_mapped_dc315",
            "equivalence_method",
            "formal equivalence",
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_report_hash_inventory_is_complete(self):
        path = self.package / "report_hashes.csv"
        EVIDENCE.write_csv(path, EVIDENCE.REPORT_FIELDS, [])
        self.refresh_hashes()
        self.assert_rejected()

    def test_verification_inventory_is_authoritative(self):
        path = self.package / "verification.csv"
        rows = EVIDENCE.read_csv(path, EVIDENCE.VERIFICATION_FIELDS)
        placeholder = dict(rows[0])
        placeholder.update({
            "verification_id": "placeholder",
            "required": "NO",
            "status": "FAIL",
        })
        EVIDENCE.write_csv(path, EVIDENCE.VERIFICATION_FIELDS, [placeholder])
        self.refresh_hashes()
        self.assert_rejected()

    def test_verification_method_is_bound(self):
        self.mutate_csv(
            "verification.csv",
            lambda row: row["verification_id"] == "implementation_g1",
            "method",
            "unreviewed_method",
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_sdc_replay_portable_handoff_is_rejected(self):
        self.mutate_json(
            "source_contract.json",
            lambda value: value["sdc_replay"].__setitem__("portable_handoff_claim", True),
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_sdc_replay_fatal_errors_are_rejected(self):
        self.mutate_json(
            "source_contract.json",
            lambda value: value["sdc_replay"].__setitem__("fatal_errors", 1),
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_sdc_replay_acceptance_inventory_is_complete(self):
        self.mutate_json(
            "source_contract.json",
            lambda value: value["sdc_replay"].__setitem__("accepted_checks", []),
        )
        self.refresh_hashes()
        self.assert_rejected()

    def test_missing_required_file(self):
        (self.package / "equivalence.csv").unlink()
        self.assert_rejected()


class ClockGatingDocumentTests(unittest.TestCase):
    DOCS = (
        "README.md",
        "README.en.md",
        "docs/zh-CN/asic_clock_gating_experiment.md",
        "docs/en/asic_clock_gating_experiment.md",
    )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for name in self.DOCS:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, target)
        comparisons = self.root / EVIDENCE.PACKAGE_REL / "comparisons.csv"
        comparisons.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(CANONICAL / "comparisons.csv", comparisons)

    def tearDown(self):
        self.temp.cleanup()

    def test_bilingual_document_values_pass(self):
        self.assertTrue(EVIDENCE.validate_doc_values(self.root))

    def test_missing_english_experiment_is_rejected(self):
        (self.root / "docs/en/asic_clock_gating_experiment.md").unlink()
        with self.assertRaises(EVIDENCE.ValidationError):
            EVIDENCE.validate_doc_values(self.root)

    def test_english_overclaim_is_rejected(self):
        path = self.root / "docs/en/asic_clock_gating_experiment.md"
        path.write_text(path.read_text(encoding="utf-8") + "\npost-route power result\n", encoding="utf-8")
        with self.assertRaises(EVIDENCE.ValidationError):
            EVIDENCE.validate_doc_values(self.root)

    def test_metric_values_cannot_be_swapped_between_rows(self):
        path = self.root / "docs/en/asic_clock_gating_experiment.md"
        text = path.read_text(encoding="utf-8")
        text = text.replace("-61.67%", "SWAPPED_VALUE", 1)
        text = text.replace("-59.52%", "-61.67%", 1)
        text = text.replace("SWAPPED_VALUE", "-59.52%", 1)
        path.write_text(text, encoding="utf-8", newline="\n")
        with self.assertRaises(EVIDENCE.ValidationError):
            EVIDENCE.validate_doc_values(self.root)

    def test_stage_two_baseline_endpoint_is_bound(self):
        path = self.root / "docs/en/asic_clock_gating_experiment.md"
        text = path.read_text(encoding="utf-8").replace("107.3535 mW", "999.0000 mW", 1)
        path.write_text(text, encoding="utf-8", newline="\n")
        with self.assertRaises(EVIDENCE.ValidationError):
            EVIDENCE.validate_doc_values(self.root)


if __name__ == "__main__":
    unittest.main()
