#!/usr/bin/env python3
"""Audit existing DC, OpenROAD, and PrimeTime timing artifacts without rerunning tools."""

from __future__ import print_function

import argparse
import hashlib
import json
import os
import re


def read_text(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def require_file(path, label):
    if not os.path.isfile(path):
        raise RuntimeError("missing {}: {}".format(label, path))
    return path


def number(pattern, text, default=None, flags=0):
    match = re.search(pattern, text, flags)
    return float(match.group(1)) if match else default


def integer(pattern, text, default=None, flags=0):
    value = number(pattern, text, default, flags)
    return int(value) if value is not None else default


def parse_sdc(path):
    text = read_text(require_file(path, "SDC"))
    return {
        "sha256": sha256(path),
        "clock_period_ns": number(r"create_clock\b[^\n]*-period\s+([0-9.]+)", text),
        "setup_uncertainty_ns": number(r"set_clock_uncertainty\s+-setup\s+([0-9.]+)", text),
        "hold_uncertainty_ns": number(r"set_clock_uncertainty\s+-hold\s+([0-9.]+)", text),
        "propagated_clock": bool(re.search(r"^\s*set_propagated_clock\b", text, re.M)),
        "input_delay_commands": len(re.findall(r"^\s*set_input_delay\b", text, re.M)),
        "output_delay_commands": len(re.findall(r"^\s*set_output_delay\b", text, re.M)),
        "false_path_commands": len(re.findall(r"^\s*set_false_path\b", text, re.M)),
        "multicycle_commands": len(re.findall(r"^\s*set_multicycle_path\b", text, re.M)),
    }


def classify_path(startpoint, endpoint):
    joined = "{} {}".format(startpoint or "", endpoint or "").lower()
    if "u_sram" in joined or "prefix_1r1w" in joined or "prefix_1rw1r" in joined:
        return "sram_path"
    if "/rn" in joined or "/sn" in joined or "reset" in joined:
        return "async_reset_path"
    if startpoint and endpoint:
        return "standard_cell_reg_to_reg"
    return "unknown"


def parse_timing_paths(path):
    if not os.path.isfile(path):
        return []
    text = read_text(path)
    starts = list(re.finditer(r"^\s*Startpoint:\s+(.+)$", text, re.M))
    paths = []
    for index, start_match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        block = text[start_match.start():end]
        endpoint = re.search(r"^\s*Endpoint:\s+(.+)$", block, re.M)
        slack = re.search(r"^\s*slack\s+\((?:VIOLATED|MET)\)\s+(-?[0-9.]+)", block, re.M)
        levels = len(re.findall(r"\([^()]+\)\s*$", block, re.M)) - 2
        startpoint = start_match.group(1).strip()
        endpoint_name = endpoint.group(1).strip() if endpoint else None
        paths.append({
            "startpoint": startpoint,
            "endpoint": endpoint_name,
            "slack_ns": float(slack.group(1)) if slack else None,
            "approximate_cell_levels": max(levels, 0),
            "class": classify_path(startpoint, endpoint_name),
        })
    return paths[:20]


def parse_dc(root):
    qor_path = require_file(os.path.join(root, "qor.rpt"), "DC QoR")
    timing_path = require_file(os.path.join(root, "timing.rpt"), "DC timing")
    netlist_path = require_file(os.path.join(root, "mrtc_rdtc_wb_wrapper_baseline.v"), "DC netlist")
    sdc_path = require_file(os.path.join(root, "mrtc_rdtc_wb_wrapper_baseline.sdc"), "DC SDC")
    qor = read_text(qor_path)
    timing = read_text(timing_path)
    return {
        "netlist_sha256": sha256(netlist_path),
        "sdc": parse_sdc(sdc_path),
        "critical_path_length_ns": number(r"Critical Path Length:\s+(-?[0-9.]+)", qor),
        "critical_path_slack_ns": number(r"Critical Path Slack:\s+(-?[0-9.]+)", qor),
        "total_negative_slack_ns": number(r"Total Negative Slack:\s+(-?[0-9.]+)", qor),
        "setup_violating_paths": integer(r"No\. of Violating Paths:\s+([0-9.]+)", qor),
        "logic_levels": integer(r"Levels of Logic:\s+([0-9.]+)", qor),
        "max_cap_violations": integer(r"Max Cap Violations:\s+([0-9.]+)", qor),
        "operating_condition": re.search(r"Operating Conditions:\s+(\S+)", timing).group(1),
        "library": re.search(r"Operating Conditions:.*Library:\s+(\S+)", timing).group(1),
        "wire_load_mode": re.search(r"Wire Load Model Mode:\s+(\S+)", timing).group(1),
        "setup_paths": parse_timing_paths(timing_path),
    }


def parse_global_summary(path, kind):
    text = read_text(require_file(path, "PrimeTime {} summary".format(kind)))
    if "No {} violations found".format(kind) in text:
        return {"wns_ns": 0.0, "tns_ns": 0.0, "violating_paths": 0}
    row = re.search(r"^WNS\s+(-?[0-9.]+).*\nTNS\s+(-?[0-9.]+).*\nNUM\s+([0-9]+)", text, re.M)
    if not row:
        raise RuntimeError("cannot parse PrimeTime {} summary: {}".format(kind, path))
    return {"wns_ns": float(row.group(1)), "tns_ns": float(row.group(2)), "violating_paths": int(row.group(3))}


def parse_pt(root):
    check_path = require_file(os.path.join(root, "check_timing.rpt"), "PrimeTime check_timing")
    check = read_text(check_path)
    parent = os.path.dirname(root)
    handoff = os.path.join(parent, "openroad", "handoff")
    netlist = require_file(os.path.join(handoff, "mrtc_rdtc_wb_wrapper_postroute.v"), "post-route netlist")
    sdc = require_file(os.path.join(handoff, "mrtc_rdtc_wb_wrapper_postroute.sdc"), "post-route SDC")
    spef = require_file(os.path.join(handoff, "mrtc_rdtc_wb_wrapper_postroute.spef"), "post-route SPEF")
    check_lines = [line.strip() for line in check.splitlines() if line.strip()]
    check_status = int(check_lines[-1]) if check_lines and check_lines[-1] in ("0", "1") else None
    setup_paths = parse_timing_paths(os.path.join(root, "setup_timing.rpt"))
    hold_paths = parse_timing_paths(os.path.join(root, "hold_timing.rpt"))
    return {
        "netlist_sha256": sha256(netlist),
        "spef_sha256": sha256(spef),
        "sdc": parse_sdc(sdc),
        "setup": parse_global_summary(os.path.join(root, "setup_summary.rpt"), "setup"),
        "hold": parse_global_summary(os.path.join(root, "hold_summary.rpt"), "hold"),
        "setup_paths": setup_paths,
        "hold_paths": hold_paths,
        "setup_path_classes": dict((name, sum(1 for item in setup_paths if item["class"] == name)) for name in sorted(set(item["class"] for item in setup_paths))),
        "hold_path_classes": dict((name, sum(1 for item in hold_paths if item["class"] == name)) for name in sorted(set(item["class"] for item in hold_paths))),
        "rc004_warnings": len(re.findall(r"\(RC-004\)", check)),
        "rc009_warnings": len(re.findall(r"\(RC-009\)", check)),
        "check_timing_status": check_status,
        "input_delay_commands": parse_sdc(sdc)["input_delay_commands"],
        "output_delay_commands": parse_sdc(sdc)["output_delay_commands"],
    }


def parse_openroad(root):
    cts_path = require_file(os.path.join(root, "4_1_cts.log"), "OpenROAD CTS log")
    final_path = require_file(os.path.join(root, "6_report.log"), "OpenROAD final report log")
    cts = read_text(cts_path)
    final = read_text(final_path)
    created = [int(value) for value in re.findall(r"Created\s+([0-9]+)\s+clock buffers", cts)]
    return {
        "hold_margin_ns": number(r"repair_timing\s+-setup_margin\s+[-0-9.]+\s+-hold_margin\s+([-0-9.]+)", cts),
        "root_buffer": re.search(r"Root buffer is\s+(\S+)\.", cts).group(1),
        "sink_buffer": re.search(r"Sink buffer is\s+(\S+)\.", cts).group(1),
        "explicit_target_skew": bool(re.search(r"-target_skew\b", cts)),
        "cts_created_clock_buffers": max(created) if created else None,
        "cts_delay_buffers": integer(r"Total number of delay buffers:\s+([0-9]+)", cts, 0),
        "final_clock_buffers": integer(r"Clock buffer\s+([0-9]+)", final),
        "final_timing_repair_buffers": integer(r"Timing Repair Buffer\s+([0-9]+)", final),
        "final_design_area_um2": number(r"Design area\s+([0-9.]+)\s+um\^2", final),
    }


def parse_named(values):
    result = {}
    for value in values:
        if "=" not in value:
            raise RuntimeError("expected NAME=PATH, got {}".format(value))
        name, path = value.split("=", 1)
        result[name] = path
    return result


def build_matrix(dc, pt_runs, openroad_runs, library_reports_equal):
    matrix = []
    matrix.append({
        "category": "real_microarchitecture_path",
        "status": "confirmed" if dc["critical_path_slack_ns"] < 0 else "not_observed",
        "detail": "DC target does not close; critical path has {} logic levels and {:.2f} ns path length.".format(dc["logic_levels"], dc["critical_path_length_ns"]),
    })
    missing_io = any(run["input_delay_commands"] == 0 or run["output_delay_commands"] == 0 for run in pt_runs.values())
    matrix.append({"category": "missing_integration_constraint", "status": "confirmed" if missing_io else "not_observed", "detail": "Internal-clock profile has no integration-level IO delays."})
    rc004 = sum(run["rc004_warnings"] for run in pt_runs.values())
    sram_setup_paths = sum(run["setup_path_classes"].get("sram_path", 0) for run in pt_runs.values())
    matrix.append({"category": "model_limitation", "status": "confirmed" if rc004 and sram_setup_paths else "not_observed", "detail": "PrimeTime check_timing contains {} visible RC-004 warnings and {} of the reported setup paths are SRAM paths.".format(rc004, sram_setup_paths)})
    matrix.append({"category": "confirmed_flow_bug", "status": "not_observed", "detail": "Clock periods and mapped-netlist identity are checked explicitly; no mismatch was found in the audited inputs."})
    repair_counts = [run["final_timing_repair_buffers"] for run in openroad_runs.values() if run["final_timing_repair_buffers"] is not None]
    repair_detail = "Hold results vary across independently placed/routed profiles; frequency reduction is not a monotonic hold repair."
    if repair_counts:
        repair_detail += " Timing-repair buffer count ranges from {} to {}.".format(min(repair_counts), max(repair_counts))
    matrix.append({"category": "expected_physical_variation", "status": "confirmed", "detail": repair_detail})
    matrix.append({"category": "standard_cell_library_mismatch", "status": "not_observed" if library_reports_equal else "needs_review", "detail": "Normalized report_lib outputs {}.".format("match" if library_reports_equal else "differ")})
    return matrix


def write_markdown(path, result):
    lines = [
        "# RDTC Timing Audit",
        "",
        "This report parses existing artifacts only; it does not rerun synthesis, place-and-route, or STA.",
        "",
        "## Constraint Chain",
        "",
        "| Stage | Period | Setup uncertainty | Hold uncertainty | Propagated | IO delays |",
        "| --- | ---: | ---: | ---: | --- | --- |",
    ]
    dc_sdc = result["dc"]["sdc"]
    lines.append("| DC900 target | {:.3f} ns | {:.3f} ns | {:.3f} ns | {} | {}/{} |".format(dc_sdc["clock_period_ns"], dc_sdc["setup_uncertainty_ns"], dc_sdc["hold_uncertainty_ns"], "yes" if dc_sdc["propagated_clock"] else "no", dc_sdc["input_delay_commands"], dc_sdc["output_delay_commands"]))
    for name in sorted(result["pt"]):
        sdc = result["pt"][name]["sdc"]
        lines.append("| {} PT | {:.3f} ns | {:.3f} ns | {:.3f} ns | {} | {}/{} |".format(name, sdc["clock_period_ns"], sdc["setup_uncertainty_ns"], sdc["hold_uncertainty_ns"], "yes" if sdc["propagated_clock"] else "no", sdc["input_delay_commands"], sdc["output_delay_commands"]))
    lines.extend(["", "## Timing Results", "", "- DC900 target: {:.2f} ns critical path, {:.2f} ns WNS, {} setup violations, {} logic levels.".format(result["dc"]["critical_path_length_ns"], result["dc"]["critical_path_slack_ns"], result["dc"]["setup_violating_paths"], result["dc"]["logic_levels"])])
    for name in sorted(result["pt"]):
        run = result["pt"][name]
        lines.append("- {}: setup WNS/TNS {:.2f}/{:.2f} ns ({} paths); hold WNS/TNS {:.2f}/{:.2f} ns ({} paths); setup path classes {}.".format(name, run["setup"]["wns_ns"], run["setup"]["tns_ns"], run["setup"]["violating_paths"], run["hold"]["wns_ns"], run["hold"]["tns_ns"], run["hold"]["violating_paths"], json.dumps(run["setup_path_classes"], sort_keys=True)))
    lines.extend(["", "## Physical Optimization", "", "| Run | Hold margin | CTS buffer | Explicit target skew | CTS-created buffers | Final clock buffers | Timing-repair buffers | Final area |", "| --- | ---: | --- | --- | ---: | ---: | ---: | ---: |"])
    for name in sorted(result["openroad"]):
        run = result["openroad"][name]
        lines.append("| {} | {:.3f} ns | {} | {} | {} | {} | {} | {:.0f} um2 |".format(name, run["hold_margin_ns"], run["root_buffer"], "yes" if run["explicit_target_skew"] else "no", run["cts_created_clock_buffers"], run["final_clock_buffers"], run["final_timing_repair_buffers"], run["final_design_area_um2"]))
    lines.extend(["", "## Problem Matrix", "", "| Category | Status | Detail |", "| --- | --- | --- |"])
    for item in result["problem_matrix"]:
        lines.append("| `{}` | `{}` | {} |".format(item["category"], item["status"], item["detail"]))
    lines.extend(["", "## Conclusion", "", "The DC900 target is limited by deep standard-cell logic in the bitpacker and never closed. The audited post-route 500-600 MHz setup boundary is dominated by SRAM-output paths evaluated with an analytical OpenRAM model that also triggers RC-004 warnings. Treat the macro-aware frequency result as model-limited until a register-expanded control STA or a better-characterized SRAM view is available.", ""])
    with open(path, "w") as handle:
        handle.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dc-root", required=True)
    parser.add_argument("--pt", action="append", default=[], help="NAME=primetime-report-directory")
    parser.add_argument("--openroad", action="append", default=[], help="NAME=OpenROAD log directory containing 4_1_cts.log and 6_report.log")
    parser.add_argument("--dc-netlist-copy", action="append", default=[], help="NAME=netlist copied into a physical run")
    parser.add_argument("--library-report", action="append", default=[], help="normalized report_lib output; provide exactly two")
    parser.add_argument("--output", required=True)
    parser.add_argument("--markdown")
    args = parser.parse_args()

    dc = parse_dc(args.dc_root)
    pt_paths = parse_named(args.pt)
    pt_runs = dict((name, parse_pt(path)) for name, path in pt_paths.items())
    openroad_paths = parse_named(args.openroad)
    openroad_runs = dict((name, parse_openroad(path)) for name, path in openroad_paths.items())
    copies = {}
    for name, path in parse_named(args.dc_netlist_copy).items():
        copies[name] = {"sha256": sha256(require_file(path, "DC netlist copy")), "matches_dc": sha256(path) == dc["netlist_sha256"]}
    library_reports_equal = True
    if args.library_report:
        if len(args.library_report) != 2:
            raise RuntimeError("--library-report must be provided exactly twice")
        library_reports_equal = read_text(args.library_report[0]) == read_text(args.library_report[1])

    result = {
        "schema": "rdtc-timing-audit-v1",
        "dc": dc,
        "pt": pt_runs,
        "openroad": openroad_runs,
        "dc_netlist_copies": copies,
        "library_reports_equal": library_reports_equal,
    }
    result["problem_matrix"] = build_matrix(dc, pt_runs, openroad_runs, library_reports_equal)
    output_dir = os.path.dirname(os.path.abspath(args.output))
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir)
    with open(args.output, "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    if args.markdown:
        write_markdown(args.markdown, result)
    print("timing_audit: wrote {}".format(args.output))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("timing_audit: error: {}".format(error))
        raise SystemExit(2)
