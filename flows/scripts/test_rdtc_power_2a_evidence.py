#!/usr/bin/env python3
"""Focused tests for the fail-closed RDTC Power 2A evidence package."""

from __future__ import print_function

import hashlib
import json
import sys
import tempfile
import unittest
from decimal import Decimal, localcontext
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rdtc_power_2a_evidence as evidence


COMMIT = "b" * 40


def digest(text):
    return hashlib.sha256(text.encode("ascii")).hexdigest()


def write_hash_entries(path, entries):
    path.write_text(
        "".join("{}  {}\n".format(entries[name], name) for name in sorted(entries)),
        encoding="ascii",
    )


def write_output_hashes(root):
    names = (
        "classifications.csv", "comparisons.csv", "eligibility.csv", "gates.csv",
        "hierarchy_power.csv", "input_hashes.sha256", "manifest.json", "points.csv",
        "raw_reports.csv", "source_contract.json", "verification.csv",
    )
    write_hash_entries(root / "output_hashes.sha256", {
        name: evidence.sha256_file(root / name) for name in names
    })


def contract_data():
    return {
        "schema": evidence.SOURCE_CONTRACT_SCHEMA,
        "architecture_ab": {
            "as_run_flow_commit": COMMIT, "fixed_public_rtl_commit": COMMIT,
            "source_set_sha256": digest("arch-source"), "filelist_sha256": digest("arch-list"),
            "sdc_sha256": digest("arch-sdc"), "dc_run_tcl_sha256": digest("arch-dc"),
        },
        "direct_clock_gating": {
            "fixed_rtl_commit": COMMIT, "mapped_netlist_sha256": digest("mapped"),
            "routed_netlist_sha256": digest("routed"), "postroute_sdc_sha256": digest("route-sdc"),
            "postroute_spef_sha256": digest("spef"),
        },
        "library": {"stdcell_db_sha256": digest("db")},
        "tool_contract": {"mapped_equivalence_method": "gate_level_regression"},
    }


def point(experiment, group, variant, workload, source_contract_sha, **updates):
    postroute = experiment == "postroute"
    is_gated = variant == "G1"
    unique = "{}:{}:{}:{}".format(experiment, group, variant, workload)
    row = {field: "NA" for field in evidence.POINT_FIELDS}
    row.update({
        "point_id": unique, "experiment": experiment, "comparison_group": group,
        "variant": variant, "workload_id": workload, "status": "PASS",
        "implementation": "postroute_ptpx" if postroute else "mapped_dc",
        "top": "mrtc_rdtc_bounded_axis_multiengine_wrapper",
        "profile": "direct_register", "source_commit": COMMIT,
        "shared_source_set_sha256": digest("shared-source"),
        "variant_source_set_sha256": digest("variant-source"),
        "source_contract_sha256": source_contract_sha, "library_id": "nangate45_tt",
        "library_sha256": digest("library"), "sdc_sha256": digest("sdc"),
        "activity_sha256": digest("activity:" + unique),
        "normalized_packet_trace_sha256": digest("trace:" + group + ":" + workload),
        "workload_manifest_sha256": digest("workload:" + workload),
        "input_sequence_sha256": digest("input:" + workload),
        "expected_packet_sequence_sha256": digest("packet:" + workload),
        "selected_k_sequence_sha256": digest("k:" + workload),
        "descriptor_sequence_sha256": digest("descriptor:" + workload),
        "output_ready_sequence_sha256": digest("ready:" + workload),
        "activity_method": "gate_level_saif", "activity_strip_path_sha256": digest("strip:" + unique),
        "frequency_mhz": "600", "tool_version": "O-2018.06-SP1", "random_seed": "0",
        "measurement_start_cycle": "100", "measurement_end_cycle": "1300", "window_cycles": "1200",
        "blocks_completed": "3", "raw_bytes": "12288", "compressed_bytes": "1000",
        "clock_coverage_pct": "100", "functional_input_coverage_pct": "100",
        "sequential_output_coverage_pct": "98", "internal_leaf_pin_coverage_pct": "95",
        "overall_nondefault_coverage_pct": "96", "clock_nets_annotated": "100", "clock_nets_total": "100",
        "functional_inputs_annotated": "50", "functional_inputs_total": "50",
        "sequential_outputs_annotated": "98", "sequential_outputs_total": "100",
        "internal_leaf_pins_annotated": "95", "internal_leaf_pins_total": "100",
        "overall_objects_annotated": "96", "overall_objects_total": "100",
        "activity_unmatched_objects": "0", "activity_default_toggle_objects": "0",
        "area_total_um2": "102" if is_gated else "100", "area_combinational_um2": "30",
        "area_sequential_um2": "50", "cell_count": "100", "sequential_cell_count": "40",
        "buffer_cell_count": "3", "inverter_cell_count": "4", "sequential_bits": "40000",
        "gated_bits": "10000" if is_gated else "0",
        "inserted_icg_count": "100" if is_gated else "0",
        "eligible_sequential_bits": "12000" if is_gated else "0",
        "potential_icg_count": "120" if is_gated else "0",
        "max_icg_fanout": "64" if is_gated else "0", "max_enable_fanout": "64" if is_gated else "0",
        "fanout_violations": "0", "setup_wns_ns": "0.01", "setup_tns_ns": "0",
        "electrical_violations": "0", "clock_gating_violations": "0",
        "max_transition_violations": "0", "max_capacitance_violations": "0", "max_fanout_violations": "0",
        "dynamic_mw": "9" if is_gated and workload == "bursty" else ("10.1" if is_gated and workload == "sustained" else "10"),
        "internal_mw": "5" if is_gated and workload == "bursty" else ("6.1" if is_gated and workload == "sustained" else "6"),
        "switching_mw": "4", "leakage_mw": "2", "total_mw": "11" if is_gated and workload == "bursty" else ("12.1" if is_gated and workload == "sustained" else "12"),
        "report_quantization_mw": "0.001",
        "clock_mw": "3" if is_gated else "4", "sequential_power_mw": "1" if is_gated else "2",
        "combinational_power_mw": "5",
    })
    if postroute:
        row.update({
            "routed_netlist_sha256": digest("routed:" + variant),
            "routed_sdc_sha256": digest("routed-sdc:" + variant),
            "routed_spef_sha256": digest("spef:" + variant), "routed_odb_sha256": digest("odb:" + variant),
            "hold_wns_ns": "0.01", "hold_tns_ns": "0", "route_drc": "0", "antenna_violations": "0",
            "unrouted_nets": "0", "no_clock_registers": "0", "unconstrained_endpoints": "0",
            "physical_flow_errors": "0", "clock_buffer_count": "10", "clock_inverter_count": "1",
            "gated_clock_sink_count": "100" if is_gated else "0", "clock_wirelength_um": "1000",
            "clock_skew_ns": "0.02", "clock_insertion_delay_ns": "0.1", "utilization_pct": "50",
        })
    row.update(updates)
    return row


def raw_report_rows(points):
    rows = []
    for item in points:
        if item["status"] != "PASS":
            continue
        for kind in sorted(evidence.REQUIRED_RAW_REPORTS[item["experiment"]]):
            report_hash = digest("report:{}:{}".format(item["point_id"], kind))
            if kind == "activity":
                report_hash = item["activity_sha256"]
            elif kind == "functional":
                report_hash = item["normalized_packet_trace_sha256"]
            rows.append({"report_id": "{}:{}".format(item["point_id"], kind), "point_id": item["point_id"], "report_kind": kind, "report_sha256": report_hash})
    for item in points:
        own = [row for row in rows if row["point_id"] == item["point_id"]]
        if own:
            item["raw_report_set_sha256"] = hashlib.sha256(json.dumps(sorted(own, key=lambda row: row["report_kind"]), sort_keys=True, separators=(",", ":")).encode("ascii")).hexdigest()
        else:
            item["raw_report_set_sha256"] = "NA"
    return rows


def verification_rows(points):
    rows = []
    for item in points:
        for kind in evidence.REQUIRED_VERIFICATION[item["experiment"]]:
            passed = item["status"] == "PASS"
            rows.append({
                "verification_id": "{}:{}".format(item["point_id"], kind), "point_id": item["point_id"],
                "kind": kind, "method": "gate_level_regression" if kind == "equivalence" else "tool_report",
                "required": "YES", "trace_sha256": item["normalized_packet_trace_sha256"] if passed else "NA",
                "result_sha256": digest("verification:{}:{}".format(item["point_id"], kind)) if passed else "NA",
                "status": "PASS" if passed else "NOT_STARTED",
            })
    return rows


def hierarchy_rows(points):
    rows = []
    for item in points:
        if item["status"] != "PASS":
            continue
        root = {"point_id": item["point_id"], "hierarchy_id": "__ROOT__", "status": "PASS"}
        root.update({field: item[field] for field in ("internal_mw", "switching_mw", "leakage_mw", "total_mw")})
        root["report_quantization_mw"] = item["report_quantization_mw"]
        rows.append(root)
        rows.append({"point_id": item["point_id"], "hierarchy_id": "bitpacker", "status": "PASS", "internal_mw": "1", "switching_mw": "1", "leakage_mw": "0", "total_mw": "2", "report_quantization_mw": "0.001"})
    return rows


def eligibility_rows(points):
    rows = []
    for item in points:
        if item["status"] != "PASS" or item["experiment"] not in ("gating", "postroute") or item["variant"] != "G1":
            continue
        total = {"point_id": item["point_id"], "hierarchy_id": "__TOTAL__", "status": "PASS", "uncovered_reason": "documented", "enable_expr_sha256": digest("enable:total:" + item["point_id"])}
        total.update({field: item[point_field] for field, point_field in (
            ("sequential_bits", "sequential_bits"), ("eligible_bits", "eligible_sequential_bits"),
            ("gated_bits", "gated_bits"), ("potential_icg_count", "potential_icg_count"),
            ("inserted_icg_count", "inserted_icg_count"), ("max_icg_fanout", "max_icg_fanout"),
            ("max_enable_fanout", "max_enable_fanout"))})
        rows.append(total)
        rows.append({"point_id": item["point_id"], "hierarchy_id": "engine0.ring", "status": "PASS", "sequential_bits": "32768", "eligible_bits": "10000", "gated_bits": "10000", "potential_icg_count": "120", "inserted_icg_count": "100", "max_icg_fanout": "64", "max_enable_fanout": "64", "uncovered_reason": "protocol_control_excluded", "enable_expr_sha256": digest("enable:ring:" + item["point_id"])})
    return rows


def write_package(root, points):
    (root / "README.md").write_text("Fixture evidence package.\n", encoding="utf-8")
    contract = contract_data()
    contract_path = root / "source_contract.json"
    contract_path.write_text(json.dumps(contract, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    contract_sha = evidence.sha256_file(contract_path)
    for item in points:
        item["source_contract_sha256"] = contract_sha
    raw_reports = raw_report_rows(points)
    verification = verification_rows(points)
    hierarchy = hierarchy_rows(points)
    eligibility = eligibility_rows(points)
    point_map = {item["point_id"]: item for item in points}
    comparisons = evidence.derive_comparisons(point_map)
    verification_map = {}
    for row in verification:
        verification_map.setdefault(row["point_id"], {})[row["kind"]] = row
    gates = evidence.derive_gates(point_map, comparisons, verification_map)
    classifications = evidence.derive_classifications(point_map, comparisons, gates, verification_map)
    write_hash_entries(root / "input_hashes.sha256", {
        "activity:fixture:bundle": digest("fixture-input"),
    })
    manifest = {
        "schema": evidence.SCHEMA, "points_csv": "points.csv", "comparisons_csv": "comparisons.csv",
        "verification_csv": "verification.csv", "gates_csv": "gates.csv", "classifications_csv": "classifications.csv",
        "eligibility_csv": "eligibility.csv", "hierarchy_power_csv": "hierarchy_power.csv", "raw_reports_csv": "raw_reports.csv",
        "source_contract_json": "source_contract.json", "source_contract_sha256": contract_sha,
        "source_contract_schema": evidence.SOURCE_CONTRACT_SCHEMA,
        "input_hashes_file": "input_hashes.sha256",
        "input_hashes_sha256": evidence.sha256_file(root / "input_hashes.sha256"),
        "output_hashes_file": "output_hashes.sha256",
    }
    (root / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    evidence.write_csv(root / "points.csv", evidence.POINT_FIELDS, points)
    evidence.write_csv(root / "comparisons.csv", evidence.COMPARISON_FIELDS, comparisons)
    evidence.write_csv(root / "verification.csv", evidence.VERIFICATION_FIELDS, verification)
    evidence.write_csv(root / "gates.csv", evidence.GATE_FIELDS, gates)
    evidence.write_csv(root / "classifications.csv", evidence.CLASSIFICATION_FIELDS, classifications)
    evidence.write_csv(root / "eligibility.csv", evidence.ELIGIBILITY_FIELDS, eligibility)
    evidence.write_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS, hierarchy)
    evidence.write_csv(root / "raw_reports.csv", evidence.RAW_REPORT_FIELDS, raw_reports)
    write_output_hashes(root)
    return root


def gating_points(contract_sha="pending"):
    return [point("gating", "gating-600", variant, workload, contract_sha)
            for workload in ("bursty", "sustained") for variant in ("G0", "G1")]


class EvidenceContractTests(unittest.TestCase):
    def test_complete_mapped_gating_package_is_promotable(self):
        with tempfile.TemporaryDirectory() as temp:
            result = evidence.validate(write_package(Path(temp), gating_points()))
        self.assertTrue(result["promotion_eligible"])
        self.assertEqual(result["classifications"][0]["classification"], "CG_MAPPED_POSITIVE")

    def test_energy_metrics_use_full_precision_and_all_denominators(self):
        item = point("architecture", "arch", "A0", "bursty", digest("contract"), total_mw="1", internal_mw="0.6", switching_mw="0.4", leakage_mw="0", dynamic_mw="1", frequency_mhz="3", window_cycles="1", measurement_end_cycle="101", blocks_completed="1", raw_bytes="2", compressed_bytes="4")
        with localcontext() as context:
            context.prec = evidence.DECIMAL_PRECISION
            self.assertEqual(evidence._metric(item, "energy_per_block_nj"), Decimal(1) / Decimal(3))
            self.assertEqual(evidence._metric(item, "dynamic_energy_per_raw_byte_nj"), Decimal(1) / Decimal(6))
            self.assertEqual(evidence._metric(item, "energy_per_compressed_byte_nj"), Decimal(1) / Decimal(12))

    def test_source_contract_hash_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            (root / "source_contract.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "SHA-256"):
                evidence.validate(root)

    def test_input_hashes_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            (root / "input_hashes.sha256").write_text(
                "{}  activity:fixture:bundle\n".format(digest("tampered-input")), encoding="ascii"
            )
            with self.assertRaisesRegex(evidence.ValidationError, "input_hashes.sha256 SHA-256"):
                evidence.validate(root)

    def test_extra_raw_report_is_rejected_even_without_private_tokens(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            (root / "power.rpt").write_text("Total Dynamic Power = 1.0 mW\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "package inventory mismatch"):
                evidence.validate(root)

    def test_promoted_input_authority_is_exact(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            manifest_path = root / "manifest.json"
            entries = evidence._read_hash_entries(root / "input_hashes.sha256")
            entries["activity:fixture:bundle"] = "0" * 64
            write_hash_entries(root / "input_hashes.sha256", entries)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["input_hashes_sha256"] = evidence.sha256_file(root / "input_hashes.sha256")
            manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8")
            write_output_hashes(root)
            with self.assertRaisesRegex(evidence.ValidationError, "promoted input authority inventory"):
                evidence.validate(root, require_promotion=True)

    def test_output_hashes_are_required_and_verified(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            (root / "output_hashes.sha256").unlink()
            with self.assertRaisesRegex(evidence.ValidationError, "missing output_hashes.sha256|package inventory mismatch"):
                evidence.validate(root)
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            entries = evidence._read_hash_entries(root / "output_hashes.sha256")
            entries["points.csv"] = digest("tampered-points")
            write_hash_entries(root / "output_hashes.sha256", entries)
            with self.assertRaisesRegex(evidence.ValidationError, "mismatch for points.csv"):
                evidence.validate(root)

    def test_missing_raw_report_or_set_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            rows = (root / "raw_reports.csv").read_text(encoding="utf-8").splitlines()
            (root / "raw_reports.csv").write_text("\n".join(rows[:-1]) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "raw report kinds mismatch|raw report set hash"):
                evidence.validate(root)

    def test_private_path_is_rejected_before_parsing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            (root / "note.txt").write_text("C:\\\\private\\\\raw.log", encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "absolute private path"):
                evidence.validate(root)

    def test_coverage_requires_exact_machine_readable_denominator(self):
        with tempfile.TemporaryDirectory() as temp:
            points = gating_points()
            points[0]["sequential_output_coverage_pct"] = "97"
            root = write_package(Path(temp), points)
            with self.assertRaisesRegex(evidence.ValidationError, "match its explicit coverage denominator"):
                evidence.validate(root)

    def test_low_coverage_is_valid_negative_but_fails_promotion(self):
        with tempfile.TemporaryDirectory() as temp:
            points = gating_points()
            for item in points:
                item["internal_leaf_pins_annotated"] = "80"
                item["internal_leaf_pin_coverage_pct"] = "80"
            result = evidence.validate(write_package(Path(temp), points))
            self.assertFalse(result["promotion_eligible"])
            self.assertEqual(result["classifications"][0]["classification"], "CG_POWER_TOOL_UNAVAILABLE")
            with self.assertRaisesRegex(evidence.ValidationError, "fail-closed promotion gate"):
                evidence.validate(Path(temp), require_promotion=True)

    def test_power_and_area_partition_arithmetic_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            content = (root / "points.csv").read_text(encoding="utf-8")
            (root / "points.csv").write_text(content.replace(",10,6,4,2,12,", ",10,6,4,2,11,", 1), encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "total_mw must equal"):
                evidence.validate(root)
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            content = (root / "points.csv").read_text(encoding="utf-8")
            (root / "points.csv").write_text(content.replace(",100,30,50,100,", ",100,80,50,100,", 1), encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "area exceeds"):
                evidence.validate(root)

    def test_power_partition_accepts_only_recorded_report_quantization(self):
        with tempfile.TemporaryDirectory() as temp:
            points = gating_points()
            points[0]["internal_mw"] = "6.0009"
            points[0]["report_quantization_mw"] = "0.001"
            evidence.validate(write_package(Path(temp), points))
        with tempfile.TemporaryDirectory() as temp:
            points = gating_points()
            points[0]["internal_mw"] = "6.0011"
            points[0]["report_quantization_mw"] = "0.001"
            root = write_package(Path(temp), points)
            with self.assertRaisesRegex(evidence.ValidationError, "dynamic_mw must equal"):
                evidence.validate(root)

    def test_report_quantization_must_be_bounded(self):
        for value in ("0", "-0.001", "3.1", "0.3"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temp:
                points = gating_points()
                points[0]["report_quantization_mw"] = value
                root = write_package(Path(temp), points)
                with self.assertRaisesRegex(evidence.ValidationError, "quantization"):
                    evidence.validate(root)

    def test_hierarchy_root_must_bind_machine_readable_power(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            rows = evidence._read_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS)
            rows[0]["total_mw"] = "11"
            evidence.write_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS, rows)
            with self.assertRaisesRegex(evidence.ValidationError, "hierarchy total_mw|hierarchy root"):
                evidence.validate(root)

    def test_hierarchy_root_uses_combined_report_quantization(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            rows = evidence._read_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS)
            rows[0]["internal_mw"] = "6.0015"
            rows[0]["total_mw"] = "12.0015"
            evidence.write_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS, rows)
            write_output_hashes(root)
            evidence.validate(root)

    def test_hierarchy_root_rejects_value_beyond_combined_quantization(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            rows = evidence._read_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS)
            rows[0]["internal_mw"] = "6.0021"
            rows[0]["total_mw"] = "12.0021"
            evidence.write_csv(root / "hierarchy_power.csv", evidence.HIERARCHY_POWER_FIELDS, rows)
            with self.assertRaisesRegex(evidence.ValidationError, "hierarchy root"):
                evidence.validate(root)

    def test_schema_v2_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["schema"] = "rdtc_power_2a_evidence_v2"
            (root / "manifest.json").write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(evidence.ValidationError, "unsupported manifest schema"):
                evidence.validate(root)

    def test_gated_point_requires_total_and_hierarchy_eligibility(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            lines = (root / "eligibility.csv").read_text(encoding="utf-8").splitlines()
            lines = [line for line in lines if "engine0.ring" not in line]
            (root / "eligibility.csv").write_text("\n".join(lines) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "hierarchy-level eligibility"):
                evidence.validate(root)

    def test_pair_requires_identical_logical_work_and_distinct_activity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            content = (root / "points.csv").read_text(encoding="utf-8")
            original = digest("packet:bursty")
            (root / "points.csv").write_text(content.replace(original, digest("different-packet"), 1), encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "paired identity mismatch expected_packet"):
                evidence.validate(root)
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            content = (root / "points.csv").read_text(encoding="utf-8")
            activity_0 = digest("activity:gating:gating-600:G0:bursty")
            activity_1 = digest("activity:gating:gating-600:G1:bursty")
            (root / "points.csv").write_text(content.replace(activity_1, activity_0, 1), encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "own activity artifact"):
                evidence.validate(root)

    def test_postroute_requires_routed_identity_and_physical_metrics(self):
        with tempfile.TemporaryDirectory() as temp:
            points = [point("postroute", "postroute-600", variant, workload, "pending")
                      for workload in ("bursty", "sustained") for variant in ("G0", "G1")]
            points[0]["routed_spef_sha256"] = "NA"
            root = write_package(Path(temp), points)
            with self.assertRaisesRegex(evidence.ValidationError, "routed_spef_sha256"):
                evidence.validate(root)

    def test_architecture_and_gating_classifications_are_independent(self):
        with tempfile.TemporaryDirectory() as temp:
            points = gating_points()
            for workload in ("bursty", "active"):
                points.extend((
                    point("architecture", "arch-315", "A0", workload, "pending", top="buffered_top", profile="buffered", frequency_mhz="315"),
                    point("architecture", "arch-315", "A1", workload, "pending", top="direct_top", profile="direct", frequency_mhz="315", variant_source_set_sha256=digest("direct-source"), dynamic_mw="11", internal_mw="7", switching_mw="4", leakage_mw="2", total_mw="13"),
                ))
            result = evidence.validate(write_package(Path(temp), points))
            classes = {row["experiment"]: row["classification"] for row in result["classifications"]}
            self.assertEqual(classes["architecture"], "ARCH_POWER_NEGATIVE")
            self.assertEqual(classes["gating"], "CG_MAPPED_POSITIVE")

    def test_architecture_pair_allows_variant_sdc_and_run_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            points = []
            for workload in ("bursty", "active"):
                points.extend((
                    point("architecture", "arch-315", "A0", workload, "pending", top="buffered_top", profile="buffered", frequency_mhz="315", sdc_sha256=digest("a0-sdc"), workload_manifest_sha256=digest("a0-manifest:" + workload)),
                    point("architecture", "arch-315", "A1", workload, "pending", top="direct_top", profile="direct", frequency_mhz="315", variant_source_set_sha256=digest("direct-source"), sdc_sha256=digest("a1-sdc"), workload_manifest_sha256=digest("a1-manifest:" + workload), dynamic_mw="8.9", internal_mw="4.9", switching_mw="4", leakage_mw="2", total_mw="10.9"),
                ))
            result = evidence.validate(write_package(Path(temp), points))
            self.assertEqual(result["classifications"][0]["classification"], "ARCH_POWER_POSITIVE")

    def test_architecture_pair_still_requires_common_logical_trace(self):
        with tempfile.TemporaryDirectory() as temp:
            points = []
            for workload in ("bursty", "active"):
                points.extend((
                    point("architecture", "arch-315", "A0", workload, "pending", top="buffered_top", profile="buffered", frequency_mhz="315"),
                    point("architecture", "arch-315", "A1", workload, "pending", top="direct_top", profile="direct", frequency_mhz="315", variant_source_set_sha256=digest("direct-source")),
                ))
            points[1]["normalized_packet_trace_sha256"] = digest("different-logical-trace")
            with self.assertRaisesRegex(evidence.ValidationError, "paired identity mismatch normalized_packet_trace"):
                write_package(Path(temp), points)

    def test_equal_zero_metrics_have_deterministic_zero_delta(self):
        points = []
        for workload in ("bursty", "active"):
            points.extend((
                point("architecture", "arch-315", "A0", workload, "pending", top="buffered_top", profile="buffered", frequency_mhz="315", clock_mw="0"),
                point("architecture", "arch-315", "A1", workload, "pending", top="direct_top", profile="direct", frequency_mhz="315", variant_source_set_sha256=digest("direct-source"), clock_mw="0"),
            ))
        comparisons = evidence.derive_comparisons({item["point_id"]: item for item in points})
        clock_rows = [row for row in comparisons if row["metric"] == "clock_mw"]
        self.assertEqual(len(clock_rows), 2)
        for row in clock_rows:
            self.assertEqual(row["baseline"], "0")
            self.assertEqual(row["candidate"], "0")
            self.assertEqual(row["delta"], "0")
            self.assertEqual(row["delta_percent"], "0")
            self.assertEqual(row["formula"], "candidate-baseline; equal_zero_baseline=>0_percent")

    def test_zero_baseline_with_nonzero_candidate_is_rejected(self):
        points = []
        for workload in ("bursty", "active"):
            points.extend((
                point("architecture", "arch-315", "A0", workload, "pending", top="buffered_top", profile="buffered", frequency_mhz="315", clock_mw="0"),
                point("architecture", "arch-315", "A1", workload, "pending", top="direct_top", profile="direct", frequency_mhz="315", variant_source_set_sha256=digest("direct-source"), clock_mw="1"),
            ))
        with self.assertRaisesRegex(evidence.ValidationError, "zero baseline metric is not comparable: arch-315:bursty:clock_mw"):
            evidence.derive_comparisons({item["point_id"]: item for item in points})

    def test_architecture_promotion_uses_conservative_quantization_bound(self):
        with tempfile.TemporaryDirectory() as temp:
            points = []
            for workload in ("bursty", "active"):
                candidate_power = {
                    "dynamic_mw": "9", "internal_mw": "5", "switching_mw": "4",
                    "leakage_mw": "2", "total_mw": "11",
                } if workload == "bursty" else {}
                points.extend((
                    point("architecture", "arch-315", "A0", workload, "pending", top="buffered_top", profile="buffered", frequency_mhz="315"),
                    point("architecture", "arch-315", "A1", workload, "pending", top="direct_top", profile="direct", frequency_mhz="315", variant_source_set_sha256=digest("direct-source"), **candidate_power),
                ))
            result = evidence.validate(write_package(Path(temp), points))
        primary = next(
            row for row in result["gates"]
            if row["gate_id"] == "arch-315:architecture_primary_saving"
        )
        self.assertEqual(primary["status"], "BLOCKED")
        self.assertLess(Decimal(primary["value"]), Decimal("10"))
        self.assertFalse(result["promotion_eligible"])

    def test_tampered_derived_csvs_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            content = (root / "comparisons.csv").read_text(encoding="utf-8")
            (root / "comparisons.csv").write_text(content.replace("-10", "-9", 1), encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "comparison is not"):
                evidence.validate(root)
        with tempfile.TemporaryDirectory() as temp:
            root = write_package(Path(temp), gating_points())
            content = (root / "classifications.csv").read_text(encoding="utf-8")
            (root / "classifications.csv").write_text(content.replace("CG_MAPPED_POSITIVE", "CG_NEGATIVE_LOW_COVERAGE"), encoding="utf-8")
            with self.assertRaisesRegex(evidence.ValidationError, "classification is not"):
                evidence.validate(root)

    def test_negative_result_remains_valid_but_promotion_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            points = gating_points()
            for item in points:
                if item["variant"] == "G1":
                    item["gated_bits"] = "100"
                    item["eligible_sequential_bits"] = "100"
            result = evidence.validate(write_package(Path(temp), points))
            self.assertFalse(result["promotion_eligible"])
            self.assertEqual(result["classifications"][0]["classification"], "CG_NEGATIVE_LOW_COVERAGE")


if __name__ == "__main__":
    unittest.main()
