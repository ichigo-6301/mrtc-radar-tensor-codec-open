#!/usr/bin/env python3
"""Bind and stage the single-use bounded-direct SRAM electrical ECO resume."""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

import pnr_sta_relocation


SCHEMA_VERSION = 1
KIND = "mrtc_bounded_direct_sram_electrical_eco_resume"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VIOLATION_PIN_RE = re.compile(
    r"^\s+(g_engine\[[01]\]\.u_engine/u_way_ring/"
    r"g_way\[[0-3]\]\.u_way/u_sram/(?:addr0\[[0-4]\]|dout0\[\d+\]))\s*$",
    re.MULTILINE,
)
HOOK_TARGET_RE = re.compile(
    r"\[list \{(?P<pin>g_engine\[[01]\]\.u_engine/u_way_ring/"
    r"g_way\[[0-3]\]\.u_way/u_sram/(?:addr0\[[0-4]\]|dout0\[\d+\]))\} "
    r"(?P<buffer>rdtc_direct_eco_(?:addr|dout)_buf_\d+) "
    r"(?P<side>top|bottom) "
    r"\{(?P<peer>g_engine\[[01]\]\.u_engine/[^}]+)\} "
    r"(?P<peer_master>[A-Z0-9_]+) (?P<peer_io>INPUT|OUTPUT)\]"
)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json_object(path, label):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing {}: {}".format(label, path))
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot read {} {}: {}".format(label, path, error))
    if not isinstance(value, dict):
        raise RuntimeError("{} root must be an object".format(label))
    return value


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(str(temporary), str(path))


def artifact_record(path):
    path = Path(path).resolve()
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing ECO artifact: {}".format(path))
    return {
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def _require_sha256(value, label):
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise RuntimeError("{} SHA256 is malformed".format(label))


def _validate_artifact_specs(value, label):
    if not isinstance(value, dict) or not value:
        raise RuntimeError("{} artifact map is missing".format(label))
    for role, record in sorted(value.items()):
        if not isinstance(role, str) or not role:
            raise RuntimeError("{} artifact role is malformed".format(label))
        if not isinstance(record, dict) or set(record) != {
            "relative_path",
            "sha256",
        }:
            raise RuntimeError("{} {} artifact record is malformed".format(label, role))
        relative = Path(record["relative_path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("{} {} artifact path is unsafe".format(label, role))
        _require_sha256(record["sha256"], "{} {}".format(label, role))


def validate_policy(policy):
    expected_keys = {
        "schema_version",
        "name",
        "parent",
        "pt_artifacts",
        "buffer_cells",
        "placement_policy",
        "targets",
    }
    if set(policy) != expected_keys or policy.get("schema_version") != SCHEMA_VERSION:
        raise RuntimeError("direct SRAM electrical ECO policy fields are malformed")
    if policy.get("name") != "direct_sram_pt300_electrical_eco1":
        raise RuntimeError("direct SRAM electrical ECO policy name mismatch")
    parent = policy.get("parent")
    if not isinstance(parent, dict) or set(parent) != {
        "source_commit",
        "build_tag",
        "sram_macro",
        "sram_macro_count",
        "artifacts",
    }:
        raise RuntimeError("direct SRAM electrical ECO parent policy is malformed")
    if re.fullmatch(r"[0-9a-f]{40}", str(parent.get("source_commit", ""))) is None:
        raise RuntimeError("direct SRAM electrical ECO parent commit is malformed")
    if parent.get("build_tag") != "rdtc_v1_bounded_direct_sram_dc315_pnr300_syncio10":
        raise RuntimeError("direct SRAM electrical ECO parent build tag mismatch")
    if (
        parent.get("sram_macro") != "mrtc_rdtc_bounded_ring_1rw_32x128"
        or parent.get("sram_macro_count") != 8
    ):
        raise RuntimeError("direct SRAM electrical ECO parent macro identity mismatch")
    _validate_artifact_specs(parent.get("artifacts"), "parent")
    required_parent_roles = {
        "run_contract",
        "floorplan_contract",
        "macro_audit",
        "verification",
        "relocation_manifest",
        "grt_odb",
        "grt_sdc",
        "route_guide",
    }
    if set(parent["artifacts"]) != required_parent_roles:
        raise RuntimeError("direct SRAM electrical ECO parent artifact roles are incomplete")
    _validate_artifact_specs(policy.get("pt_artifacts"), "PrimeTime")
    if set(policy["pt_artifacts"]) != {
        "analysis_coverage",
        "check_timing",
        "constraint_violations",
        "max_transition",
        "max_capacitance",
        "minimum_period",
        "minimum_pulse_width",
        "parasitics_command_log",
        "pt_command_log",
        "relocation_manifest",
        "setup_summary",
        "hold_summary",
        "sta_execution",
        "verification_summary",
    }:
        raise RuntimeError("direct SRAM electrical ECO PrimeTime roles are incomplete")
    if policy.get("buffer_cells") != {"addr": "BUF_X4", "dout": "BUF_X1"}:
        raise RuntimeError("direct SRAM electrical ECO buffer-cell policy mismatch")
    if policy.get("placement_policy") != {
        "macro_halo_um": 20.0,
        "macro_channel_um": 60.0,
        "target_offsets_um": {"addr": 30.0, "dout": 22.0},
    }:
        raise RuntimeError("direct SRAM electrical ECO placement policy mismatch")

    targets = policy.get("targets")
    if not isinstance(targets, list) or len(targets) != 14:
        raise RuntimeError("direct SRAM electrical ECO must contain 14 targets")
    names = set()
    pins = set()
    kind_counts = {"addr": 0, "dout": 0}
    for target in targets:
        if not isinstance(target, dict) or set(target) != {
            "buffer_name",
            "engine",
            "kind",
            "peer",
            "pin",
            "side",
            "way",
        }:
            raise RuntimeError("direct SRAM electrical ECO target is malformed")
        kind = target.get("kind")
        if kind not in kind_counts:
            raise RuntimeError("direct SRAM electrical ECO target kind is invalid")
        expected_prefix = "rdtc_direct_eco_{}_buf_".format(kind)
        if not str(target.get("buffer_name", "")).startswith(expected_prefix):
            raise RuntimeError("direct SRAM electrical ECO buffer name is malformed")
        if target["buffer_name"] in names or target["pin"] in pins:
            raise RuntimeError("direct SRAM electrical ECO target is duplicated")
        names.add(target["buffer_name"])
        pins.add(target["pin"])
        kind_counts[kind] += 1
        if target.get("engine") not in (0, 1) or target.get("way") not in range(4):
            raise RuntimeError("direct SRAM electrical ECO ownership is invalid")
        if target.get("side") not in ("top", "bottom"):
            raise RuntimeError("direct SRAM electrical ECO target side is invalid")
        peer = target.get("peer")
        if not isinstance(peer, dict) or set(peer) != {
            "instance",
            "io_type",
            "master",
            "pin",
        }:
            raise RuntimeError("direct SRAM electrical ECO peer is malformed")
        expected_peer_io = "OUTPUT" if kind == "addr" else "INPUT"
        expected_peer_prefix = "g_engine[{}].u_engine/".format(target["engine"])
        if (
            not str(peer.get("instance", "")).startswith(expected_peer_prefix)
            or peer.get("io_type") != expected_peer_io
            or re.fullmatch(r"[A-Z0-9_]+", str(peer.get("master", ""))) is None
            or re.fullmatch(r"[A-Z][A-Z0-9]*", str(peer.get("pin", ""))) is None
        ):
            raise RuntimeError("direct SRAM electrical ECO peer identity mismatch")
        expected_hierarchy = "g_engine[{}].u_engine/u_way_ring/g_way[{}].u_way/u_sram/".format(
            target["engine"], target["way"]
        )
        expected_pin_prefix = "addr0[" if kind == "addr" else "dout0["
        if not target["pin"].startswith(expected_hierarchy + expected_pin_prefix):
            raise RuntimeError("direct SRAM electrical ECO pin ownership mismatch")
    if kind_counts != {"addr": 11, "dout": 3}:
        raise RuntimeError("direct SRAM electrical ECO target counts mismatch")
    return policy


def load_policy(path):
    return validate_policy(read_json_object(Path(path).resolve(), "ECO policy"))


def verify_hook_targets(targets, placement_policy, hook_path):
    hook_path = Path(hook_path).resolve()
    if not hook_path.is_file() or hook_path.stat().st_size == 0:
        raise RuntimeError("direct SRAM electrical ECO hook is missing")
    text = hook_path.read_text(encoding="utf-8", errors="strict")
    addr_start = text.index("set rdtc_addr_targets")
    dout_start = text.index("set rdtc_dout_targets", addr_start)
    list_end = text.index("if {[llength $rdtc_addr_targets]", dout_start)
    expected = []
    for target in targets:
        peer = target["peer"]
        expected.append(
            (
                target["kind"],
                target["pin"],
                target["buffer_name"],
                target["side"],
                peer["instance"] + "/" + peer["pin"],
                peer["master"],
                peer["io_type"],
            )
        )
    observed = []
    for match in HOOK_TARGET_RE.finditer(text):
        if addr_start <= match.start() < dout_start:
            kind = "addr"
        elif dout_start <= match.start() < list_end:
            kind = "dout"
        else:
            raise RuntimeError("direct SRAM electrical ECO hook target escaped its list")
        observed.append(
            (
                kind,
                match.group("pin"),
                match.group("buffer"),
                match.group("side"),
                match.group("peer"),
                match.group("peer_master"),
                match.group("peer_io"),
            )
        )
    if observed != expected:
        raise RuntimeError("direct SRAM electrical ECO hook target set drifted")
    addr_loop_start = text.index("foreach rdtc_target $rdtc_addr_targets")
    dout_loop_start = text.index("foreach rdtc_target $rdtc_dout_targets")
    loop_end = text.index("# Keep the parent GRT placement immutable", dout_loop_start)
    addr_loop = text[addr_loop_start:dout_loop_start]
    dout_loop = text[dout_loop_start:loop_end]
    target_offsets = placement_policy.get("target_offsets_um", {})
    expected_addr_offset = (
        "set rdtc_addr_offset_dbu "
        "[expr {{round({:.1f} * $rdtc_dbu_per_micron)}}]"
    ).format(target_offsets.get("addr", -1.0))
    expected_dout_offset = (
        "set rdtc_dout_offset_dbu "
        "[expr {{round({:.1f} * $rdtc_dbu_per_micron)}}]"
    ).format(target_offsets.get("dout", -1.0))
    if (
        text.count(expected_addr_offset) != 1
        or text.count(expected_dout_offset) != 1
        or addr_loop.count("$rdtc_addr_offset_dbu") != 1
        or "$rdtc_dout_offset_dbu" in addr_loop
        or dout_loop.count("$rdtc_dout_offset_dbu") != 1
        or "$rdtc_addr_offset_dbu" in dout_loop
    ):
        raise RuntimeError("direct SRAM electrical ECO hook offset policy drifted")
    if (
        addr_loop.count("-buffer_cell BUF_X4") != 1
        or "-buffer_cell BUF_X1" in addr_loop
        or dout_loop.count("-buffer_cell BUF_X1") != 1
        or "-buffer_cell BUF_X4" in dout_loop
    ):
        raise RuntimeError("direct SRAM electrical ECO hook buffer-cell policy drifted")
    return {
        "path": str(hook_path),
        "bytes": hook_path.stat().st_size,
        "sha256": sha256_file(hook_path),
        "target_count": len(observed),
        "buffer_cells": {"addr": "BUF_X4", "dout": "BUF_X1"},
        "target_offsets_um": target_offsets,
    }


def _resolve_expected_artifacts(root, specs, label):
    root = Path(root).resolve()
    records = {}
    for role, spec in sorted(specs.items()):
        path = (root / spec["relative_path"]).resolve()
        try:
            path.relative_to(root)
        except ValueError:
            raise RuntimeError("{} {} artifact escapes its root".format(label, role))
        record = artifact_record(path)
        if record["sha256"] != spec["sha256"]:
            raise RuntimeError("{} {} artifact SHA256 mismatch".format(label, role))
        records[role] = record
    return records


def _same_artifact_identity(left, right):
    return (
        isinstance(left, dict)
        and isinstance(right, dict)
        and left.get("bytes") == right.get("bytes")
        and left.get("sha256") == right.get("sha256")
    )


def _validate_parent_relocation(source_records, pt_records, verification):
    if pt_records["relocation_manifest"]["sha256"] != source_records[
        "relocation_manifest"
    ]["sha256"]:
        raise RuntimeError("parent PT relocation manifest differs from P&R evidence")
    relocation_path = Path(pt_records["relocation_manifest"]["path"])
    relocation_result = pnr_sta_relocation.verify_manifest(relocation_path)
    if relocation_result["manifest_sha256"] != pt_records["relocation_manifest"][
        "sha256"
    ]:
        raise RuntimeError("parent PT relocation verification hash mismatch")
    relocation = read_json_object(relocation_path, "parent PT relocation manifest")
    if (
        relocation.get("schema_version") != 1
        or relocation.get("kind") != "rdtc_openroad_sta_relocation"
        or relocation.get("source_verification_sha256")
        != source_records["verification"]["sha256"]
    ):
        raise RuntimeError("parent PT relocation manifest identity mismatch")
    expected_source_paths = {
        "run_contract": source_records["run_contract"]["path"],
        "verification": source_records["verification"]["path"],
        "macro_audit": source_records["macro_audit"]["path"],
    }
    if relocation.get("source_paths") != expected_source_paths:
        raise RuntimeError("parent PT relocation source paths differ from P&R evidence")
    artifacts = relocation.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(
        pnr_sta_relocation.REQUIRED_ARTIFACT_ROLES
    ):
        raise RuntimeError("parent PT relocation artifact role set is incomplete")
    source_bindings = {
        "run_contract": source_records["run_contract"],
        "floorplan_contract": source_records["floorplan_contract"],
        "source_macro_audit": source_records["macro_audit"],
        "source_verification": source_records["verification"],
    }
    for role, expected in source_bindings.items():
        if not _same_artifact_identity(artifacts.get(role), expected):
            raise RuntimeError(
                "parent PT relocation {} identity mismatch".format(role)
            )
    for suffix in pnr_sta_relocation.REQUIRED_FINAL_SUFFIXES:
        expected = verification["final_artifacts"].get(suffix)
        if not _same_artifact_identity(artifacts.get("final_" + suffix), expected):
            raise RuntimeError(
                "parent PT relocation final {} identity mismatch".format(suffix)
            )
    for suffix in pnr_sta_relocation.REQUIRED_HANDOFF_SUFFIXES:
        expected = verification["handoff_artifacts"].get(suffix)
        if not _same_artifact_identity(
            artifacts.get("handoff_" + suffix), expected
        ):
            raise RuntimeError(
                "parent PT relocation handoff {} identity mismatch".format(suffix)
            )
    return relocation


def _validate_parent_pt_semantics(policy, pt_records, relocation):
    execution = read_json_object(
        Path(pt_records["sta_execution"]["path"]), "parent PT execution"
    )
    if any(
        (
            execution.get("stage") != "sta",
            execution.get("status") != "pass",
            execution.get("returncode") != 0,
            execution.get("timed_out") is not False,
            execution.get("termination") != "not_requested",
        )
    ):
        raise RuntimeError("parent PrimeTime execution did not complete cleanly")

    summary_lines = Path(
        pt_records["verification_summary"]["path"]
    ).read_text(encoding="utf-8", errors="strict").splitlines()
    if summary_lines != [
        "status: FAIL",
        "reason: PrimeTime max_transition report contains 11 unauthorized violation(s)",
    ]:
        raise RuntimeError("parent PrimeTime failure classification drifted")

    coverage = Path(pt_records["analysis_coverage"]["path"]).read_text(
        encoding="utf-8", errors="replace"
    )
    for check in ("setup", "hold"):
        if re.search(
            r"^{}\s+18276\s+18276 \(100%\)\s+0 \(  0%\)\s+0 \(  0%\)".format(
                check
            ),
            coverage,
            re.MULTILINE,
        ) is None:
            raise RuntimeError("parent PrimeTime {} coverage is incomplete".format(check))
    for role, option in (
        ("minimum_period", "-min_period"),
        ("minimum_pulse_width", "-min_pulse_width"),
    ):
        text = Path(pt_records[role]["path"]).read_text(
            encoding="utf-8", errors="replace"
        )
        if option not in text or "(VIOLATED" in text or "Error:" in text:
            raise RuntimeError("parent PrimeTime {} gate is not clean".format(role))
    check_timing = Path(pt_records["check_timing"]["path"]).read_text(
        encoding="utf-8", errors="replace"
    )
    if (
        "Checking 'unconstrained_endpoints'" not in check_timing
        or re.search(r"\n0\s*$", check_timing) is None
    ):
        raise RuntimeError("parent PrimeTime check_timing did not complete cleanly")

    expected_pins = {target["pin"] for target in policy["targets"]}
    constraints = Path(pt_records["constraint_violations"]["path"]).read_text(
        encoding="utf-8", errors="replace"
    )
    if (
        set(VIOLATION_PIN_RE.findall(constraints)) != expected_pins
        or constraints.count("(VIOLATED") != 14
    ):
        raise RuntimeError("parent PrimeTime aggregate constraint set mismatch")

    command_log = Path(pt_records["pt_command_log"]["path"]).read_text(
        encoding="utf-8", errors="replace"
    )
    for marker in (
        "require_sha256 $approved_path",
        "read_verilog $rdtc_postroute_netlist",
        "read_sdc $rdtc_postroute_sdc",
        "read_parasitics $rdtc_postroute_spef",
        'puts "INFO: PrimeTime post-route STA completed"',
    ):
        if marker not in command_log:
            raise RuntimeError("parent PrimeTime command contract is incomplete")
    parasitics = Path(pt_records["parasitics_command_log"]["path"]).read_text(
        encoding="utf-8", errors="replace"
    )
    handoff_spef_name = Path(
        relocation["artifacts"]["handoff_spef"]["path"]
    ).name
    if (
        "Report : read_parasitics" not in parasitics
        or handoff_spef_name not in parasitics
        or "0 error(s)" not in parasitics
        or re.search(r"Annotated nets\s+:\s+124634", parasitics) is None
    ):
        raise RuntimeError("parent PrimeTime parasitic annotation is incomplete")


def _validate_parent_evidence(policy, source_records, pt_records):
    run_contract = read_json_object(
        Path(source_records["run_contract"]["path"]), "parent P&R run contract"
    )
    profile = run_contract.get("profile")
    if (
        run_contract.get("schema_version") != 1
        or run_contract.get("source_commit") != policy["parent"]["source_commit"]
        or not isinstance(profile, dict)
        or profile.get("build_tag") != policy["parent"]["build_tag"]
        or profile.get("bounded_asic_family") != "direct"
        or profile.get("bounded_asic_profile") != "sram"
        or profile.get("clock_period_ns") != "3.333333"
        or profile.get("expected_sram_count") != 8
    ):
        raise RuntimeError("parent P&R run-contract profile mismatch")
    macro_model = run_contract.get("sram_model")
    if not isinstance(macro_model, dict) or (
        macro_model.get("macro") != policy["parent"]["sram_macro"]
    ):
        raise RuntimeError("parent P&R SRAM model mismatch")
    floorplan = read_json_object(
        Path(source_records["floorplan_contract"]["path"]), "parent floorplan"
    )
    if (
        run_contract.get("floorplan", {}).get("contract_sha256")
        != source_records["floorplan_contract"]["sha256"]
        or floorplan.get("profile") != "direct-sram"
        or floorplan.get("floorplan", {}).get("macro_count") != 8
        or floorplan.get("floorplan", {}).get("macro_channel_um") != 60.0
        or floorplan.get("floorplan", {}).get("local_buffer_channel_um") != 20.0
    ):
        raise RuntimeError("parent P&R floorplan mismatch")
    macro_audit = read_json_object(
        Path(source_records["macro_audit"]["path"]), "parent macro audit"
    )
    if (
        macro_audit.get("status") != "PASS"
        or macro_audit.get("profile") != "sram"
        or macro_audit.get("observed_block_macro_count") != 8
    ):
        raise RuntimeError("parent final-ODB macro audit is not PASS")
    verification = read_json_object(
        Path(source_records["verification"]["path"]), "parent route verification"
    )
    if verification.get("status") != "PASS" or any(
        verification.get("metrics", {}).get(key) != 0
        for key in (
            "detailedroute__route__drc_errors",
            "detailedroute__antenna__violating__nets",
            "detailedroute__antenna__violating__pins",
            "detailedroute__route__unrouted_nets",
        )
    ):
        raise RuntimeError("parent OpenROAD route verification is not PASS")
    relocation = _validate_parent_relocation(
        source_records, pt_records, verification
    )
    if "No setup violations found." not in Path(
        pt_records["setup_summary"]["path"]
    ).read_text(encoding="utf-8", errors="replace"):
        raise RuntimeError("parent PrimeTime setup summary is not clean")
    if "No hold violations found." not in Path(
        pt_records["hold_summary"]["path"]
    ).read_text(encoding="utf-8", errors="replace"):
        raise RuntimeError("parent PrimeTime hold summary is not clean")
    _validate_parent_pt_semantics(policy, pt_records, relocation)

    expected_by_kind = {
        kind: {target["pin"] for target in policy["targets"] if target["kind"] == kind}
        for kind in ("addr", "dout")
    }
    observed_addr = set(
        VIOLATION_PIN_RE.findall(
            Path(pt_records["max_transition"]["path"]).read_text(
                encoding="utf-8", errors="replace"
            )
        )
    )
    observed_dout = set(
        VIOLATION_PIN_RE.findall(
            Path(pt_records["max_capacitance"]["path"]).read_text(
                encoding="utf-8", errors="replace"
            )
        )
    )
    if observed_addr != expected_by_kind["addr"]:
        raise RuntimeError("parent max-transition target set mismatch")
    if observed_dout != expected_by_kind["dout"]:
        raise RuntimeError("parent max-capacitance target set mismatch")
    return run_contract, floorplan


def create_resume_manifest(policy_path, parent_build_root, parent_pt_root, output_path):
    policy_path = Path(policy_path).resolve()
    policy = load_policy(policy_path)
    source_records = _resolve_expected_artifacts(
        parent_build_root, policy["parent"]["artifacts"], "parent"
    )
    pt_records = _resolve_expected_artifacts(
        parent_pt_root, policy["pt_artifacts"], "PrimeTime"
    )
    run_contract, floorplan = _validate_parent_evidence(
        policy, source_records, pt_records
    )
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "kind": KIND,
        "name": policy["name"],
        "policy": artifact_record(policy_path),
        "parent_build_root": str(Path(parent_build_root).resolve()),
        "parent_pt_root": str(Path(parent_pt_root).resolve()),
        "source_artifacts": source_records,
        "pt_artifacts": pt_records,
        "parent_identity": {
            "source_commit": run_contract["source_commit"],
            "rtl": run_contract["rtl"],
            "profile": run_contract["profile"],
            "physical_policy": run_contract["physical_policy"],
            "dc_ring_macro_instances": run_contract["dc_ring_macro_instances"],
            "dc_netlist_sha256": run_contract["inputs"]["dc_netlist"]["sha256"],
            "sram_model": run_contract["sram_model"],
            "floorplan_values": floorplan["floorplan"],
        },
        "buffer_cells": policy["buffer_cells"],
        "placement_policy": policy["placement_policy"],
        "targets": policy["targets"],
    }
    write_json(output_path, manifest)
    return manifest


def _verify_record(record, label):
    if not isinstance(record, dict) or set(record) != {"path", "bytes", "sha256"}:
        raise RuntimeError("{} record is malformed".format(label))
    path = Path(record["path"]).resolve()
    _require_sha256(record["sha256"], label)
    if (
        not path.is_file()
        or path.stat().st_size != record["bytes"]
        or sha256_file(path) != record["sha256"]
    ):
        raise RuntimeError("{} hash or size mismatch".format(label))
    return path


def verify_resume_manifest(manifest_path, policy_path=None):
    manifest_path = Path(manifest_path).resolve()
    manifest = read_json_object(manifest_path, "ECO resume manifest")
    expected_fields = {
        "schema_version",
        "kind",
        "name",
        "policy",
        "parent_build_root",
        "parent_pt_root",
        "source_artifacts",
        "pt_artifacts",
        "parent_identity",
        "buffer_cells",
        "placement_policy",
        "targets",
    }
    if (
        set(manifest) != expected_fields
        or manifest.get("schema_version") != SCHEMA_VERSION
        or manifest.get("kind") != KIND
    ):
        raise RuntimeError("ECO resume manifest fields are malformed")
    recorded_policy_path = _verify_record(manifest.get("policy"), "ECO policy")
    if policy_path is not None:
        policy_path = Path(policy_path).resolve()
        if recorded_policy_path != policy_path:
            raise RuntimeError("ECO resume policy path mismatch")
    policy = load_policy(recorded_policy_path)
    if (
        manifest.get("name") != policy["name"]
        or manifest.get("buffer_cells") != policy["buffer_cells"]
        or manifest.get("placement_policy") != policy["placement_policy"]
        or manifest.get("targets") != policy["targets"]
    ):
        raise RuntimeError("ECO resume policy content mismatch")
    source_records = manifest.get("source_artifacts")
    pt_records = manifest.get("pt_artifacts")
    if not isinstance(source_records, dict) or set(source_records) != set(
        policy["parent"]["artifacts"]
    ):
        raise RuntimeError("ECO resume parent artifact roles mismatch")
    if not isinstance(pt_records, dict) or set(pt_records) != set(
        policy["pt_artifacts"]
    ):
        raise RuntimeError("ECO resume PrimeTime artifact roles mismatch")
    for role, record in sorted(source_records.items()):
        _verify_record(record, "parent {}".format(role))
        if record["sha256"] != policy["parent"]["artifacts"][role]["sha256"]:
            raise RuntimeError("parent {} policy hash mismatch".format(role))
    for role, record in sorted(pt_records.items()):
        _verify_record(record, "PrimeTime {}".format(role))
        if record["sha256"] != policy["pt_artifacts"][role]["sha256"]:
            raise RuntimeError("PrimeTime {} policy hash mismatch".format(role))
    run_contract, floorplan = _validate_parent_evidence(
        policy, source_records, pt_records
    )
    expected_identity = {
        "source_commit": run_contract["source_commit"],
        "rtl": run_contract["rtl"],
        "profile": run_contract["profile"],
        "physical_policy": run_contract["physical_policy"],
        "dc_ring_macro_instances": run_contract["dc_ring_macro_instances"],
        "dc_netlist_sha256": run_contract["inputs"]["dc_netlist"]["sha256"],
        "sram_model": run_contract["sram_model"],
        "floorplan_values": floorplan["floorplan"],
    }
    if manifest.get("parent_identity") != expected_identity:
        raise RuntimeError("ECO resume parent identity mismatch")
    return {
        "status": "PASS",
        "manifest_path": str(manifest_path),
        "manifest_sha256": sha256_file(manifest_path),
        "policy_path": str(recorded_policy_path),
        "policy_sha256": manifest["policy"]["sha256"],
        "source_artifacts": source_records,
        "pt_artifacts": pt_records,
        "parent_identity": expected_identity,
        "buffer_cells": policy["buffer_cells"],
        "placement_policy": policy["placement_policy"],
        "targets": policy["targets"],
    }


def verify_child_compatibility(child_contract, resume):
    parent = resume["parent_identity"]
    child_profile = child_contract.get("profile", {})
    parent_profile = parent["profile"]
    for key in (
        "bounded_asic_family",
        "bounded_asic_profile",
        "top",
        "technology",
        "memory_mode",
        "clock_period_ns",
        "orfs_platform",
        "orfs_image",
        "orfs_commit",
        "expected_bulk_storage_bits",
        "expected_sram_count",
    ):
        if child_profile.get(key) != parent_profile.get(key):
            raise RuntimeError("ECO child/parent profile mismatch: {}".format(key))
    if child_contract.get("rtl") != parent["rtl"]:
        raise RuntimeError("ECO child/parent RTL source-set mismatch")
    if child_contract.get("physical_policy") != parent["physical_policy"]:
        raise RuntimeError("ECO child/parent physical policy mismatch")
    if child_contract.get("dc_ring_macro_instances") != parent[
        "dc_ring_macro_instances"
    ]:
        raise RuntimeError("ECO child/parent macro ownership mismatch")
    if child_contract.get("inputs", {}).get("dc_netlist", {}).get(
        "sha256"
    ) != parent["dc_netlist_sha256"]:
        raise RuntimeError("ECO child/parent DC netlist mismatch")
    if _relocatable_sram_model_identity(
        child_contract.get("sram_model")
    ) != _relocatable_sram_model_identity(parent["sram_model"]):
        raise RuntimeError("ECO child/parent SRAM model mismatch")
    if child_contract.get("floorplan", {}).get("values") != parent[
        "floorplan_values"
    ]:
        raise RuntimeError("ECO child/parent floorplan values mismatch")


def _relocatable_sram_model_identity(model):
    if not isinstance(model, dict) or not isinstance(model.get("views"), dict):
        raise RuntimeError("ECO child/parent SRAM model is malformed")
    identity = {key: value for key, value in model.items() if key != "views"}
    identity["views"] = {}
    for role, record in sorted(model["views"].items()):
        if not isinstance(record, dict):
            raise RuntimeError("ECO child/parent SRAM view is malformed")
        identity["views"][role] = {
            key: value for key, value in record.items() if key != "path"
        }
    return identity


def stage_resume_manifest(resume, destination_build_root):
    source = Path(resume["manifest_path"]).resolve()
    destination = (
        Path(destination_build_root).resolve()
        / "openroad/direct_sram_electrical_eco_resume.json"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if (
            not destination.is_file()
            or destination.stat().st_size != source.stat().st_size
            or sha256_file(destination) != resume["manifest_sha256"]
        ):
            raise RuntimeError("existing staged ECO resume manifest differs")
    else:
        shutil.copy2(str(source), str(destination))
    record = artifact_record(destination)
    if record["sha256"] != resume["manifest_sha256"]:
        raise RuntimeError("staged ECO resume manifest SHA256 mismatch")
    return record


def seed_resume_checkpoint(resume, destination_build_root, run_contract_path):
    destination_build_root = Path(destination_build_root).resolve()
    run_contract_path = Path(run_contract_path).resolve()
    run_contract_record = artifact_record(run_contract_path)
    results = (
        destination_build_root
        / "openroad/orfs/results/nangate45/rdtc_v1/base"
    )
    results.mkdir(parents=True, exist_ok=True)
    role_to_name = {
        "grt_odb": "5_1_grt.odb",
        "grt_sdc": "5_1_grt.sdc",
        "route_guide": "route.guide",
    }
    copied = {}
    for role, destination_name in sorted(role_to_name.items()):
        source = Path(resume["source_artifacts"][role]["path"])
        destination = results / destination_name
        if destination.exists():
            if (
                not destination.is_file()
                or destination.stat().st_size != source.stat().st_size
                or sha256_file(destination) != resume["source_artifacts"][role]["sha256"]
            ):
                raise RuntimeError("existing ECO resume checkpoint differs: {}".format(destination))
        else:
            shutil.copy2(str(source), str(destination))
        copied[role] = {
            "source": resume["source_artifacts"][role],
            "destination": artifact_record(destination),
        }
    seed_path = destination_build_root / "openroad/resume_seed.json"
    seed = {
        "schema_version": SCHEMA_VERSION,
        "kind": KIND,
        "resume_manifest": {
            "path": resume["manifest_path"],
            "sha256": resume["manifest_sha256"],
        },
        "run_contract": run_contract_record,
        "copied": copied,
    }
    if seed_path.is_file():
        if read_json_object(seed_path, "existing ECO resume seed") != seed:
            raise RuntimeError("existing ECO resume seed belongs to another contract")
    else:
        write_json(seed_path, seed)
    marker = destination_build_root / "openroad/results_run_contract.sha256"
    if marker.is_file():
        if marker.read_text(encoding="ascii").strip() != run_contract_record["sha256"]:
            raise RuntimeError("existing ORFS result marker belongs to another contract")
    else:
        marker.write_text(run_contract_record["sha256"] + "\n", encoding="ascii")
    return seed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command")
    create = subparsers.add_parser("create")
    create.add_argument("--policy", required=True, type=Path)
    create.add_argument("--parent-build-root", required=True, type=Path)
    create.add_argument("--parent-pt-root", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument("--policy", type=Path)
    args = parser.parse_args()
    if args.command == "create":
        result = create_resume_manifest(
            args.policy, args.parent_build_root, args.parent_pt_root, args.output
        )
        print(
            "direct-sram-electrical-eco: CREATED targets={} output={}".format(
                len(result["targets"]), args.output.resolve()
            )
        )
    elif args.command == "verify":
        result = verify_resume_manifest(args.manifest, args.policy)
        print(
            "direct-sram-electrical-eco: PASS manifest_sha256={}".format(
                result["manifest_sha256"]
            )
        )
    else:
        parser.error("a command is required")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("direct-sram-electrical-eco: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
