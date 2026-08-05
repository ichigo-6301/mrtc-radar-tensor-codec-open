#!/usr/bin/env python3
"""Fail-closed, sanitized evidence contract for the private RDTC Power 2A study.

Raw EDA reports, SAIF/VCD, netlists, and private paths stay under ignored
``build/`` roots.  This module validates only their SHA-256 bindings plus
machine-readable, public-safe metrics.  ``comparisons.csv``, ``gates.csv``,
and ``classifications.csv`` are deterministic derivatives of ``points.csv``.
"""

from __future__ import print_function

import csv
import hashlib
import json
import re
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path


SCHEMA = "rdtc_power_2a_evidence_v3"
SOURCE_CONTRACT_SCHEMA = "rdtc-power-2a-source-contract-v1"
DECIMAL_PRECISION = 80
MAX_REPORT_QUANTIZATION_MW = Decimal("3")
MAX_REPORT_QUANTIZATION_PCT = Decimal("2")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
STATUS = ("PASS", "BLOCKED", "NOT_STARTED", "NA")
YES_NO = ("YES", "NO")
PRIVATE_TEXT = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\|/(?:home|mnt|Users|work|tmp|root|opt)/|(?:LM_LICENSE_FILE|SNPSLMD_LICENSE_FILE|MGLS_LICENSE_FILE|license|licserver|password|token)\\s*[:=])", re.IGNORECASE)

MANIFEST_FIELDS = (
    "schema", "points_csv", "comparisons_csv", "verification_csv", "gates_csv",
    "classifications_csv", "eligibility_csv", "hierarchy_power_csv", "raw_reports_csv",
    "source_contract_json", "source_contract_sha256", "source_contract_schema",
)

POINT_FIELDS = [
    "point_id", "experiment", "comparison_group", "variant", "workload_id", "status",
    "implementation", "top", "profile", "source_commit", "shared_source_set_sha256",
    "variant_source_set_sha256", "source_contract_sha256", "library_id", "library_sha256",
    "sdc_sha256", "routed_netlist_sha256", "routed_sdc_sha256", "routed_spef_sha256",
    "routed_odb_sha256", "activity_sha256", "normalized_packet_trace_sha256",
    "workload_manifest_sha256", "input_sequence_sha256", "expected_packet_sequence_sha256",
    "selected_k_sequence_sha256", "descriptor_sequence_sha256",
    "output_ready_sequence_sha256", "activity_method", "activity_strip_path_sha256",
    "raw_report_set_sha256", "frequency_mhz", "tool_version", "random_seed",
    "measurement_start_cycle", "measurement_end_cycle", "window_cycles", "blocks_completed",
    "raw_bytes", "compressed_bytes", "clock_coverage_pct", "functional_input_coverage_pct",
    "sequential_output_coverage_pct", "internal_leaf_pin_coverage_pct",
    "overall_nondefault_coverage_pct", "clock_nets_annotated", "clock_nets_total",
    "functional_inputs_annotated", "functional_inputs_total", "sequential_outputs_annotated",
    "sequential_outputs_total", "internal_leaf_pins_annotated", "internal_leaf_pins_total",
    "overall_objects_annotated", "overall_objects_total", "activity_unmatched_objects",
    "activity_default_toggle_objects", "area_total_um2", "area_combinational_um2",
    "area_sequential_um2", "cell_count", "sequential_cell_count", "buffer_cell_count",
    "inverter_cell_count", "sequential_bits", "gated_bits", "inserted_icg_count",
    "eligible_sequential_bits", "potential_icg_count", "max_icg_fanout",
    "max_enable_fanout", "fanout_violations", "setup_wns_ns", "setup_tns_ns",
    "hold_wns_ns", "hold_tns_ns", "electrical_violations", "clock_gating_violations",
    "max_transition_violations", "max_capacitance_violations", "max_fanout_violations",
    "route_drc", "antenna_violations", "unrouted_nets", "no_clock_registers",
    "unconstrained_endpoints", "physical_flow_errors", "clock_buffer_count",
    "clock_inverter_count", "gated_clock_sink_count", "clock_wirelength_um", "clock_skew_ns",
    "clock_insertion_delay_ns", "utilization_pct", "dynamic_mw", "internal_mw",
    "switching_mw", "leakage_mw", "total_mw", "report_quantization_mw", "clock_mw",
    "sequential_power_mw", "combinational_power_mw",
]
COMPARISON_FIELDS = [
    "comparison_id", "experiment", "comparison_group", "workload_id", "baseline_point",
    "candidate_point", "metric", "baseline", "candidate", "delta", "delta_percent",
    "formula", "status",
]
VERIFICATION_FIELDS = [
    "verification_id", "point_id", "kind", "method", "required", "trace_sha256",
    "result_sha256", "status",
]
GATE_FIELDS = [
    "gate_id", "experiment", "comparison_group", "status", "value", "threshold", "unit",
    "reason",
]
CLASSIFICATION_FIELDS = [
    "classification_id", "experiment", "comparison_group", "classification", "branch_only",
    "promotion_eligible", "merge_recommended", "production_rtl_changed",
    "postroute_pair_completed", "lec_status", "reason",
]
ELIGIBILITY_FIELDS = [
    "point_id", "hierarchy_id", "status", "sequential_bits", "eligible_bits", "gated_bits",
    "potential_icg_count", "inserted_icg_count", "max_icg_fanout", "max_enable_fanout",
    "uncovered_reason", "enable_expr_sha256",
]
HIERARCHY_POWER_FIELDS = [
    "point_id", "hierarchy_id", "status", "internal_mw", "switching_mw", "leakage_mw",
    "total_mw", "report_quantization_mw",
]
RAW_REPORT_FIELDS = ["report_id", "point_id", "report_kind", "report_sha256"]

EXPERIMENT_VARIANTS = {
    "architecture": ("A0", "A1"),
    "gating": ("G0", "G1"),
    "postroute": ("G0", "G1"),
}
REQUIRED_WORKLOADS = {
    "architecture": frozenset(("bursty", "active")),
    "gating": frozenset(("bursty", "sustained")),
    "postroute": frozenset(("bursty", "sustained")),
}
REQUIRED_VERIFICATION = {
    "architecture": ("functional", "activity_coverage", "timing", "electrical"),
    "gating": ("functional", "activity_coverage", "timing", "electrical", "clock_gating", "equivalence"),
    "postroute": ("functional", "activity_coverage", "timing", "electrical", "clock_gating", "equivalence", "postroute"),
}
REQUIRED_RAW_REPORTS = {
    "architecture": frozenset(("area", "timing_setup", "power", "activity", "functional", "hierarchy_power")),
    "gating": frozenset(("area", "timing_setup", "power", "activity", "functional", "hierarchy_power", "clock_gating", "eligibility")),
    "postroute": frozenset(("area", "timing_setup", "timing_hold", "power", "activity", "functional", "hierarchy_power", "clock_gating", "eligibility", "physical", "ptpx")),
}
WORKLOADS = ("idle", "bursty", "active", "sustained")
ACTIVITY_METHODS = ("gate_level_saif", "rtl_saif_mapped")
COMPARISON_METRICS = (
    "dynamic_mw", "internal_mw", "switching_mw", "leakage_mw", "total_mw", "clock_mw",
    "sequential_power_mw", "combinational_power_mw", "area_total_um2",
    "area_combinational_um2", "area_sequential_um2", "cell_count", "sequential_cell_count",
    "buffer_cell_count", "inverter_cell_count", "energy_per_block_nj",
    "dynamic_energy_per_block_nj", "energy_per_raw_byte_nj",
    "energy_per_compressed_byte_nj", "dynamic_energy_per_raw_byte_nj",
    "dynamic_energy_per_compressed_byte_nj",
)
POWER_FIELDS = (
    "dynamic_mw", "internal_mw", "switching_mw", "leakage_mw", "total_mw", "clock_mw",
    "sequential_power_mw", "combinational_power_mw",
)
AREA_FIELDS = (
    "area_total_um2", "area_combinational_um2", "area_sequential_um2", "cell_count",
    "sequential_cell_count", "buffer_cell_count", "inverter_cell_count", "sequential_bits",
)
WORKLOAD_IDENTITY_FIELDS = (
    "workload_manifest_sha256", "input_sequence_sha256", "expected_packet_sequence_sha256",
    "selected_k_sequence_sha256", "descriptor_sequence_sha256", "output_ready_sequence_sha256",
    "normalized_packet_trace_sha256", "random_seed",
)
PAIR_IDENTITY_FIELDS = (
    "comparison_group", "workload_id", "implementation", "source_commit",
    "shared_source_set_sha256", "source_contract_sha256", "library_id", "library_sha256",
    "sdc_sha256", "frequency_mhz", "tool_version", "activity_method",
) + WORKLOAD_IDENTITY_FIELDS
ARCHITECTURE_VARIANT_IDENTITY_FIELDS = frozenset((
    "sdc_sha256", "workload_manifest_sha256",
))
GROUP_IDENTITY_FIELDS = (
    "implementation", "source_commit", "shared_source_set_sha256", "variant_source_set_sha256",
    "source_contract_sha256", "library_id", "library_sha256", "sdc_sha256", "frequency_mhz",
    "tool_version", "top", "profile", "activity_method",
)
STRUCTURAL_POINT_FIELDS = (
    "area_total_um2", "area_combinational_um2", "area_sequential_um2", "cell_count",
    "sequential_cell_count", "buffer_cell_count", "inverter_cell_count", "sequential_bits",
    "gated_bits", "inserted_icg_count", "eligible_sequential_bits", "potential_icg_count",
    "max_icg_fanout", "max_enable_fanout", "fanout_violations", "setup_wns_ns", "setup_tns_ns",
    "hold_wns_ns", "hold_tns_ns", "electrical_violations", "clock_gating_violations",
    "max_transition_violations", "max_capacitance_violations", "max_fanout_violations",
    "route_drc", "antenna_violations", "unrouted_nets", "no_clock_registers",
    "unconstrained_endpoints", "physical_flow_errors", "clock_buffer_count", "clock_inverter_count",
    "gated_clock_sink_count", "clock_wirelength_um", "clock_skew_ns", "clock_insertion_delay_ns",
    "utilization_pct",
)
NON_POSTROUTE_FIELDS = (
    "routed_netlist_sha256", "routed_sdc_sha256", "routed_spef_sha256", "routed_odb_sha256",
    "hold_wns_ns", "hold_tns_ns", "route_drc", "antenna_violations", "unrouted_nets",
    "no_clock_registers", "unconstrained_endpoints", "physical_flow_errors", "clock_buffer_count",
    "clock_inverter_count", "gated_clock_sink_count", "clock_wirelength_um", "clock_skew_ns",
    "clock_insertion_delay_ns", "utilization_pct",
)
POSTROUTE_REQUIRED_FIELDS = tuple(field for field in NON_POSTROUTE_FIELDS if field not in (
    "routed_netlist_sha256", "routed_sdc_sha256", "routed_spef_sha256", "routed_odb_sha256",
))
EXECUTED_NUMERIC_FIELDS = tuple(field for field in POINT_FIELDS if field in (
    "frequency_mhz", "measurement_start_cycle", "measurement_end_cycle", "window_cycles",
    "blocks_completed", "raw_bytes", "compressed_bytes", "clock_coverage_pct",
    "functional_input_coverage_pct", "sequential_output_coverage_pct",
    "internal_leaf_pin_coverage_pct", "overall_nondefault_coverage_pct", "clock_nets_annotated",
    "clock_nets_total", "functional_inputs_annotated", "functional_inputs_total",
    "sequential_outputs_annotated", "sequential_outputs_total", "internal_leaf_pins_annotated",
    "internal_leaf_pins_total", "overall_objects_annotated", "overall_objects_total",
    "activity_unmatched_objects", "activity_default_toggle_objects", "report_quantization_mw",
) + AREA_FIELDS + (
    "gated_bits", "inserted_icg_count", "eligible_sequential_bits", "potential_icg_count",
    "max_icg_fanout", "max_enable_fanout", "fanout_violations", "setup_wns_ns", "setup_tns_ns",
    "electrical_violations", "clock_gating_violations", "max_transition_violations",
    "max_capacitance_violations", "max_fanout_violations",
) + POWER_FIELDS)
PROMOTION_THRESHOLDS = {
    "architecture": {
        "bursty_dynamic_reduction_pct": Decimal("10"),
        "bursty_energy_per_block_reduction_pct": Decimal("15"),
        "active_dynamic_regression_pct": Decimal("3"),
    },
    "gating": {
        "gated_bits": Decimal("8192"), "gated_state_pct": Decimal("20"),
        "bursty_dynamic_reduction_pct": Decimal("5"),
        "bursty_clock_sequential_reduction_pct": Decimal("10"),
        "sustained_dynamic_regression_pct": Decimal("1.5"), "area_overhead_pct": Decimal("3"),
    },
    "postroute": {
        "bursty_dynamic_reduction_pct": Decimal("3"),
        "bursty_energy_per_block_reduction_pct": Decimal("3"),
        "bursty_clock_sequential_reduction_pct": Decimal("8"),
        "sustained_dynamic_regression_pct": Decimal("1"), "area_overhead_pct": Decimal("5"),
    },
}


class ValidationError(Exception):
    """Evidence is incomplete, inconsistent, private, or unsafe to promote."""


def decimal(value, label):
    if value == "NA":
        return None
    try:
        result = Decimal(value)
    except (InvalidOperation, TypeError):
        raise ValidationError("{} is not a finite decimal: {}".format(label, value))
    if not result.is_finite():
        raise ValidationError("{} is not finite".format(label))
    return result


def canonical_decimal(value):
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        rendered = format((+decimal(value, "derived value")).normalize(), "f")
    return "0" if rendered in ("", "-0") else rendered


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_hash(value, label, allow_na=False):
    if allow_na and value == "NA":
        return
    if not isinstance(value, str) or not SHA256_RE.match(value):
        raise ValidationError("{} must be a lowercase SHA-256".format(label))


def _require_status(value, label):
    if value not in STATUS:
        raise ValidationError("{} has invalid status {}".format(label, value))


def _read_csv(path, fields, allow_empty=False):
    path = Path(path)
    if not path.is_file():
        raise ValidationError("missing {}".format(path.name))
    with path.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        if (reader.fieldnames or []) != fields:
            raise ValidationError("{} header mismatch".format(path.name))
        rows = list(reader)
    if not rows and not allow_empty:
        raise ValidationError("{} is empty".format(path.name))
    for number, row in enumerate(rows, start=2):
        if set(row) != set(fields) or None in row:
            raise ValidationError("{} row {} width mismatch".format(path.name, number))
        if any(value is None or value == "" for value in row.values()):
            raise ValidationError("{} row {} contains an empty field".format(path.name, number))
    return rows


def _private_leak_scan(directory):
    for path in Path(directory).rglob("*"):
        if not path.is_file():
            continue
        try:
            contents = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            raise ValidationError("non-text evidence file: {}".format(path.name))
        if PRIVATE_TEXT.search(contents):
            raise ValidationError("absolute private path or credential-like text in {}".format(path.name))


def _validate_source_contract(path, expected_sha256, expected_schema):
    if expected_schema != SOURCE_CONTRACT_SCHEMA:
        raise ValidationError("unsupported source-contract schema")
    _require_hash(expected_sha256, "manifest source_contract_sha256")
    if sha256_file(path) != expected_sha256:
        raise ValidationError("source_contract.json SHA-256 does not match manifest")
    try:
        contract = json.loads(Path(path).read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as exc:
        raise ValidationError("invalid source_contract.json: {}".format(exc))
    if not isinstance(contract, dict) or contract.get("schema") != SOURCE_CONTRACT_SCHEMA:
        raise ValidationError("source_contract.json schema mismatch")
    for section in ("architecture_ab", "direct_clock_gating", "library", "tool_contract"):
        if not isinstance(contract.get(section), dict):
            raise ValidationError("source_contract.json missing {}".format(section))
    for key, value in _walk_json(contract):
        if key.endswith("_sha256"):
            _require_hash(value, "source contract {}".format(key))
        if key.endswith("_commit") and not COMMIT_RE.match(str(value)):
            raise ValidationError("source contract {} must be a full lowercase Git SHA".format(key))
    return contract


def _walk_json(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key, child
            for nested in _walk_json(child):
                yield nested
    elif isinstance(value, list):
        for child in value:
            for nested in _walk_json(child):
                yield nested


def read_package(directory):
    directory = Path(directory)
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        raise ValidationError("missing manifest.json")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as exc:
        raise ValidationError("invalid manifest.json: {}".format(exc))
    if not isinstance(manifest, dict) or set(manifest) != set(MANIFEST_FIELDS):
        raise ValidationError("manifest fields mismatch")
    if manifest["schema"] != SCHEMA:
        raise ValidationError("unsupported manifest schema")
    expected_names = {
        "points_csv": "points.csv", "comparisons_csv": "comparisons.csv",
        "verification_csv": "verification.csv", "gates_csv": "gates.csv",
        "classifications_csv": "classifications.csv", "eligibility_csv": "eligibility.csv",
        "hierarchy_power_csv": "hierarchy_power.csv", "raw_reports_csv": "raw_reports.csv",
        "source_contract_json": "source_contract.json",
    }
    for key, expected in expected_names.items():
        if manifest[key] != expected:
            raise ValidationError("manifest {} must be {}".format(key, expected))
    contract = _validate_source_contract(
        directory / manifest["source_contract_json"], manifest["source_contract_sha256"],
        manifest["source_contract_schema"],
    )
    return manifest, contract, {
        "points": _read_csv(directory / "points.csv", POINT_FIELDS),
        "comparisons": _read_csv(directory / "comparisons.csv", COMPARISON_FIELDS, allow_empty=True),
        "verification": _read_csv(directory / "verification.csv", VERIFICATION_FIELDS, allow_empty=True),
        "gates": _read_csv(directory / "gates.csv", GATE_FIELDS, allow_empty=True),
        "classifications": _read_csv(directory / "classifications.csv", CLASSIFICATION_FIELDS, allow_empty=True),
        "eligibility": _read_csv(directory / "eligibility.csv", ELIGIBILITY_FIELDS, allow_empty=True),
        "hierarchy": _read_csv(directory / "hierarchy_power.csv", HIERARCHY_POWER_FIELDS, allow_empty=True),
        "raw_reports": _read_csv(directory / "raw_reports.csv", RAW_REPORT_FIELDS, allow_empty=True),
    }


def _point_by_id(rows):
    points = {}
    for row in rows:
        point_id = row["point_id"]
        if not point_id or point_id in points:
            raise ValidationError("point IDs must be nonempty and unique")
        points[point_id] = row
    return points


def _is_integer(value):
    return value == value.to_integral_value()


def _require_nonnegative(row, fields):
    for field in fields:
        value = decimal(row[field], "{} for {}".format(field, row["point_id"]))
        if value is not None and value < 0:
            raise ValidationError("{} must be non-negative: {}".format(field, row["point_id"]))


def _validate_report_quantization(quantization, total, label):
    if quantization <= 0:
        raise ValidationError("{} report quantization must be positive".format(label))
    if quantization > MAX_REPORT_QUANTIZATION_MW:
        raise ValidationError("{} report quantization exceeds the schema limit".format(label))
    if total == 0:
        return
    if quantization * Decimal("100") > total * MAX_REPORT_QUANTIZATION_PCT:
        raise ValidationError("{} report quantization exceeds the relative schema limit".format(label))


def _coverage_pair(row, percentage_field, numerator_field, denominator_field, minimum):
    label = "{} for {}".format(percentage_field, row["point_id"])
    percentage = decimal(row[percentage_field], label)
    numerator = decimal(row[numerator_field], label)
    denominator = decimal(row[denominator_field], label)
    if percentage is None or numerator is None or denominator is None:
        raise ValidationError("executed point has NA {}".format(percentage_field))
    if denominator <= 0 or numerator < 0 or numerator > denominator:
        raise ValidationError("invalid activity denominator for {}".format(percentage_field))
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        expected = numerator * Decimal("100") / denominator
    if percentage != expected:
        raise ValidationError("{} must match its explicit coverage denominator".format(percentage_field))
    if percentage < 0 or percentage > 100:
        raise ValidationError("coverage must be in [0, 100]: {}".format(percentage_field))
    return percentage >= minimum


def _validate_point_numeric_contract(row):
    point_id = row["point_id"]
    for field in EXECUTED_NUMERIC_FIELDS:
        if decimal(row[field], "{} for {}".format(field, point_id)) is None:
            raise ValidationError("executed point has NA {}: {}".format(field, point_id))
    if row["experiment"] == "postroute":
        for field in POSTROUTE_REQUIRED_FIELDS:
            if decimal(row[field], "{} for {}".format(field, point_id)) is None:
                raise ValidationError("postroute point has NA {}: {}".format(field, point_id))
    else:
        for field in NON_POSTROUTE_FIELDS:
            if row[field] != "NA":
                raise ValidationError("non-postroute {} must be NA: {}".format(field, point_id))
    _require_nonnegative(row, (
        "frequency_mhz", "measurement_start_cycle", "measurement_end_cycle", "window_cycles",
        "blocks_completed", "raw_bytes", "compressed_bytes", "activity_unmatched_objects",
        "activity_default_toggle_objects", "area_total_um2", "area_combinational_um2",
        "area_sequential_um2", "cell_count", "sequential_cell_count", "buffer_cell_count",
        "inverter_cell_count", "sequential_bits", "gated_bits", "inserted_icg_count",
        "eligible_sequential_bits", "potential_icg_count", "max_icg_fanout", "max_enable_fanout",
        "fanout_violations", "electrical_violations", "clock_gating_violations",
        "max_transition_violations", "max_capacitance_violations", "max_fanout_violations",
        "dynamic_mw", "internal_mw", "switching_mw", "leakage_mw", "total_mw",
        "report_quantization_mw", "clock_mw", "sequential_power_mw", "combinational_power_mw",
        "route_drc", "antenna_violations", "unrouted_nets", "no_clock_registers",
        "unconstrained_endpoints", "physical_flow_errors", "clock_buffer_count",
        "clock_inverter_count", "gated_clock_sink_count", "clock_wirelength_um", "clock_skew_ns",
        "clock_insertion_delay_ns", "utilization_pct",
    ))
    if decimal(row["frequency_mhz"], point_id) <= 0:
        raise ValidationError("frequency_mhz must be positive: {}".format(point_id))
    start = decimal(row["measurement_start_cycle"], point_id)
    end = decimal(row["measurement_end_cycle"], point_id)
    window = decimal(row["window_cycles"], point_id)
    if not all(_is_integer(value) for value in (start, end, window)) or end <= start or window != end - start:
        raise ValidationError("measurement cycle window must be an exact nonempty half-open interval: {}".format(point_id))
    integer_fields = (
        "measurement_start_cycle", "measurement_end_cycle", "window_cycles", "blocks_completed",
        "raw_bytes", "compressed_bytes", "clock_nets_annotated", "clock_nets_total",
        "functional_inputs_annotated", "functional_inputs_total", "sequential_outputs_annotated",
        "sequential_outputs_total", "internal_leaf_pins_annotated", "internal_leaf_pins_total",
        "overall_objects_annotated", "overall_objects_total", "activity_unmatched_objects",
        "activity_default_toggle_objects", "cell_count", "sequential_cell_count", "buffer_cell_count",
        "inverter_cell_count", "sequential_bits", "gated_bits", "inserted_icg_count",
        "eligible_sequential_bits", "potential_icg_count", "max_icg_fanout", "max_enable_fanout",
        "fanout_violations", "electrical_violations", "clock_gating_violations",
        "max_transition_violations", "max_capacitance_violations", "max_fanout_violations",
    )
    for field in integer_fields:
        if not _is_integer(decimal(row[field], point_id)):
            raise ValidationError("{} must be an integer: {}".format(field, point_id))
    if decimal(row["area_combinational_um2"], point_id) + decimal(row["area_sequential_um2"], point_id) > decimal(row["area_total_um2"], point_id):
        raise ValidationError("combinational plus sequential area exceeds total: {}".format(point_id))
    if any(decimal(row[field], point_id) > decimal(row["cell_count"], point_id) for field in ("sequential_cell_count", "buffer_cell_count", "inverter_cell_count")):
        raise ValidationError("cell subtype count exceeds cell_count: {}".format(point_id))
    if decimal(row["gated_bits"], point_id) > decimal(row["eligible_sequential_bits"], point_id) or decimal(row["eligible_sequential_bits"], point_id) > decimal(row["sequential_bits"], point_id):
        raise ValidationError("gating bit hierarchy invalid: {}".format(point_id))
    if decimal(row["inserted_icg_count"], point_id) > decimal(row["potential_icg_count"], point_id):
        raise ValidationError("inserted ICG count exceeds potential count: {}".format(point_id))
    quantization = decimal(row["report_quantization_mw"], point_id)
    _validate_report_quantization(
        quantization, decimal(row["total_mw"], point_id), "point {}".format(point_id)
    )
    if abs(decimal(row["dynamic_mw"], point_id) - decimal(row["internal_mw"], point_id) - decimal(row["switching_mw"], point_id)) > quantization:
        raise ValidationError("dynamic_mw must equal internal_mw plus switching_mw: {}".format(point_id))
    if abs(decimal(row["total_mw"], point_id) - decimal(row["dynamic_mw"], point_id) - decimal(row["leakage_mw"], point_id)) > quantization:
        raise ValidationError("total_mw must equal dynamic_mw plus leakage_mw: {}".format(point_id))
    if any(decimal(row[field], point_id) > decimal(row["total_mw"], point_id) for field in ("clock_mw", "sequential_power_mw", "combinational_power_mw")):
        raise ValidationError("power category exceeds total_mw: {}".format(point_id))
    _coverage_pair(row, "clock_coverage_pct", "clock_nets_annotated", "clock_nets_total", Decimal("100"))
    _coverage_pair(row, "functional_input_coverage_pct", "functional_inputs_annotated", "functional_inputs_total", Decimal("100"))
    _coverage_pair(row, "sequential_output_coverage_pct", "sequential_outputs_annotated", "sequential_outputs_total", Decimal("95"))
    _coverage_pair(row, "internal_leaf_pin_coverage_pct", "internal_leaf_pins_annotated", "internal_leaf_pins_total", Decimal("90"))
    _coverage_pair(row, "overall_nondefault_coverage_pct", "overall_objects_annotated", "overall_objects_total", Decimal("90"))
    if row["workload_id"] == "idle":
        if any(decimal(row[field], point_id) != 0 for field in ("blocks_completed", "raw_bytes", "compressed_bytes")):
            raise ValidationError("IDLE work must report zero blocks and bytes: {}".format(point_id))
    elif any(decimal(row[field], point_id) <= 0 for field in ("blocks_completed", "raw_bytes", "compressed_bytes")):
        raise ValidationError("non-idle work must report positive blocks and bytes: {}".format(point_id))


def _validate_points(rows, source_contract_sha256):
    points = _point_by_id(rows)
    activity_hashes = set()
    for point_id, row in points.items():
        _require_status(row["status"], "point {}".format(point_id))
        if row["experiment"] not in EXPERIMENT_VARIANTS or row["variant"] not in EXPERIMENT_VARIANTS.get(row["experiment"], ()):
            raise ValidationError("unsupported experiment/variant: {}".format(point_id))
        if row["workload_id"] not in WORKLOADS:
            raise ValidationError("unsupported workload: {}".format(point_id))
        expected_implementation = "postroute_ptpx" if row["experiment"] == "postroute" else "mapped_dc"
        if row["implementation"] != expected_implementation:
            raise ValidationError("implementation does not match experiment: {}".format(point_id))
        if not COMMIT_RE.match(row["source_commit"]):
            raise ValidationError("source_commit must be a full lowercase Git SHA: {}".format(point_id))
        for field in ("shared_source_set_sha256", "variant_source_set_sha256", "source_contract_sha256", "library_sha256", "sdc_sha256"):
            _require_hash(row[field], "{} for {}".format(field, point_id))
        if row["source_contract_sha256"] != source_contract_sha256:
            raise ValidationError("point source_contract_sha256 does not bind the manifest contract: {}".format(point_id))
        if row["status"] in ("NOT_STARTED", "NA"):
            for field in POINT_FIELDS:
                if field not in ("point_id", "experiment", "comparison_group", "variant", "workload_id", "status", "implementation", "top", "profile", "source_commit", "shared_source_set_sha256", "variant_source_set_sha256", "source_contract_sha256", "library_id", "library_sha256", "sdc_sha256", "tool_version", "random_seed") and row[field] != "NA":
                    raise ValidationError("unstarted point carries measurement/artifact {}: {}".format(field, point_id))
            continue
        for field in (
                "activity_sha256", "normalized_packet_trace_sha256", "workload_manifest_sha256",
                "input_sequence_sha256", "expected_packet_sequence_sha256", "selected_k_sequence_sha256",
                "descriptor_sequence_sha256", "output_ready_sequence_sha256",
                "activity_strip_path_sha256", "raw_report_set_sha256"):
            _require_hash(row[field], "{} for {}".format(field, point_id))
        if row["activity_method"] not in ACTIVITY_METHODS:
            raise ValidationError("unknown activity method: {}".format(point_id))
        if row["activity_sha256"] in activity_hashes:
            raise ValidationError("each executed point needs its own activity artifact: {}".format(point_id))
        activity_hashes.add(row["activity_sha256"])
        for field in ("routed_netlist_sha256", "routed_sdc_sha256", "routed_spef_sha256", "routed_odb_sha256"):
            _require_hash(row[field], "{} for {}".format(field, point_id), allow_na=row["experiment"] != "postroute")
        _validate_point_numeric_contract(row)
    return points


def _validate_raw_reports(rows, points):
    records = {}
    by_point = {}
    for row in rows:
        if not row["report_id"] or row["report_id"] in records:
            raise ValidationError("raw report IDs must be nonempty and unique")
        records[row["report_id"]] = row
        point = points.get(row["point_id"])
        if point is None:
            raise ValidationError("raw report refers to unknown point")
        if row["report_kind"] not in set().union(*REQUIRED_RAW_REPORTS.values()):
            raise ValidationError("unknown raw report kind")
        _require_hash(row["report_sha256"], "raw report hash")
        key = (row["point_id"], row["report_kind"])
        if key in by_point:
            raise ValidationError("duplicate raw report kind for point {}".format(row["point_id"]))
        by_point[key] = row
    for point_id, point in points.items():
        if point["status"] != "PASS":
            continue
        expected = REQUIRED_RAW_REPORTS[point["experiment"]]
        actual = {kind for (owner, kind) in by_point if owner == point_id}
        if actual != expected:
            raise ValidationError("raw report kinds mismatch for {}".format(point_id))
        ordered = [by_point[(point_id, kind)] for kind in sorted(actual)]
        rendered = json.dumps(ordered, sort_keys=True, separators=(",", ":")).encode("ascii")
        if hashlib.sha256(rendered).hexdigest() != point["raw_report_set_sha256"]:
            raise ValidationError("raw report set hash mismatch for {}".format(point_id))
        if by_point[(point_id, "activity")]["report_sha256"] != point["activity_sha256"]:
            raise ValidationError("activity report hash must match point activity hash: {}".format(point_id))
        if by_point[(point_id, "functional")]["report_sha256"] != point["normalized_packet_trace_sha256"]:
            raise ValidationError("functional report hash must match normalized packet trace: {}".format(point_id))
    return by_point


def _validate_verification(rows, points):
    allowed = set(kind for required in REQUIRED_VERIFICATION.values() for kind in required)
    by_point, ids = {}, set()
    for row in rows:
        if not row["verification_id"] or row["verification_id"] in ids:
            raise ValidationError("verification IDs must be nonempty and unique")
        ids.add(row["verification_id"])
        point = points.get(row["point_id"])
        if point is None or row["kind"] not in allowed:
            raise ValidationError("verification refers to an unknown point or kind")
        _require_status(row["status"], "verification {}".format(row["verification_id"]))
        if row["required"] not in YES_NO or not row["method"]:
            raise ValidationError("verification method/required invalid")
        key = (row["point_id"], row["kind"])
        if key in by_point:
            raise ValidationError("duplicate verification {}".format(key))
        if row["status"] in ("PASS", "BLOCKED"):
            _require_hash(row["trace_sha256"], "verification trace")
            _require_hash(row["result_sha256"], "verification result")
            if point["status"] in ("PASS", "BLOCKED") and row["trace_sha256"] != point["normalized_packet_trace_sha256"]:
                raise ValidationError("verification trace does not bind packet trace: {}".format(point["point_id"]))
        elif row["trace_sha256"] != "NA" or row["result_sha256"] != "NA":
            raise ValidationError("unstarted verification must use NA hashes")
        by_point[key] = row
    result = {}
    for point_id, point in points.items():
        required = REQUIRED_VERIFICATION[point["experiment"]]
        point_records = {}
        for kind in required:
            record = by_point.get((point_id, kind))
            if record is None or record["required"] != "YES":
                raise ValidationError("missing required {} verification for {}".format(kind, point_id))
            if point["status"] == "PASS" and record["status"] != "PASS":
                raise ValidationError("PASS point has non-PASS {} verification: {}".format(kind, point_id))
            if point["status"] in ("NOT_STARTED", "NA") and record["status"] not in ("NOT_STARTED", "NA"):
                raise ValidationError("unstarted point has executed verification: {}".format(point_id))
            point_records[kind] = record
        result[point_id] = point_records
    return result


def _validate_hierarchy(rows, points, raw_reports):
    by_point, keys = {}, set()
    for row in rows:
        point = points.get(row["point_id"])
        key = (row["point_id"], row["hierarchy_id"])
        if point is None or not row["hierarchy_id"] or key in keys:
            raise ValidationError("invalid or duplicate hierarchy-power row")
        keys.add(key)
        _require_status(row["status"], "hierarchy row")
        for field in ("internal_mw", "switching_mw", "leakage_mw", "total_mw", "report_quantization_mw"):
            value = decimal(row[field], "hierarchy {}".format(row["hierarchy_id"]))
            if row["status"] == "PASS" and (value is None or value < 0):
                raise ValidationError("PASS hierarchy row has invalid {}".format(field))
            if row["status"] != "PASS" and value is not None:
                raise ValidationError("non-PASS hierarchy row must use NA metrics")
        if row["status"] == "PASS":
            quantization = decimal(row["report_quantization_mw"], "hierarchy")
            total = decimal(row["total_mw"], "hierarchy")
            _validate_report_quantization(
                quantization, total,
                "hierarchy {}".format(row["hierarchy_id"]),
            )
            components = (
                decimal(row["internal_mw"], "hierarchy"),
                decimal(row["switching_mw"], "hierarchy"),
                decimal(row["leakage_mw"], "hierarchy"),
            )
            if total == 0 and any(value != 0 for value in components):
                raise ValidationError("zero-power hierarchy row has a nonzero component")
            component_delta = abs(
                total - sum(components, Decimal("0"))
            )
            if component_delta > quantization:
                raise ValidationError("hierarchy total_mw must equal internal plus switching plus leakage within report quantization")
        by_point.setdefault(row["point_id"], []).append(row)
    for point_id, point in points.items():
        if point["status"] != "PASS":
            continue
        entries = by_point.get(point_id, [])
        roots = [row for row in entries if row["hierarchy_id"] == "__ROOT__" and row["status"] == "PASS"]
        if len(roots) != 1 or len(entries) < 2:
            raise ValidationError("PASS point requires root and hierarchy-level machine-readable power: {}".format(point_id))
        root = roots[0]
        root_tolerance = (
            decimal(root["report_quantization_mw"], point_id)
            + decimal(point["report_quantization_mw"], point_id)
        )
        for field in ("internal_mw", "switching_mw", "leakage_mw", "total_mw"):
            if abs(decimal(root[field], point_id) - decimal(point[field], point_id)) > root_tolerance:
                raise ValidationError("hierarchy root does not match point {}: {}".format(field, point_id))
        if (point_id, "hierarchy_power") not in raw_reports:
            raise ValidationError("hierarchy rows have no raw report binding: {}".format(point_id))
    return by_point


def _validate_eligibility(rows, points, raw_reports):
    by_point, keys = {}, set()
    for row in rows:
        point = points.get(row["point_id"])
        key = (row["point_id"], row["hierarchy_id"])
        if point is None or point["experiment"] not in ("gating", "postroute") or not row["hierarchy_id"] or key in keys:
            raise ValidationError("invalid or duplicate eligibility row")
        keys.add(key)
        _require_status(row["status"], "eligibility row")
        _require_hash(row["enable_expr_sha256"], "eligibility enable expression", allow_na=row["status"] != "PASS")
        numeric = ("sequential_bits", "eligible_bits", "gated_bits", "potential_icg_count", "inserted_icg_count", "max_icg_fanout", "max_enable_fanout")
        values = {field: decimal(row[field], "eligibility {}".format(row["hierarchy_id"])) for field in numeric}
        if row["status"] == "PASS":
            if any(value is None or value < 0 or not _is_integer(value) for value in values.values()):
                raise ValidationError("PASS eligibility metrics must be nonnegative integers")
            if values["gated_bits"] > values["eligible_bits"] or values["eligible_bits"] > values["sequential_bits"] or values["inserted_icg_count"] > values["potential_icg_count"]:
                raise ValidationError("eligibility metrics are internally inconsistent")
        elif any(value is not None for value in values.values()):
            raise ValidationError("non-PASS eligibility row must use NA metrics")
        if not row["uncovered_reason"]:
            raise ValidationError("eligibility uncovered reason must be present")
        by_point.setdefault(row["point_id"], []).append(row)
    for point_id, point in points.items():
        if point["status"] != "PASS" or point["experiment"] not in ("gating", "postroute") or point["variant"] != "G1":
            continue
        entries = by_point.get(point_id, [])
        totals = [row for row in entries if row["hierarchy_id"] == "__TOTAL__" and row["status"] == "PASS"]
        if len(totals) != 1 or len(entries) < 2:
            raise ValidationError("gated point needs total and hierarchy-level eligibility evidence: {}".format(point_id))
        total = totals[0]
        pairs = (("sequential_bits", "sequential_bits"), ("eligible_bits", "eligible_sequential_bits"), ("gated_bits", "gated_bits"), ("potential_icg_count", "potential_icg_count"), ("inserted_icg_count", "inserted_icg_count"), ("max_icg_fanout", "max_icg_fanout"), ("max_enable_fanout", "max_enable_fanout"))
        for row_field, point_field in pairs:
            if decimal(total[row_field], point_id) != decimal(point[point_field], point_id):
                raise ValidationError("eligibility total does not match point {}: {}".format(point_field, point_id))
        if (point_id, "eligibility") not in raw_reports or (point_id, "clock_gating") not in raw_reports:
            raise ValidationError("gated point has no eligibility/clock-gating raw report binding: {}".format(point_id))
    return by_point


def _metric(point, name):
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        if name.startswith("dynamic_energy_"):
            power = decimal(point["dynamic_mw"], name)
        elif name.startswith("energy_"):
            power = decimal(point["total_mw"], name)
        else:
            return decimal(point[name], name)
        if name.endswith("per_block_nj"):
            divisor = decimal(point["blocks_completed"], name)
        elif name.endswith("per_raw_byte_nj"):
            divisor = decimal(point["raw_bytes"], name)
        elif name.endswith("per_compressed_byte_nj"):
            divisor = decimal(point["compressed_bytes"], name)
        else:
            raise ValidationError("unsupported derived metric {}".format(name))
        if divisor <= 0:
            raise ValidationError("energy denominator must be positive: {}".format(name))
        # mW * (cycles / MHz) is nJ.  Keep one final division so a recurring
        # fraction is rounded once at the declared Decimal precision.
        return power * decimal(point["window_cycles"], name) / (decimal(point["frequency_mhz"], name) * divisor)


def derive_comparisons(points):
    groups = {}
    for point in points.values():
        groups.setdefault((point["experiment"], point["comparison_group"]), []).append(point)
    derived = []
    for (experiment, group), members in sorted(groups.items()):
        baseline_variant, candidate_variant = EXPERIMENT_VARIANTS[experiment]
        baseline = [point for point in members if point["variant"] == baseline_variant]
        candidate = [point for point in members if point["variant"] == candidate_variant]
        if not baseline or not candidate:
            raise ValidationError("comparison group lacks a baseline or candidate: {}".format(group))
        baseline_workloads = [point["workload_id"] for point in baseline]
        candidate_workloads = [point["workload_id"] for point in candidate]
        if len(baseline_workloads) != len(set(baseline_workloads)) or len(candidate_workloads) != len(set(candidate_workloads)):
            raise ValidationError("comparison group has duplicate variant workloads: {}".format(group))
        if set(baseline_workloads) != set(candidate_workloads):
            raise ValidationError("comparison group workload sets differ: {}".format(group))
        if not REQUIRED_WORKLOADS[experiment].issubset(set(baseline_workloads)):
            raise ValidationError("comparison group lacks required workloads: {}".format(group))
        for variant, variant_points in ((baseline_variant, baseline), (candidate_variant, candidate)):
            reference = variant_points[0]
            for point in variant_points[1:]:
                for field in GROUP_IDENTITY_FIELDS + STRUCTURAL_POINT_FIELDS:
                    if point[field] != reference[field]:
                        raise ValidationError("{} identity changes across workloads for {} in {}".format(field, variant, group))
        candidate_by_workload = {point["workload_id"]: point for point in candidate}
        for base in baseline:
            cand = candidate_by_workload[base["workload_id"]]
            pair_fields = list(PAIR_IDENTITY_FIELDS)
            if experiment == "architecture":
                pair_fields = [
                    field for field in pair_fields
                    if field not in ARCHITECTURE_VARIANT_IDENTITY_FIELDS
                ]
            else:
                pair_fields.extend(("top", "profile", "variant_source_set_sha256"))
            for field in pair_fields:
                if base[field] != cand[field]:
                    raise ValidationError("paired identity mismatch {} in {}".format(field, group))
            if base["status"] == cand["status"] == "PASS" and base["activity_sha256"] == cand["activity_sha256"]:
                raise ValidationError("paired points reuse one activity artifact in {}".format(group))
            status = "PASS" if base["status"] == cand["status"] == "PASS" else "BLOCKED"
            metrics = list(COMPARISON_METRICS)
            if base["workload_id"] == "idle":
                metrics = [metric for metric in metrics if "energy_" not in metric]
            for metric in metrics:
                row = {
                    "comparison_id": "{}:{}:{}".format(group, base["workload_id"], metric),
                    "experiment": experiment, "comparison_group": group, "workload_id": base["workload_id"],
                    "baseline_point": base["point_id"], "candidate_point": cand["point_id"], "metric": metric,
                    "baseline": "NA", "candidate": "NA", "delta": "NA", "delta_percent": "NA",
                    "formula": "NA", "status": status,
                }
                if status == "PASS":
                    baseline_value, candidate_value = _metric(base, metric), _metric(cand, metric)
                    if baseline_value == 0:
                        if candidate_value != 0:
                            raise ValidationError("zero baseline metric is not comparable: {}".format(row["comparison_id"]))
                        delta = Decimal("0")
                        percent = Decimal("0")
                        formula = "candidate-baseline; equal_zero_baseline=>0_percent"
                    else:
                        with localcontext() as context:
                            context.prec = DECIMAL_PRECISION
                            delta = candidate_value - baseline_value
                            percent = delta * Decimal("100") / baseline_value
                        formula = "candidate-baseline; 100*(candidate-baseline)/baseline"
                    row.update({"baseline": canonical_decimal(baseline_value), "candidate": canonical_decimal(candidate_value), "delta": canonical_decimal(delta), "delta_percent": canonical_decimal(percent), "formula": formula})
                derived.append(row)
    return sorted(derived, key=lambda row: row["comparison_id"])


def _comparison_map(rows):
    result = {}
    for row in rows:
        if row["comparison_id"] in result:
            raise ValidationError("duplicate comparison_id")
        result[row["comparison_id"]] = row
    return result


def _compare_rows(recorded, derived):
    if len(recorded) != len(derived):
        raise ValidationError("comparisons.csv row count differs from deterministic result")
    actual = _comparison_map(recorded)
    for row in derived:
        if actual.get(row["comparison_id"]) != row:
            raise ValidationError("comparison is not the deterministic derived result: {}".format(row["comparison_id"]))


def _comparison_value(rows, group, workload, metric):
    matches = [row for row in rows if row["comparison_group"] == group and row["workload_id"] == workload and row["metric"] == metric]
    if len(matches) != 1 or matches[0]["status"] != "PASS":
        return None
    return decimal(matches[0]["delta_percent"], "comparison delta")


def _paired_points(points, experiment, group, workload):
    baseline_variant, candidate_variant = EXPERIMENT_VARIANTS[experiment]
    matches = [
        point for point in points.values()
        if point["experiment"] == experiment
        and point["comparison_group"] == group
        and point["workload_id"] == workload
        and point["status"] == "PASS"
    ]
    baseline = [point for point in matches if point["variant"] == baseline_variant]
    candidate = [point for point in matches if point["variant"] == candidate_variant]
    if len(baseline) != 1 or len(candidate) != 1:
        return None, None
    return baseline[0], candidate[0]


def _metric_quantization(point, metric):
    if metric not in POWER_FIELDS and not metric.startswith(("energy_", "dynamic_energy_")):
        return Decimal("0")
    bound = decimal(point["report_quantization_mw"], "report quantization")
    if metric in POWER_FIELDS:
        return bound
    if metric.endswith("per_block_nj"):
        divisor = decimal(point["blocks_completed"], metric)
    elif metric.endswith("per_raw_byte_nj"):
        divisor = decimal(point["raw_bytes"], metric)
    elif metric.endswith("per_compressed_byte_nj"):
        divisor = decimal(point["compressed_bytes"], metric)
    else:
        raise ValidationError("unsupported quantized metric {}".format(metric))
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        return bound * decimal(point["window_cycles"], metric) / (
            decimal(point["frequency_mhz"], metric) * divisor
        )


def _conservative_comparison_value(points, rows, experiment, group, workload, metric):
    if _comparison_value(rows, group, workload, metric) is None:
        return None
    baseline, candidate = _paired_points(points, experiment, group, workload)
    if baseline is None:
        return None
    baseline_value = _metric(baseline, metric)
    candidate_value = _metric(candidate, metric)
    baseline_lower = baseline_value - _metric_quantization(baseline, metric)
    candidate_upper = candidate_value + _metric_quantization(candidate, metric)
    if baseline_lower <= 0:
        return None
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        return (candidate_upper - baseline_lower) * Decimal("100") / baseline_lower


def _conservative_comparison_sum_reduction(points, rows, experiment, group, workload, metrics):
    selected = [row for row in rows if row["comparison_group"] == group and row["workload_id"] == workload and row["metric"] in metrics]
    if len(selected) != len(metrics) or any(row["status"] != "PASS" for row in selected):
        return None
    baseline, candidate = _paired_points(points, experiment, group, workload)
    if baseline is None:
        return None
    baseline_lower = sum(
        (_metric(baseline, metric) - _metric_quantization(baseline, metric) for metric in metrics),
        Decimal("0"),
    )
    candidate_upper = sum(
        (_metric(candidate, metric) + _metric_quantization(candidate, metric) for metric in metrics),
        Decimal("0"),
    )
    if baseline_lower <= 0:
        return None
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        return (baseline_lower - candidate_upper) * Decimal("100") / baseline_lower


def _gate_status(gates, group, suffix):
    match = [row for row in gates if row["comparison_group"] == group and row["gate_id"] == "{}:{}".format(group, suffix)]
    return match[0]["status"] if len(match) == 1 else "BLOCKED"


def derive_gates(points, comparisons, verification):
    gates = []
    groups = sorted({(row["experiment"], row["comparison_group"]) for row in comparisons})
    for experiment, group in groups:
        threshold = PROMOTION_THRESHOLDS[experiment]
        gating_threshold = PROMOTION_THRESHOLDS["gating"]
        def add(name, value, limit, passes, unit, reason=None):
            gates.append({"gate_id": "{}:{}".format(group, name), "experiment": experiment,
                          "comparison_group": group, "status": "PASS" if passes else "BLOCKED",
                          "value": canonical_decimal(value) if value is not None else "NA",
                          "threshold": canonical_decimal(limit), "unit": unit,
                          "reason": reason or ("threshold_met" if passes else "threshold_not_met_or_evidence_unavailable")})
        relevant = [point for point in points.values() if point["experiment"] == experiment and point["comparison_group"] == group and point["workload_id"] in REQUIRED_WORKLOADS[experiment]]
        verification_ok = bool(relevant) and all(
            verification.get(point["point_id"], {}).get(kind, {}).get("status") == "PASS"
            for point in relevant for kind in REQUIRED_VERIFICATION[experiment]
        )
        add("required_verification", Decimal("1") if verification_ok else Decimal("0"), Decimal("1"), verification_ok, "boolean")
        coverage = (
            ("clock_activity_coverage", "clock_coverage_pct", Decimal("100")),
            ("functional_input_activity_coverage", "functional_input_coverage_pct", Decimal("100")),
            ("sequential_activity_coverage", "sequential_output_coverage_pct", Decimal("95")),
            ("internal_leaf_activity_coverage", "internal_leaf_pin_coverage_pct", Decimal("90")),
            ("overall_nondefault_activity_coverage", "overall_nondefault_coverage_pct", Decimal("90")),
        )
        for name, field, minimum in coverage:
            values = [decimal(point[field], point["point_id"]) for point in relevant]
            value = min(values) if values and None not in values else None
            add(name, value, minimum, value is not None and value >= minimum, "percent")
        def minimum(field):
            values = [decimal(point[field], point["point_id"]) for point in relevant]
            return min(values) if values and None not in values else None
        def maximum(field):
            values = [decimal(point[field], point["point_id"]) for point in relevant]
            return max(values) if values and None not in values else None
        setup_wns, setup_tns, electrical = minimum("setup_wns_ns"), maximum("setup_tns_ns"), maximum("electrical_violations")
        add("setup_wns", setup_wns, Decimal("0"), setup_wns is not None and setup_wns >= 0, "ns")
        add("setup_tns", setup_tns, Decimal("0"), setup_tns is not None and setup_tns == 0, "ns")
        add("electrical_violations", electrical, Decimal("0"), electrical is not None and electrical == 0, "count")
        burst_dynamic = _conservative_comparison_value(points, comparisons, experiment, group, "bursty", "dynamic_mw")
        burst_energy = _conservative_comparison_value(points, comparisons, experiment, group, "bursty", "energy_per_block_nj")
        active_dynamic = _conservative_comparison_value(points, comparisons, experiment, group, "active", "dynamic_mw")
        sustained_dynamic = _conservative_comparison_value(points, comparisons, experiment, group, "sustained", "dynamic_mw")
        area = _conservative_comparison_value(points, comparisons, experiment, group, "bursty", "area_total_um2")
        burst_clock_seq = _conservative_comparison_sum_reduction(points, comparisons, experiment, group, "bursty", ("clock_mw", "sequential_power_mw"))
        if experiment == "architecture":
            dynamic_reduction = None if burst_dynamic is None else -burst_dynamic
            energy_reduction = None if burst_energy is None else -burst_energy
            primary = dynamic_reduction is not None and energy_reduction is not None and (dynamic_reduction >= threshold["bursty_dynamic_reduction_pct"] or energy_reduction >= threshold["bursty_energy_per_block_reduction_pct"])
            add("architecture_primary_saving", dynamic_reduction if dynamic_reduction is not None and dynamic_reduction >= threshold["bursty_dynamic_reduction_pct"] else energy_reduction, threshold["bursty_dynamic_reduction_pct"], primary, "percent", "dynamic_or_energy_per_block_threshold")
            add("architecture_active_dynamic_regression", active_dynamic, threshold["active_dynamic_regression_pct"], active_dynamic is not None and active_dynamic <= threshold["active_dynamic_regression_pct"], "percent")
            continue
        candidates = [point for point in relevant if point["variant"] == "G1" and point["status"] == "PASS"]
        gated_bits = min((decimal(point["gated_bits"], point["point_id"]) for point in candidates), default=None)
        state_pct = min((decimal(point["gated_bits"], point["point_id"]) * Decimal("100") / decimal(point["sequential_bits"], point["point_id"]) for point in candidates), default=None)
        inserted = min((decimal(point["inserted_icg_count"], point["point_id"]) for point in candidates), default=None)
        cg_violations, fanout = maximum("clock_gating_violations"), maximum("fanout_violations")
        add("gating_inserted_icg_count", inserted, Decimal("1"), inserted is not None and inserted > 0, "count")
        add("gating_min_gated_bits", gated_bits, gating_threshold["gated_bits"], gated_bits is not None and gated_bits >= gating_threshold["gated_bits"], "bits")
        add("gating_state_coverage", state_pct, gating_threshold["gated_state_pct"], state_pct is not None and state_pct >= gating_threshold["gated_state_pct"], "percent")
        add("gating_check_violations", cg_violations, Decimal("0"), cg_violations is not None and cg_violations == 0, "count")
        add("gating_fanout_violations", fanout, Decimal("0"), fanout is not None and fanout == 0, "count")
        burst_reduction = None if burst_dynamic is None else -burst_dynamic
        add("{}_bursty_dynamic_reduction".format(experiment), burst_reduction, threshold["bursty_dynamic_reduction_pct"], burst_reduction is not None and burst_reduction >= threshold["bursty_dynamic_reduction_pct"], "percent")
        add("{}_bursty_clock_sequential_reduction".format(experiment), burst_clock_seq, threshold["bursty_clock_sequential_reduction_pct"], burst_clock_seq is not None and burst_clock_seq >= threshold["bursty_clock_sequential_reduction_pct"], "percent")
        add("{}_sustained_dynamic_regression".format(experiment), sustained_dynamic, threshold["sustained_dynamic_regression_pct"], sustained_dynamic is not None and sustained_dynamic <= threshold["sustained_dynamic_regression_pct"], "percent")
        add("{}_area_overhead".format(experiment), area, threshold["area_overhead_pct"], area is not None and area <= threshold["area_overhead_pct"], "percent")
        if experiment == "postroute":
            energy_reduction = None if burst_energy is None else -burst_energy
            add("postroute_bursty_energy_per_block_reduction", energy_reduction, threshold["bursty_energy_per_block_reduction_pct"], energy_reduction is not None and energy_reduction >= threshold["bursty_energy_per_block_reduction_pct"], "percent")
            for field, name, unit in (
                    ("hold_wns_ns", "postroute_hold_wns", "ns"), ("hold_tns_ns", "postroute_hold_tns", "ns"),
                    ("max_transition_violations", "postroute_max_transition_violations", "count"),
                    ("max_capacitance_violations", "postroute_max_capacitance_violations", "count"),
                    ("max_fanout_violations", "postroute_max_fanout_violations", "count"),
                    ("route_drc", "postroute_route_drc", "count"), ("antenna_violations", "postroute_antenna_violations", "count"),
                    ("unrouted_nets", "postroute_unrouted_nets", "count"), ("no_clock_registers", "postroute_no_clock_registers", "count"),
                    ("unconstrained_endpoints", "postroute_unconstrained_endpoints", "count"),
                    ("physical_flow_errors", "postroute_flow_errors", "count")):
                value = minimum(field) if field == "hold_wns_ns" else maximum(field)
                add(name, value, Decimal("0"), value is not None and (value >= 0 if field == "hold_wns_ns" else value == 0), unit)
    return sorted(gates, key=lambda row: row["gate_id"])


def _compare_gates(recorded, derived):
    actual = {row["gate_id"]: row for row in recorded}
    if len(actual) != len(recorded) or len(actual) != len(derived):
        raise ValidationError("gates.csv row count or IDs differ from deterministic result")
    for row in derived:
        if actual.get(row["gate_id"]) != row:
            raise ValidationError("gate is not the deterministic result: {}".format(row["gate_id"]))


def _classification_reason(gates, group):
    blocked = [row["gate_id"].split(":", 1)[1] for row in gates if row["comparison_group"] == group and row["status"] != "PASS"]
    return "all_promotion_gates_pass" if not blocked else "blocked:" + ",".join(sorted(blocked))


def derive_classifications(points, comparisons, gates, verification):
    rows = []
    groups = sorted({(row["experiment"], row["comparison_group"]) for row in comparisons})
    for experiment, group in groups:
        blocked = [row for row in gates if row["experiment"] == experiment and row["comparison_group"] == group and row["status"] != "PASS"]
        promotion = not blocked
        coverage_blocked = any("activity_coverage" in row["gate_id"] for row in blocked)
        verification_blocked = _gate_status(gates, group, "required_verification") != "PASS"
        equivalence = [record for point_id, records in verification.items() for kind, record in records.items() if points[point_id]["experiment"] == experiment and points[point_id]["comparison_group"] == group and kind == "equivalence"]
        if not equivalence:
            lec_status = "NA"
        elif all(row["status"] == "PASS" and row["method"] == "formality" for row in equivalence):
            lec_status = "FORMAL_PASS"
        elif all(row["status"] == "PASS" and row["method"] == "gate_level_regression" for row in equivalence):
            lec_status = "GATE_LEVEL_REGRESSION_PASS"
        else:
            lec_status = "BLOCKED"
        if experiment == "architecture":
            burst_delta = _comparison_value(comparisons, group, "bursty", "dynamic_mw")
            if coverage_blocked or verification_blocked:
                classification = "ARCH_POWER_INSUFFICIENT_ACTIVITY"
            elif promotion:
                classification = "ARCH_POWER_POSITIVE"
            elif burst_delta is not None and burst_delta > 0:
                classification = "ARCH_POWER_NEGATIVE"
            else:
                classification = "ARCH_POWER_NEUTRAL"
        elif experiment == "gating":
            if lec_status == "BLOCKED":
                classification = "CG_EQUIVALENCE_BLOCKED"
            elif coverage_blocked or verification_blocked:
                classification = "CG_POWER_TOOL_UNAVAILABLE"
            elif _gate_status(gates, group, "gating_min_gated_bits") != "PASS" or _gate_status(gates, group, "gating_state_coverage") != "PASS":
                classification = "CG_NEGATIVE_LOW_COVERAGE"
            elif _gate_status(gates, group, "setup_wns") != "PASS" or _gate_status(gates, group, "setup_tns") != "PASS" or _gate_status(gates, group, "electrical_violations") != "PASS":
                classification = "CG_TIMING_BLOCKED"
            elif _gate_status(gates, group, "gating_sustained_dynamic_regression") != "PASS":
                classification = "CG_NEGATIVE_WORKLOAD_DEPENDENT"
            elif promotion:
                classification = "CG_MAPPED_POSITIVE"
            else:
                classification = "CG_NEGATIVE_WORKLOAD_DEPENDENT"
        else:
            physical_gate_names = frozenset((
                "postroute_hold_wns", "postroute_hold_tns", "postroute_max_transition_violations",
                "postroute_max_capacitance_violations", "postroute_max_fanout_violations",
                "postroute_route_drc", "postroute_antenna_violations", "postroute_unrouted_nets",
                "postroute_no_clock_registers", "postroute_unconstrained_endpoints", "postroute_flow_errors",
            ))
            physical_block = any(row["gate_id"].split(":", 1)[1] in physical_gate_names and row["status"] != "PASS" for row in gates if row["comparison_group"] == group)
            if lec_status == "BLOCKED":
                classification = "CG_EQUIVALENCE_BLOCKED"
            elif physical_block:
                classification = "CG_PHYSICAL_PAIR_BLOCKED"
            elif promotion:
                classification = "CG_POSTROUTE_POSITIVE"
            else:
                classification = "CG_NEGATIVE_WORKLOAD_DEPENDENT"
        rows.append({
            "classification_id": "{}:{}".format(experiment, group), "experiment": experiment,
            "comparison_group": group, "classification": classification,
            "branch_only": "NO" if promotion else "YES", "promotion_eligible": "YES" if promotion else "NO",
            "merge_recommended": "YES" if classification in ("ARCH_POWER_POSITIVE", "CG_POSTROUTE_POSITIVE") else "NO",
            "production_rtl_changed": "NO", "postroute_pair_completed": "YES" if experiment == "postroute" and not physical_block else "NO",
            "lec_status": lec_status, "reason": _classification_reason(gates, group),
        })
    return rows


def _compare_classifications(recorded, derived):
    actual = {row["classification_id"]: row for row in recorded}
    if len(actual) != len(recorded) or len(actual) != len(derived):
        raise ValidationError("classifications.csv row count or IDs differ from deterministic result")
    for row in derived:
        if actual.get(row["classification_id"]) != row:
            raise ValidationError("classification is not deterministic: {}".format(row["classification_id"]))


def validate(directory, require_promotion=False):
    """Validate sanitized evidence; ``--require-promotion`` is deliberately stricter."""
    directory = Path(directory)
    _private_leak_scan(directory)
    manifest, contract, package = read_package(directory)
    points = _validate_points(package["points"], manifest["source_contract_sha256"])
    raw_reports = _validate_raw_reports(package["raw_reports"], points)
    verification = _validate_verification(package["verification"], points)
    _validate_hierarchy(package["hierarchy"], points, raw_reports)
    _validate_eligibility(package["eligibility"], points, raw_reports)
    comparisons = derive_comparisons(points)
    _compare_rows(package["comparisons"], comparisons)
    gates = derive_gates(points, comparisons, verification)
    _compare_gates(package["gates"], gates)
    classifications = derive_classifications(points, comparisons, gates, verification)
    _compare_classifications(package["classifications"], classifications)
    blocked = [row["gate_id"] for row in gates if row["status"] != "PASS"]
    if require_promotion and blocked:
        raise ValidationError("fail-closed promotion gate: {}".format(blocked[0]))
    return {"manifest": manifest, "source_contract": contract, "points": points, "comparisons": comparisons,
            "gates": gates, "classifications": classifications, "promotion_eligible": not blocked,
            "blocked_gates": blocked}


def write_csv(path, fields, rows):
    """Write canonical, LF-terminated CSV for fixtures and private evidence runners."""
    with Path(path).open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
