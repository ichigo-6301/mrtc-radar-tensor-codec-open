#!/usr/bin/env python3
"""Run and audit the public bounded buffered versus Direct-AXIS DC A/B."""

from __future__ import print_function

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import flowctl  # noqa: E402


FIXED_PUBLIC_RTL_COMMIT = "4bb56f543d75bb91c9ddeb26cdeef5201560c669"
EXPECTED_DC_VERSION = "O-2018.06-SP1"
EXPECTED_DB_SHA256 = flowctl.BOUNDED_DC_AB_STDCELL_DB_SHA256
FILELIST = flowctl.BOUNDED_DC_AB_FILELIST
COMMON_SDC = flowctl.BOUNDED_DC_AB_SDC
RUN_TCL = "flows/synthesis/dc/baseline/run.tcl"
POINTS = (
    {
        "key": "buffered315",
        "family": "buffered",
        "frequency_mhz": 315,
        "period_ns": 3.174603,
        "storage_bits": 180224,
        "config": "rdtc_v1_bounded_ab_buffered_dc315_defconfig",
        "build_tag": "rdtc_v1_bounded_ab_buffered_dc315",
    },
    {
        "key": "direct315",
        "family": "direct",
        "frequency_mhz": 315,
        "period_ns": 3.174603,
        "storage_bits": 32768,
        "config": "rdtc_v1_bounded_ab_direct_dc315_defconfig",
        "build_tag": "rdtc_v1_bounded_ab_direct_dc315",
    },
    {
        "key": "buffered630",
        "family": "buffered",
        "frequency_mhz": 630,
        "period_ns": 1.587302,
        "storage_bits": 180224,
        "config": "rdtc_v1_bounded_ab_buffered_dc630_defconfig",
        "build_tag": "rdtc_v1_bounded_ab_buffered_dc630",
    },
    {
        "key": "direct630",
        "family": "direct",
        "frequency_mhz": 630,
        "period_ns": 1.587302,
        "storage_bits": 32768,
        "config": "rdtc_v1_bounded_ab_direct_dc630_defconfig",
        "build_tag": "rdtc_v1_bounded_ab_direct_dc630",
    },
)

PUBLIC_CLOSURE_FIELDS = (
    "status",
    "setup_wns",
    "setup_tns",
    "setup_violating_paths",
    "constraint_violating_checks",
    "bounded_design_rule_repair_passes",
    "seqgen_cell_count",
    "gtech_cell_count",
    "designware_cell_count",
    "unmapped_cell_count",
    "retiming",
    "bounded_asic_family",
    "bounded_bulk_storage_bits",
    "bounded_register_storage_bits",
    "memory_macro_count",
    "stdcell_db_sha256",
    "dc_max_cores",
    "input_manifest_sha256",
)

PUBLIC_CONTRACT_FIELDS = (
    "product_profile",
    "technology",
    "top",
    "clock_period_library_units",
    "documented_clock_period_ns",
    "sdc_time_scale",
    "memory_mode",
    "bounded_dc_ab",
    "bounded_asic_family",
    "bounded_bulk_storage_bits",
    "setup_wns",
    "setup_tns",
    "setup_violating_paths",
    "constraint_violating_checks",
    "bounded_design_rule_repair_passes",
    "seqgen_cell_count",
    "gtech_cell_count",
    "designware_cell_count",
    "unmapped_cell_count",
    "memory_macro_count",
    "total_cell_count",
    "stdcell_db_sha256",
    "dc_max_cores",
    "input_manifest_sha256",
)

REQUIRED_REPORTS = {
    "closure": "dc_closure_summary.txt",
    "contract": "run_contract.txt",
    "area": "area.rpt",
    "hierarchy": "area_hier.rpt",
    "timing": "timing.rpt",
}
INPUT_MANIFEST_NAME = "input_manifest.json"


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_git(root, arguments, check=True):
    process = subprocess.Popen(
        ["git", "-C", str(root)] + list(arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout, stderr = process.communicate()
    if check and process.returncode:
        raise RuntimeError(
            "git {} failed: {}".format(
                " ".join(arguments), stderr.decode("utf-8", errors="replace").strip()
            )
        )
    return process.returncode, stdout.decode("utf-8", errors="replace").strip()


def relative_path(root, path):
    path = Path(path).resolve()
    try:
        return path.relative_to(Path(root).resolve()).as_posix()
    except ValueError:
        return path.name


def file_record(root, path):
    path = Path(path).resolve()
    if not path.is_file():
        raise RuntimeError("missing comparison input: {}".format(path))
    return {
        "path": relative_path(root, path),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def filelist_sources(root):
    entries = []
    for raw in (root / FILELIST).read_text(encoding="utf-8").splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line or line.startswith("+"):
            continue
        if line.endswith((".sv", ".v")):
            entries.append(line.replace("\\", "/"))
    if not entries:
        raise RuntimeError("paired comparison filelist contains no RTL")
    return entries


def source_identity(root):
    root = Path(root).resolve()
    _, head = run_git(root, ("rev-parse", "HEAD"))
    ancestor_rc, _ = run_git(
        root,
        ("merge-base", "--is-ancestor", FIXED_PUBLIC_RTL_COMMIT, head),
        check=False,
    )
    if ancestor_rc:
        raise RuntimeError("fixed public RTL commit is not an ancestor of HEAD")
    rtl_entries = filelist_sources(root)
    diff_rc, _ = run_git(
        root,
        ("diff", "--quiet", FIXED_PUBLIC_RTL_COMMIT, "--") + tuple(rtl_entries),
        check=False,
    )
    if diff_rc:
        raise RuntimeError("paired RTL differs from the fixed public architecture commit")
    records = []
    aggregate = hashlib.sha256()
    for path in rtl_entries:
        record = file_record(root, root / path)
        records.append(record)
        aggregate.update(path.encode("utf-8"))
        aggregate.update(b"\0")
        aggregate.update(record["sha256"].encode("ascii"))
        aggregate.update(b"\n")
    _, status = run_git(root, ("status", "--porcelain", "--untracked-files=no"))
    return {
        "source_head": head,
        "fixed_public_rtl_commit": FIXED_PUBLIC_RTL_COMMIT,
        "fixed_public_rtl_match": True,
        "tracked_worktree_clean": not bool(status),
        "source_set_sha256": aggregate.hexdigest(),
        "source_count": len(records),
        "files": records,
    }


def parse_key_values(path):
    values = {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def select_public_fields(values, fields):
    return {key: values[key] for key in fields if key in values}


def required_match(text, pattern, label, cast):
    match = re.search(pattern, text, flags=re.MULTILINE)
    if match is None:
        raise RuntimeError("area report lacks {}".format(label))
    return cast(match.group(1))


def parse_area_report(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    result = {}
    integer_fields = {
        "cell_count": r"^Number of cells:\s+(\d+)\s*$",
        "combinational_cell_count": r"^Number of combinational cells:\s+(\d+)\s*$",
        "sequential_cell_count": r"^Number of sequential cells:\s+(\d+)\s*$",
        "macro_count": r"^Number of macros/black boxes:\s+(\d+)\s*$",
        "buf_inv_cell_count": r"^Number of buf/inv:\s+(\d+)\s*$",
    }
    float_fields = {
        "combinational_area_um2": r"^Combinational area:\s+([0-9.+-]+)\s*$",
        "sequential_area_um2": r"^Noncombinational area:\s+([0-9.+-]+)\s*$",
        "total_cell_area_um2": r"^Total cell area:\s+([0-9.+-]+)\s*$",
    }
    for key, pattern in integer_fields.items():
        result[key] = required_match(text, pattern, key, int)
    for key, pattern in float_fields.items():
        result[key] = required_match(text, pattern, key, float)
    result["tool_version"] = required_match(
        text, r"^Version:\s+(\S+)\s*$", "tool version", str
    )
    return result


def parse_hierarchy_area(path, top):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    entries = {}
    pattern = re.compile(
        r"^(\S+)(?:[ \t]+|\r?\n[ \t]+)([0-9]+\.[0-9]+)[ \t]+",
        re.MULTILINE,
    )
    for match in pattern.finditer(text):
        entries[match.group(1)] = float(match.group(2))

    def sum_suffix(suffix):
        return sum(area for name, area in entries.items() if name.endswith(suffix))

    return {
        "top_area_um2": entries.get(top),
        "engine_area_um2": sum_suffix(".u_engine"),
        "ddr_feeder_area_um2": sum_suffix(".u_feeder"),
        "payload_commit_area_um2": sum_suffix(".u_pktbuf"),
        "entry_count": len(entries),
    }


def run_paths(root, point):
    build_root = root / "build" / point["build_tag"]
    return build_root, build_root / "dc_baseline"


def required_report_paths(root, point):
    _, dc_root = run_paths(root, point)
    return {name: dc_root / filename for name, filename in REQUIRED_REPORTS.items()}


def available_report_hashes(root, point):
    return {
        name: sha256_file(path)
        for name, path in required_report_paths(root, point).items()
        if path.is_file()
    }


def collect_run(root, point, execution, input_manifest_sha256):
    build_root, dc_root = run_paths(root, point)
    required = required_report_paths(root, point)
    missing = [name for name, path in required.items() if not path.is_file()]
    if missing:
        return {
            "status": "INCOMPLETE",
            "missing": missing,
            "build_root": relative_path(root, build_root),
        }
    closure = parse_key_values(required["closure"])
    contract = parse_key_values(required["contract"])
    execution_record = execution.get(point["key"], {})
    expected_top = (
        flowctl.BOUNDED_BUFFERED_TOP
        if point["family"] == "buffered"
        else flowctl.BOUNDED_DIRECT_TOP
    )
    return {
        "status": closure.get("status", "UNKNOWN"),
        "family": point["family"],
        "frequency_mhz": point["frequency_mhz"],
        "period_ns": point["period_ns"],
        "storage_bits": point["storage_bits"],
        "build_root": relative_path(root, build_root),
        "closure": select_public_fields(closure, PUBLIC_CLOSURE_FIELDS),
        "contract": select_public_fields(contract, PUBLIC_CONTRACT_FIELDS),
        "area": parse_area_report(required["area"]),
        "hierarchy_area": parse_hierarchy_area(required["hierarchy"], expected_top),
        "elapsed_seconds": execution_record.get("elapsed_seconds"),
        "input_manifest_sha256": input_manifest_sha256,
        "execution_input_manifest_sha256": execution_record.get(
            "input_manifest_sha256"
        ),
        "execution_report_sha256": execution_record.get("report_sha256", {}),
        "artifacts": {
            name: file_record(root, path) for name, path in required.items()
        },
    }


def gate_run(run, point):
    if run.get("status") == "INCOMPLETE":
        return False, ["incomplete reports"]
    closure = run["closure"]
    contract = run["contract"]
    failures = []
    expected = {
        "status": "PASS",
        "setup_violating_paths": "0",
        "constraint_violating_checks": "0",
        "seqgen_cell_count": "0",
        "gtech_cell_count": "0",
        "designware_cell_count": "0",
        "unmapped_cell_count": "0",
        "memory_macro_count": "0",
        "retiming": "disabled",
        "bounded_asic_family": point["family"],
        "bounded_bulk_storage_bits": str(point["storage_bits"]),
        "bounded_register_storage_bits": str(point["storage_bits"]),
        "stdcell_db_sha256": EXPECTED_DB_SHA256,
        "dc_max_cores": "4",
        "input_manifest_sha256": run.get("input_manifest_sha256"),
    }
    for key, value in expected.items():
        if closure.get(key) != value:
            failures.append("{} expected {} got {}".format(key, value, closure.get(key)))
    try:
        wns = float(closure["setup_wns"])
        tns = float(closure["setup_tns"])
    except (KeyError, ValueError):
        wns, tns = -1.0, -1.0
    if (
        not math.isfinite(wns)
        or not math.isfinite(tns)
        or wns < 0.0
        or abs(tns) > 1.0e-12
    ):
        failures.append("setup timing did not close")
    expected_top = (
        flowctl.BOUNDED_BUFFERED_TOP
        if point["family"] == "buffered"
        else flowctl.BOUNDED_DIRECT_TOP
    )
    if contract.get("top") != expected_top:
        failures.append("top identity mismatch")
    numeric_contract = (
        ("documented_clock_period_ns", "documented clock period", point["period_ns"], 1.0e-6),
        ("clock_period_library_units", "library-unit clock period", point["period_ns"], 1.0e-6),
        ("sdc_time_scale", "SDC time scale", 1.0, 1.0e-12),
    )
    for key, label, expected_value, tolerance in numeric_contract:
        try:
            actual_value = float(contract[key])
        except (KeyError, ValueError):
            failures.append("{} is missing or invalid".format(label))
            continue
        if (
            not math.isfinite(actual_value)
            or abs(actual_value - float(expected_value)) > tolerance
        ):
            failures.append(
                "{} expected {:.6f} got {}".format(
                    label, expected_value, contract.get(key)
                )
            )
    area = run.get("area", {})
    if area.get("tool_version") != EXPECTED_DC_VERSION:
        failures.append("DC version mismatch")
    if area.get("macro_count") != 0:
        failures.append("area report contains macros")
    try:
        contract_cell_count = int(contract["total_cell_count"])
    except (KeyError, ValueError):
        failures.append("run contract total cell count is missing or invalid")
    else:
        if contract_cell_count != area.get("cell_count"):
            failures.append("area report cell count differs from run contract")
    hierarchy_top_area = run.get("hierarchy_area", {}).get("top_area_um2")
    if hierarchy_top_area is None or not math.isfinite(hierarchy_top_area):
        failures.append("hierarchy report lacks finite top area")
    else:
        total_cell_area = area.get("total_cell_area_um2")
        if total_cell_area is None or not math.isfinite(total_cell_area):
            failures.append("area report lacks finite total cell area")
        elif abs(hierarchy_top_area - total_cell_area) > 1.0e-3:
            failures.append("hierarchy top area differs from total cell area")
    if run.get("execution_input_manifest_sha256") != run.get(
        "input_manifest_sha256"
    ):
        failures.append("execution input manifest identity mismatch")
    if contract.get("input_manifest_sha256") != run.get("input_manifest_sha256"):
        failures.append("run contract input manifest identity mismatch")
    expected_reports = run.get("execution_report_sha256", {})
    actual_reports = {
        name: record["sha256"] for name, record in run.get("artifacts", {}).items()
    }
    if set(expected_reports) != set(REQUIRED_REPORTS):
        failures.append("execution metadata lacks the complete report hash set")
    elif expected_reports != actual_reports:
        failures.append("collected report hashes differ from execution metadata")
    return not failures, failures


def percent_reduction(baseline, optimized):
    if baseline <= 0:
        raise RuntimeError("comparison baseline must be positive")
    return 100.0 * (baseline - optimized) / baseline


def comparison_inputs(root, identity):
    configs = {}
    for point in POINTS:
        path = root / "configs" / point["config"]
        config = flowctl.parse_config(path)
        spec = flowctl.bounded_dc_ab_spec(config)
        if spec is None or spec["family"] != point["family"]:
            raise RuntimeError("invalid paired config: {}".format(path.name))
        configs[point["key"]] = file_record(root, path)
    return {
        "source": identity,
        "filelist": file_record(root, root / FILELIST),
        "sdc": file_record(root, root / COMMON_SDC),
        "dc_run_tcl": file_record(root, root / RUN_TCL),
        "flowctl": file_record(root, root / "flows/scripts/flowctl.py"),
        "paired_runner": file_record(root, Path(__file__)),
        "configs": configs,
        "expected_stdcell_db_sha256": EXPECTED_DB_SHA256,
        "expected_dc_version": EXPECTED_DC_VERSION,
    }


def read_json_object(path, label):
    path = Path(path)
    if not path.is_file():
        raise RuntimeError("missing {}: {}".format(label, path))
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot read {} {}: {}".format(label, path, error))
    if not isinstance(value, dict):
        raise RuntimeError("{} is malformed: {}".format(label, path))
    return value


def write_input_manifest(root, orchestration_root, inputs):
    path = Path(orchestration_root) / INPUT_MANIFEST_NAME
    write_json(path, {"schema_version": 1, "inputs": inputs})
    return file_record(root, path)


def validate_bound_inputs(root, orchestration_root, current_inputs, execution):
    path = Path(orchestration_root) / INPUT_MANIFEST_NAME
    manifest = read_json_object(path, "input manifest")
    actual_record = file_record(root, path)
    expected_hash = execution.get("input_manifest_sha256")
    if expected_hash != actual_record["sha256"]:
        raise RuntimeError("execution metadata and input manifest SHA256 differ")
    if execution.get("input_manifest") != actual_record:
        raise RuntimeError("execution metadata and input manifest record differ")
    if manifest.get("schema_version") != 1 or not isinstance(
        manifest.get("inputs"), dict
    ):
        raise RuntimeError("input manifest schema is malformed: {}".format(path))
    if manifest["inputs"] != current_inputs:
        raise RuntimeError("current comparison inputs differ from the as-run manifest")
    return manifest["inputs"], actual_record


def read_execution(path):
    data = read_execution_document(path)
    return {item["key"]: item for item in data.get("runs", [])}


def read_execution_document(path):
    path = Path(path)
    if not path.is_file():
        return {"status": "NEW", "runs": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot read execution metadata {}: {}".format(path, error))
    if not isinstance(data, dict) or not isinstance(data.get("runs"), list):
        raise RuntimeError("execution metadata is malformed: {}".format(path))
    if any(not isinstance(item, dict) or "key" not in item for item in data["runs"]):
        raise RuntimeError("execution run record is malformed: {}".format(path))
    return data


def update_execution_run(execution, record):
    retained = [
        item for item in execution.get("runs", []) if item.get("key") != record["key"]
    ]
    retained.append(record)
    point_order = {point["key"]: index for index, point in enumerate(POINTS)}
    execution["runs"] = sorted(
        retained, key=lambda item: point_order.get(item.get("key"), len(POINTS))
    )


def existing_run_passes(root, point, execution, input_manifest_sha256):
    run = collect_run(root, point, execution, input_manifest_sha256)
    return gate_run(run, point)[0]


def preflight_new_run_outputs(root, orchestration_root, points):
    conflicts = []
    for point in points:
        _, dc_root = run_paths(root, point)
        if dc_root.exists():
            conflicts.append(str(dc_root))
    execution_path = Path(orchestration_root) / "execution.json"
    if execution_path.exists():
        conflicts.append(str(execution_path))
    input_manifest_path = Path(orchestration_root) / INPUT_MANIFEST_NAME
    if input_manifest_path.exists():
        conflicts.append(str(input_manifest_path))
    if conflicts:
        raise RuntimeError(
            "refusing to overwrite existing paired DC output: {}".format(
                ", ".join(conflicts)
            )
        )


def archive_retry_closure(orchestration_root, point, closure_path):
    closure_path = Path(closure_path)
    if not closure_path.is_file():
        return None
    digest = sha256_file(closure_path)[:12]
    archive_root = Path(orchestration_root) / "resume_archive"
    archive_root.mkdir(parents=True, exist_ok=True)
    archive_path = archive_root / "{}.{}.txt".format(point["key"], digest)
    if not archive_path.exists():
        shutil.copy2(str(closure_path), str(archive_path))
    closure_path.unlink()
    return archive_path


def collect(root, orchestration_root):
    root = Path(root).resolve()
    identity = source_identity(root)
    current_inputs = comparison_inputs(root, identity)
    execution_path = Path(orchestration_root) / "execution.json"
    execution_document = read_execution_document(execution_path)
    inputs, input_manifest = validate_bound_inputs(
        root, orchestration_root, current_inputs, execution_document
    )
    execution = {
        item["key"]: item for item in execution_document.get("runs", [])
    }
    runs = {
        point["key"]: collect_run(
            root, point, execution, input_manifest["sha256"]
        )
        for point in POINTS
    }
    gates = {}
    for point in POINTS:
        passed, failures = gate_run(runs[point["key"]], point)
        gates[point["key"]] = {"pass": passed, "failures": failures}
    paired_315_pass = gates["buffered315"]["pass"] and gates["direct315"]["pass"]
    comparison = None
    if paired_315_pass:
        buffered = runs["buffered315"]
        direct = runs["direct315"]
        comparison = {
            "frequency_mhz": 315,
            "area_reduction_percent": percent_reduction(
                buffered["area"]["total_cell_area_um2"],
                direct["area"]["total_cell_area_um2"],
            ),
            "cell_count_reduction_percent": percent_reduction(
                buffered["area"]["cell_count"], direct["area"]["cell_count"]
            ),
            "sequential_cell_reduction_percent": percent_reduction(
                buffered["area"]["sequential_cell_count"],
                direct["area"]["sequential_cell_count"],
            ),
            "storage_bit_reduction_percent": percent_reduction(180224, 32768),
        }
    summary = {
        "schema_version": 1,
        "comparison": "mrtc_bounded_buffered_vs_direct_register_expanded_dc",
        "status": "PASS_DC_ONLY" if paired_315_pass else "NOT_RESUME_READY",
        "inputs": inputs,
        "input_manifest": input_manifest,
        "runs": runs,
        "gates": gates,
        "dc315_comparison": comparison,
        "limitations": [
            "register-expanded DC-only architecture comparison",
            "not SRAM macro area, post-route area, power, Fmax, or foundry signoff",
            "Direct retains the 277 cycles/packet > 256 cycles/block scheduling limit",
        ],
    }
    summary["execution_status"] = final_execution_status(summary)
    return summary


def final_execution_status(summary):
    mandatory_failed = any(
        not summary["gates"][point["key"]]["pass"]
        for point in POINTS
        if is_mandatory_point(point)
    )
    if mandatory_failed:
        return "FAILED_GATES"
    stress_failed = any(
        not summary["gates"][point["key"]]["pass"]
        for point in POINTS
        if not is_mandatory_point(point)
    )
    return "COMPLETE_WITH_STRESS_FAILURE" if stress_failed else "COMPLETE"


def format_finite_float(value, precision):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "n/a"
    if not math.isfinite(number):
        return "n/a"
    return ("{:.%df}" % precision).format(number)


def render_markdown(summary):
    lines = [
        "# MRTC Bounded Buffered vs Direct-AXIS DC A/B",
        "",
        "- Status: `{}`".format(summary["status"]),
        "- Method: two Engines, register-expanded storage, common synchronous I/O budget, no retiming.",
        "",
        "| Run | WNS (ns) | Area (um2) | Cells | Sequential cells | Gate |",
        "| --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for point in POINTS:
        run = summary["runs"][point["key"]]
        gate = summary["gates"][point["key"]]
        if run.get("status") == "INCOMPLETE":
            lines.append("| {} | n/a | n/a | n/a | n/a | INCOMPLETE |".format(point["key"]))
            continue
        lines.append(
            "| {key} | {wns} | {area:.3f} | {cells} | {seq} | {gate} |".format(
                key=point["key"],
                wns=format_finite_float(run.get("closure", {}).get("setup_wns"), 6),
                area=run["area"]["total_cell_area_um2"],
                cells=run["area"]["cell_count"],
                seq=run["area"]["sequential_cell_count"],
                gate="PASS" if gate["pass"] else "FAIL",
            )
        )
    lines.extend(["", "## 315 MHz comparison", ""])
    comparison = summary.get("dc315_comparison")
    if comparison:
        lines.extend(
            [
                "- Total cell area reduction: `{:.2f}%`.".format(comparison["area_reduction_percent"]),
                "- Cell-count reduction: `{:.2f}%`.".format(comparison["cell_count_reduction_percent"]),
                "- Sequential-cell reduction: `{:.2f}%`.".format(comparison["sequential_cell_reduction_percent"]),
            ]
        )
    else:
        lines.append("No percentage is published because the paired 315 MHz gate failed.")
    lines.extend(["", "## Limitations", ""])
    lines.extend("- " + item for item in summary["limitations"])
    return "\n".join(lines) + "\n"


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(str(temporary), str(path))


def is_mandatory_point(point):
    return point["frequency_mhz"] == 315


def run_all(args):
    root = Path(args.root).resolve()
    orchestration_root = Path(args.orchestration_root).resolve()
    identity = source_identity(root)
    inputs = comparison_inputs(root, identity)
    if not identity["tracked_worktree_clean"]:
        raise RuntimeError("paired DC execution requires a tracked-clean worktree")
    if sha256_file(args.stdcell_db) != EXPECTED_DB_SHA256:
        raise RuntimeError("standard-cell DB SHA256 differs from the comparison contract")
    selected = set(args.point or [point["key"] for point in POINTS])
    unknown = selected - {point["key"] for point in POINTS}
    if unknown:
        raise RuntimeError("unknown comparison point(s): {}".format(", ".join(sorted(unknown))))
    selected_points = [point for point in POINTS if point["key"] in selected]
    execution_path = orchestration_root / "execution.json"
    if not args.resume:
        preflight_new_run_outputs(root, orchestration_root, selected_points)
        orchestration_root.mkdir(parents=True, exist_ok=True)
        input_manifest = write_input_manifest(root, orchestration_root, inputs)
        execution = {
            "status": "RUNNING",
            "runs": [],
            "input_manifest": input_manifest,
            "input_manifest_sha256": input_manifest["sha256"],
        }
    else:
        execution = read_execution_document(execution_path)
        _, input_manifest = validate_bound_inputs(
            root, orchestration_root, inputs, execution
        )
        execution["status"] = "RUNNING"
    write_json(execution_path, execution)
    for point in selected_points:
        build_root, dc_root = run_paths(root, point)
        execution_by_key = {
            item["key"]: item for item in execution.get("runs", []) if "key" in item
        }
        if args.resume and existing_run_passes(
            root, point, execution_by_key, input_manifest["sha256"]
        ):
            record = dict(execution_by_key.get(point["key"], {}))
            record.update({"key": point["key"], "status": "SKIPPED_EXISTING"})
            update_execution_run(execution, record)
            write_json(execution_path, execution)
            continue
        if args.resume:
            archive_retry_closure(
                orchestration_root, point, dc_root / "dc_closure_summary.txt"
            )
        config_path = root / "configs" / point["config"]
        log_path = orchestration_root / (point["key"] + ".log")
        command = [
            sys.executable,
            str(root / "flows/scripts/flowctl.py"),
            "--root",
            str(root),
            "--config",
            str(config_path),
            "run",
            "--stage",
            "dc-baseline",
        ]
        environment = os.environ.copy()
        environment.update(
            {
                "RDTC_TOOL_DC": args.dc_tool,
                "RDTC_DC_SETUP": str(Path(args.dc_setup).resolve()),
                "RDTC_STDCELL_DB": str(Path(args.stdcell_db).resolve()),
                "RDTC_DC_AB_INPUT_MANIFEST_SHA256": input_manifest["sha256"],
            }
        )
        started = time.monotonic()
        with log_path.open("w", encoding="utf-8") as log_stream:
            process = subprocess.Popen(
                command,
                cwd=str(root),
                env=environment,
                stdout=log_stream,
                stderr=subprocess.STDOUT,
            )
            print(
                "MRTC_DC_LAUNCH key={} pid={} run_dir={}".format(
                    point["key"], process.pid, relative_path(root, build_root)
                ),
                flush=True,
            )
            returncode = process.wait()
        update_execution_run(
            execution,
            {
                "key": point["key"],
                "returncode": returncode,
                "elapsed_seconds": round(time.monotonic() - started, 2),
                "build_root": relative_path(root, build_root),
                "log": relative_path(root, log_path),
                "input_manifest_sha256": input_manifest["sha256"],
                "report_sha256": available_report_hashes(root, point),
            },
        )
        write_json(execution_path, execution)
        if returncode:
            if is_mandatory_point(point):
                break
    summary = collect(root, orchestration_root)
    execution["status"] = summary["execution_status"]
    write_json(execution_path, execution)
    write_json(args.output, summary)
    Path(args.markdown_output).write_text(render_markdown(summary), encoding="utf-8")
    return 0 if summary["status"] == "PASS_DC_ONLY" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=SCRIPT_DIR.parents[1])
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("validate")

    collect_parser = subparsers.add_parser("collect")
    collect_parser.add_argument("--orchestration-root", required=True)
    collect_parser.add_argument("--output", required=True)
    collect_parser.add_argument("--markdown-output", required=True)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--dc-tool", required=True)
    run_parser.add_argument("--dc-setup", required=True)
    run_parser.add_argument("--stdcell-db", required=True)
    run_parser.add_argument("--orchestration-root", required=True)
    run_parser.add_argument("--output", required=True)
    run_parser.add_argument("--markdown-output", required=True)
    run_parser.add_argument("--point", action="append")
    run_parser.add_argument("--resume", action="store_true")

    args = parser.parse_args()
    if args.command is None:
        parser.error("a command is required")
    try:
        root = Path(args.root).resolve()
        if args.command == "validate":
            print(json.dumps(comparison_inputs(root, source_identity(root)), indent=2))
            return 0
        if args.command == "collect":
            summary = collect(root, args.orchestration_root)
            execution_path = Path(args.orchestration_root) / "execution.json"
            execution = read_execution_document(execution_path)
            execution["status"] = summary["execution_status"]
            write_json(execution_path, execution)
            write_json(args.output, summary)
            Path(args.markdown_output).write_text(render_markdown(summary), encoding="utf-8")
            return 0 if summary["status"] == "PASS_DC_ONLY" else 1
        return run_all(args)
    except RuntimeError as error:
        print("bounded-buffered-direct-dc-ab: error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
