#!/usr/bin/env python3
"""Run or audit the bounded payload-commit Vivado OOC gate."""

from __future__ import annotations

import argparse
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


NAME = "mrtc_bounded_ht_way_ring_ooc_200m"
SCHEMA = 3
TOP = "mrtc_rdtc_ddr_multiengine_wrapper"
PART = "xc7z100ffg900-2"
CLOCK_PERIOD_NS = "5.000"
TARGET_MHZ = 200
NUM_ENGINES = 2
WAY_COUNT = 4
WAY_DEPTH_WORDS = 32
PAYLOAD_DEPTHS = (256, 512)
WAY_LUTRAM_PRIMITIVES = 128
TOTAL_RING_LUTRAM_PRIMITIVES = NUM_ENGINES * WAY_COUNT * WAY_LUTRAM_PRIMITIVES
PAYLOAD_BRAM_EQUIVALENT_X2_PER_ENGINE = 4
DEFINES = ("RDTC_BOUNDED_HT_WAY_RING",)
EXPECTED_DRC_FINDINGS = {"ZPS7-1": {"severity": "Warning", "count": 1}}
TCL_MARKER = "MRTC_BOUNDED_HT_WAY_RING_OOC_TCL_PASS"
PASS_MARKER = "MRTC_BOUNDED_HT_WAY_RING_OOC_200M_PASS"
TIMING_FAIL_MARKER = "MRTC_BOUNDED_HT_WAY_RING_OOC_200M_TIMING_FAIL"
REPORT_FILES = (
    "timing_summary.rpt",
    "timing_worst_50.rpt",
    "utilization.rpt",
    "utilization_hierarchical.rpt",
    "drc.rpt",
    "check_timing.rpt",
)
RUN_OUTPUTS = (
    "vivado.log",
    "vivado.jou",
    "input_identity.json",
    "tcl_identity.txt",
    "structural_audit.txt",
    "tcl_status.txt",
    *REPORT_FILES,
    "gate_summary.json",
    "terminal_status.txt",
)


class GateError(RuntimeError):
    pass


def ascii_safe_error(error: BaseException) -> str:
    return str(error).encode("ascii", errors="backslashreplace").decode("ascii")


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[2]


def validate_payload_depth(payload_depth: int) -> None:
    if payload_depth not in PAYLOAD_DEPTHS:
        raise GateError(f"unsupported payload depth: {payload_depth}")


def profile_name(payload_depth: int) -> str:
    validate_payload_depth(payload_depth)
    return f"way4_payload{payload_depth}"


def default_build_dir(repo_root: Path, payload_depth: int) -> Path:
    return repo_root / "build" / "vivado" / f"{NAME}_{profile_name(payload_depth)}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_filelist(repo_root: Path) -> list[Path]:
    filelist = repo_root / "scripts" / "rtl_synth_core_filelist.f"
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
    return sources


def relative_hashes(repo_root: Path, paths: Iterable[Path]) -> dict[str, str]:
    return {
        path.resolve().relative_to(repo_root.resolve()).as_posix(): sha256_file(path)
        for path in paths
    }


def current_identity(repo_root: Path, payload_depth: int) -> dict[str, object]:
    profile = profile_name(payload_depth)
    script_dir = repo_root / "scripts" / "vivado"
    tracked = [
        repo_root / "scripts" / "rtl_synth_core_filelist.f",
        *parse_filelist(repo_root),
        script_dir / f"{NAME}.tcl",
        script_dir / f"{NAME}.xdc",
        script_dir / f"{NAME}_parser.py",
        script_dir / f"{NAME}_run.bat",
    ]
    return {
        "schema": SCHEMA,
        "profile": profile,
        "top": TOP,
        "part": PART,
        "mode": "out_of_context",
        "clock_period_ns": CLOCK_PERIOD_NS,
        "target_mhz": TARGET_MHZ,
        "num_engines": NUM_ENGINES,
        "way_count": WAY_COUNT,
        "way_depth_words": WAY_DEPTH_WORDS,
        "payload_depth": payload_depth,
        "defines": list(DEFINES),
        "inputs": relative_hashes(repo_root, tracked),
    }


def prepare_build(repo_root: Path, build_dir: Path, payload_depth: int) -> None:
    build_dir.mkdir(parents=True, exist_ok=True)
    identity = current_identity(repo_root, payload_depth)
    (build_dir / "input_identity.json").write_text(
        json.dumps(identity, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )


def clear_previous_outputs(build_dir: Path) -> None:
    for name in RUN_OUTPUTS:
        path = build_dir / name
        if path.is_file() or path.is_symlink():
            path.unlink()


def require_nonempty(build_dir: Path, names: Iterable[str]) -> None:
    for name in names:
        path = build_dir / name
        if not path.is_file() or path.stat().st_size == 0:
            raise GateError(f"required output is missing or empty: {path}")


def parse_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw_line.strip():
            continue
        if "=" not in raw_line:
            raise GateError(f"malformed key/value line in {path.name}: {raw_line!r}")
        key, value = (part.strip() for part in raw_line.split("=", 1))
        if not key or key in values:
            raise GateError(f"duplicate or empty key in {path.name}: {key!r}")
        values[key] = value
    return values


def parse_report_field(text: str, field: str) -> str:
    matches = re.findall(
        rf"^\|\s*{re.escape(field)}\s*:\s*(.*?)\s*$", text, re.MULTILINE
    )
    if len(matches) != 1 or not matches[0]:
        raise GateError(f"unable to identify Vivado report field: {field}")
    return matches[0]


def parse_optional_report_field(text: str, field: str) -> str | None:
    matches = re.findall(
        rf"^\|\s*{re.escape(field)}\s*:\s*(.*?)\s*$", text, re.MULTILINE
    )
    if len(matches) > 1:
        raise GateError(f"duplicate Vivado report field: {field}")
    return matches[0] if matches else None


def normalize_report_part(device: str, speed_file: str | None) -> str:
    device = device.strip()
    full_device = device if device.startswith("xc") else "xc" + device
    if full_device == PART:
        expected_speed = "-" + PART.rsplit("-", 1)[1]
        if speed_file is not None and speed_file.split()[0] != expected_speed:
            raise GateError(f"Vivado report speed identity is unexpected: {speed_file}")
        return PART
    if speed_file is None:
        raise GateError(
            f"Vivado report omits speed identity for an abbreviated device: {device}"
        )
    speed_match = re.search(r"(-[0-9]+)$", PART)
    speed = speed_file.split()[0]
    if not speed_match or speed != speed_match.group(1):
        raise GateError(f"Vivado report speed identity is unexpected: {speed_file}")
    base = device.replace("-", "")
    if not base.startswith("xc"):
        base = "xc" + base
    candidate = base if base.endswith(speed) else base + speed
    if candidate != PART:
        raise GateError(f"Vivado report device identity is unexpected: {device}")
    return candidate


def parse_report_identity(text: str) -> dict[str, str]:
    tool = parse_report_field(text, "Tool Version")
    version = re.search(r"\bVivado\s+v?\.?([0-9]+(?:\.[0-9]+)+)\b", tool)
    if not version:
        raise GateError(f"unable to normalize Vivado tool version: {tool}")
    return {
        "vivado_version_short": version.group(1),
        "top": parse_report_field(text, "Design"),
        "part": normalize_report_part(
            parse_report_field(text, "Device"),
            parse_optional_report_field(text, "Speed File"),
        ),
    }


def parse_report_identities(build_dir: Path) -> dict[str, str]:
    identities = {
        name: parse_report_identity(
            (build_dir / name).read_text(encoding="utf-8", errors="replace")
        )
        for name in REPORT_FILES
    }
    if len({json.dumps(value, sort_keys=True) for value in identities.values()}) != 1:
        raise GateError(f"Vivado report identities differ: {identities}")
    identity = next(iter(identities.values()))
    if identity["top"] != TOP or identity["part"] != PART:
        raise GateError(f"Vivado report design identity is unexpected: {identity}")
    return identity


def parse_setup_summary(text: str) -> tuple[float, float, int]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if "WNS(ns)" not in line or "TNS Failing Endpoints" not in line:
            continue
        for candidate in lines[index + 1 : index + 8]:
            fields = candidate.split()
            if len(fields) < 3:
                continue
            try:
                wns, tns, failing = float(fields[0]), float(fields[1]), int(fields[2])
            except ValueError:
                continue
            if not math.isfinite(wns) or not math.isfinite(tns):
                raise GateError("timing summary contains a non-finite metric")
            return wns, tns, failing
    raise GateError("unable to parse setup WNS/TNS/failing endpoints")


def parse_timing_check_count(text: str, check_name: str) -> int:
    matches = re.findall(
        rf"^\s*\d+\.\s+checking\s+{re.escape(check_name)}\s+\((\d+)\)\s*$",
        text,
        re.MULTILINE,
    )
    if not matches or len(set(matches)) != 1:
        raise GateError(f"unable to identify timing check count: {check_name}")
    return int(matches[0])


def parse_utilization(text: str) -> dict[str, int]:
    labels = {
        "slice_luts": r"Slice LUTs\*",
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
        if len(matches) != 1:
            raise GateError(f"unable to uniquely parse utilization metric: {key}")
        result[key] = int(matches[0])
    return result


def parse_drc_summary(text: str) -> dict[str, dict[str, object]]:
    if re.search(r"No DRC violations were found", text, re.IGNORECASE):
        return {}
    result: dict[str, dict[str, object]] = {}
    row = re.compile(
        r"^\|\s*([A-Z][A-Z0-9-]+)\s*\|\s*"
        r"(Warning|Critical Warning|Error)\s*\|.*\|\s*(\d+)\s*\|\s*$"
    )
    for line in text.splitlines():
        match = row.match(line)
        if not match:
            continue
        rule = match.group(1)
        if rule in result:
            raise GateError(f"duplicate DRC summary row: {rule}")
        result[rule] = {"severity": match.group(2), "count": int(match.group(3))}
    if not result:
        raise GateError("unable to identify a clean DRC result or DRC summary table")
    return result


def classify_endpoint(endpoint: str) -> str:
    lowered = endpoint.lower()
    classes = (
        ("payload_ram", ("u_payload_ram",)),
        ("payload_commit_store", ("payload_commit_store", "u_pktbuf")),
        ("way_ring", ("u_way_ring", "g_way[", "u_way/")),
        ("bitpacker", ("u_bpack", "u_rice_bitpacker", "width_packer", "p0_", "p1_", "p2_")),
        ("prefix", ("u_prefix", "u_k_policy", "selected_k", "prefix_")),
        ("feeder", ("u_feeder", "feeder_")),
        ("output_elastic", ("output_elastic", "out_axis", "m_axis", "arb_", "packet_lock")),
    )
    for name, tokens in classes:
        if any(token in lowered for token in tokens):
            return name
    return "other"


def parse_worst_paths(text: str) -> dict[str, object]:
    blocks = re.split(r"(?=^Slack\s+\()", text, flags=re.MULTILINE)[1:]
    classes: Counter[str] = Counter()
    examples: list[dict[str, object]] = []
    for index, block in enumerate(blocks):
        slack_match = re.search(
            r"^Slack\s+\([^)]*\)\s*:\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))ns",
            block,
            re.MULTILINE,
        )
        source_match = re.search(
            r"^\s*(?:Source|Startpoint):\s*(\S+)", block, re.MULTILINE
        )
        dest_match = re.search(
            r"^\s*(?:Destination|Endpoint):\s*(\S+)", block, re.MULTILINE
        )
        if not slack_match or not source_match or not dest_match:
            raise GateError(f"unable to parse worst timing path block {index}")
        slack = float(slack_match.group(1))
        if not math.isfinite(slack):
            raise GateError("worst timing path contains non-finite slack")
        source, destination = source_match.group(1), dest_match.group(1)
        path_class = f"{classify_endpoint(source)}->{classify_endpoint(destination)}"
        classes[path_class] += 1
        examples.append(
            {
                "rank": index + 1,
                "slack_ns": slack,
                "source": source,
                "destination": destination,
                "class": path_class,
            }
        )
    if not blocks or len(blocks) > 50:
        raise GateError(f"worst timing report contains {len(blocks)} paths, expected 1..50")
    return {
        "path_count": len(blocks),
        "classes": dict(sorted(classes.items())),
        "paths": examples,
    }


def find_unresolved_references(log_text: str) -> list[str]:
    patterns = (
        re.compile(r"unresolved reference", re.IGNORECASE),
        re.compile(r"\[Synth 8-439\].*module .* not found", re.IGNORECASE),
        re.compile(r"failed to synthesize module", re.IGNORECASE),
        re.compile(r"could not resolve .*reference", re.IGNORECASE),
    )
    return [
        line.strip()
        for line in log_text.splitlines()
        if any(pattern.search(line) for pattern in patterns)
    ]


def _int_value(values: dict[str, str], key: str) -> int:
    try:
        return int(values[key])
    except (KeyError, ValueError) as error:
        raise GateError(f"structural audit integer is malformed: {key}") from error


def audit_structure(values: dict[str, str], payload_depth: int) -> dict[str, object]:
    profile = profile_name(payload_depth)
    expected_common = {
        "schema": str(SCHEMA),
        "profile": profile,
        "num_engines": str(NUM_ENGINES),
        "expected_ways_per_engine": str(WAY_COUNT),
        "way_depth_words": str(WAY_DEPTH_WORDS),
        "payload_depth": str(payload_depth),
        "engine_hierarchy_count": str(NUM_ENGINES),
        "ring_hierarchy_count": str(NUM_ENGINES),
        "way_hierarchy_count": str(NUM_ENGINES * WAY_COUNT),
        "commit_store_hierarchy_count": str(NUM_ENGINES),
        "payload_bram_hierarchy_count": str(NUM_ENGINES),
        "legacy_packet_buffer_hierarchy_count": "0",
        "blackbox_count": "0",
        "latch_count": "0",
        "global_uram_primitive_count": "0",
        "global_fifo_primitive_count": "0",
        "ring_memory_unowned_count": "0",
        "ring_memory_multiply_owned_count": "0",
        "ring_memory_primitive_count": str(TOTAL_RING_LUTRAM_PRIMITIVES),
        "payload_bram_unowned_count": "0",
        "payload_bram_multiply_owned_count": "0",
    }
    for key, expected in expected_common.items():
        if values.get(key) != expected:
            raise GateError(
                f"structural audit mismatch {key}: {values.get(key)!r} != {expected!r}"
            )

    expected_keys = set(expected_common)
    expected_keys.update(
        (
            "global_lutram_primitive_count",
            "non_ring_lutram_primitive_count",
            "global_ramb18_primitive_count",
            "global_ramb36_primitive_count",
        )
    )
    global_lutram = _int_value(values, "global_lutram_primitive_count")
    non_ring_lutram = _int_value(values, "non_ring_lutram_primitive_count")
    if global_lutram < TOTAL_RING_LUTRAM_PRIMITIVES:
        raise GateError("global LUTRAM count is smaller than the 4-way ring contract")
    if non_ring_lutram != global_lutram - TOTAL_RING_LUTRAM_PRIMITIVES:
        raise GateError("non-ring LUTRAM accounting is inconsistent")
    global_ramb18 = _int_value(values, "global_ramb18_primitive_count")
    global_ramb36 = _int_value(values, "global_ramb36_primitive_count")
    if 2 * global_ramb36 + global_ramb18 != (
        NUM_ENGINES * PAYLOAD_BRAM_EQUIVALENT_X2_PER_ENGINE
    ):
        raise GateError("global payload BRAM capacity/mapping is unexpected")
    if payload_depth == 512 and (global_ramb36 != 4 or global_ramb18 != 0):
        raise GateError("512-deep payload mapping must be exactly four RAMB36 primitives")

    engines: list[dict[str, object]] = []
    total_ring_primitives = 0
    total_payload_ramb18 = 0
    total_payload_ramb36 = 0
    for engine in range(NUM_ENGINES):
        fields = {
            "path": f"engine_{engine}_path",
            "ring_path": f"engine_{engine}_ring_path",
            "way_count": f"engine_{engine}_way_count",
            "ring_count": f"engine_{engine}_ring_memory_primitive_count",
            "store_path": f"engine_{engine}_commit_store_path",
            "payload_path": f"engine_{engine}_payload_bram_path",
            "ramb18": f"engine_{engine}_payload_ramb18_count",
            "ramb36": f"engine_{engine}_payload_ramb36_count",
            "equiv_x2": f"engine_{engine}_payload_bram_equivalent_x2",
            "refs": f"engine_{engine}_payload_bram_ref_names",
            "lutram": f"engine_{engine}_payload_lutram_count",
            "ff": f"engine_{engine}_payload_ff_count",
            "uram": f"engine_{engine}_payload_uram_count",
            "fifo": f"engine_{engine}_payload_fifo_count",
        }
        expected_keys.update(fields.values())
        engine_path = values.get(fields["path"], "")
        ring_path = values.get(fields["ring_path"], "")
        store_path = values.get(fields["store_path"], "")
        payload_path = values.get(fields["payload_path"], "")
        if not engine_path.endswith(f"g_engine[{engine}].u_engine"):
            raise GateError(f"engine {engine} hierarchy identity is malformed")
        if not ring_path.startswith(engine_path + "/"):
            raise GateError(f"engine {engine} ring hierarchy identity is malformed")
        if not store_path.endswith(f"g_engine[{engine}].u_pktbuf"):
            raise GateError(f"engine {engine} commit store hierarchy identity is malformed")
        if not payload_path.startswith(store_path + "/") or not payload_path.endswith(
            "/u_payload_ram"
        ):
            raise GateError(f"engine {engine} payload BRAM hierarchy identity is malformed")
        if values.get(fields["way_count"]) != str(WAY_COUNT):
            raise GateError(f"engine {engine} does not contain exactly {WAY_COUNT} ways")
        ring_count = _int_value(values, fields["ring_count"])
        if ring_count != WAY_COUNT * WAY_LUTRAM_PRIMITIVES:
            raise GateError(f"engine {engine} ring LUTRAM primitive count drifted")

        ramb18 = _int_value(values, fields["ramb18"])
        ramb36 = _int_value(values, fields["ramb36"])
        equiv_x2 = _int_value(values, fields["equiv_x2"])
        if equiv_x2 != PAYLOAD_BRAM_EQUIVALENT_X2_PER_ENGINE:
            raise GateError(f"engine {engine} payload BRAM capacity/mapping is unexpected")
        if 2 * ramb36 + ramb18 != equiv_x2:
            raise GateError(f"engine {engine} payload BRAM accounting is inconsistent")
        if payload_depth == 512 and (ramb36 != 2 or ramb18 != 0):
            raise GateError(
                f"engine {engine} 512-deep payload must map to exactly two RAMB36 primitives"
            )
        refs = tuple(item for item in values.get(fields["refs"], "").split(",") if item)
        expected_refs = tuple(
            ref
            for ref, count in (("RAMB18E1", ramb18), ("RAMB36E1", ramb36))
            if count
        )
        if refs != expected_refs:
            raise GateError(f"engine {engine} payload BRAM reference set drifted")
        for forbidden in ("lutram", "ff", "uram", "fifo"):
            if values.get(fields[forbidden]) != "0":
                raise GateError(
                    f"engine {engine} payload BRAM leaf contains forbidden {forbidden} primitives"
                )

        ways: list[dict[str, object]] = []
        way_sum = 0
        for way in range(WAY_COUNT):
            path_key = f"engine_{engine}_way_{way}_path"
            count_key = f"engine_{engine}_way_{way}_memory_primitive_count"
            refs_key = f"engine_{engine}_way_{way}_memory_primitive_ref_names"
            expected_keys.update((path_key, count_key, refs_key))
            path = values.get(path_key, "")
            if not path.startswith(ring_path + "/") or not path.endswith(
                f"g_way[{way}].u_way"
            ):
                raise GateError(f"engine {engine} way {way} hierarchy identity is malformed")
            count = _int_value(values, count_key)
            refs_for_way = tuple(item for item in values.get(refs_key, "").split(",") if item)
            if count != WAY_LUTRAM_PRIMITIVES or refs_for_way != ("RAM32X1S",):
                raise GateError(f"engine {engine} way {way} LUTRAM mapping drifted")
            way_sum += count
            ways.append(
                {
                    "index": way,
                    "path": path,
                    "memory_primitive_count": count,
                    "memory_ref_names": refs_for_way,
                }
            )
        if way_sum != ring_count:
            raise GateError(f"engine {engine} ring memory is not partitioned uniquely by way")

        total_ring_primitives += ring_count
        total_payload_ramb18 += ramb18
        total_payload_ramb36 += ramb36
        engines.append(
            {
                "index": engine,
                "path": engine_path,
                "ring_path": ring_path,
                "commit_store_path": store_path,
                "payload_bram_path": payload_path,
                "ring_memory_primitive_count": ring_count,
                "payload_ramb18_count": ramb18,
                "payload_ramb36_count": ramb36,
                "payload_bram_equivalent_x2": equiv_x2,
                "payload_bram_ref_names": refs,
                "ways": ways,
            }
        )

    if total_ring_primitives != TOTAL_RING_LUTRAM_PRIMITIVES:
        raise GateError("ring LUTRAM total does not match the 1024-primitive contract")
    if total_payload_ramb18 != global_ramb18 or total_payload_ramb36 != global_ramb36:
        raise GateError("payload BRAM primitives are not uniquely owned by the two leaves")
    if set(values) != expected_keys:
        missing = sorted(expected_keys - set(values))
        extra = sorted(set(values) - expected_keys)
        raise GateError(f"structural audit key set drifted: missing={missing} extra={extra}")
    return {
        "ring_lutram_primitive_count": total_ring_primitives,
        "global_lutram_primitive_count": global_lutram,
        "non_ring_lutram_primitive_count": non_ring_lutram,
        "payload_ramb18_primitive_count": total_payload_ramb18,
        "payload_ramb36_primitive_count": total_payload_ramb36,
        "payload_bram_equivalent_x2": 2 * total_payload_ramb36 + total_payload_ramb18,
        "engines": engines,
    }


def audit_build(repo_root: Path, build_dir: Path, payload_depth: int) -> dict[str, object]:
    profile = profile_name(payload_depth)
    require_nonempty(
        build_dir,
        (
            "input_identity.json",
            "vivado.log",
            "tcl_identity.txt",
            "structural_audit.txt",
            "tcl_status.txt",
            *REPORT_FILES,
        ),
    )
    recorded = json.loads((build_dir / "input_identity.json").read_text(encoding="ascii"))
    if recorded != current_identity(repo_root, payload_depth):
        raise GateError("input identity is stale or does not match current sources")

    tcl_identity = parse_key_values(build_dir / "tcl_identity.txt")
    version = tcl_identity.get("vivado_version_short", "")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
        raise GateError("Tcl Vivado version identity is missing or malformed")
    expected_tcl = {
        "schema": str(SCHEMA),
        "vivado_version_short": version,
        "profile": profile,
        "top": TOP,
        "part": PART,
        "mode": "out_of_context",
        "flatten_hierarchy": "none",
        "clock_period_ns": CLOCK_PERIOD_NS,
        "target_mhz": str(TARGET_MHZ),
        "way_count": str(WAY_COUNT),
        "way_depth_words": str(WAY_DEPTH_WORDS),
        "payload_depth": str(payload_depth),
        "num_engines": str(NUM_ENGINES),
        "defines": ",".join(DEFINES),
    }
    if tcl_identity != expected_tcl:
        raise GateError("Tcl design identity is incomplete or unexpected")

    status = (build_dir / "tcl_status.txt").read_text(encoding="ascii", errors="replace")
    log = (build_dir / "vivado.log").read_text(encoding="utf-8", errors="replace")
    if status.strip() != TCL_MARKER or TCL_MARKER not in log:
        raise GateError("terminal Tcl PASS marker is missing")
    unresolved = find_unresolved_references(log)
    if unresolved:
        raise GateError(f"unresolved RTL reference detected: {unresolved[0]}")

    report_identity = parse_report_identities(build_dir)
    if report_identity["vivado_version_short"] != version:
        raise GateError("Tcl and report Vivado tool versions differ")

    timing_text = (build_dir / "timing_summary.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    wns, tns, failing = parse_setup_summary(timing_text)
    no_clock = parse_timing_check_count(timing_text, "no_clock")
    unconstrained = parse_timing_check_count(
        timing_text, "unconstrained_internal_endpoints"
    )
    if no_clock != 0 or unconstrained != 0:
        raise GateError(
            f"timing coverage failed: no_clock={no_clock} unconstrained={unconstrained}"
        )

    check_timing = (build_dir / "check_timing.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    if not re.search(r"check_timing", check_timing, re.IGNORECASE):
        raise GateError("check_timing report identity/content is incomplete")

    structure = audit_structure(
        parse_key_values(build_dir / "structural_audit.txt"), payload_depth
    )
    utilization = parse_utilization(
        (build_dir / "utilization.rpt").read_text(encoding="utf-8", errors="replace")
    )
    if utilization["register_as_latch"] != 0:
        raise GateError("utilization report contains inferred latches")
    if utilization["lut_as_memory"] != structure["global_lutram_primitive_count"]:
        raise GateError(
            "LUTRAM utilization does not match the structural primitive audit"
        )
    if utilization["ramb18"] != structure["payload_ramb18_primitive_count"]:
        raise GateError("RAMB18 utilization does not match payload BRAM leaf ownership")
    if utilization["ramb36"] != structure["payload_ramb36_primitive_count"]:
        raise GateError("RAMB36 utilization does not match payload BRAM leaf ownership")

    drc = parse_drc_summary(
        (build_dir / "drc.rpt").read_text(encoding="utf-8", errors="replace")
    )
    if drc != EXPECTED_DRC_FINDINGS:
        raise GateError(
            "DRC finding set drifted: "
            f"expected {EXPECTED_DRC_FINDINGS}, got {drc}"
        )
    worst_paths = parse_worst_paths(
        (build_dir / "timing_worst_50.rpt").read_text(
            encoding="utf-8", errors="replace"
        )
    )

    timing_closed = wns >= 0.0 and abs(tns) <= 1e-9 and failing == 0
    result = "PASS" if timing_closed else "TIMING_FAIL"
    summary: dict[str, object] = {
        "schema": SCHEMA,
        "result": result,
        "profile": profile,
        "top": TOP,
        "part": PART,
        "mode": "out_of_context",
        "clock_period_ns": float(CLOCK_PERIOD_NS),
        "target_mhz": TARGET_MHZ,
        "way_count": WAY_COUNT,
        "way_depth_words": WAY_DEPTH_WORDS,
        "payload_depth": payload_depth,
        "num_engines": NUM_ENGINES,
        "setup_wns_ns": wns,
        "setup_tns_ns": tns,
        "setup_failing_endpoints": failing,
        "no_clock_endpoint_count": no_clock,
        "unconstrained_internal_endpoint_count": unconstrained,
        "blackbox_count": 0,
        "latch_count": 0,
        "drc_findings": drc,
        "vivado": report_identity,
        "utilization": utilization,
        "structure": structure,
        "worst_50_path_classification": worst_paths,
        "input_identity_sha256": sha256_file(build_dir / "input_identity.json"),
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


def run_vivado(
    repo_root: Path, build_dir: Path, payload_depth: int, vivado: str
) -> dict[str, object]:
    clear_previous_outputs(build_dir)
    prepare_build(repo_root, build_dir, payload_depth)
    arguments = [
        "-mode",
        "batch",
        "-source",
        str(repo_root / "scripts" / "vivado" / f"{NAME}.tcl"),
        "-log",
        str(build_dir / "vivado.log"),
        "-journal",
        str(build_dir / "vivado.jou"),
    ]
    environment = os.environ.copy()
    environment["MRTC_BHT_OOC_OUT_DIR"] = str(build_dir)
    environment["MRTC_BHT_PAYLOAD_DEPTH"] = str(payload_depth)
    completed = subprocess.run(
        build_vivado_command(vivado, arguments),
        cwd=repo_root,
        env=environment,
        check=False,
    )
    if completed.returncode != 0:
        raise GateError(f"Vivado exited with status {completed.returncode}")
    return audit_build(repo_root, build_dir, payload_depth)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--run", action="store_true", help="prepare, run Vivado, and audit")
    mode.add_argument("--check", action="store_true", help="audit an existing fixed build")
    parser.add_argument("--payload-depth", type=int, choices=PAYLOAD_DEPTHS, required=True)
    parser.add_argument("--vivado", default=os.environ.get("VIVADO", "vivado"))
    parser.add_argument("--build-root", type=Path)
    args = parser.parse_args(argv)

    root = repo_root_from_script()
    build_root = args.build_root or root / "build" / "vivado"
    build_dir = build_root / f"{NAME}_{profile_name(args.payload_depth)}"
    try:
        result = (
            run_vivado(root, build_dir, args.payload_depth, args.vivado)
            if args.run
            else audit_build(root, build_dir, args.payload_depth)
        )
    except (
        GateError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ) as error:
        print(f"{NAME}: FAIL: {ascii_safe_error(error)}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
