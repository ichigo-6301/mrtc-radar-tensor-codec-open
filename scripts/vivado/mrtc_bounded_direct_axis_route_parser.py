#!/usr/bin/env python3
"""Run or audit the bounded direct-AXIS dual-Engine post-route gate."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Iterable
import xml.etree.ElementTree as ET
import zipfile

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
import mrtc_bounded_ht_way_ring_ooc_200m_parser as common


FLOW_NAME = "mrtc_bounded_direct_axis_route"
NAME = "mrtc_bounded_direct_axis_route_200m"
SCHEMA = 2
TOP = "mrtc_rdtc_bounded_axis_multiengine_wrapper"
PART = "xc7z100ffg900-2"
CLOCK_PERIOD_NS = "5.000"
TARGET_MHZ = 200
TCL_MARKER = "MRTC_BOUNDED_DIRECT_AXIS_ROUTE_TCL_PASS"
PASS_MARKER = "MRTC_BOUNDED_DIRECT_AXIS_ROUTE200_TIMING_CLOSED"
TIMING_FAIL_MARKER = "MRTC_BOUNDED_DIRECT_AXIS_ROUTE200_TIMING_FAIL"
FILELIST = Path("flows/manifests/rdtc_v1_bounded_direct.f")
ARTIFACT_MANIFEST = "run_artifact_manifest.json"
REQUIRED_ZERO_TIMING_CHECKS = (
    "no_clock",
    "constant_clock",
    "pulse_width_clock",
    "unconstrained_internal_endpoints",
    "multiple_clock",
    "generated_clocks",
    "loops",
    "partial_input_delay",
    "partial_output_delay",
    "latch_loops",
)
REPORT_FILES = (
    "post_synth_timing_summary.rpt",
    "post_synth_timing_worst_50.rpt",
    "post_synth_high_fanout.rpt",
    "post_place_timing_summary.rpt",
    "post_place_timing_worst_50.rpt",
    "post_place_high_fanout.rpt",
    "timing_setup_summary.rpt",
    "timing_setup_worst_50.rpt",
    "timing_hold_summary.rpt",
    "timing_hold_worst_50.rpt",
    "utilization.rpt",
    "utilization_hierarchical.rpt",
    "route_status.rpt",
    "drc.rpt",
    "methodology.rpt",
    "check_timing.rpt",
    "post_route_high_fanout.rpt",
    "all_setup_violations.tsv",
)
RUN_OUTPUTS = (
    "vivado.log",
    "vivado.jou",
    "input_identity.json",
    "tcl_identity.txt",
    "structural_audit.txt",
    "tcl_status.txt",
    "post_route.dcp",
    *REPORT_FILES,
    ARTIFACT_MANIFEST,
    "gate_summary.json",
    "terminal_status.txt",
)
RUN_BOUND_ARTIFACTS = (
    "vivado.log",
    "vivado.jou",
    "tcl_identity.txt",
    "structural_audit.txt",
    "tcl_status.txt",
    "post_route.dcp",
    *REPORT_FILES,
)


class GateError(RuntimeError):
    pass


def configure_target(target_mhz: int) -> None:
    global NAME, CLOCK_PERIOD_NS, TARGET_MHZ, PASS_MARKER, TIMING_FAIL_MARKER
    if target_mhz not in (200, 250):
        raise GateError("target frequency must be 200 or 250 MHz")
    TARGET_MHZ = target_mhz
    CLOCK_PERIOD_NS = "5.000" if target_mhz == 200 else "4.000"
    NAME = f"{FLOW_NAME}_{target_mhz}m"
    PASS_MARKER = f"MRTC_BOUNDED_DIRECT_AXIS_ROUTE{target_mhz}_TIMING_CLOSED"
    TIMING_FAIL_MARKER = (
        f"MRTC_BOUNDED_DIRECT_AXIS_ROUTE{target_mhz}_TIMING_FAIL"
    )


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[2]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_filelist(repo_root: Path) -> list[Path]:
    filelist = repo_root / FILELIST
    sources: list[Path] = []
    for raw_line in filelist.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("+incdir+"):
            continue
        if not line.endswith(".sv"):
            raise GateError(f"unsupported filelist entry: {line}")
        source = repo_root / line
        if not source.is_file():
            raise GateError(f"missing RTL source: {source}")
        sources.append(source)
    if not sources:
        raise GateError("wrapper RTL filelist contains no sources")
    return sources


def relative_hashes(repo_root: Path, paths: Iterable[Path]) -> dict[str, str]:
    return {
        path.resolve().relative_to(repo_root.resolve()).as_posix(): sha256_file(path)
        for path in paths
    }


def current_identity(repo_root: Path) -> dict[str, object]:
    script_dir = repo_root / "scripts" / "vivado"
    tracked = [
        repo_root / FILELIST,
        *parse_filelist(repo_root),
        script_dir / f"{FLOW_NAME}.tcl",
        script_dir / f"{FLOW_NAME}_200m.xdc",
        script_dir / f"{FLOW_NAME}_250m.xdc",
        script_dir / f"{FLOW_NAME}_parser.py",
        script_dir / "mrtc_bounded_ht_way_ring_ooc_200m_parser.py",
    ]
    return {
        "schema": SCHEMA,
        "top": TOP,
        "part": PART,
        "mode": "out_of_context",
        "implementation_stage": "post_route",
        "clock_period_ns": CLOCK_PERIOD_NS,
        "target_mhz": TARGET_MHZ,
        "defines": [],
        "generics": {
            "AXIS_DATA_W": 128,
            "NUM_ENGINES": 2,
            "ENGINE_BOUNDED_WAY_COUNT": 4,
            "PREFIX_SAMPLES": 128,
            "OUTPUT_FIFO_DEPTH": 16,
        },
        "inputs": relative_hashes(repo_root, tracked),
    }


def build_dir_for(repo_root: Path, build_root: Path | None) -> Path:
    root = build_root or repo_root / "build" / "vivado"
    return root / NAME


def clear_previous_outputs(build_dir: Path) -> None:
    for name in RUN_OUTPUTS:
        path = build_dir / name
        if path.is_file() or path.is_symlink():
            path.unlink()


def prepare_build(repo_root: Path, build_dir: Path) -> None:
    build_dir.mkdir(parents=True, exist_ok=True)
    (build_dir / "input_identity.json").write_text(
        json.dumps(current_identity(repo_root), indent=2, sort_keys=True) + "\n",
        encoding="ascii",
    )


def require_nonempty(build_dir: Path, names: Iterable[str]) -> None:
    for name in names:
        path = build_dir / name
        if not path.is_file() or path.stat().st_size == 0:
            raise GateError(f"required output is missing or empty: {path}")


def artifact_manifest(build_dir: Path) -> dict[str, object]:
    require_nonempty(build_dir, ("input_identity.json", *RUN_BOUND_ARTIFACTS))
    return {
        "schema": SCHEMA,
        "input_identity_sha256": sha256_file(build_dir / "input_identity.json"),
        "artifacts": {
            name: sha256_file(build_dir / name) for name in RUN_BOUND_ARTIFACTS
        },
    }


def write_artifact_manifest(build_dir: Path) -> None:
    (build_dir / ARTIFACT_MANIFEST).write_text(
        json.dumps(artifact_manifest(build_dir), indent=2, sort_keys=True) + "\n",
        encoding="ascii",
    )


def audit_artifact_manifest(build_dir: Path) -> dict[str, object]:
    recorded = json.loads(
        (build_dir / ARTIFACT_MANIFEST).read_text(encoding="ascii")
    )
    expected = artifact_manifest(build_dir)
    if recorded != expected:
        raise GateError("post-route artifact manifest is stale or inconsistent")
    return recorded


def parse_setup_pulse_summary(
    text: str,
) -> tuple[float, float, int, float, float, int]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if (
            "WNS(ns)" not in line
            or "TNS Failing Endpoints" not in line
            or "WPWS(ns)" not in line
            or "TPWS Failing Endpoints" not in line
        ):
            continue
        for candidate in lines[index + 1 : index + 8]:
            fields = candidate.split()
            if len(fields) < 7:
                continue
            try:
                values = (
                    float(fields[0]),
                    float(fields[1]),
                    int(fields[2]),
                    float(fields[4]),
                    float(fields[5]),
                    int(fields[6]),
                )
            except ValueError:
                continue
            if not all(math.isfinite(value) for value in (*values[:2], *values[3:5])):
                raise GateError("setup/pulse timing summary contains a non-finite metric")
            return values
    raise GateError("unable to parse setup and pulse-width timing summary")


def parse_timing_check_gate(text: str) -> dict[str, int]:
    checks = {
        name: common.parse_timing_check_count(text, name)
        for name in REQUIRED_ZERO_TIMING_CHECKS
    }
    checks["no_input_delay"] = common.parse_timing_check_count(
        text, "no_input_delay"
    )
    checks["no_output_delay"] = common.parse_timing_check_count(
        text, "no_output_delay"
    )
    nonzero = {name: checks[name] for name in REQUIRED_ZERO_TIMING_CHECKS if checks[name]}
    if nonzero:
        raise GateError(f"critical check_timing findings are nonzero: {nonzero}")
    return checks


def audit_dcp_identity(path: Path) -> dict[str, str]:
    try:
        with zipfile.ZipFile(path) as archive:
            root = ET.fromstring(archive.read("dcp.xml"))
            members = set(archive.namelist())
    except (KeyError, OSError, ET.ParseError, zipfile.BadZipFile) as error:
        raise GateError(f"unable to parse post-route checkpoint identity: {error}") from error

    def child_name(tag: str) -> str:
        child = root.find(tag)
        return "" if child is None else child.attrib.get("Name", "")

    identity = {
        "product": child_name("PRODUCT"),
        "part": child_name("Part"),
        "top": child_name("Top"),
        "out_of_context": child_name("OutOfContext"),
    }
    route_member = f"{TOP}.rdb"
    if identity != {
        "product": "Vivado v2022.2 (64-bit)",
        "part": PART,
        "top": TOP,
        "out_of_context": "1",
    } or route_member not in members:
        raise GateError(f"post-route checkpoint identity is unexpected: {identity}")
    return identity


def parse_hold_summary(text: str) -> tuple[float, float, int]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if "WHS(ns)" not in line or "THS Failing Endpoints" not in line:
            continue
        for candidate in lines[index + 1 : index + 8]:
            fields = candidate.split()
            if len(fields) < 3:
                continue
            try:
                whs, ths, failing = float(fields[0]), float(fields[1]), int(fields[2])
            except ValueError:
                continue
            if not math.isfinite(whs) or not math.isfinite(ths):
                raise GateError("hold timing summary contains a non-finite metric")
            return whs, ths, failing
    raise GateError("unable to parse hold WHS/THS/failing endpoints")


def parse_route_errors(text: str) -> int:
    matches = re.findall(
        r"# of nets with routing errors\.*\s*:\s*(\d+)\s*:", text
    )
    if len(matches) != 1:
        raise GateError("unable to parse routed-net error count")
    return int(matches[0])


def parse_utilization(text: str) -> dict[str, int]:
    labels = {
        "slice_luts": r"Slice LUTs\*?",
        "slice_registers": r"Slice Registers",
        "register_as_latch": r"Register as Latch",
        "lut_as_memory": r"LUT as Memory",
        "ramb18": r"RAMB18",
        "ramb36": r"RAMB36/FIFO\*",
    }
    result: dict[str, int] = {}
    for key, label in labels.items():
        matches = re.findall(
            rf"^\|\s*{label}\s*\|\s*(\d+)\s*\|", text, re.MULTILINE
        )
        if not matches or len(set(matches)) != 1:
            raise GateError(f"unable to uniquely parse utilization metric: {key}")
        result[key] = int(matches[0])
    return result


def parse_methodology_summary(text: str) -> dict[str, dict[str, object]]:
    if re.search(r"No violations were found", text, re.IGNORECASE):
        return {}
    row = re.compile(
        r"^\|\s*([A-Z][A-Z0-9-]+)\s*\|\s*"
        r"(Warning|Critical Warning|Error)\s*\|.*\|\s*(\d+)\s*\|\s*$"
    )
    result: dict[str, dict[str, object]] = {}
    for line in text.splitlines():
        match = row.match(line)
        if not match:
            continue
        rule = match.group(1)
        if rule in result:
            raise GateError(f"duplicate methodology summary row: {rule}")
        result[rule] = {"severity": match.group(2), "count": int(match.group(3))}
    if not result:
        raise GateError("unable to identify methodology result")
    allowed = {"TIMING-18", "SYNTH-6"}
    unexpected = set(result) - allowed
    if unexpected:
        raise GateError(f"unexpected methodology finding set: {sorted(unexpected)}")
    for rule, finding in result.items():
        if finding["severity"] != "Warning" or int(finding["count"]) <= 0:
            raise GateError(f"unexpected methodology finding: {rule}={finding}")
    return result


def audit_report_identity(build_dir: Path) -> dict[str, str]:
    identities = {}
    report_states = {
        "utilization.rpt": "Routed",
        "utilization_hierarchical.rpt": "Routed",
        "drc.rpt": "Fully Routed",
        "methodology.rpt": "Fully Routed",
    }
    excluded = {"route_status.rpt", "all_setup_violations.tsv"}
    abbreviated_device_reports = {
        "post_synth_high_fanout.rpt",
        "post_place_high_fanout.rpt",
        "post_route_high_fanout.rpt",
    }
    for name in (report for report in REPORT_FILES if report not in excluded):
        text = (build_dir / name).read_text(encoding="utf-8", errors="replace")
        expected_state = report_states.get(name)
        if expected_state is not None:
            state_matches = re.findall(
                r"^\| Design State\s*:\s*(.+?)\s*$", text, re.MULTILINE
            )
            if state_matches != [expected_state]:
                raise GateError(
                    f"unexpected post-route report state for {name}: {state_matches}"
                )
        if name in abbreviated_device_reports:
            identities[name] = parse_abbreviated_report_identity(text)
        else:
            identities[name] = common.parse_report_identity(text)
    unique = {json.dumps(value, sort_keys=True) for value in identities.values()}
    if len(unique) != 1:
        raise GateError(f"Vivado report identities differ: {identities}")
    identity = next(iter(identities.values()))
    if identity["top"] != TOP or identity["part"] != PART:
        raise GateError(f"Vivado report design identity is unexpected: {identity}")
    return identity


def parse_abbreviated_report_identity(
    text: str, *, expected_top: str = TOP, expected_part: str = PART
) -> dict[str, str]:
    fields: dict[str, str] = {}
    for key, pattern in {
        "tool": r"^\| Tool Version\s*:\s*Vivado v\.([0-9.]+)",
        "top": r"^\| Design\s*:\s*(\S+)",
        "device": r"^\| Device\s*:\s*(\S+)",
    }.items():
        matches = re.findall(pattern, text, re.MULTILINE)
        if len(matches) != 1:
            raise GateError(f"unable to identify abbreviated report field: {key}")
        fields[key] = matches[0]
    if fields != {"tool": "2022.2", "top": expected_top, "device": "xc7z100"}:
        raise GateError(f"abbreviated Vivado report identity is unexpected: {fields}")
    return {
        "vivado_version_short": fields["tool"],
        "top": fields["top"],
        "part": expected_part,
    }


def old_feedback_paths(text: str) -> list[str]:
    findings: list[str] = []
    for block in re.split(r"(?=^Slack \()", text, flags=re.MULTILINE):
        if not block.startswith("Slack ("):
            continue
        has_control = re.search(
            r"packet_abort|\bi_abort\b|commit_store.*ready|u_pktbuf.*(?:ready|reserve)",
            block,
            re.IGNORECASE,
        )
        has_pipeline = re.search(
            r"token_ready|p0_|p1r_|bounded_req", block, re.IGNORECASE
        )
        if has_control and has_pipeline:
            findings.append(block.splitlines()[0])
    return findings


def forbidden_removed_storage_paths(text: str) -> list[str]:
    findings: list[str] = []
    pattern = re.compile(
        r"u_pktbuf|payload_commit|payload_bram|u_feeder|ddr_feeder|"
        r"mrtc_axis_packet_buffer",
        re.IGNORECASE,
    )
    for block in re.split(r"(?=^Slack \()", text, flags=re.MULTILINE):
        if block.startswith("Slack (") and pattern.search(block):
            findings.append(block.splitlines()[0])
    return findings


def classify_setup_endpoint(startpoint: str, endpoint: str) -> str:
    def has(module: str, value: str) -> bool:
        return f".{module}/" in value or value.startswith(f"{module}/")

    start_engine = has("u_engine", startpoint)
    end_engine = has("u_engine", endpoint)
    start_fifo = has("u_output_fifo", startpoint)
    end_fifo = has("u_output_fifo", endpoint)
    if start_engine and end_engine:
        return "engine_internal"
    if start_engine and end_fifo:
        return "engine_to_output_fifo"
    if start_fifo and end_fifo:
        return "output_fifo_internal"
    if not start_engine and end_engine:
        return "wrapper_to_engine"
    if start_engine and not end_engine:
        return "engine_to_wrapper"
    if start_fifo or end_fifo or start_engine or end_engine:
        return "wrapper_cross_boundary"
    return "wrapper_other"


def parse_all_setup_violations(path: Path) -> dict[str, object]:
    with path.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != ["slack_ns", "startpoint", "endpoint"]:
            raise GateError("all-setup endpoint TSV header is unexpected")
        rows = list(reader)
    classes: Counter[str] = Counter()
    endpoints: set[str] = set()
    worst_slack: float | None = None
    for row in rows:
        try:
            slack = float(row["slack_ns"])
        except (TypeError, ValueError) as error:
            raise GateError("all-setup endpoint TSV contains invalid slack") from error
        startpoint = row["startpoint"].strip()
        endpoint = row["endpoint"].strip()
        if not math.isfinite(slack) or slack >= 0.0 or not startpoint or not endpoint:
            raise GateError("all-setup endpoint TSV contains an invalid row")
        if endpoint in endpoints:
            raise GateError(f"duplicate violating endpoint: {endpoint}")
        endpoints.add(endpoint)
        classes[classify_setup_endpoint(startpoint, endpoint)] += 1
        worst_slack = slack if worst_slack is None else min(worst_slack, slack)
    return {
        "count": len(rows),
        "worst_slack_ns": worst_slack,
        "classification": dict(sorted(classes.items())),
    }


def audit_build(repo_root: Path, build_dir: Path) -> dict[str, object]:
    require_nonempty(
        build_dir,
        (
            "input_identity.json",
            "vivado.log",
            "tcl_identity.txt",
            "structural_audit.txt",
            "tcl_status.txt",
            "post_route.dcp",
            ARTIFACT_MANIFEST,
            *REPORT_FILES,
        ),
    )
    recorded = json.loads((build_dir / "input_identity.json").read_text(encoding="ascii"))
    if recorded != current_identity(repo_root):
        raise GateError("input identity is stale or does not match current sources")
    run_artifacts = audit_artifact_manifest(build_dir)

    tcl_identity = common.parse_key_values(build_dir / "tcl_identity.txt")
    version = tcl_identity.get("vivado_version_short", "")
    all_setup = parse_all_setup_violations(
        build_dir / "all_setup_violations.tsv"
    )
    expected_tcl = {
        "schema": str(SCHEMA),
        "vivado_version_short": version,
        "top": TOP,
        "part": PART,
        "mode": "out_of_context",
        "implementation_stage": "post_route",
        "flatten_hierarchy": "none",
        "clock_period_ns": CLOCK_PERIOD_NS,
        "target_mhz": str(TARGET_MHZ),
        "hd_clk_src": "BUFGCTRL_X0Y0",
        "axis_data_w": "128",
        "num_engines": "2",
        "way_count": "4",
        "way_depth_words": "32",
        "prefix_samples": "128",
        "output_fifo_depth": "16",
        "defines": "",
        "negative_setup_endpoint_count": str(all_setup["count"]),
    }
    if version != "2022.2" or tcl_identity != expected_tcl:
        raise GateError("Tcl design identity is incomplete or unexpected")

    structural = common.parse_key_values(build_dir / "structural_audit.txt")
    if structural != {
        "schema": str(SCHEMA),
        "top": TOP,
        "num_engines": "2",
        "way_count": "8",
        "way_depth_words": "32",
        "prefix_samples": "128",
        "output_fifo_depth": "16",
        "ring_count": "2",
        "commit_store_count": "0",
        "payload_bram_leaf_count": "0",
        "payload_slot_leaf_count": "0",
        "ddr_feeder_count": "0",
        "feeder_fifo_leaf_count": "0",
        "width_packer_count": "2",
        "ingress_queue_count": "2",
        "output_fifo_count": "1",
        "legacy_packet_buffer_count": "0",
        "legacy_accumulator_count": "0",
        "blackbox_count": "0",
        "latch_count": "0",
        "global_lutram_primitive_count": structural.get(
            "global_lutram_primitive_count", ""
        ),
        "ring_lutram_primitive_count": "1024",
        "output_fifo_lutram_primitive_count": structural.get(
            "output_fifo_lutram_primitive_count", ""
        ),
        "output_fifo_srl_primitive_count": structural.get(
            "output_fifo_srl_primitive_count", ""
        ),
        "output_fifo_ff_primitive_count": structural.get(
            "output_fifo_ff_primitive_count", ""
        ),
        "ramb36_count": "0",
        "ramb18_count": "0",
    }:
        raise GateError("direct wrapper structural audit is incomplete or unexpected")

    for key in (
        "global_lutram_primitive_count",
        "output_fifo_lutram_primitive_count",
        "output_fifo_srl_primitive_count",
        "output_fifo_ff_primitive_count",
    ):
        try:
            value = int(structural[key])
        except (KeyError, ValueError) as error:
            raise GateError(f"invalid structural primitive count: {key}") from error
        if value < 0:
            raise GateError(f"negative structural primitive count: {key}")
    if int(structural["global_lutram_primitive_count"]) != (
        1024 + int(structural["output_fifo_lutram_primitive_count"])
    ):
        raise GateError("global LUTRAM is not fully attributed to ring and output FIFO")

    status = (build_dir / "tcl_status.txt").read_text(encoding="ascii").strip()
    log = (build_dir / "vivado.log").read_text(encoding="utf-8", errors="replace")
    if status != TCL_MARKER or TCL_MARKER not in log:
        raise GateError("terminal Tcl PASS marker is missing")
    unresolved = common.find_unresolved_references(log)
    if unresolved:
        raise GateError(f"unresolved RTL reference detected: {unresolved[0]}")

    report_identity = audit_report_identity(build_dir)
    if report_identity["vivado_version_short"] != "2022.2":
        raise GateError("Vivado report version must be exactly 2022.2")
    dcp_identity = audit_dcp_identity(build_dir / "post_route.dcp")

    setup_text = (build_dir / "timing_setup_summary.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    hold_text = (build_dir / "timing_hold_summary.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    (
        setup_wns,
        setup_tns,
        setup_failing,
        pulse_wns,
        pulse_tns,
        pulse_failing,
    ) = parse_setup_pulse_summary(setup_text)
    hold_wns, hold_tns, hold_failing = parse_hold_summary(hold_text)
    if all_setup["count"] != setup_failing:
        raise GateError(
            "all-setup endpoint count does not match timing summary: "
            f"{all_setup['count']} != {setup_failing}"
        )
    if setup_failing == 0 and all_setup["worst_slack_ns"] is not None:
        raise GateError("closed timing summary has violating endpoint rows")
    if setup_failing != 0 and all_setup["worst_slack_ns"] is None:
        raise GateError("failing timing summary has no violating endpoint rows")
    timing_checks = parse_timing_check_gate(
        (build_dir / "check_timing.rpt").read_text(
            encoding="utf-8", errors="replace"
        )
    )

    route_errors = parse_route_errors(
        (build_dir / "route_status.rpt").read_text(
            encoding="utf-8", errors="replace"
        )
    )
    if route_errors != 0:
        raise GateError(f"route contains {route_errors} nets with errors")
    drc = common.parse_drc_summary(
        (build_dir / "drc.rpt").read_text(encoding="utf-8", errors="replace")
    )
    if drc != common.EXPECTED_DRC_FINDINGS:
        raise GateError(
            f"DRC finding set drifted: expected {common.EXPECTED_DRC_FINDINGS}, got {drc}"
        )
    methodology = parse_methodology_summary(
        (build_dir / "methodology.rpt").read_text(
            encoding="utf-8", errors="replace"
        )
    )

    setup_paths_text = (build_dir / "timing_setup_worst_50.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    feedback = old_feedback_paths(setup_paths_text)
    if feedback:
        raise GateError(f"old abort/ready feedback path remains: {feedback[0]}")
    removed_storage_paths = forbidden_removed_storage_paths(setup_paths_text)
    if removed_storage_paths:
        raise GateError(
            "removed DDR/payload storage appears in a timing path: "
            f"{removed_storage_paths[0]}"
        )
    setup_paths = common.parse_worst_paths(setup_paths_text)
    hold_paths = common.parse_worst_paths(
        (build_dir / "timing_hold_worst_50.rpt").read_text(
            encoding="utf-8", errors="replace"
        )
    )
    utilization = parse_utilization(
        (build_dir / "utilization.rpt").read_text(
            encoding="utf-8", errors="replace"
        )
    )
    if utilization["register_as_latch"] != 0:
        raise GateError("utilization report contains inferred latches")
    if utilization["ramb18"] != 0 or utilization["ramb36"] != 0:
        raise GateError("direct wrapper utilization unexpectedly contains block RAM")
    if utilization["slice_luts"] >= 40000 or utilization["slice_registers"] >= 30000:
        raise GateError("direct wrapper exceeded its 40k LUT / 30k FF ceiling")

    timing_closed = (
        setup_wns >= 0.0
        and abs(setup_tns) <= 1e-9
        and setup_failing == 0
        and pulse_wns >= 0.0
        and abs(pulse_tns) <= 1e-9
        and pulse_failing == 0
        and hold_wns >= 0.0
        and abs(hold_tns) <= 1e-9
        and hold_failing == 0
    )
    result = "PASS" if timing_closed else "TIMING_FAIL"
    summary: dict[str, object] = {
        "schema": SCHEMA,
        "result": result,
        "top": TOP,
        "part": PART,
        "mode": "out_of_context",
        "implementation_stage": "post_route",
        "clock_period_ns": float(CLOCK_PERIOD_NS),
        "target_mhz": TARGET_MHZ,
        "setup_wns_ns": setup_wns,
        "setup_tns_ns": setup_tns,
        "setup_failing_endpoints": setup_failing,
        "pulse_width_wns_ns": pulse_wns,
        "pulse_width_tns_ns": pulse_tns,
        "pulse_width_failing_endpoints": pulse_failing,
        "hold_wns_ns": hold_wns,
        "hold_tns_ns": hold_tns,
        "hold_failing_endpoints": hold_failing,
        "timing_check_counts": timing_checks,
        "route_error_net_count": route_errors,
        "drc_findings": drc,
        "methodology_findings": methodology,
        "old_feedback_path_count": len(feedback),
        "removed_storage_path_count": len(removed_storage_paths),
        "all_setup_violations": all_setup,
        "scheduler_functional_gate": "FAILED_SERVICE_TIME_EXCEEDS_ARRIVAL_INTERVAL",
        "scheduler_service_cycles": 277,
        "scheduler_arrival_interval_cycles": 256,
        "utilization": utilization,
        "setup_worst_50_path_classification": setup_paths,
        "hold_worst_50_path_classification": hold_paths,
        "vivado": report_identity,
        "post_route_checkpoint_identity": dcp_identity,
        "input_identity_sha256": sha256_file(build_dir / "input_identity.json"),
        "run_artifact_manifest_sha256": sha256_file(
            build_dir / ARTIFACT_MANIFEST
        ),
        "run_artifact_count": len(run_artifacts["artifacts"]),
        "report_sha256": {
            name: sha256_file(build_dir / name) for name in REPORT_FILES
        },
        "post_route_checkpoint_sha256": sha256_file(build_dir / "post_route.dcp"),
    }
    (build_dir / "gate_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )
    marker = PASS_MARKER if timing_closed else TIMING_FAIL_MARKER
    (build_dir / "terminal_status.txt").write_text(marker + "\n", encoding="ascii")
    return summary


def build_vivado_command(vivado: str, arguments: list[str]) -> list[str]:
    candidate = Path(vivado)
    resolved = (
        str(candidate.resolve())
        if candidate.is_file()
        else (shutil.which(vivado) or vivado)
    )
    if os.name != "nt" or Path(resolved).suffix.lower() not in {".bat", ".cmd"}:
        return [resolved, *arguments]
    shell = os.environ.get("COMSPEC") or shutil.which("cmd.exe")
    if not shell:
        raise GateError("Windows command shell is unavailable")
    return [shell, "/d", "/s", "/c", subprocess.list2cmdline([resolved, *arguments])]


def run_vivado(repo_root: Path, build_dir: Path, vivado: str) -> dict[str, object]:
    clear_previous_outputs(build_dir)
    prepare_build(repo_root, build_dir)
    arguments = [
        "-mode",
        "batch",
        "-source",
        str(repo_root / "scripts" / "vivado" / f"{FLOW_NAME}.tcl"),
        "-log",
        str(build_dir / "vivado.log"),
        "-journal",
        str(build_dir / "vivado.jou"),
    ]
    environment = os.environ.copy()
    environment["MRTC_DIRECT_ROUTE_OUT_DIR"] = str(build_dir)
    environment["MRTC_DIRECT_TARGET_MHZ"] = str(TARGET_MHZ)
    environment["MRTC_DIRECT_CLOCK_PERIOD_NS"] = CLOCK_PERIOD_NS
    completed = subprocess.run(
        build_vivado_command(vivado, arguments),
        cwd=repo_root,
        env=environment,
        check=False,
    )
    if completed.returncode != 0:
        raise GateError(f"Vivado exited with status {completed.returncode}")
    write_artifact_manifest(build_dir)
    return audit_build(repo_root, build_dir)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--run", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--vivado", default=os.environ.get("VIVADO", "vivado"))
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--target-mhz", type=int, choices=(200, 250), default=200)
    args = parser.parse_args(argv)

    try:
        configure_target(args.target_mhz)
        repo_root = repo_root_from_script()
        build_dir = build_dir_for(repo_root, args.build_root)
        if args.run and TARGET_MHZ == 250:
            configure_target(200)
            prerequisite_dir = build_dir_for(repo_root, args.build_root)
            prerequisite = audit_build(repo_root, prerequisite_dir)
            if prerequisite["result"] != "PASS":
                raise GateError("250 MHz stress requires a closed fresh 200 MHz run")
            configure_target(250)
            build_dir = build_dir_for(repo_root, args.build_root)
        result = (
            run_vivado(repo_root, build_dir, args.vivado)
            if args.run
            else audit_build(repo_root, build_dir)
        )
    except (
        GateError,
        common.GateError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ) as error:
        message = str(error).encode("ascii", errors="backslashreplace").decode("ascii")
        print(f"{NAME}: FAIL: {message}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
