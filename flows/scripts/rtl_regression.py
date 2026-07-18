#!/usr/bin/env python3
"""Run the bounded public RDTC RTL regression with Questa or ModelSim."""

import argparse
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


RUN_DO = "onerror {quit -code 1}; run -all; quit -code 0"


def command_text(command):
    return " ".join(shlex.quote(str(item)) for item in command)


def resolve_tool(environment_name, default, dry_run):
    value = os.environ.get(environment_name, default).strip()
    candidate = Path(value.strip('"'))
    if candidate.is_file():
        return [str(candidate)]
    parts = shlex.split(value, posix=(os.name != "nt"))
    if not parts:
        raise RuntimeError("Empty tool setting: {}".format(environment_name))
    if dry_run:
        return parts
    executable = shutil.which(parts[0])
    if not executable:
        raise RuntimeError("Tool executable not found: {}".format(parts[0]))
    return [executable] + parts[1:]


def parse_filelist(root, filelist):
    include_args = []
    source_files = []
    for raw_line in filelist.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if not line:
            continue
        if line.startswith("+incdir+"):
            for entry in line[len("+incdir+"):].split("+"):
                include_dir = (root / entry).resolve()
                if not include_dir.is_dir():
                    raise RuntimeError("Missing include directory: {}".format(include_dir))
                include_args.append("+incdir+{}".format(include_dir))
            continue
        if line.startswith("+define+"):
            include_args.append(line)
            continue
        if line.startswith("+"):
            raise RuntimeError("Unsupported public filelist directive: {}".format(line))
        source = (root / line).resolve()
        if not source.is_file():
            raise RuntimeError("Missing RTL source: {}".format(source))
        source_files.append(str(source))
    if not source_files:
        raise RuntimeError("No RTL sources found in {}".format(filelist))
    return include_args, source_files


def run_logged(command, cwd, log_path, dry_run):
    print("command: {}".format(command_text(command)))
    if dry_run:
        return ""
    with log_path.open("w", encoding="utf-8") as log_file:
        result = subprocess.run(
            [str(item) for item in command],
            cwd=str(cwd),
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )
    text = log_path.read_text(encoding="utf-8", errors="replace")
    if result.returncode != 0:
        tail = "\n".join(text.splitlines()[-40:])
        raise RuntimeError("Command failed; log={}\n{}".format(log_path, tail))
    return text


def regression_cases(suite, build_dir):
    full = "1" if suite == "full" else "0"
    cases = []
    cases.append({
        "name": "prefix_buffer_{}".format(suite),
        "top": "tb_mrtc_prefix_sample_buffer",
        "args": [],
        "marker": "PASS tb_mrtc_prefix_sample_buffer",
        "result": None,
    })
    for lane_mode in (1, 4):
        result_csv = build_dir / "bitpacker_mode{}_{}.csv".format(lane_mode, suite)
        cases.append({
            "name": "bitpacker_mode{}_{}".format(lane_mode, suite),
            "top": "tb_mrtc_rice_bitpacker_lane_axis",
            "args": [
                "+PACKER_LANE_MODE={}".format(lane_mode),
                "+RUN_FULL_MATRIX={}".format(full),
                "+RESULT_CSV={}".format(result_csv.as_posix()),
            ],
            "marker": "PASS tb_mrtc_rice_bitpacker_lane_axis",
            "result": result_csv,
        })
    smallbuf_args = ["+FULL=1"] if suite == "full" else ["+CASE=zero_sparse", "+BACKPRESSURE=0"]
    cases.append({
        "name": "smallbuf_{}".format(suite),
        "top": "tb_mrtc_rdtc_encoder_axis_bp_smallbuf",
        "args": smallbuf_args,
        "marker": "PASS tb_mrtc_rdtc_encoder_axis_bp_smallbuf",
        "result": None,
    })
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--filelist")
    parser.add_argument("--suite", choices=("smoke", "full"), default="smoke")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    filelist = Path(args.filelist).resolve() if args.filelist else root / "flows/manifests/rdtc_v1.f"
    if not filelist.is_file():
        raise RuntimeError("Missing public RTL filelist: {}".format(filelist))

    vlib = resolve_tool("RDTC_TOOL_VLIB", "vlib", args.dry_run)
    vlog = resolve_tool("RDTC_TOOL_VLOG", "vlog", args.dry_run)
    vsim = resolve_tool("RDTC_TOOL_VSIM", "vsim", args.dry_run)
    include_args, source_files = parse_filelist(root, filelist)

    checker = root / "tb/sv/mrtc_axis_protocol_checker.sv"
    prefix_buffer_tb = root / "tb/sv/tb_mrtc_prefix_sample_buffer.sv"
    bitpacker_tb = root / "tb/sv/tb_mrtc_rice_bitpacker_lane_axis.sv"
    smallbuf_tb = root / "tb/sv/tb_mrtc_rdtc_encoder_axis_bp_smallbuf.sv"
    for source in (checker, prefix_buffer_tb, bitpacker_tb, smallbuf_tb):
        if not source.is_file():
            raise RuntimeError("Missing public regression source: {}".format(source))

    build_dir = root / "build/rtl_sim" / args.suite
    if not args.dry_run:
        if build_dir.exists():
            shutil.rmtree(str(build_dir))
        build_dir.mkdir(parents=True)

    run_logged(vlib + ["work"], build_dir, build_dir / "vlib.log", args.dry_run)
    compile_command = vlog + ["-work", "work", "-sv", "+define+RDTC_PREFIX_BUFFER_ASSERTIONS"] + include_args + source_files + [
        str(checker.resolve()),
        str(prefix_buffer_tb.resolve()),
        str(bitpacker_tb.resolve()),
        str(smallbuf_tb.resolve()),
    ]
    compile_text = run_logged(
        compile_command, build_dir, build_dir / "compile.log", args.dry_run
    )
    if not args.dry_run and ("Errors: 0" not in compile_text or "Warnings: 0" not in compile_text):
        raise RuntimeError("RTL compile is not clean; inspect {}".format(build_dir / "compile.log"))

    cases = regression_cases(args.suite, build_dir)
    for case in cases:
        log_path = build_dir / "{}.log".format(case["name"])
        command = vsim + ["-c", "work.{}".format(case["top"])] + case["args"] + ["-do", RUN_DO]
        text = run_logged(command, build_dir, log_path, args.dry_run)
        if args.dry_run:
            continue
        if case["marker"] not in text:
            raise RuntimeError("PASS marker missing from {}".format(log_path))
        if case["result"] is not None and (
            not case["result"].is_file() or case["result"].stat().st_size == 0
        ):
            raise RuntimeError("Expected result CSV missing: {}".format(case["result"]))
        print("rtl-regression: PASS {} log={}".format(case["name"], log_path))

    if args.dry_run:
        print("rtl-regression: DRY-RUN suite={} cases={}".format(args.suite, len(cases)))
    else:
        print("rtl-regression: PASS suite={} cases={}".format(args.suite, len(cases)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("rtl-regression: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
