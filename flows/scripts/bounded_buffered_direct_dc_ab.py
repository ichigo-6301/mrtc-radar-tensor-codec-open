#!/usr/bin/env python3
"""Run and audit the public bounded buffered versus Direct-AXIS DC A/B."""

from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
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


def parse_hierarchy_area(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    entries = {}
    pattern = re.compile(r"^(\S+)\s+([0-9]+\.[0-9]+)\s+", re.MULTILINE)
    for match in pattern.finditer(text):
        entries[match.group(1)] = float(match.group(2))

    def sum_suffix(suffix):
        return sum(area for name, area in entries.items() if name.endswith(suffix))

    return {
        "engine_area_um2": sum_suffix(".u_engine"),
        "ddr_feeder_area_um2": sum_suffix(".u_feeder"),
        "payload_commit_area_um2": sum_suffix(".u_pktbuf"),
        "entry_count": len(entries),
    }


def run_paths(root, point):
    build_root = root / "build" / point["build_tag"]
    return build_root, build_root / "dc_baseline"


def collect_run(root, point, execution):
    build_root, dc_root = run_paths(root, point)
    required = {
        "closure": dc_root / "dc_closure_summary.txt",
        "contract": dc_root / "run_contract.txt",
        "area": dc_root / "area.rpt",
        "hierarchy": dc_root / "area_hier.rpt",
        "timing": dc_root / "timing.rpt",
    }
    missing = [name for name, path in required.items() if not path.is_file()]
    if missing:
        return {
            "status": "INCOMPLETE",
            "missing": missing,
            "build_root": relative_path(root, build_root),
        }
    return {
        "status": parse_key_values(required["closure"]).get("status", "UNKNOWN"),
        "family": point["family"],
        "frequency_mhz": point["frequency_mhz"],
        "period_ns": point["period_ns"],
        "storage_bits": point["storage_bits"],
        "build_root": relative_path(root, build_root),
        "closure": parse_key_values(required["closure"]),
        "contract": parse_key_values(required["contract"]),
        "area": parse_area_report(required["area"]),
        "hierarchy_area": parse_hierarchy_area(required["hierarchy"]),
        "elapsed_seconds": execution.get(point["key"], {}).get("elapsed_seconds"),
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
    }
    for key, value in expected.items():
        if closure.get(key) != value:
            failures.append("{} expected {} got {}".format(key, value, closure.get(key)))
    try:
        wns = float(closure["setup_wns"])
        tns = float(closure["setup_tns"])
    except (KeyError, ValueError):
        wns, tns = -1.0, -1.0
    if wns < 0.0 or abs(tns) > 1.0e-12:
        failures.append("setup timing did not close")
    expected_top = (
        flowctl.BOUNDED_BUFFERED_TOP
        if point["family"] == "buffered"
        else flowctl.BOUNDED_DIRECT_TOP
    )
    if contract.get("top") != expected_top:
        failures.append("top identity mismatch")
    if run["area"]["tool_version"] != EXPECTED_DC_VERSION:
        failures.append("DC version mismatch")
    if run["area"]["macro_count"] != 0:
        failures.append("area report contains macros")
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


def read_execution(path):
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {item["key"]: item for item in data.get("runs", [])}


def collect(root, orchestration_root):
    root = Path(root).resolve()
    identity = source_identity(root)
    inputs = comparison_inputs(root, identity)
    execution = read_execution(Path(orchestration_root) / "execution.json")
    runs = {point["key"]: collect_run(root, point, execution) for point in POINTS}
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
    return {
        "schema_version": 1,
        "comparison": "mrtc_bounded_buffered_vs_direct_register_expanded_dc",
        "status": "PASS_DC_ONLY" if paired_315_pass else "NOT_RESUME_READY",
        "inputs": inputs,
        "runs": runs,
        "gates": gates,
        "dc315_comparison": comparison,
        "limitations": [
            "register-expanded DC-only architecture comparison",
            "not SRAM macro area, post-route area, power, Fmax, or foundry signoff",
            "Direct retains the 277 cycles/packet > 256 cycles/block scheduling limit",
        ],
    }


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
            "| {key} | {wns:.6f} | {area:.3f} | {cells} | {seq} | {gate} |".format(
                key=point["key"],
                wns=float(run["closure"]["setup_wns"]),
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
    comparison_inputs(root, identity)
    if not identity["tracked_worktree_clean"]:
        raise RuntimeError("paired DC execution requires a tracked-clean worktree")
    if sha256_file(args.stdcell_db) != EXPECTED_DB_SHA256:
        raise RuntimeError("standard-cell DB SHA256 differs from the comparison contract")
    orchestration_root.mkdir(parents=True, exist_ok=True)
    execution_path = orchestration_root / "execution.json"
    execution = {"status": "RUNNING", "runs": []}
    write_json(execution_path, execution)
    selected = set(args.point or [point["key"] for point in POINTS])
    unknown = selected - {point["key"] for point in POINTS}
    if unknown:
        raise RuntimeError("unknown comparison point(s): {}".format(", ".join(sorted(unknown))))
    stress_failed = False
    for point in POINTS:
        if point["key"] not in selected:
            continue
        build_root, dc_root = run_paths(root, point)
        if dc_root.exists() and not args.resume:
            raise RuntimeError("refusing to overwrite existing DC output: {}".format(dc_root))
        if args.resume and (dc_root / "dc_closure_summary.txt").is_file():
            execution["runs"].append({"key": point["key"], "status": "SKIPPED_EXISTING"})
            write_json(execution_path, execution)
            continue
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
        execution["runs"].append(
            {
                "key": point["key"],
                "returncode": returncode,
                "elapsed_seconds": round(time.monotonic() - started, 2),
                "build_root": relative_path(root, build_root),
                "log": relative_path(root, log_path),
            }
        )
        write_json(execution_path, execution)
        if returncode:
            if is_mandatory_point(point):
                execution["status"] = "FAILED"
                write_json(execution_path, execution)
                raise RuntimeError(
                    "{} exited with status {}".format(point["key"], returncode)
                )
            stress_failed = True
    summary = collect(root, orchestration_root)
    execution["status"] = (
        "COMPLETE_WITH_STRESS_FAILURE" if stress_failed else "COMPLETE"
    )
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
            write_json(args.output, summary)
            Path(args.markdown_output).write_text(render_markdown(summary), encoding="utf-8")
            return 0 if summary["status"] == "PASS_DC_ONLY" else 1
        return run_all(args)
    except RuntimeError as error:
        print("bounded-buffered-direct-dc-ab: error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
