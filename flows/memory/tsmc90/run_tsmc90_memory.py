#!/usr/bin/env python3
"""Generate and audit one local TSMC90 prefix-memory variant.

The proprietary generator and every generated view remain under the ignored
build root. The tracked script records only the reproducible command contract.
"""

from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


VARIANTS = {
    "rf64x128": {
        "generator_env": "RDTC_TSMC90_RF_GENERATOR",
        "generator_default": "rf_2p_adv",
        "cell": "RF_2P_ADV",
        "words": 64,
        "bits": 128,
        "mux": None,
        "kind": "two_port_register_file",
        "expected_pins": [
            "QA", "CLKA", "CENA", "AA", "CLKB", "CENB", "AB", "DB",
            "EMAA", "EMAB",
        ],
    },
    "sram128x128": {
        "generator_env": "RDTC_TSMC90_SRAM_GENERATOR",
        "generator_default": "sram_dp_adv",
        "cell": "SRAM_DP_ADV",
        "words": 128,
        "bits": 128,
        "mux": 4,
        "kind": "true_dual_port_sram",
        "expected_pins": [
            "QA", "QB", "CLKA", "CENA", "WENA", "AA", "DA", "CLKB",
            "CENB", "WENB", "AB", "DB", "EMAA", "EMAB",
        ],
    },
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_tool(value):
    candidate = Path(value.strip('"'))
    if candidate.is_file():
        return [str(candidate)]
    parts = shlex.split(value, posix=(os.name != "nt"))
    if not parts:
        raise RuntimeError("empty tool command")
    executable = shutil.which(parts[0])
    if not executable:
        raise RuntimeError("tool executable not found: {}".format(parts[0]))
    return [executable] + parts[1:]


def tcl_brace(value):
    if "}" in value:
        raise RuntimeError("unsupported closing brace in Tcl path: {}".format(value))
    return "{" + value + "}"


def generator_command(generator, fmt, spec):
    command = [str(generator), fmt, "-words", str(spec["words"]),
               "-bits", str(spec["bits"])]
    if spec["mux"] is not None:
        command.extend(["-mux", str(spec["mux"])])
    return command


def run_generator(generator, output, fmt, spec, required):
    command = generator_command(generator, fmt, spec)
    result = subprocess.run(
        command,
        cwd=str(output),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
    )
    log_name = fmt + ".log"
    (output / log_name).write_text(result.stdout, encoding="utf-8")
    unavailable = "generator is not available" in result.stdout.lower()
    record = {
        "command": [Path(command[0]).name] + command[1:],
        "log": log_name,
        "returncode": result.returncode,
        "status": "generated",
    }
    if unavailable:
        record["status"] = "not_available"
    elif result.returncode:
        record["status"] = "failed"
    if required and record["status"] != "generated":
        raise RuntimeError(
            "required {} generation failed with status {}".format(fmt, record["status"])
        )
    if not required and record["status"] == "failed":
        raise RuntimeError("optional {} command failed without an unavailable marker".format(fmt))
    return record, result.stdout


def compile_liberty(output, cell):
    liberty = output / (cell + "_tt_1.0_25.0_syn.lib")
    db = output / (cell + "_tt_1.0_25.0_syn.db")
    if not liberty.is_file():
        raise RuntimeError("TT Liberty is missing: {}".format(liberty))
    lc = resolve_tool(os.environ.get("RDTC_TOOL_LC", "lc_shell"))
    script = output / "compile_lib.tcl"
    script.write_text(
        "read_lib {}\nwrite_lib USERLIB -format db -output {}\nquit\n".format(
            tcl_brace(str(liberty)), tcl_brace(str(db))
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        lc + ["-no_init", "-no_log", "-f", str(script)],
        cwd=str(output),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
    )
    (output / "lc_shell.log").write_text(result.stdout, encoding="utf-8")
    if result.returncode or re.search(r"(?m)^Error:", result.stdout) or not db.is_file():
        raise RuntimeError("Library Compiler failed; inspect lc_shell.log")
    return db


def primetime_library_smoke(output, db, cell):
    pt = resolve_tool(os.environ.get("RDTC_TOOL_PRIMETIME", "pt_shell"))
    marker = "RDTC_PT_LIB_CELL_COUNT"
    command = (
        "read_db {db}; "
        "puts \"{marker}=[sizeof_collection [get_lib_cells */{cell}]]\"; "
        "report_lib USERLIB; exit"
    ).format(db=tcl_brace(str(db)), marker=marker, cell=cell)
    result = subprocess.run(
        pt + ["-no_init", "-x", command],
        cwd=str(output),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
    )
    (output / "pt_lib_smoke.log").write_text(result.stdout, encoding="utf-8")
    match = re.search(r"{}=(\d+)".format(marker), result.stdout)
    if (
        result.returncode
        or re.search(r"(?m)^Error:", result.stdout)
        or not match
        or int(match.group(1)) != 1
    ):
        raise RuntimeError("PrimeTime library smoke failed; inspect pt_lib_smoke.log")
    return {"status": "pass", "cell_count": int(match.group(1))}


def parse_liberty(path, cell):
    text = path.read_text(encoding="utf-8", errors="replace")
    voltage = re.search(r"\bnom_voltage\s*:\s*([0-9.]+)", text)
    temperature = re.search(r"\bnom_temperature\s*:\s*(-?[0-9.]+)", text)
    cell_match = re.search(r"\bcell\s*\(\s*" + re.escape(cell) + r"\s*\)", text)
    blocks = re.findall(
        r"minimum_period\s*\(\s*\)\s*\{\s*constraint\s*:\s*([0-9.]+)\s*;"
        r"\s*when\s*:\s*\"([^\"]+)\"",
        text,
        re.S,
    )
    ema000 = [float(value) for value, when in blocks if when.count("(!EMA") == 3]
    unconditional = [
        float(value)
        for value in re.findall(r"(?m)^\s*min_period\s*:\s*([0-9.]+)\s*;", text)
    ]
    if not voltage or not temperature or not cell_match or not ema000 or not unconditional:
        raise RuntimeError("Liberty audit failed for {}".format(path.name))
    return {
        "cell": cell,
        "nom_voltage_v": float(voltage.group(1)),
        "nom_temperature_c": float(temperature.group(1)),
        "minimum_period_ema000_ns": max(ema000),
        "minimum_period_ema000_values_ns": sorted(set(ema000)),
        "unconditional_min_period_max_ns": max(unconditional),
        "unconditional_min_period_values_ns": sorted(set(unconditional)),
    }


def parse_verilog(path, spec):
    text = path.read_text(encoding="utf-8", errors="replace")
    pins = {pin: bool(re.search(r"\b" + re.escape(pin) + r"\b", text))
            for pin in spec["expected_pins"]}
    checks = {
        "module": bool(re.search(r"\bmodule\s+" + re.escape(spec["cell"]) + r"\b", text)),
        "word_depth": bool(re.search(r"WORD_DEPTH\s*=\s*{}\b".format(spec["words"]), text)),
        "bits": bool(re.search(r"BITS\s*=\s*{}\b".format(spec["bits"]), text)),
        "pins": pins,
        "contention_model": "is_contention" in text,
    }
    if not checks["module"] or not checks["word_depth"] or not checks["bits"] or not all(pins.values()):
        raise RuntimeError("generated Verilog audit failed: {}".format(checks))
    return checks


def parse_vclef(path, cell, expected_pins):
    text = path.read_text(encoding="utf-8", errors="replace")
    macro = re.search(r"(?m)^MACRO\s+(\S+)", text)
    size = re.search(r"(?m)^\s*SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)\s*;", text)
    pins = set(re.findall(r"(?m)^\s*PIN\s+(\S+)", text))
    scalar_or_bus = set(pin.split("[")[0] for pin in pins)
    missing = sorted(set(expected_pins) - scalar_or_bus)
    if not macro or macro.group(1) != cell or not size or missing:
        raise RuntimeError("VCLEF audit failed: macro={} missing_pins={}".format(
            macro.group(1) if macro else None, missing
        ))
    return {
        "macro": macro.group(1),
        "width_um": float(size.group(1)),
        "height_um": float(size.group(2)),
        "pin_count": len(pins),
        "power_pins": sorted(pin for pin in scalar_or_bus if pin in ("VDD", "VSS")),
    }


def generator_version(texts):
    for text in texts:
        match = re.search(r"(?m)^Version\s+([^\s]+)", text)
        if match:
            return match.group(1)
    return "unknown"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=sorted(VARIANTS), required=True)
    parser.add_argument("--generator")
    parser.add_argument("--output", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    spec = dict(VARIANTS[args.variant])
    generator_value = args.generator or os.environ.get(
        spec["generator_env"], spec["generator_default"]
    )
    generator = Path(generator_value).expanduser()
    output = Path(args.output).resolve()

    if args.dry_run:
        print("variant={}".format(args.variant))
        print("generator={}".format(generator))
        print("output={}".format(output))
        for fmt in ("verilog", "synopsys", "vclef-fp", "gds2", "lvs"):
            print("command={}".format(" ".join(generator_command(generator, fmt, spec))))
        return 0

    if not generator.is_file():
        raise RuntimeError("missing generator: {}".format(generator))
    output.mkdir(parents=True, exist_ok=True)

    format_records = {}
    transcripts = []
    for fmt in ("verilog", "synopsys", "vclef-fp"):
        record, transcript = run_generator(generator, output, fmt, spec, required=True)
        format_records[fmt] = record
        transcripts.append(transcript)
    for fmt in ("gds2", "lvs"):
        record, transcript = run_generator(generator, output, fmt, spec, required=False)
        format_records[fmt] = record
        transcripts.append(transcript)

    cell = spec["cell"]
    verilog = output / (cell + ".v")
    vclef = output / (cell + ".vclef")
    liberty_files = sorted(output.glob(cell + "_*_syn.lib"))
    expected_liberty_count = 4
    if not verilog.is_file() or not vclef.is_file() or len(liberty_files) != expected_liberty_count:
        raise RuntimeError("required logical/physical views are incomplete")

    db = compile_liberty(output, cell)
    tt_liberty = output / (cell + "_tt_1.0_25.0_syn.lib")
    audit = {
        "verilog": parse_verilog(verilog, spec),
        "liberty": parse_liberty(tt_liberty, cell),
        "vclef": parse_vclef(vclef, cell, spec["expected_pins"]),
        "primetime_library_smoke": primetime_library_smoke(output, db, cell),
    }

    generated_files = [verilog, vclef, db] + liberty_files
    antenna = output / (cell + "_ant.clf")
    if antenna.is_file():
        generated_files.append(antenna)
    files = []
    for path in sorted(generated_files, key=lambda item: item.name):
        files.append({
            "file": path.name,
            "sha256": sha256(path),
            "bytes": path.stat().st_size,
        })

    manifest = {
        "schema_version": 1,
        "variant": args.variant,
        "memory_kind": spec["kind"],
        "generator": {
            "command": generator.name,
            "version": generator_version(transcripts),
        },
        "physical_organization": {
            "words": spec["words"],
            "bits": spec["bits"],
            "mux": spec["mux"],
        },
        "logical_rdtc_contract": {
            "words": 64,
            "bits": 128,
            "read_latency_cycles": 1,
            "same_address_read_write": "forbidden_by_wrapper_contract",
            "upper_address_bit": "tied_low" if args.variant == "sram128x128" else "not_applicable",
        },
        "corner": {"process": "tt", "voltage_v": 1.0, "temperature_c": 25.0},
        "formats": format_records,
        "audit": audit,
        "files": files,
        "status": {
            "logical_timing_views": "verified",
            "physical_abstract": "partial",
            "gds2": format_records["gds2"]["status"],
            "lvs": format_records["lvs"]["status"],
            "overall": "partial",
        },
        "caveats": [
            "The installed generator does not provide GDS2 or LVS views.",
            "The VCLEF physical abstract has no audited same-source GDS correspondence.",
        ],
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        "tsmc90-memory-prepare: PASS variant={} logical=verified physical=partial "
        "min_period_ema000_ns={:.3f} manifest={}".format(
            args.variant,
            audit["liberty"]["minimum_period_ema000_ns"],
            manifest_path,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print("tsmc90-memory-prepare: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
