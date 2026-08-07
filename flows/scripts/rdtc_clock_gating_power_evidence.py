#!/usr/bin/env python3
"""Validate the sanitized RDTC mapped clock-gating power package."""

from __future__ import print_function

import argparse
import csv
import hashlib
import io
import json
import re
import sys
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP, getcontext
from pathlib import Path


getcontext().prec = 28

SCHEMA = "rdtc-clock-gating-mapped-dc-public-v1"
PACKAGE_REL = Path("evidence/rdtc_v1_clock_gating_mapped_dc")
POINT_IDS = (
    "G0_IDLE", "G0_BURST_IDLE", "G0_ACTIVE_LEGAL",
    "G1_IDLE", "G1_BURST_IDLE", "G1_ACTIVE_LEGAL",
)
WORKLOADS = ("IDLE", "BURST_IDLE", "ACTIVE_LEGAL")
ACTIVITY_CATEGORIES = (
    "clocks", "functional_inputs", "sequential_outputs",
    "internal_leaf_pins", "overall_non_default",
)
REPORT_NAMES = (
    "area", "check_design", "check_timing", "clock_gating", "constraint",
    "coverage_clocks", "coverage_inputs", "coverage_leaf_pins",
    "coverage_sequential", "power", "power_groups", "power_hierarchy",
    "qor", "timing_hold", "timing_setup",
)
VERIFICATION_IDS = (
    "authority_hash_chain", "mapped_artifact_identity", "equivalence_2",
    "equivalence_32", "equivalence_64", "activity_six_point",
    "implementation_g0", "implementation_g1", "icg_model",
    "parser_recovery", "release_audit",
)
VERIFICATION_CONTRACTS = {
    "authority_hash_chain": ("package", "provenance", "sha256_recompute"),
    "mapped_artifact_identity": ("G0_G1", "identity", "paired_compile_handoff"),
    "equivalence_2": ("MINIMAL_TWO_BLOCK", "functional", "gate-level regression equivalence evidence"),
    "equivalence_32": ("BURST_IDLE", "functional", "gate-level regression equivalence evidence"),
    "equivalence_64": ("ACTIVE_LEGAL", "functional", "gate-level regression equivalence evidence"),
    "activity_six_point": ("G0_G1", "activity", "mapped_zero_delay"),
    "implementation_g0": ("G0", "implementation", "mapped_dc"),
    "implementation_g1": ("G1", "implementation", "mapped_dc_gate_clock"),
    "icg_model": ("CLKGATETST_X1", "model", "exact_model_and_canary"),
    "parser_recovery": ("power", "parser", "immutable_report_reparse"),
    "release_audit": ("power", "ownership", "process_group_release"),
}
HIERARCHIES = ("__ROOT__", "engine0", "engine1", "ring", "bitpacker", "prefix_k", "output_fifo")
CLOCK_GATING_KEYS = (
    ("G0", "icg_count"),
    ("G1", "icg_count"),
    ("G1", "gated_bits"),
    ("G1", "postmap_sequential_bits"),
    ("G1", "gated_pct_of_postmap_sequential_bits"),
    ("G1", "precompile_register_bits"),
    ("G1", "gated_pct_of_precompile_register_bits"),
    ("G0", "mapped_sequential_cells"),
    ("G1", "mapped_sequential_cells"),
    ("G1", "ring_gated_bits"),
    ("G1", "ring_total_bits"),
    ("G1", "ring_coverage_pct"),
    ("G1", "gating_setup_wns"),
    ("G1", "gating_hold_wns"),
)
SDC_REPLAY_ACCEPTED_CHECKS = (
    "DDC constraints retained",
    "mapped SDC hash matched",
    "clock count and period matched",
    "operating condition matched",
    "setup WNS and TNS passed",
    "electrical violations zero",
    "check_timing passed",
)
PACKAGE_FILES = frozenset((
    "README.md", "manifest.json", "source_contract.json", "points.csv",
    "comparisons.csv", "gates.csv", "classifications.csv",
    "hierarchy_power.csv", "clock_gating.csv", "activity_coverage.csv",
    "equivalence.csv", "verification.csv", "report_hashes.csv",
    "model_audit.json", "parser_recovery.json", "input_hashes.sha256",
    "output_hashes.sha256",
))
POINT_FIELDS = (
    "point_id", "variant", "workload", "status", "top", "profile",
    "source_bundle", "source_set_sha256", "library_id", "library_sha256",
    "sdc_sha256", "mapped_ddc_sha256", "mapped_netlist_sha256",
    "mapped_sdc_sha256", "activity_method", "drive_mode", "test_enable",
    "activity_sha256", "normalized_trace_sha256", "window_cycles",
    "blocks_completed", "raw_bytes", "compressed_bytes",
    "clock_coverage_pct", "functional_input_coverage_pct",
    "sequential_output_coverage_pct", "internal_leaf_pin_coverage_pct",
    "overall_nondefault_coverage_pct", "default_toggle_rate",
    "default_static_probability", "area_total_um2", "area_combinational_um2",
    "area_sequential_um2", "cell_count", "sequential_cell_count",
    "setup_wns_ns", "setup_tns_ns", "electrical_violations", "icg_count",
    "gated_bits", "ring_gated_bits", "ring_total_bits",
    "gating_setup_wns_ns", "gating_hold_wns_ns", "dynamic_mw", "internal_mw",
    "switching_mw", "leakage_mw", "total_mw", "energy_per_block_nj",
    "dynamic_energy_per_block_nj", "clock_mw", "sequential_power_mw",
    "combinational_power_mw",
)
COMPARISON_FIELDS = (
    "comparison_id", "workload", "baseline_point", "candidate_point", "metric",
    "baseline", "candidate", "delta", "percent_change", "formula", "status",
)
GATE_FIELDS = ("gate_id", "status", "value", "threshold", "unit", "reason")
CLOCK_GATING_FIELDS = (
    "variant", "metric", "value", "unit", "denominator",
    "denominator_kind", "status",
)
ACTIVITY_FIELDS = (
    "point_id", "category", "annotated_pct", "default_toggle_rate",
    "default_static_probability", "activity_method", "status",
)
EQUIVALENCE_FIELDS = (
    "workload", "blocks", "method", "test_enable", "packet_trace_sha256",
    "decoder_trace_sha256", "status",
)
HIERARCHY_FIELDS = (
    "point_id", "hierarchy", "internal_mw", "switching_mw", "leakage_mw",
    "total_mw", "status",
)
CLASSIFICATION_FIELDS = (
    "classification_id", "two_c_decision", "mapped_power_classification",
    "promotion_classification", "branch_ready", "production_rtl_changed",
    "formality_status", "equivalence_method", "status", "reason",
)
VERIFICATION_FIELDS = (
    "verification_id", "scope", "kind", "method", "evidence_sha256",
    "required", "status", "notes",
)
REPORT_FIELDS = (
    "point_id", "logical_report_name", "sha256", "byte_count", "sanitizer_status",
)
POWER_METRICS = (
    "dynamic_mw", "internal_mw", "switching_mw", "leakage_mw", "total_mw",
    "energy_per_block_nj", "dynamic_energy_per_block_nj", "clock_mw",
    "sequential_power_mw", "combinational_power_mw",
)
IMPLEMENTATION_METRICS = (
    "area_total_um2", "area_combinational_um2", "area_sequential_um2",
    "cell_count", "sequential_cell_count", "setup_wns_ns", "setup_tns_ns",
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN_PUBLIC_PATTERNS = (
    re.compile(r"(?i)(?:[a-z]:[/\\]|/home/|/mnt/[a-z]/|license[_ -]?server)"),
    re.compile(r"(?i)\.(?:saif|vcd|ddc|svf|spef|sdf|def|odb|gds)(?:\b|$)"),
    re.compile(r"(?i)(?:D:/master|\\master\\project|/home/ICer|private_snapshot)"),
)
OVERCLAIM_PATTERNS = (
    re.compile(r"(?i)Formality\s+PASS|formal\s+LEC|exhaustive\s+equivalence"),
    re.compile(r"(?i)post[- ]route\s+power\s+(?:result|reduction|saving)"),
    re.compile(r"(?i)PrimeTime[- ]PX\s+(?:PASS|result)"),
    re.compile(r"(?i)100%\s+(?:code|functional|assertion|test)\s+coverage"),
    re.compile(r"(?i)cumulative\s+(?:power\s+)?(?:reduction|saving)"),
)


class ValidationError(Exception):
    pass


def _pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError("duplicate JSON key: {}".format(key))
        result[key] = value
    return result


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs_no_duplicates)
    except (OSError, ValueError) as exc:
        if isinstance(exc, ValidationError):
            raise
        raise ValidationError("cannot parse {}: {}".format(path, exc))


def read_csv(path, fields, unique_field=None):
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if tuple(reader.fieldnames or ()) != tuple(fields):
                raise ValidationError("unexpected CSV header in {}".format(path.name))
            rows = list(reader)
    except OSError as exc:
        raise ValidationError("cannot read {}: {}".format(path, exc))
    seen = set()
    for index, row in enumerate(rows):
        if None in row or any(value == "" for value in row.values()):
            raise ValidationError("empty or extra CSV field in {} row {}".format(path.name, index + 2))
        if unique_field:
            value = row[unique_field]
            if value in seen:
                raise ValidationError("duplicate {} {} in {}".format(unique_field, value, path.name))
            seen.add(value)
    return rows


def write_csv(path, fields, rows):
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    path.write_text(buffer.getvalue(), encoding="utf-8", newline="\n")


def decimal(value, label):
    if value == "NA":
        return None
    try:
        return Decimal(str(value))
    except InvalidOperation:
        raise ValidationError("{} is not a decimal: {}".format(label, value))


def decimal_text(value):
    if value is None:
        return "NA"
    if value == 0:
        return "0"
    text = format(value, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


def percent_change(baseline, candidate):
    if baseline is None or candidate is None or baseline == 0:
        return None
    return (candidate - baseline) * Decimal("100") / baseline


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_hash_manifest(path):
    rows = []
    for index, line in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.:/+-]+)", line)
        if not match:
            raise ValidationError("invalid hash manifest line {} in {}".format(index, path.name))
        rows.append((match.group(2), match.group(1)))
    names = [name for name, _ in rows]
    if names != sorted(names) or len(names) != len(set(names)):
        raise ValidationError("hash manifest {} is not uniquely sorted".format(path.name))
    return dict(rows)


def package_path(root):
    return Path(root).resolve() / PACKAGE_REL


def point_map(points):
    return {row["point_id"]: row for row in points}


def expected_comparisons(points):
    by_id = point_map(points)
    rows = []
    for workload in WORKLOADS:
        baseline_id = "G0_{}".format(workload)
        candidate_id = "G1_{}".format(workload)
        baseline_row, candidate_row = by_id[baseline_id], by_id[candidate_id]
        for metric in POWER_METRICS:
            baseline = decimal(baseline_row[metric], "{} {}".format(baseline_id, metric))
            candidate = decimal(candidate_row[metric], "{} {}".format(candidate_id, metric))
            delta = None if baseline is None or candidate is None else candidate - baseline
            rows.append({
                "comparison_id": "{}:{}".format(workload, metric),
                "workload": workload,
                "baseline_point": baseline_id,
                "candidate_point": candidate_id,
                "metric": metric,
                "baseline": decimal_text(baseline),
                "candidate": decimal_text(candidate),
                "delta": decimal_text(delta),
                "percent_change": decimal_text(percent_change(baseline, candidate)),
                "formula": "candidate-baseline;100*(candidate-baseline)/baseline",
                "status": "PASS",
            })
    baseline_id, candidate_id = "G0_IDLE", "G1_IDLE"
    for metric in IMPLEMENTATION_METRICS:
        baseline = decimal(by_id[baseline_id][metric], metric)
        candidate = decimal(by_id[candidate_id][metric], metric)
        rows.append({
            "comparison_id": "IMPLEMENTATION:{}".format(metric),
            "workload": "IMPLEMENTATION",
            "baseline_point": baseline_id,
            "candidate_point": candidate_id,
            "metric": metric,
            "baseline": decimal_text(baseline),
            "candidate": decimal_text(candidate),
            "delta": decimal_text(candidate - baseline),
            "percent_change": decimal_text(percent_change(baseline, candidate)),
            "formula": "candidate-baseline;100*(candidate-baseline)/baseline",
            "status": "PASS",
        })
    return rows


def _saving(comparisons, workload, metric):
    row = next(row for row in comparisons if row["workload"] == workload and row["metric"] == metric)
    return -decimal(row["percent_change"], "comparison percent")


def expected_gates(points, comparisons):
    by_id = point_map(points)
    g1 = by_id["G1_BURST_IDLE"]
    gated_bits = decimal(g1["gated_bits"], "gated_bits")
    postmap_bits = Decimal("50988")
    ring_bits = decimal(g1["ring_gated_bits"], "ring_gated_bits")
    ring_total = decimal(g1["ring_total_bits"], "ring_total_bits")
    area_delta = next(row for row in comparisons if row["comparison_id"] == "IMPLEMENTATION:area_total_um2")
    checks = (
        ("equivalence", Decimal("1"), Decimal("1"), "bool", "three_regressions_pass"),
        ("activity_coverage", Decimal("100"), Decimal("90"), "percent", "all_categories_at_or_above_threshold"),
        ("icg_inserted", decimal(g1["icg_count"], "icg_count"), Decimal("1"), "cells", "integrated_clock_gates_present"),
        ("gated_bits", gated_bits, Decimal("8192"), "bits", "minimum_gated_state"),
        ("gated_pct_postmap", gated_bits * 100 / postmap_bits, Decimal("20"), "percent", "postmap_register_bit_denominator"),
        ("ring_coverage", ring_bits * 100 / ring_total, Decimal("50"), "percent", "ring_data_bank_coverage"),
        ("burst_dynamic_saving", _saving(comparisons, "BURST_IDLE", "dynamic_mw"), Decimal("5"), "percent", "primary_workload_dynamic_saving"),
        ("burst_sequential_saving", _saving(comparisons, "BURST_IDLE", "sequential_power_mw"), Decimal("10"), "percent", "primary_workload_sequential_saving"),
        ("burst_internal_saving", _saving(comparisons, "BURST_IDLE", "internal_mw"), Decimal("10"), "percent", "primary_workload_internal_saving"),
        ("burst_energy_saving", _saving(comparisons, "BURST_IDLE", "energy_per_block_nj"), Decimal("5"), "percent", "primary_workload_energy_saving"),
        ("active_dynamic_regression", decimal(next(r for r in comparisons if r["comparison_id"] == "ACTIVE_LEGAL:dynamic_mw")["percent_change"], "active dynamic"), Decimal("1.5"), "percent", "maximum_allowed_regression"),
        ("area_overhead", decimal(area_delta["percent_change"], "area delta"), Decimal("3"), "percent", "maximum_allowed_overhead"),
        ("g0_setup_wns", decimal(by_id["G0_IDLE"]["setup_wns_ns"], "g0 wns"), Decimal("0"), "ns", "setup_closed"),
        ("g1_setup_wns", decimal(by_id["G1_IDLE"]["setup_wns_ns"], "g1 wns"), Decimal("0"), "ns", "setup_closed"),
        ("setup_tns", max(decimal(by_id["G0_IDLE"]["setup_tns_ns"], "g0 tns"), decimal(by_id["G1_IDLE"]["setup_tns_ns"], "g1 tns")), Decimal("0"), "ns", "zero_tns"),
        ("electrical", Decimal(str(max(int(by_id["G0_IDLE"]["electrical_violations"]), int(by_id["G1_IDLE"]["electrical_violations"])))), Decimal("0"), "violations", "zero_electrical_violations"),
        ("gating_setup_wns", decimal(g1["gating_setup_wns_ns"], "gating setup"), Decimal("0"), "ns", "clock_gating_setup_closed"),
        ("gating_hold_wns", decimal(g1["gating_hold_wns_ns"], "gating hold"), Decimal("0"), "ns", "clock_gating_hold_closed"),
    )
    rows = []
    for gate_id, value, threshold, unit, reason in checks:
        if gate_id in ("active_dynamic_regression", "area_overhead"):
            passed = value <= threshold
        elif gate_id in ("setup_tns", "electrical"):
            passed = value == threshold
        else:
            passed = value >= threshold
        rows.append({
            "gate_id": gate_id, "status": "PASS" if passed else "FAIL",
            "value": decimal_text(value), "threshold": decimal_text(threshold),
            "unit": unit, "reason": reason,
        })
    return rows


def validate_package(root):
    package = package_path(root)
    if not package.is_dir():
        raise ValidationError("missing package {}".format(package))
    actual_files = frozenset(path.name for path in package.iterdir() if path.is_file())
    if actual_files != PACKAGE_FILES:
        raise ValidationError("package inventory mismatch: missing={} extra={}".format(
            sorted(PACKAGE_FILES - actual_files), sorted(actual_files - PACKAGE_FILES)))

    manifest = load_json(package / "manifest.json")
    if manifest.get("schema") != SCHEMA:
        raise ValidationError("wrong manifest schema")
    if manifest.get("point_order") != list(POINT_IDS):
        raise ValidationError("wrong manifest point order")
    if manifest.get("two_c_decision") != "CG_EQUIVALENCE_RECOVERED_MAPPED_POWER_COMPLETE":
        raise ValidationError("wrong private final decision")
    if manifest.get("promotion_classification") != "MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE":
        raise ValidationError("wrong mapped-power promotion")

    source = load_json(package / "source_contract.json")
    expected_source = {
        "schema": SCHEMA,
        "design_source_authority": "c803374c581f7e8e1beb1f735d7176fcd6dbaab4",
        "r1_flow_authority": "a6424534c11e8d57f366c9768234239f682d4f64",
        "mapped_source_bundle": "db2660c60795182b647bd3c31010b0be6aef6374",
        "private_flow_head": "6a3b178dc9d9a075e93efeab59980ffb2ad89cb0",
        "top": "mrtc_rdtc_bounded_axis_multiengine_wrapper",
        "source_set_sha256": "c32e780aad70dd3414e13c0509e8cdc2969e6c4afb6ef24fc2ef1d47c3f24a8d",
        "filelist_sha256": "b91c3c803b3a1617b7eacda31c08d4813c80d1f00e869a966c5718a58b8dcd83",
        "sdc_sha256": "d49d2eeb1727ff8bc682783e14db317d8616938242b8bba98b76629341f96b25",
        "library_db_sha256": "c6da1f0e7a7f445c0476d1e6bf6860c9815fe4f50c9ce138264a581af59e4cb5",
        "library_lef_sha256": "840b01e500826096d1edcc752350834da647fdbf360798f243f8122b52b357c3",
        "library_liberty_sha256": "8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1",
        "common_checkpoint_sha256": "4eae020f6c4f27b69e3da9c6adddaa6e98b0f607121ec722f2f4fdb3ec972b99",
        "icg_model_sha256": "2241df05c6a73a05e9630864f48962e6eb35e2d766ec391dbf8c77d2f45ae2d6",
        "technology": "Nangate45 academic standard-cell library",
        "corner": "TT / 1.1 V / 25 C",
        "engines": 2,
        "profile": "Direct-AXIS register-expanded",
        "retiming": "disabled",
        "formality_status": "NOT_RUN_NO_REVIEWED_SETUP",
        "equivalence_method": "gate-level regression equivalence evidence",
        "functional_test_enable": 0,
    }
    for key, expected in expected_source.items():
        if source.get(key) != expected:
            raise ValidationError("source contract mismatch for {}".format(key))
    if source.get("frequency_mhz") != "315" or source.get("period_ns") != "3.174603":
        raise ValidationError("frequency/period mismatch")
    if source.get("power_maturity") != "activity-driven mapped-netlist estimate":
        raise ValidationError("wrong power maturity")
    sdc_replay = source.get("sdc_replay", {})
    if sdc_replay.get("classification") != "MAPPED_SDC_VECTOR_REPLAY_ERRORS_DDC_CONSTRAINTS_PRESERVED":
        raise ValidationError("missing SDC replay classification")
    if sdc_replay.get("uid95_cmd036_pairs") != 8136:
        raise ValidationError("wrong SDC replay count")
    if sdc_replay.get("portable_handoff_claim") is not False:
        raise ValidationError("mapped SDC must not claim a portable handoff")
    if sdc_replay.get("fatal_errors") != 0:
        raise ValidationError("mapped SDC replay fatal-error count mismatch")
    if sdc_replay.get("accepted_checks") != list(SDC_REPLAY_ACCEPTED_CHECKS):
        raise ValidationError("mapped SDC replay acceptance-check inventory mismatch")

    points = read_csv(package / "points.csv", POINT_FIELDS, "point_id")
    if [row["point_id"] for row in points] != list(POINT_IDS):
        raise ValidationError("wrong point IDs or ordering")
    by_id = point_map(points)
    expected_blocks = {"IDLE": "0", "BURST_IDLE": "32", "ACTIVE_LEGAL": "64"}
    expected_windows = {"IDLE": "4096", "BURST_IDLE": "14373", "ACTIVE_LEGAL": "20493"}
    expected_artifacts = {
        "G0": ("175f539124a9ab8e5499748b0a07d37c0681abeb046ced7a4a4cc7dc47426ae8", "100dea79a0f8152a4ce378384058c122225c78eaad9802c49d2f649d3a5aeba0", "a6deda50d1757a71197a8c5e08497f76dd216f4943f1b527c813d17eb427c0d5"),
        "G1": ("dbe1027ae53ff25103b5a46c4f9a168185f1fa46fae2c9ae781150457bf67ac8", "63565ad180f7282f3ff1598b8853d7f52beb9277fbd40eab469e268d7272bf1f", "b3090333b1b03cd383d131de06b30f96d608a253a350d904ff35a35193904328"),
    }
    saifs = set()
    for row in points:
        variant, workload = row["variant"], row["workload"]
        if row["point_id"] != "{}_{}".format(variant, workload):
            raise ValidationError("point identity mismatch")
        if row["status"] != "PASS" or row["activity_method"] != "mapped_zero_delay" or row["drive_mode"] != "RACE_FREE_DRIVE" or row["test_enable"] != "0":
            raise ValidationError("invalid activity contract for {}".format(row["point_id"]))
        if row["blocks_completed"] != expected_blocks[workload] or row["window_cycles"] != expected_windows[workload]:
            raise ValidationError("workload count/window mismatch for {}".format(row["point_id"]))
        if tuple(row[key] for key in ("mapped_ddc_sha256", "mapped_netlist_sha256", "mapped_sdc_sha256")) != expected_artifacts[variant]:
            raise ValidationError("mapped artifact mismatch for {}".format(row["point_id"]))
        if row["activity_sha256"] in saifs or not SHA256_RE.fullmatch(row["activity_sha256"]):
            raise ValidationError("reused or invalid SAIF hash")
        saifs.add(row["activity_sha256"])
        for key in ("clock_coverage_pct", "functional_input_coverage_pct", "sequential_output_coverage_pct", "internal_leaf_pin_coverage_pct", "overall_nondefault_coverage_pct"):
            if decimal(row[key], key) != Decimal("100"):
                raise ValidationError("activity coverage below canonical value")
        if decimal(row["default_toggle_rate"], "default toggle") != 0 or decimal(row["default_static_probability"], "default static") != 0:
            raise ValidationError("nonzero default activity")
        if by_id["G0_{}".format(workload)]["normalized_trace_sha256"] != by_id["G1_{}".format(workload)]["normalized_trace_sha256"]:
            raise ValidationError("normalized trace mismatch for {}".format(workload))
        if int(row["electrical_violations"]) != 0 or decimal(row["setup_wns_ns"], "wns") < 0 or decimal(row["setup_tns_ns"], "tns") != 0:
            raise ValidationError("implementation gate failed for {}".format(row["point_id"]))
        if workload != "IDLE":
            blocks = decimal(row["blocks_completed"], "blocks")
            cycles = decimal(row["window_cycles"], "cycles")
            expected_energy = decimal(row["total_mw"], "total") * cycles / Decimal("315") / blocks
            expected_dynamic_energy = decimal(row["dynamic_mw"], "dynamic") * cycles / Decimal("315") / blocks
            if decimal(row["energy_per_block_nj"], "energy") != expected_energy or decimal(row["dynamic_energy_per_block_nj"], "dynamic energy") != expected_dynamic_energy:
                raise ValidationError("energy recomputation mismatch for {}".format(row["point_id"]))
    implementation_authority = {
        "G0": {
            "area_total_um2": "420208.442440", "cell_count": "220298",
            "sequential_cell_count": "50999", "setup_wns_ns": "0.093015",
            "setup_tns_ns": "0", "electrical_violations": "0",
        },
        "G1": {
            "area_total_um2": "354760.204745", "cell_count": "149697",
            "sequential_cell_count": "51271", "setup_wns_ns": "0.0151572",
            "setup_tns_ns": "0", "electrical_violations": "0",
            "gating_setup_wns_ns": "1.4645", "gating_hold_wns_ns": "0.18546",
        },
    }
    power_authority = {
        "G0_IDLE": ("66.9676", "75.507", "NA"),
        "G0_BURST_IDLE": ("107.3535", "115.4", "164.5480357142857142857142857"),
        "G0_ACTIVE_LEGAL": ("107.2775", "115.3", "117.2045089285714285714285714"),
        "G1_IDLE": ("27.7229", "34.826", "NA"),
        "G1_BURST_IDLE": ("41.1522", "47.942", "68.36015535714285714285714284"),
        "G1_ACTIVE_LEGAL": ("43.4293", "50.209", "51.03834508928571428571428572"),
    }
    for row in points:
        for field, expected in implementation_authority[row["variant"]].items():
            if row[field] != expected:
                raise ValidationError("implementation authority mismatch for {} {}".format(row["point_id"], field))
        if tuple(row[field] for field in ("dynamic_mw", "total_mw", "energy_per_block_nj")) != power_authority[row["point_id"]]:
            raise ValidationError("power authority mismatch for {}".format(row["point_id"]))
    if len(saifs) != 6:
        raise ValidationError("six unique SAIF hashes required")
    if by_id["G0_IDLE"]["icg_count"] != "0" or by_id["G0_IDLE"]["gated_bits"] != "0":
        raise ValidationError("G0 contains clock gating")
    if by_id["G1_IDLE"]["icg_count"] != "272" or by_id["G1_IDLE"]["gated_bits"] != "34816":
        raise ValidationError("G1 clock-gating count mismatch")

    comparisons = read_csv(package / "comparisons.csv", COMPARISON_FIELDS, "comparison_id")
    if comparisons != expected_comparisons(points):
        raise ValidationError("comparisons.csv is not deterministic")
    comparison_authority = {
        "IMPLEMENTATION:area_total_um2": "-15.57518390515086101419547671",
        "IDLE:dynamic_mw": "-58.60251823269760301996786506",
        "IDLE:total_mw": "-53.87712397526057186750897268",
        "BURST_IDLE:dynamic_mw": "-61.66664337911665665302016236",
        "BURST_IDLE:total_mw": "-58.45580589254766031195840555",
        "BURST_IDLE:energy_per_block_nj": "-58.45580589254766031195840555",
        "BURST_IDLE:sequential_power_mw": "-61.4079288625416821044831419",
        "BURST_IDLE:internal_mw": "-63.09793024147182828669988501",
        "BURST_IDLE:switching_mw": "-11.80242460675283037771766356",
        "BURST_IDLE:leakage_mw": "-15.53004390601873157626338636",
        "ACTIVE_LEGAL:dynamic_mw": "-59.51686047866514413553634266",
        "ACTIVE_LEGAL:total_mw": "-56.45359930615784908933217693",
    }
    comparison_by_id = {row["comparison_id"]: row for row in comparisons}
    for comparison_id, expected in comparison_authority.items():
        if comparison_by_id[comparison_id]["percent_change"] != expected:
            raise ValidationError("comparison authority mismatch for {}".format(comparison_id))
    gates = read_csv(package / "gates.csv", GATE_FIELDS, "gate_id")
    expected_gate_rows = expected_gates(points, comparisons)
    if gates != expected_gate_rows or any(row["status"] != "PASS" for row in gates):
        raise ValidationError("gates.csv is not deterministic or has a failed gate")

    clock_rows = read_csv(package / "clock_gating.csv", CLOCK_GATING_FIELDS)
    if [(row["variant"], row["metric"]) for row in clock_rows] != list(CLOCK_GATING_KEYS):
        raise ValidationError("clock-gating metric inventory mismatch")
    if any(row["status"] != "PASS" for row in clock_rows):
        raise ValidationError("clock-gating metric status failed")
    clock_by_metric = {(row["variant"], row["metric"]): row for row in clock_rows}
    required_clock = {
        ("G1", "icg_count"): "272", ("G1", "gated_bits"): "34816",
        ("G1", "postmap_sequential_bits"): "50988",
        ("G1", "precompile_register_bits"): "55929",
        ("G0", "mapped_sequential_cells"): "50999",
        ("G1", "mapped_sequential_cells"): "51271",
        ("G1", "ring_gated_bits"): "32768", ("G1", "ring_total_bits"): "32768",
    }
    for key, value in required_clock.items():
        if clock_by_metric.get(key, {}).get("value") != value:
            raise ValidationError("clock-gating denominator/count mismatch for {}".format(key))
    post_pct = decimal(clock_by_metric[("G1", "gated_pct_of_postmap_sequential_bits")]["value"], "postmap pct")
    pre_pct = decimal(clock_by_metric[("G1", "gated_pct_of_precompile_register_bits")]["value"], "precompile pct")
    if post_pct != Decimal("34816") * 100 / Decimal("50988") or pre_pct != Decimal("34816") * 100 / Decimal("55929"):
        raise ValidationError("clock-gating percentage denominator drift")

    activity = read_csv(package / "activity_coverage.csv", ACTIVITY_FIELDS)
    actual_activity_pairs = [(row["point_id"], row["category"]) for row in activity]
    expected_activity_pairs = [
        (point_id, category)
        for point_id in POINT_IDS
        for category in ACTIVITY_CATEGORIES
    ]
    if actual_activity_pairs != expected_activity_pairs:
        raise ValidationError("activity coverage matrix must match the exact point/category product")
    for row in activity:
        if row["point_id"] not in POINT_IDS or row["annotated_pct"] != "100" or row["default_toggle_rate"] != "0" or row["default_static_probability"] != "0" or row["activity_method"] != "mapped_zero_delay" or row["status"] != "PASS":
            raise ValidationError("invalid activity coverage row")

    equivalence = read_csv(package / "equivalence.csv", EQUIVALENCE_FIELDS, "workload")
    if [row["workload"] for row in equivalence] != ["MINIMAL_TWO_BLOCK", "BURST_IDLE", "ACTIVE_LEGAL"]:
        raise ValidationError("equivalence workload order mismatch")
    if [row["blocks"] for row in equivalence] != ["2", "32", "64"]:
        raise ValidationError("equivalence block count mismatch")
    for row in equivalence:
        if row["method"] != "gate-level regression equivalence evidence" or row["test_enable"] != "0" or row["status"] != "PASS":
            raise ValidationError("invalid equivalence evidence")
        if not SHA256_RE.fullmatch(row["packet_trace_sha256"]) or not SHA256_RE.fullmatch(row["decoder_trace_sha256"]):
            raise ValidationError("invalid equivalence hash")

    classifications = read_csv(package / "classifications.csv", CLASSIFICATION_FIELDS, "classification_id")
    expected_classification = {
        "classification_id": "direct_clock_gating_mapped_dc315",
        "two_c_decision": "CG_EQUIVALENCE_RECOVERED_MAPPED_POWER_COMPLETE",
        "mapped_power_classification": "CG_MAPPED_POWER_POSITIVE",
        "promotion_classification": "MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE",
        "branch_ready": "YES",
        "production_rtl_changed": "NO",
        "formality_status": "NOT_RUN_NO_REVIEWED_SETUP",
        "equivalence_method": "gate-level regression equivalence evidence",
        "status": "PASS",
        "reason": "all_mapped_clock_gating_promotion_gates_pass",
    }
    if classifications != [expected_classification]:
        raise ValidationError("classification mismatch")
    hierarchy = read_csv(package / "hierarchy_power.csv", HIERARCHY_FIELDS)
    expected_hierarchy_pairs = [
        (point_id, hierarchy_name)
        for point_id in POINT_IDS
        for hierarchy_name in HIERARCHIES
    ]
    if [(row["point_id"], row["hierarchy"]) for row in hierarchy] != expected_hierarchy_pairs:
        raise ValidationError("curated hierarchy inventory mismatch")
    for row in hierarchy:
        if row["status"] != "PASS" or any(decimal(row[field], field) < 0 for field in ("internal_mw", "switching_mw", "leakage_mw", "total_mw")):
            raise ValidationError("invalid hierarchy power row")
        if row["hierarchy"] == "__ROOT__":
            point = by_id[row["point_id"]]
            if any(row[field] != point[field] for field in ("internal_mw", "switching_mw", "leakage_mw", "total_mw")):
                raise ValidationError("root hierarchy power does not match point result")
    verification = read_csv(package / "verification.csv", VERIFICATION_FIELDS, "verification_id")
    if [row["verification_id"] for row in verification] != list(VERIFICATION_IDS):
        raise ValidationError("verification inventory mismatch")
    if any(row["required"] != "YES" or row["status"] != "PASS" for row in verification):
        raise ValidationError("mandatory verification failed")
    if any(not SHA256_RE.fullmatch(row["evidence_sha256"]) for row in verification):
        raise ValidationError("invalid verification evidence hash")
    for row in verification:
        if tuple(row[field] for field in ("scope", "kind", "method")) != VERIFICATION_CONTRACTS[row["verification_id"]]:
            raise ValidationError("verification contract mismatch for {}".format(row["verification_id"]))
    verification_by_id = {row["verification_id"]: row for row in verification}
    equivalence_verification_ids = {
        "MINIMAL_TWO_BLOCK": "equivalence_2",
        "BURST_IDLE": "equivalence_32",
        "ACTIVE_LEGAL": "equivalence_64",
    }
    for row in equivalence:
        verification_row = verification_by_id[equivalence_verification_ids[row["workload"]]]
        if verification_row["evidence_sha256"] != row["packet_trace_sha256"]:
            raise ValidationError("equivalence trace hash does not match verification record")
        if verification_row["scope"] != row["workload"] or verification_row["kind"] != "functional" or verification_row["method"] != row["method"]:
            raise ValidationError("equivalence verification contract mismatch")
    reports = read_csv(package / "report_hashes.csv", REPORT_FIELDS)
    actual_report_pairs = [(row["point_id"], row["logical_report_name"]) for row in reports]
    expected_report_pairs = [
        (point_id, report_name)
        for point_id in POINT_IDS
        for report_name in REPORT_NAMES
    ]
    if actual_report_pairs != expected_report_pairs:
        raise ValidationError("report hash inventory must match the exact point/report product")
    for row in reports:
        if row["point_id"] not in POINT_IDS or not SHA256_RE.fullmatch(row["sha256"]) or int(row["byte_count"]) <= 0 or row["sanitizer_status"] != "HASH_ONLY_PASS":
            raise ValidationError("invalid report hash row")
        if any(token in row["logical_report_name"] for token in ("/", "\\", ":")):
            raise ValidationError("report path leaked through logical name")

    model = load_json(package / "model_audit.json")
    if model.get("classification") != "EXACT_EXPECTED_MODEL" or model.get("effective_definition_count") != 1 or model.get("duplicate_or_shadow_count") != 0 or model.get("pins") != ["CK", "E", "SE", "GCK"] or model.get("canary_status") != "PASS" or model.get("canary_cases") != {case: "PASS" for case in "ABCDEF"} or model.get("timing_check_capability") != "NOT_SUPPORTED_BY_MODEL" or model.get("functional_test_enable") != 0 or model.get("diagnostic_test_enable") != 1 or model.get("diagnostic_test_enable_result") != "ONE_OUTPUT_MISMATCH_NON_PRODUCTION_DIAGNOSTIC" or model.get("functional_model_sha256") != source["icg_model_sha256"]:
        raise ValidationError("ICG model audit mismatch")
    parser = load_json(package / "parser_recovery.json")
    if parser.get("classification") != "PARSER_FALSE_POSITIVE_RECOVERED_FROM_IMMUTABLE_REPORTS" or parser.get("point_order") != list(POINT_IDS) or parser.get("point_count") != 6 or parser.get("outer_exit_code") != 2 or parser.get("tool_exit_code") != 0 or parser.get("eda_rerun") is not False or parser.get("immutable_reports_reused") is not True or parser.get("ownership_residuals") != 0 or parser.get("release_status") != "FULL_RELEASED" or parser.get("status") != "PASS_WITH_PARSER_RECOVERY":
        raise ValidationError("parser-recovery evidence mismatch")

    input_hashes = read_hash_manifest(package / "input_hashes.sha256")
    required_inputs = {
        "private/mapped_power_result.json": "f602dffd709369a2ecb554bd41aba8f9701f1f3d08b64dec0d94c6c4ff7d64cc",
        "private/paired_compile_handoff.json": "111fabd0ad02cdb239bcb3ee33d8438f6c1b886b362af687aea3e7470d262da8",
        "private/equivalence_result.json": "c923a451b737e2cc047116aa7a5bf9971278c345875b41adb7309ae95a208d19",
    }
    for name, digest in required_inputs.items():
        if input_hashes.get(name) != digest:
            raise ValidationError("missing or wrong private authority hash {}".format(name))
    output_hashes = read_hash_manifest(package / "output_hashes.sha256")
    expected_output_names = sorted(PACKAGE_FILES - {"output_hashes.sha256"})
    if sorted(output_hashes) != expected_output_names:
        raise ValidationError("output hash inventory mismatch")
    for name, digest in output_hashes.items():
        if sha256_file(package / name) != digest:
            raise ValidationError("output hash mismatch for {}".format(name))

    public_text = "\n".join((package / name).read_text(encoding="utf-8", errors="strict") for name in sorted(PACKAGE_FILES))
    for pattern in FORBIDDEN_PUBLIC_PATTERNS + OVERCLAIM_PATTERNS:
        if pattern.search(public_text):
            raise ValidationError("forbidden public content matched: {}".format(pattern.pattern))
    return {"points": points, "comparisons": comparisons, "gates": gates}


def validate_doc_values(root):
    root = Path(root).resolve()
    files = (
        root / "README.md", root / "README.en.md",
        root / "docs/zh-CN/asic_clock_gating_experiment.md",
        root / "docs/en/asic_clock_gating_experiment.md",
    )
    for path in files:
        if not path.is_file():
            raise ValidationError("missing public document {}".format(path.relative_to(root)))
    comparisons = read_csv(package_path(root) / "comparisons.csv", COMPARISON_FIELDS, "comparison_id")
    by_comparison = {row["comparison_id"]: row for row in comparisons}
    metric_patterns = (
        ("IMPLEMENTATION:area_total_um2", r"(?:cell\s+area|area|\u9762\u79ef)[^\n]{0,120}"),
        ("BURST_IDLE:dynamic_mw", r"BURST_IDLE[^\n]{0,160}dynamic(?:(?!energy/block)[^\n]){0,120}"),
        ("BURST_IDLE:energy_per_block_nj", r"BURST_IDLE[^\n]{0,240}energy/block[^\n]{0,120}"),
        ("ACTIVE_LEGAL:dynamic_mw", r"ACTIVE_LEGAL[^\n]{0,160}dynamic[^\n]{0,120}"),
    )
    documents = {
        "zh-CN README": (files[0], "\u4e0d\u662f\u9a8c\u8bc1 test coverage"),
        "English README": (files[1], "not verification test coverage"),
        "zh-CN experiment": (files[2], "\u4e0d\u662f\u9a8c\u8bc1 test coverage"),
        "English experiment": (files[3], "not verification test coverage"),
    }
    for document_name, (path, coverage_boundary) in documents.items():
        text = path.read_text(encoding="utf-8")
        for comparison_id, label_pattern in metric_patterns:
            try:
                value = decimal(by_comparison[comparison_id]["percent_change"], comparison_id)
            except KeyError:
                raise ValidationError("comparisons.csv missing documentation metric {}".format(comparison_id))
            token = "{}%".format(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))
            pattern = re.compile(r"{}{}".format(label_pattern, re.escape(token)), re.IGNORECASE)
            if not pattern.search(text):
                raise ValidationError("{} missing bound documentation metric {}={}".format(document_name, comparison_id, token))
        if "Activity Annotation Coverage" not in text or coverage_boundary not in text:
            raise ValidationError("{} activity annotation coverage is not distinguished from test coverage".format(document_name))
        for pattern in OVERCLAIM_PATTERNS:
            if pattern.search(text):
                raise ValidationError("{} documentation overclaim matched: {}".format(document_name, pattern.pattern))
    return True


def regenerate(root, kind):
    package = package_path(root)
    points = read_csv(package / "points.csv", POINT_FIELDS, "point_id")
    if kind == "comparisons":
        write_csv(package / "comparisons.csv", COMPARISON_FIELDS, expected_comparisons(points))
    else:
        comparisons = expected_comparisons(points)
        write_csv(package / "gates.csv", GATE_FIELDS, expected_gates(points, comparisons))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "regenerate-comparisons", "regenerate-gates", "validate-doc-values"))
    parser.add_argument("--root", default=".", help="public repository root")
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            result = validate_package(args.root)
            print("PASS: schema={} points={} comparisons={} gates={}".format(
                SCHEMA, len(result["points"]), len(result["comparisons"]), len(result["gates"])))
        elif args.command == "validate-doc-values":
            validate_doc_values(args.root)
            print("PASS: clock-gating document values and boundaries")
        elif args.command == "regenerate-comparisons":
            regenerate(args.root, "comparisons")
            print("PASS: regenerated comparisons.csv")
        else:
            regenerate(args.root, "gates")
            print("PASS: regenerated gates.csv")
    except ValidationError as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
