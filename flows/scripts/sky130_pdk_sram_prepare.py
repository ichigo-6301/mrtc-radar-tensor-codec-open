#!/usr/bin/env python3
"""Audit and compile the pinned SKY130A published SRAM macro."""

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


MACRO = "sky130_sram_1kbyte_1rw1r_32x256_8"
LIBERTY = MACRO + "_TT_1p8V_25C.lib"
EXPECTED_SHA256 = {
    MACRO + ".v": "88eaee9f0c480065545479143bfef1e3186a5d97e4a7f79b8c57ad57637cdfeb",
    MACRO + ".lef": "f5389fa908c5876ef034c487b4363e755b3e13bf88ba924815c6fcea17965b92",
    MACRO + ".gds": "a90eee3d5f8291b7c081a5febbdb143863d589d196f32e44c255f7f90ac2d6e7",
    LIBERTY: "f36f91f35700d936c1c82aeaffed0084b938aceed60551588ae9a02cbd706f56",
    MACRO + ".spice": "14a94a8a24197fa0377692a5d52c37ff9e51ea1beca1d1717dadf51fdd866b02",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path, label):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing {}: {}".format(label, path))
    return path


def tool_command(value):
    parts = shlex.split(value, posix=(os.name != "nt"))
    if not parts:
        raise RuntimeError("empty Library Compiler command")
    executable = shutil.which(parts[0]) or (parts[0] if Path(parts[0]).is_file() else None)
    if not executable:
        raise RuntimeError("Library Compiler executable not found: {}".format(parts[0]))
    return [str(executable)] + parts[1:]


def audit_power_pin(lef_text, pin):
    block = re.search(
        r"\bPIN\s+{}\b(.*?)\bEND\s+{}\b".format(re.escape(pin), re.escape(pin)),
        lef_text, re.DOTALL
    )
    rectangle_count = len(re.findall(r"\bRECT\b", block.group(1))) if block else 0
    if rectangle_count == 0:
        raise RuntimeError("LEF power pin {} has no physical rectangles".format(pin))
    return rectangle_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    build_root = Path(os.environ["RDTC_BUILD_ROOT"]).resolve()
    pdk_root = Path(os.environ.get("RDTC_SKY130_PDK_ROOT", "")).expanduser().resolve()
    library_root = pdk_root / "sky130A/libs.ref/sky130_sram_macros"
    source_files = {
        MACRO + ".v": library_root / "verilog" / (MACRO + ".v"),
        MACRO + ".lef": library_root / "lef" / (MACRO + ".lef"),
        MACRO + ".gds": library_root / "gds" / (MACRO + ".gds"),
        LIBERTY: library_root / "lib" / LIBERTY,
        MACRO + ".spice": library_root / "spice" / (MACRO + ".spice"),
    }
    for name, path in source_files.items():
        require_file(path, name)
        actual = sha256(path)
        if actual != EXPECTED_SHA256[name]:
            raise RuntimeError("SKY130 SRAM hash mismatch for {}: {}".format(path, actual))

    work = build_root / "sram_openram"
    output = work / "views"
    if args.dry_run:
        print("sky130-pdk-sram-prepare: source={} output={}".format(library_root, output))
        return 0
    if work.exists():
        shutil.rmtree(str(work))
    output.mkdir(parents=True)
    for name, path in source_files.items():
        shutil.copy2(str(path), str(output / name))

    original_model = output / (MACRO + ".v")
    simulation_model = output / (MACRO + "_sim.v")
    model_text = original_model.read_text(encoding="utf-8")
    memory_declaration = "reg [DATA_WIDTH-1:0]    mem [0:RAM_DEPTH-1];\n"
    declaration_anchor = "  // All inputs are registers\n  always @(posedge clk0)\n"
    if model_text.count(memory_declaration) != 1 or model_text.count(declaration_anchor) != 1:
        raise RuntimeError("SKY130 SRAM simulation-model compatibility patch no longer matches")
    model_text = model_text.replace(memory_declaration, "")
    model_text = model_text.replace(
        declaration_anchor, "  " + memory_declaration + "\n" + declaration_anchor
    )
    simulation_model.write_text(model_text, encoding="utf-8")

    verilog_text = (output / (MACRO + ".v")).read_text(encoding="utf-8", errors="replace")
    liberty_text = (output / LIBERTY).read_text(encoding="utf-8", errors="replace")
    lef_text = (output / (MACRO + ".lef")).read_text(encoding="utf-8", errors="replace")
    spice_text = (output / (MACRO + ".spice")).read_text(encoding="utf-8", errors="replace")
    if not re.search(r"\bmodule\s+{}\b".format(MACRO), verilog_text):
        raise RuntimeError("Verilog module name does not match {}".format(MACRO))
    if not re.search(r"\bcell\s*\(\s*{}\s*\)".format(MACRO), liberty_text):
        raise RuntimeError("Liberty cell name does not match {}".format(MACRO))
    if not re.search(r"\bMACRO\s+{}\b".format(MACRO), lef_text):
        raise RuntimeError("LEF macro name does not match {}".format(MACRO))
    if not re.search(r"\.subckt\s+{}\b".format(MACRO), spice_text, re.IGNORECASE):
        raise RuntimeError("SPICE subcircuit name does not match {}".format(MACRO))
    if not re.search(r"DATABASE\s+MICRONS\s+1000\s*;", lef_text):
        raise RuntimeError("SKY130 SRAM LEF must use 1000 database units per micron")
    size = re.search(r"\bSIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)", lef_text)
    if not size:
        raise RuntimeError("SKY130 SRAM LEF has no macro size")
    library = re.search(r"\blibrary\s*\(\s*([^\s)]+)\s*\)", liberty_text)
    if not library or not re.search(r"\btiming\s*\(", liberty_text):
        raise RuntimeError("SKY130 SRAM Liberty has no usable library or timing data")

    db = work / (MACRO + ".db")
    environment = os.environ.copy()
    environment["RDTC_SRAM_LIB"] = str(output / LIBERTY)
    environment["RDTC_SRAM_LIB_NAME"] = library.group(1).strip('"')
    environment["RDTC_SRAM_DB"] = str(db)
    command = tool_command(environment.get("RDTC_TOOL_LC", "lc_shell")) + [
        "-f", str(root / "flows/memory/openram/compile_lib.tcl")
    ]
    with (work / "lc.log").open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, cwd=str(work), env=environment, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError("Library Compiler failed; inspect {}".format(work / "lc.log"))
    require_file(db, "compiled SRAM DB")

    files = [output / name for name in source_files] + [simulation_model, db]
    manifest = {
        "macro": MACRO,
        "source": "ciel_sky130A_published_sram_macro",
        "simulation_model_compatibility": "memory_declaration_moved_before_first_reference",
        "physical_organization": "256x32_1rw1r",
        "logical_mapping": "four_parallel_32bit_lanes_per_engine",
        "instances_per_engine": 4,
        "expected_instance_count": 8,
        "corner": {"process": "TT", "voltage_v": 1.8, "temperature_c": 25},
        "lef_size_um": [float(size.group(1)), float(size.group(2))],
        "lef_power_pin_rectangles": {
            "vccd1": audit_power_pin(lef_text, "vccd1"),
            "vssd1": audit_power_pin(lef_text, "vssd1"),
        },
        "files": [
            {"name": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
            for path in files
        ],
    }
    manifest_path = work / "macro_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("sky130-pdk-sram-prepare: PASS manifest={}".format(manifest_path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("sky130-pdk-sram-prepare: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
