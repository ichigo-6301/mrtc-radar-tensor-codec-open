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
from decimal import Decimal, InvalidOperation, getcontext
from pathlib import Path


getcontext().prec = 28

SCHEMA = "rdtc-clock-gating-mapped-dc-public-v1"
PACKAGE_REL = Path("evidence/rdtc_v1_clock_gating_mapped_dc")
POINT_IDS = (
    "G0_IDLE", "G0_BURST_IDLE", "G0_ACTIVE_LEGAL",
    "G1_IDLE", "G1_BURST_IDLE", "G1_ACTIVE_LEGAL",
)
WORKLOADS = ("IDLE", "BURST_IDLE", "ACTIVE_LEGAL")
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
    }
    for key, expected in expected_source.items():
        if source.get(key) != expected:
            raise ValidationError("source contract mismatch for {}".format(key))
    if source.get("frequency_mhz") != "315" or source.get("period_ns") != "3.174603":
        raise ValidationError("frequency/period mismatch")
    if source.get("power_maturity") != "activity-driven mapped-netlist estimate":
        raise ValidationError("wrong power maturity")
    if source.get("sdc_replay", {}).get("classification") != "MAPPED_SDC_VECTOR_REPLAY_ERRORS_DDC_CONSTRAINTS_PRESERVED":
        raise ValidationError("missing SDC replay classification")
    if source.get("sdc_replay", {}).get("uid95_cmd036_pairs") != 8136:
        raise ValidationError("wrong SDC replay count")

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
    if len(saifs) != 6:
        raise ValidationError("six unique SAIF hashes required")
    if by_id["G0_IDLE"]["icg_count"] != "0" or by_id["G0_IDLE"]["gated_bits"] != "0":
        raise ValidationError("G0 contains clock gating")
    if by_id["G1_IDLE"]["icg_count"] != "272" or by_id["G1_IDLE"]["gated_bits"] != "34816":
        raise ValidationError("G1 clock-gating count mismatch")

    comparisons = read_csv(package / "comparisons.csv", COMPARISON_FIELDS, "comparison_id")
    if comparisons != expected_comparisons(points):
        raise ValidationError("comparisons.csv is not deterministic")
    gates = read_csv(package / "gates.csv", GATE_FIELDS, "gate_id")
    expected_gate_rows = expected_gates(points, comparisons)
    if gates != expected_gate_rows or any(row["status"] != "PASS" for row in gates):
        raise ValidationError("gates.csv is not deterministic or has a failed gate")

    clock_rows = read_csv(package / "clock_gating.csv", CLOCK_GATING_FIELDS)
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
    if len(activity) != 30 or len({(row["point_id"], row["category"]) for row in activity}) != 30:
        raise ValidationError("activity coverage matrix must contain 30 unique rows")
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
    if len(classifications) != 1 or classifications[0]["two_c_decision"] != "CG_EQUIVALENCE_RECOVERED_MAPPED_POWER_COMPLETE" or classifications[0]["promotion_classification"] != "MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE" or classifications[0]["branch_ready"] != "YES" or classifications[0]["production_rtl_changed"] != "NO":
        raise ValidationError("classification mismatch")
    hierarchy = read_csv(package / "hierarchy_power.csv", HIERARCHY_FIELDS)
    required_hierarchies = {"__ROOT__", "engine0", "engine1", "ring", "bitpacker", "prefix_k", "output_fifo"}
    if {row["hierarchy"] for row in hierarchy} != required_hierarchies or {row["point_id"] for row in hierarchy} != set(POINT_IDS):
        raise ValidationError("curated hierarchy inventory mismatch")
    verification = read_csv(package / "verification.csv", VERIFICATION_FIELDS, "verification_id")
    if not verification or any(row["status"] != "PASS" for row in verification if row["required"] == "YES"):
        raise ValidationError("required verification failed")
    reports = read_csv(package / "report_hashes.csv", REPORT_FIELDS)
    for row in reports:
        if row["point_id"] not in POINT_IDS or not SHA256_RE.fullmatch(row["sha256"]) or int(row["byte_count"]) <= 0 or row["sanitizer_status"] != "HASH_ONLY_PASS":
            raise ValidationError("invalid report hash row")
        if any(token in row["logical_report_name"] for token in ("/", "\\", ":")):
            raise ValidationError("report path leaked through logical name")

    model = load_json(package / "model_audit.json")
    if model.get("classification") != "EXACT_EXPECTED_MODEL" or model.get("effective_definition_count") != 1 or model.get("duplicate_or_shadow_count") != 0 or model.get("pins") != ["CK", "E", "SE", "GCK"] or model.get("canary_status") != "PASS" or model.get("timing_check_capability") != "NOT_SUPPORTED_BY_MODEL":
        raise ValidationError("ICG model audit mismatch")
    parser = load_json(package / "parser_recovery.json")
    if parser.get("classification") != "PARSER_FALSE_POSITIVE_RECOVERED_FROM_IMMUTABLE_REPORTS" or parser.get("point_order") != list(POINT_IDS) or parser.get("outer_exit_code") != 2 or parser.get("eda_rerun") is not False or parser.get("release_status") != "FULL_RELEASED":
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
    groups = {
        "zh-CN": (files[0], files[2], "不是验证 test coverage"),
        "en": (files[1], files[3], "not verification test coverage"),
    }
    for language, (readme, experiment, coverage_boundary) in groups.items():
        combined = "\n".join(path.read_text(encoding="utf-8") for path in (readme, experiment))
        for token in ("61.67%", "58.46%", "59.52%", "15.58%", "Activity Annotation Coverage"):
            if token not in combined:
                raise ValidationError("{} documents missing rounded value/boundary {}".format(language, token))
        if coverage_boundary not in combined:
            raise ValidationError("{} activity annotation coverage is not distinguished from test coverage".format(language))
        for pattern in OVERCLAIM_PATTERNS:
            if pattern.search(combined):
                raise ValidationError("{} documentation overclaim matched: {}".format(language, pattern.pattern))
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
