#!/usr/bin/env python3
"""Public-safe dispatcher for the RDTC implementation-flow adapters."""

import argparse
from collections import Counter
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_profile import load_yaml, sha256, validate_selected_config


PRIMETIME_CONSTRAINT_TYPES = frozenset(
    [
        "clock_gating_hold",
        "clock_gating_setup",
        "hold",
        "max_capacitance",
        "max_delay",
        "max_fanout",
        "max_transition",
        "min_capacitance",
        "min_delay",
        "min_period",
        "min_pulse_width",
        "min_transition",
        "recovery",
        "removal",
        "setup",
    ]
)

NUMBER_PATTERN = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


STAGES = {
    "lib-prep": {
        "symbol": "CONFIG_FLOW_LIBRARY_PREP",
        "tool_env": "RDTC_TOOL_PYTHON",
        "tool": "python3",
        "script": "flows/scripts/sky130_library_prepare.py",
        "args": ["{script}", "--root", "{root}"],
        "dry_run_args": ["--dry-run"],
        "execute_dry_run": True,
        "setup": "RDTC_SKY130_PDK_ROOT",
    },
    "sram-prep": {
        "symbol": "CONFIG_FLOW_SRAM_PREP",
        "tool_env": "RDTC_TOOL_PYTHON",
        "tool": "python3",
        "script": "flows/scripts/sram_prepare.py",
        "args": ["{script}", "--root", "{root}"],
        "dry_run_args": ["--dry-run"],
        "execute_dry_run": True,
        "setup": "RDTC_OPENRAM_HOME",
    },
    "rc-prep": {
        "symbol": "CONFIG_FLOW_RC_PREP",
        "tool_env": "RDTC_TOOL_PYTHON",
        "tool": "python3",
        "script": "flows/scripts/freepdk45_rc_prepare.py",
        "args": ["{script}"],
        "dry_run_args": ["--dry-run"],
        "execute_dry_run": True,
        "setup": "RDTC_FREEPDK45_ROOT",
    },
    "sim": {
        "symbol": "CONFIG_FLOW_RTL_SIM",
        "tool_env": "RDTC_TOOL_PYTHON",
        "tool": "python3",
        "script": "flows/scripts/rtl_regression.py",
        "args": ["{script}", "--root", "{root}", "--suite", "smoke"],
        "dry_run_args": ["--dry-run"],
        "execute_dry_run": True,
        "setup": None,
    },
    "lint": {
        "symbol": "CONFIG_FLOW_LINT",
        "tool_env": "RDTC_TOOL_SPYGLASS",
        "tool": "spyglass",
        "script": "flows/lint/spyglass/run.prj",
        "args": ["-project", "{script}", "-batch", "-goals", "lint/lint_rtl"],
        "setup": None,
    },
    "cdc": {
        "symbol": "CONFIG_FLOW_CDC",
        "tool_env": "RDTC_TOOL_SPYGLASS",
        "tool": "spyglass",
        "script": "flows/cdc/spyglass/run.prj",
        "args": ["-project", "{script}", "-batch", "-goals", "cdc/cdc_setup,cdc/cdc_verify_struct"],
        "setup": None,
    },
    "dc-baseline": {
        "symbol": "CONFIG_FLOW_DC_BASELINE",
        "tool_env": "RDTC_TOOL_DC",
        "tool": "dc_shell",
        "script": "flows/synthesis/dc/baseline/run.tcl",
        "args": ["-f", "{script}"],
        "setup": "RDTC_DC_SETUP",
    },
    "dc-gated": {
        "symbol": "CONFIG_FLOW_DC_GATED",
        "tool_env": "RDTC_TOOL_DC",
        "tool": "dc_shell",
        "script": "flows/synthesis/dc/gated/run.tcl",
        "args": ["-f", "{script}"],
        "setup": "RDTC_DC_SETUP",
    },
    "dft": {
        "symbol": "CONFIG_FLOW_DFT",
        "tool_env": "RDTC_TOOL_DFT",
        "tool": "dc_shell",
        "script": "flows/dft/run.tcl",
        "args": ["-f", "{script}"],
        "setup": "RDTC_DFT_SETUP",
    },
    "lec": {
        "symbol": "CONFIG_FLOW_LEC",
        "tool_env": "RDTC_TOOL_LEC",
        "tool": "fm_shell",
        "script": "flows/lec/run.tcl",
        "args": ["-f", "{script}"],
        "setup": "RDTC_LEC_SETUP",
    },
    "icc2-libs": {
        "symbol": "CONFIG_FLOW_ICC2_LIBS",
        "tool_env": "RDTC_TOOL_ICC2_LM",
        "tool": "icc2_lm_shell",
        "script": "flows/physical/icc2/build_reference_lib.tcl",
        "args": ["-batch", "-f", "{script}"],
        "setup": "RDTC_ICC2_SETUP",
    },
    "pnr": {
        "symbol": "CONFIG_FLOW_PNR",
        "tool_env": "RDTC_TOOL_OPENROAD",
        "tool": "bash",
        "script": "flows/physical/openroad/run.sh",
        "args": ["{script}"],
        "setup": None,
    },
    "sta": {
        "symbol": "CONFIG_FLOW_STA",
        "tool_env": "RDTC_TOOL_PRIMETIME",
        "tool": "pt_shell",
        "script": "flows/sta/primetime/run.tcl",
        "args": ["-f", "{script}"],
        "setup": "RDTC_PRIMETIME_SETUP",
    },
}


def parse_config(path: Path) -> Dict[str, str]:
    if not path.is_file():
        raise RuntimeError(f"Missing {path}. Run 'make rdtc_v1_45nm_defconfig' first.")
    values = {}  # type: Dict[str, str]
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[2:-11]] = "n"
            continue
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip().strip('"')
    return values


def split_tool(value: str) -> List[str]:
    candidate = Path(value.strip('"'))
    if candidate.is_file():
        return [str(candidate)]
    return shlex.split(value, posix=(os.name != "nt"))


def stage_command(root: Path, stage: str, dry_run: bool, config: Dict[str, str]) -> List[str]:
    spec = STAGES[stage]
    build_root = str(root / "build" / config.get("CONFIG_FLOW_BUILD_TAG", "rdtc_v1_45nm"))
    if stage == "sram-prep" and config.get("CONFIG_FLOW_TECHNOLOGY", "").startswith("tsmc90"):
        variant = config.get("CONFIG_FLOW_TSMC90_MEMORY_VARIANT", "rf64x128")
        setup = (
            "RDTC_TSMC90_SRAM_GENERATOR"
            if variant == "sram128x128"
            else "RDTC_TSMC90_RF_GENERATOR"
        )
        spec = {
            "tool_env": "RDTC_TOOL_PYTHON",
            "tool": "python3",
            "script": "flows/memory/tsmc90/run_tsmc90_memory.py",
            "args": [
                "{script}", "--variant", variant,
                "--output", build_root + "/sram_tsmc90",
            ],
            "dry_run_args": ["--dry-run"],
            "execute_dry_run": True,
            "setup": setup,
        }
    if stage == "sram-prep" and config.get("CONFIG_FLOW_TECHNOLOGY") == "sky130hd_pdk_sram":
        spec = {
            "tool_env": "RDTC_TOOL_PYTHON",
            "tool": "python3",
            "script": "flows/scripts/sky130_pdk_sram_prepare.py",
            "args": ["{script}", "--root", "{root}"],
            "dry_run_args": ["--dry-run"],
            "execute_dry_run": True,
            "setup": "RDTC_SKY130_PDK_ROOT",
        }
    if stage == "pnr" and config.get("CONFIG_FLOW_PNR_BACKEND", "openroad") == "icc2":
        spec = {
            "tool_env": "RDTC_TOOL_ICC2",
            "tool": "icc2_shell",
            "script": "flows/physical/icc2/run.tcl",
            "args": ["-batch", "-f", "{script}"],
            "setup": "RDTC_ICC2_SETUP",
        }
    tool = os.environ.get(spec["tool_env"]) or spec["tool"]
    script = str(root / spec["script"])
    args = [item.format(script=script, root=str(root)) for item in spec["args"]]
    if dry_run:
        args.extend(spec.get("dry_run_args", []))
    return [*split_tool(tool), *args]


def stage_environment(
    root: Path, config_path: Path, config: Dict[str, str], stage: str
) -> Dict[str, str]:
    environment = os.environ.copy()
    default_period = config.get("CONFIG_FLOW_CLOCK_PERIOD_NS", "2.500")
    dc_period = config.get("CONFIG_FLOW_DC_CLOCK_PERIOD_NS", "") or default_period
    pnr_period = config.get("CONFIG_FLOW_PNR_CLOCK_PERIOD_NS", "") or default_period
    sta_period = config.get("CONFIG_FLOW_STA_CLOCK_PERIOD_NS", "") or pnr_period
    build_tag = config.get("CONFIG_FLOW_BUILD_TAG", "rdtc_v1_45nm")
    dc_handoff_tag = config.get("CONFIG_FLOW_DC_HANDOFF_BUILD_TAG", "") or build_tag
    stage_period = {
        "dc-baseline": dc_period,
        "dc-gated": dc_period,
        "dft": dc_period,
        "lec": dc_period,
        "pnr": pnr_period,
        "sta": sta_period,
    }.get(stage, default_period)
    defaults = {
        "RDTC_FLOW_ROOT": str(root),
        "RDTC_FLOW_CONFIG": str(config_path.resolve()),
        "RDTC_FILELIST": str(root / "flows/manifests/rdtc_v1.f"),
        "RDTC_SDC": str(root / "flows/constraints/rdtc_v1_internal_400m.sdc"),
        "RDTC_TOP": config.get("CONFIG_RDTC_TOP", "mrtc_rdtc_wb_wrapper"),
        "RDTC_BUILD_ROOT": str(root / "build" / build_tag),
        "RDTC_DC_HANDOFF_ROOT": str(root / "build" / dc_handoff_tag),
        "RDTC_PRODUCT_PROFILE": config.get("CONFIG_FLOW_PRODUCT_PROFILE", "sram-macro"),
        "RDTC_TECHNOLOGY": config.get("CONFIG_FLOW_TECHNOLOGY", ""),
        "RDTC_SDC_TIME_SCALE": config.get(
            "CONFIG_FLOW_SDC_TIME_SCALE",
            "1000.0" if config.get("CONFIG_FLOW_TECHNOLOGY", "") == "nangate15_registers" else "1.0",
        ),
        "CONFIG_FLOW_TECHNOLOGY": config.get("CONFIG_FLOW_TECHNOLOGY", ""),
        "CONFIG_FLOW_PNR_BACKEND": config.get("CONFIG_FLOW_PNR_BACKEND", "openroad"),
        "CONFIG_FLOW_PNR_SCOPE": config.get("CONFIG_FLOW_PNR_SCOPE", "full"),
        "RDTC_PNR_SCOPE": config.get("CONFIG_FLOW_PNR_SCOPE", "full"),
        "RDTC_DC_CLOCK_PERIOD_NS": dc_period,
        "RDTC_PNR_CLOCK_PERIOD_NS": pnr_period,
        "RDTC_STA_CLOCK_PERIOD_NS": sta_period,
        "RDTC_SETUP_SLACK_MARGIN_NS": config.get(
            "CONFIG_FLOW_SETUP_SLACK_MARGIN_NS", "0.00"
        ),
        "RDTC_HOLD_SLACK_MARGIN_NS": config.get(
            "CONFIG_FLOW_HOLD_SLACK_MARGIN_NS", "-0.05"
        ),
        "RDTC_CAP_MARGIN_PERCENT": config.get(
            "CONFIG_FLOW_CAP_MARGIN_PERCENT", ""
        ),
        "RDTC_SLEW_MARGIN_PERCENT": config.get(
            "CONFIG_FLOW_SLEW_MARGIN_PERCENT", ""
        ),
        "RDTC_TARGETED_DRC_ECO": config.get(
            "CONFIG_FLOW_TARGETED_DRC_ECO", ""
        ),
        "RDTC_EXPECTED_DC_NETLIST_SHA256": config.get(
            "CONFIG_FLOW_EXPECTED_DC_NETLIST_SHA256", ""
        ),
        "RDTC_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER": config.get(
            "CONFIG_FLOW_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER", "n"
        ),
        "RDTC_GRT_HOLD_SLACK_MARGIN_NS": config.get(
            "CONFIG_FLOW_GRT_HOLD_SLACK_MARGIN_NS", ""
        ),
        "RDTC_POST_GRT_HOLD_REPAIR_PASSES": config.get(
            "CONFIG_FLOW_POST_GRT_HOLD_REPAIR_PASSES", "0"
        ),
        "RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS": config.get(
            "CONFIG_FLOW_POST_GRT_HOLD_SLACK_MARGIN_NS", "0.00"
        ),
        "RDTC_MEMORY_MODE": config.get("CONFIG_FLOW_MEMORY_MODE", "macro"),
        "RDTC_TSMC90_MEMORY_VARIANT": config.get(
            "CONFIG_FLOW_TSMC90_MEMORY_VARIANT", "rf64x128"
        ),
        "RDTC_ORFS_PLATFORM": config.get("CONFIG_FLOW_OPENROAD_PLATFORM", "nangate45"),
    }
    for key, value in defaults.items():
        if not environment.get(key):
            environment[key] = value
    # The generic constraint variable is intentionally stage-specific. This
    # prevents a fast DC target from silently becoming the P&R/STA target.
    environment["RDTC_CLOCK_PERIOD_NS"] = stage_period
    return environment


def require_local_setup(stage: str, environment: Dict[str, str]) -> None:
    setup_key = STAGES[stage]["setup"]
    if stage == "sram-prep" and environment.get("CONFIG_FLOW_TECHNOLOGY", "").startswith("tsmc90"):
        setup_key = (
            "RDTC_TSMC90_SRAM_GENERATOR"
            if environment.get("RDTC_TSMC90_MEMORY_VARIANT") == "sram128x128"
            else "RDTC_TSMC90_RF_GENERATOR"
        )
    if stage == "pnr" and environment.get("CONFIG_FLOW_PNR_BACKEND") == "icc2":
        setup_key = "RDTC_ICC2_SETUP"
    if not setup_key and stage != "pnr":
        return
    setup = environment.get(setup_key, "") if setup_key else ""
    if stage == "lib-prep":
        pdk_root = Path(setup).expanduser()
        required = [
            pdk_root / "sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib",
            pdk_root / "sky130A/libs.tech/klayout/lvs/sky130.lylvs",
            pdk_root / "sky130A/libs.tech/ngspice/sky130.lib.spice",
        ]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise RuntimeError("lib-prep requires a complete SKY130A PDK root: " + ", ".join(missing))
        return
    if stage == "sram-prep":
        if environment.get("CONFIG_FLOW_TECHNOLOGY", "").startswith("tsmc90"):
            generator = Path(setup).expanduser()
            if not generator.is_file():
                raise RuntimeError("TSMC90 sram-prep requires {}".format(setup_key))
            return
        if environment.get("CONFIG_FLOW_TECHNOLOGY") == "sky130hd_pdk_sram":
            pdk_root = Path(environment.get("RDTC_SKY130_PDK_ROOT", "")).expanduser()
            macro_root = pdk_root / "sky130A/libs.ref/sky130_sram_macros"
            required = [
                macro_root / "verilog/sky130_sram_1kbyte_1rw1r_32x256_8.v",
                macro_root / "lef/sky130_sram_1kbyte_1rw1r_32x256_8.lef",
                macro_root / "gds/sky130_sram_1kbyte_1rw1r_32x256_8.gds",
                macro_root / "lib/sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib",
                macro_root / "spice/sky130_sram_1kbyte_1rw1r_32x256_8.spice",
            ]
            missing = [str(path) for path in required if not path.is_file()]
            if missing:
                raise RuntimeError("SKY130 PDK SRAM views are incomplete: " + ", ".join(missing))
            return
        home = Path(setup).expanduser()
        if not setup or not ((home / "sram_compiler.py").is_file() or (home / "openram.py").is_file()):
            raise RuntimeError("sram-prep requires an OpenRAM checkout in RDTC_OPENRAM_HOME")
        return
    if stage == "rc-prep":
        pdk_root = Path(setup).expanduser()
        required = [
            pdk_root / "ncsu_basekit/techfile/calibre/calibrexRC.rul",
            pdk_root / "ncsu_basekit/techfile/rules.txt",
            pdk_root / "ncsu_basekit/techfile/FreePDK45.tf",
        ]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise RuntimeError("rc-prep requires a FreePDK45 v1.4 root: " + ", ".join(missing))
        if not environment.get("RDTC_RC_OUTPUT_DIR"):
            raise RuntimeError("rc-prep requires RDTC_RC_OUTPUT_DIR in the ignored local toolchain")
        return
    if stage == "pnr":
        if environment.get("CONFIG_FLOW_PNR_BACKEND") == "icc2":
            setup = environment.get("RDTC_ICC2_SETUP", "")
            if not setup or not Path(setup).is_file():
                raise RuntimeError(
                    "pnr requires RDTC_ICC2_SETUP; copy flows/config/icc2_setup.tcl.example "
                    "to flows/local/icc2_setup.tcl"
                )
            build_root = Path(environment["RDTC_BUILD_ROOT"])
            dc_handoff_root = Path(environment["RDTC_DC_HANDOFF_ROOT"])
            top = environment["RDTC_TOP"]
            required = [
                dc_handoff_root / "dc_baseline" / (top + "_baseline.v"),
                dc_handoff_root / "dc_baseline" / (top + "_baseline.sdc"),
                build_root / "icc2_libs" / "rdtc_tsmc90_stdcell.ndm",
                build_root / "icc2_libs" / "rdtc_tsmc90_memory.ndm",
            ]
            missing = [str(path) for path in required if not path.exists()]
            if missing:
                raise RuntimeError("ICC2 pnr requires DC and reference NDM handoff: " + ", ".join(missing))
            return
        image = environment.get("RDTC_ORFS_IMAGE", "")
        if not image or "@sha256:" not in image:
            raise RuntimeError("pnr requires a digest-pinned RDTC_ORFS_IMAGE")
        build_root = Path(environment["RDTC_BUILD_ROOT"])
        dc_handoff_root = Path(environment["RDTC_DC_HANDOFF_ROOT"])
        top = environment["RDTC_TOP"]
        required = [
            dc_handoff_root / "dc_baseline" / (top + "_baseline.v"),
            dc_handoff_root / "dc_baseline" / (top + "_baseline.sdc"),
        ]
        if environment.get("RDTC_MEMORY_MODE", "macro") == "macro":
            if environment.get("RDTC_ORFS_PLATFORM") == "sky130hd":
                macro = "sky130_sram_1kbyte_1rw1r_32x256_8"
                liberty = macro + "_TT_1p8V_25C.lib"
            else:
                spice_sram = environment.get("CONFIG_FLOW_TECHNOLOGY") == "nangate45_openram_spice"
                macro = (
                    "mrtc_rdtc_prefix_1rw1r_64x128" if spice_sram
                    else "mrtc_rdtc_prefix_1r1w_64x128"
                )
                voltage = "1p1" if spice_sram else "1p0"
                liberty = macro + "_TT_{}V_25C.lib".format(voltage)
            required.extend([
                build_root / "sram_openram" / "views" / (macro + ".lef"),
                build_root / "sram_openram" / "views" / liberty,
                build_root / "sram_openram" / "views" / (macro + ".gds"),
            ])
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise RuntimeError("pnr requires a complete DC and memory handoff: " + ", ".join(missing))
        return
    if not setup or not Path(setup).is_file():
        setup_name = setup_key.lower()
        if setup_name.startswith("rdtc_"):
            setup_name = setup_name[5:]
        raise RuntimeError(
            f"{stage} requires {setup_key}. Copy flows/config/{setup_name}.tcl.example "
            f"to flows/local/ and configure local PDK/library paths."
        )
    if stage in ("dc-baseline", "dc-gated") and environment.get("RDTC_MEMORY_MODE") == "registers":
        stdcell_db = Path(environment.get("RDTC_STDCELL_DB", "")).expanduser()
        if not stdcell_db.is_file():
            raise RuntimeError(
                "{} register-expanded profile requires RDTC_STDCELL_DB: {}".format(
                    stage, stdcell_db
                )
            )
    if stage == "sta":
        build_root = Path(environment["RDTC_BUILD_ROOT"])
        top = environment["RDTC_TOP"]
        if environment.get("CONFIG_FLOW_PNR_BACKEND") == "icc2":
            handoff_dir = build_root / "icc2"
        else:
            handoff_dir = build_root / "openroad" / "handoff"
        required = [handoff_dir / (top + "_postroute.v"), handoff_dir / (top + "_postroute.sdc"), handoff_dir / (top + "_postroute.spef")]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise RuntimeError("sta requires a complete post-route netlist/SDC/SPEF handoff: " + ", ".join(missing))


def verify_spyglass_result(stage: str, environment: Dict[str, str]) -> None:
    stage_root = Path(environment["RDTC_BUILD_ROOT"]) / stage
    logs = list(stage_root.rglob("spyglass.log"))
    if not logs:
        raise RuntimeError("{} completed without a readable SpyGlass log".format(stage))
    log = max(logs, key=lambda path: path.stat().st_mtime)
    text = log.read_text(encoding="utf-8", errors="replace")
    summaries = re.findall(
        r"Reported Messages:\s+(\d+) Fatals,\s+(\d+) Errors,\s+(\d+) Warnings,\s+(\d+) Infos",
        text,
    )
    if not summaries:
        raise RuntimeError("{} SpyGlass log has no reported-message summary: {}".format(stage, log))
    fatals, errors, warnings, infos = (int(value) for value in summaries[-1])
    print(
        "spyglass_summary: fatals={} errors={} warnings={} infos={} log={}".format(
            fatals, errors, warnings, infos, log
        )
    )
    if fatals or errors:
        raise RuntimeError("{} completed with {} fatal(s) and {} error(s)".format(stage, fatals, errors))


def read_required_report(path: Path) -> str:
    if not path.is_file():
        raise RuntimeError("missing PrimeTime report: {}".format(path))
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        raise RuntimeError("empty PrimeTime report: {}".format(path))
    return text


def parse_timing_slacks(path: Path, check_type: str) -> List[float]:
    text = read_required_report(path)
    matches = re.findall(
        r"^\s*slack\s+\((MET|VIOLATED)\)\s+(" + NUMBER_PATTERN + r")",
        text,
        re.MULTILINE,
    )
    if not matches:
        raise RuntimeError(
            "{} timing report contains no constrained path slack: {}".format(
                check_type, path
            )
        )
    slacks = [float(value) for _, value in matches]
    violated = [value for status, value in matches if status == "VIOLATED"]
    if violated or min(slacks) < 0.0:
        raise RuntimeError(
            "{} timing has negative slack; worst={} ns".format(
                check_type, min(slacks)
            )
        )
    return slacks


def require_clean_timing_summary(path: Path, check_type: str) -> None:
    text = read_required_report(path)
    marker = "No {} violations found.".format(check_type)
    if marker not in text:
        raise RuntimeError(
            "{} global timing summary does not contain {!r}: {}".format(
                check_type, marker, path
            )
        )


def parse_constraint_violations(path: Path) -> List[tuple]:
    text = read_required_report(path)
    section = None
    previous_nonempty = ""
    violations = []
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if stripped in PRIMETIME_CONSTRAINT_TYPES:
            section = stripped
            previous_nonempty = ""
            continue
        if "(VIOLATED" in raw_line:
            if section is None or not previous_nonempty:
                raise RuntimeError(
                    "cannot classify PrimeTime constraint violation near: {}".format(
                        stripped
                    )
                )
            violations.append((section, previous_nonempty))
        if stripped:
            previous_nonempty = stripped
    return violations


def load_waiver_policy(path: Path) -> dict:
    policy = load_yaml(path)
    required = {
        "policy_id", "profile_id", "maturity", "constraint_type",
        "expected_count", "object_scope", "match_mode", "allow_extra",
        "allow_missing", "objects",
    }
    missing = sorted(required - set(policy))
    if missing:
        raise RuntimeError("waiver policy missing fields: {}".format(", ".join(missing)))
    if policy["constraint_type"] not in PRIMETIME_CONSTRAINT_TYPES:
        raise RuntimeError("unsupported waiver constraint type: {}".format(policy["constraint_type"]))
    if policy["match_mode"] != "exact_set":
        raise RuntimeError("waiver policy match_mode must be exact_set")
    if policy["allow_extra"] is not False or policy["allow_missing"] is not False:
        raise RuntimeError("exact waiver policy cannot allow extra or missing objects")
    objects = policy["objects"]
    if not isinstance(objects, list) or not all(isinstance(item, str) for item in objects):
        raise RuntimeError("waiver policy objects must be a string list")
    if len(objects) != len(set(objects)):
        raise RuntimeError("waiver policy contains duplicate objects")
    if policy["expected_count"] != len(objects):
        raise RuntimeError(
            "waiver policy expected_count={} but defines {} objects".format(
                policy["expected_count"], len(objects)
            )
        )
    policy["object_set"] = set(objects)
    policy["sha256"] = sha256(path)
    return policy


def write_verification_summary(path: Path, lines: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def verify_primetime_result(
    environment: Dict[str, str], waiver_policy_path=None
) -> None:
    report_dir = Path(environment["RDTC_BUILD_ROOT"]) / "primetime"
    summary_path = report_dir / "verification_summary.txt"
    details = []  # type: List[str]
    try:
        require_clean_timing_summary(report_dir / "setup_summary.rpt", "setup")
        require_clean_timing_summary(report_dir / "hold_summary.rpt", "hold")
        setup_slacks = parse_timing_slacks(
            report_dir / "setup_timing.rpt", "setup"
        )
        hold_slacks = parse_timing_slacks(report_dir / "hold_timing.rpt", "hold")
        violations = parse_constraint_violations(
            report_dir / "constraint_violations.rpt"
        )

        policy = load_waiver_policy(Path(waiver_policy_path)) if waiver_policy_path else None
        expected_waiver = policy["object_set"] if policy else set()
        expected_category = policy["constraint_type"] if policy else None
        waived = [obj for category, obj in violations if category == expected_category and obj in expected_waiver]
        unwaived = [
            (category, obj)
            for category, obj in violations
            if not (category == expected_category and obj in expected_waiver)
        ]

        if policy:
            if len(waived) != policy["expected_count"] or set(waived) != expected_waiver:
                missing = sorted(expected_waiver - set(waived))
                duplicates = len(waived) - len(set(waived))
                raise RuntimeError(
                    "waiver mismatch: count={} unique={} "
                    "missing={} duplicates={}".format(
                        len(waived), len(set(waived)), len(missing), duplicates
                    )
                )

        if unwaived:
            first = ", ".join(
                "{}:{}".format(category, obj)
                for category, obj in unwaived[:5]
            )
            raise RuntimeError(
                "{} unwaived PrimeTime constraint violation(s): {}".format(
                    len(unwaived), first
                )
            )

        category_counts = Counter(category for category, _ in violations)
        details = [
            "status: PASS",
            "setup_worst_slack_ns: {:.6g}".format(min(setup_slacks)),
            "hold_worst_slack_ns: {:.6g}".format(min(hold_slacks)),
            "setup_reported_paths: {}".format(len(setup_slacks)),
            "hold_reported_paths: {}".format(len(hold_slacks)),
            "constraint_violation_count: {}".format(len(violations)),
            "waived_constraint_count: {}".format(len(waived)),
            "unwaived_constraint_violation_count: 0",
            "waiver_policy: {}".format(policy["policy_id"] if policy else "disabled"),
            "waiver_policy_sha256: {}".format(policy["sha256"] if policy else "none"),
        ]
        for category in sorted(category_counts):
            details.append(
                "constraint_{}_count: {}".format(
                    category, category_counts[category]
                )
            )
        write_verification_summary(summary_path, details)
    except RuntimeError as error:
        failure = ["status: FAIL", "reason: {}".format(error)]
        if details:
            failure.extend(details)
        write_verification_summary(summary_path, failure)
        raise RuntimeError(
            "PrimeTime verification failed: {}; summary={}".format(
                error, summary_path
            )
        )

    print(
        "primetime_summary: setup_worst={}ns hold_worst={}ns "
        "waived_constraints={} summary={}".format(
            min(setup_slacks), min(hold_slacks), len(waived), summary_path
        )
    )


def run_stage(root: Path, config_path: Path, config: Dict[str, str], stage: str, dry_run: bool) -> None:
    spec = STAGES[stage]
    if config.get(spec["symbol"]) != "y":
        raise RuntimeError(f"{stage} is disabled by {spec['symbol']} in {config_path}.")
    if stage in ("dc-baseline", "dc-gated", "pnr", "sta"):
        validate_selected_config(root, config, stage=stage)
    environment = stage_environment(root, config_path, config, stage)
    command = stage_command(root, stage, dry_run, config)
    print(f"stage: {stage}")
    print(f"tool: {command[0]}")
    print("command: " + " ".join(shlex.quote(item) for item in command))
    print(f"build_root: {environment['RDTC_BUILD_ROOT']}")
    print(f"clock_period_ns: {environment['RDTC_CLOCK_PERIOD_NS']}")
    sys.stdout.flush()
    if dry_run:
        if spec.get("execute_dry_run"):
            if not shutil.which(command[0]) and not Path(command[0]).is_file():
                raise RuntimeError(f"Tool executable not found: {command[0]}")
            try:
                subprocess.run(command, cwd=root, env=environment, check=True)
            except subprocess.CalledProcessError as error:
                raise RuntimeError(
                    "{} dry-run failed with exit status {}".format(stage, error.returncode)
                )
        return
    require_local_setup(stage, environment)
    if not shutil.which(command[0]) and not Path(command[0]).is_file():
        raise RuntimeError(f"Tool executable not found: {command[0]}")
    Path(environment["RDTC_BUILD_ROOT"]).mkdir(parents=True, exist_ok=True)
    stage_work = Path(environment["RDTC_BUILD_ROOT"]) / stage / "work"
    stage_work.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(command, cwd=stage_work, env=environment, check=True)
    except subprocess.CalledProcessError as error:
        raise RuntimeError("{} failed with exit status {}".format(stage, error.returncode))
    if stage in ("lint", "cdc"):
        verify_spyglass_result(stage, environment)
    if stage == "sta":
        policy_path = config.get("CONFIG_FLOW_STA_WAIVER_POLICY", "")
        if config.get("CONFIG_FLOW_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER") != "y":
            policy_path = None
        elif policy_path:
            policy_path = str(root / policy_path)
        verify_primetime_result(
            environment,
            policy_path,
        )


def command_defconfig(args: argparse.Namespace) -> None:
    source = Path(args.source).resolve()
    if not source.is_file():
        raise RuntimeError(f"Missing defconfig: {source}")
    destination = Path(args.config).resolve()
    destination.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"wrote {destination}")


def command_show_config(args: argparse.Namespace) -> None:
    config = parse_config(Path(args.config))
    print(f"top: {config.get('CONFIG_RDTC_TOP', 'mrtc_rdtc_wb_wrapper')}")
    print(f"product_profile: {config.get('CONFIG_FLOW_PRODUCT_PROFILE', 'sram-macro')}")
    print(f"technology: {config.get('CONFIG_FLOW_TECHNOLOGY', 'unset')}")
    default_period = config.get("CONFIG_FLOW_CLOCK_PERIOD_NS", "unset")
    dc_period = config.get("CONFIG_FLOW_DC_CLOCK_PERIOD_NS", "") or default_period
    pnr_period = config.get("CONFIG_FLOW_PNR_CLOCK_PERIOD_NS", "") or default_period
    sta_period = config.get("CONFIG_FLOW_STA_CLOCK_PERIOD_NS", "") or pnr_period
    print(f"default_clock_ns: {default_period}")
    print(f"dc_clock_ns: {dc_period}")
    print(f"pnr_clock_ns: {pnr_period}")
    print(f"sta_clock_ns: {sta_period}")
    print(
        "setup_slack_margin_ns: "
        + config.get("CONFIG_FLOW_SETUP_SLACK_MARGIN_NS", "0.00")
    )
    print(
        "hold_slack_margin_ns: "
        + config.get("CONFIG_FLOW_HOLD_SLACK_MARGIN_NS", "-0.05")
    )
    print(
        "cap_margin_percent: "
        + config.get("CONFIG_FLOW_CAP_MARGIN_PERCENT", "")
    )
    print(
        "slew_margin_percent: "
        + config.get("CONFIG_FLOW_SLEW_MARGIN_PERCENT", "")
    )
    print(
        "targeted_drc_eco: "
        + config.get("CONFIG_FLOW_TARGETED_DRC_ECO", "")
    )
    print(
        "unused_rw_dout_min_cap_waiver: "
        + config.get("CONFIG_FLOW_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER", "n")
    )
    print("sta_waiver_policy: " + config.get("CONFIG_FLOW_STA_WAIVER_POLICY", ""))
    print(
        "grt_hold_slack_margin_ns: "
        + config.get("CONFIG_FLOW_GRT_HOLD_SLACK_MARGIN_NS", "")
    )
    print(
        "post_grt_hold_repair_passes: "
        + config.get("CONFIG_FLOW_POST_GRT_HOLD_REPAIR_PASSES", "0")
    )
    print(
        "post_grt_hold_slack_margin_ns: "
        + config.get("CONFIG_FLOW_POST_GRT_HOLD_SLACK_MARGIN_NS", "0.00")
    )
    print(
        "tsmc90_memory_variant: "
        + config.get("CONFIG_FLOW_TSMC90_MEMORY_VARIANT", "rf64x128")
    )
    print("memory_mode: " + config.get("CONFIG_FLOW_MEMORY_MODE", "macro"))
    print("sdc_time_scale: " + config.get("CONFIG_FLOW_SDC_TIME_SCALE", "1.0"))
    print("pnr_backend: " + config.get("CONFIG_FLOW_PNR_BACKEND", "openroad"))
    print("pnr_scope: " + config.get("CONFIG_FLOW_PNR_SCOPE", "full"))
    print("public_rtl_smoke: " + config.get("CONFIG_FLOW_PUBLIC_RTL_SMOKE", "n"))
    print("enabled_stages: " + ", ".join(stage for stage, spec in STAGES.items() if config.get(spec["symbol"]) == "y"))


def command_list_stages() -> None:
    for stage, spec in STAGES.items():
        setup = spec["setup"] or "none"
        print(f"{stage:12} {spec['symbol']:28} setup={setup}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2])
    parser.add_argument("--config", default=".config")
    subparsers = parser.add_subparsers(dest="command")
    defconfig = subparsers.add_parser("defconfig")
    defconfig.add_argument("--source", required=True)
    subparsers.add_parser("show-config")
    subparsers.add_parser("list-stages")
    for name in ("run", "run-selected"):
        subparser = subparsers.add_parser(name)
        if name == "run":
            subparser.add_argument("--stage", choices=STAGES, required=True)
        subparser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.command is None:
        parser.error("a command is required")
    try:
        if args.command == "defconfig":
            command_defconfig(args)
            return 0
        if args.command == "list-stages":
            command_list_stages()
            return 0
        root = Path(args.root).resolve()
        config_path = Path(args.config)
        if not config_path.is_absolute():
            config_path = root / config_path
        config = parse_config(config_path)
        if args.command == "show-config":
            command_show_config(args)
            return 0
        if args.command == "run":
            run_stage(root, config_path, config, args.stage, args.dry_run)
            return 0
        for stage in STAGES:
            if config.get(STAGES[stage]["symbol"]) == "y":
                run_stage(root, config_path, config, stage, args.dry_run)
        return 0
    except RuntimeError as error:
        print(f"flowctl: error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
