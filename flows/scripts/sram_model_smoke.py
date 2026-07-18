#!/usr/bin/env python3
"""Run the selected generated SRAM model through the stable RDTC wrapper."""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def run(command, cwd, log):
    print("command: {}".format(" ".join(shlex.quote(str(item)) for item in command)))
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, cwd=str(cwd), stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError("command failed; inspect {}".format(log))
    return log.read_text(encoding="utf-8", errors="replace")


def run_expect_fatal(command, cwd, log, marker):
    print("command: {}".format(" ".join(shlex.quote(str(item)) for item in command)))
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, cwd=str(cwd), stdout=stream, stderr=subprocess.STDOUT)
    text = log.read_text(encoding="utf-8", errors="replace")
    if marker not in text or not re.search(r"(?m)^Fatal:", text):
        raise RuntimeError("negative test did not report the expected fatal; inspect {}".format(log))
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    build_root = Path(os.environ["RDTC_BUILD_ROOT"]).resolve()
    vcs = shutil.which(os.environ.get("RDTC_TOOL_VCS", "vcs"))
    if not vcs:
        raise RuntimeError("VCS executable not found")
    technology = os.environ.get("RDTC_TECHNOLOGY", "")
    rtl_root = root / "rtl"
    if not rtl_root.is_dir():
        private_overlay_rtl = root.parents[1] / "rtl"
        if not private_overlay_rtl.is_dir():
            raise RuntimeError("RDTC RTL root is missing from the public tree and private overlay")
        rtl_root = private_overlay_rtl
    wrapper = None
    if technology.startswith("tsmc90"):
        variant = os.environ.get("RDTC_TSMC90_MEMORY_VARIANT", "rf64x128")
        if variant == "sram128x128":
            macro = "SRAM_DP_ADV"
            rtl_define = "RDTC_USE_TSMC90_PREFIX_SRAM_DP_128X128"
            wrapper = root / "flows/memory/tsmc90/sram_dp_adv_wrapper.sv"
        else:
            macro = "RF_2P_ADV"
            rtl_define = "RDTC_USE_TSMC90_PREFIX_RF"
            wrapper = root / "flows/memory/tsmc90/rf_2p_adv_wrapper.sv"
        model = build_root / ("sram_tsmc90/" + macro + ".v")
    elif technology == "nangate45_openram_spice":
        macro = "mrtc_rdtc_prefix_1rw1r_64x128"
        model = build_root / ("sram_openram/views/" + macro + ".v")
        rtl_define = "RDTC_USE_OPENRAM_PREFIX_SRAM_1RW1R"
    elif technology.startswith("sky130"):
        macro = "sky130_sram_1kbyte_1rw1r_32x256_8"
        model = build_root / ("sram_openram/views/" + macro + "_sim.v")
        rtl_define = "RDTC_USE_SKY130_PREFIX_SRAM"
    else:
        macro = "mrtc_rdtc_prefix_1r1w_64x128"
        model = build_root / ("sram_openram/views/" + macro + ".v")
        rtl_define = "RDTC_USE_OPENRAM_PREFIX_SRAM"
    if not model.is_file():
        raise RuntimeError("generated SRAM model is missing: {}".format(model))
    work = build_root / "sram_model_sim"
    work.mkdir(parents=True, exist_ok=True)
    simv = work / "simv"
    sources = [str(rtl_root / "rdtc/mrtc_prefix_sample_buffer.sv")]
    if wrapper is not None:
        sources.append(str(wrapper))
    sources.extend([str(model), str(root / "tb/sv/tb_mrtc_prefix_sample_buffer_macro.sv")])
    compile_command = [
        vcs, "-full64", "-sverilog", "-timescale=1ns/1ps",
        "+define+" + rtl_define, "+define+RDTC_PREFIX_BUFFER_ASSERTIONS",
    ] + sources + [
        "-top", "tb_mrtc_prefix_sample_buffer_macro", "-o", str(simv),
    ]
    run(compile_command, work, work / "compile.log")
    text = run([str(simv)], work, work / "run.log")
    if "PASS tb_mrtc_prefix_sample_buffer_macro" not in text:
        raise RuntimeError("SRAM model PASS marker is missing")

    collision_simv = work / "simv_collision"
    collision_compile = [
        vcs, "-full64", "-sverilog", "-timescale=1ns/1ps",
        "+define+" + rtl_define, "+define+RDTC_PREFIX_BUFFER_ASSERTIONS",
        "+define+RDTC_TEST_SAME_ADDRESS_COLLISION",
    ] + sources + [
        "-top", "tb_mrtc_prefix_sample_buffer_macro", "-o", str(collision_simv),
    ]
    run(collision_compile, work, work / "collision_compile.log")
    run_expect_fatal(
        [str(collision_simv)],
        work,
        work / "collision_run.log",
        "forbids same-cycle same-address read/write",
    )
    print("sram-model-smoke: PASS macro={} log={}".format(macro, work / "run.log"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("sram-model-smoke: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
