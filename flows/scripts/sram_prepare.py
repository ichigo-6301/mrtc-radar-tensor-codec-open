#!/usr/bin/env python3
"""Generate, audit, hash, and compile the RDTC OpenRAM macro views."""

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


EXPECTED_OPENRAM_COMMIT = "e16d9eb0b4495e8beee441ced3fcad68391155e6"
EXPECTED_SKY130_SRAM_CELL_COMMIT = "fc63b12883b4bf458ee8c756ba64c37063e1ffb9"
EXPECTED_NGSPICE_SOURCE_SHA256 = "a0d1699af1940b06649276dcd6ff5a566c8c0cad01b2f7b5e99dedbb4d64c19b"
EXPECTED_NGSPICE_VERSION = "46"


PROFILES = {
    "freepdk45": {
        "macro": "mrtc_rdtc_prefix_1r1w_64x128",
        "config": "config.py",
        "ports": "1R1W",
        "voltage": 1.1,
        "required_pins": ("clk0", "csb0", "addr0", "din0", "clk1", "csb1", "addr1", "dout1"),
        "bus_pins": ("addr0", "din0", "addr1", "dout1"),
    },
    "freepdk45_spice": {
        "macro": "mrtc_rdtc_prefix_1rw1r_64x128",
        "config": "config_spice.py",
        "ports": "1RW1R",
        "voltage": 1.1,
        "required_pins": (
            "clk0", "csb0", "web0", "addr0", "din0", "dout0",
            "clk1", "csb1", "addr1", "dout1",
        ),
        "bus_pins": ("addr0", "din0", "dout0", "addr1", "dout1"),
    },
    "sky130": {
        "macro": "mrtc_rdtc_prefix_1rw1r_64x128",
        "config": "sky130_config.py",
        "ports": "1RW1R",
        "voltage": 1.8,
        "required_pins": (
            "clk0", "csb0", "web0", "addr0", "din0", "dout0",
            "clk1", "csb1", "addr1", "dout1",
        ),
        "bus_pins": ("addr0", "din0", "dout0", "addr1", "dout1"),
    },
}


def tool_command(value):
    parts = shlex.split(value, posix=(os.name != "nt"))
    if not parts:
        raise RuntimeError("empty tool command")
    executable = shutil.which(parts[0]) or (parts[0] if Path(parts[0]).is_file() else None)
    if not executable:
        raise RuntimeError("tool executable not found: {}".format(parts[0]))
    return [str(executable)] + parts[1:]


def run(command, cwd, log_path, environment, dry_run):
    print("command: {}".format(" ".join(shlex.quote(str(item)) for item in command)))
    if dry_run:
        return
    with log_path.open("w", encoding="utf-8") as stream:
        result = subprocess.run(
            [str(item) for item in command], cwd=str(cwd), env=environment,
            stdout=stream, stderr=subprocess.STDOUT
        )
    if result.returncode != 0:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        raise RuntimeError("command failed; log={}\n{}".format(log_path, "\n".join(text.splitlines()[-50:])))


def require_file(path, label):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing {}: {}".format(label, path))
    return path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_commit(path, label):
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=str(path), universal_newlines=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("cannot resolve {} commit: {}".format(label, error))


def build_sky130_technology_overlay(openram_home, cell_root, work):
    cell_commit = git_commit(cell_root, "SKY130 SRAM cell library")
    if cell_commit != EXPECTED_SKY130_SRAM_CELL_COMMIT:
        raise RuntimeError(
            "SKY130 SRAM cell commit {} does not match pinned {}".format(
                cell_commit, EXPECTED_SKY130_SRAM_CELL_COMMIT
            )
        )
    source_technology = openram_home / "technology/sky130"
    overlay_root = work / "openram_technology"
    overlay = overlay_root / "sky130"
    if overlay_root.exists():
        shutil.rmtree(str(overlay_root))
    shutil.copytree(
        str(source_technology), str(overlay),
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
    )
    gds_lib = overlay / "gds_lib"
    sp_lib = overlay / "sp_lib"
    lvs_lib = overlay / "lvs_lib"
    for directory in (gds_lib, sp_lib, lvs_lib):
        directory.mkdir()
    gds_count = 0
    spice_count = 0
    for cell_dir in sorted((cell_root / "cells").iterdir()):
        if not cell_dir.is_dir():
            continue
        cell_name = "sky130_fd_bd_sram__" + cell_dir.name
        gds = cell_dir / (cell_name + ".gds")
        spice = cell_dir / (cell_name + ".base.spice")
        if not spice.is_file():
            spice = cell_dir / (cell_name + ".spice")
        lvs = cell_dir / (cell_name + ".lvs.spice")
        if gds.is_file():
            shutil.copy2(str(gds), str(gds_lib / gds.name))
            gds_count += 1
        if spice.is_file():
            shutil.copy2(str(spice), str(sp_lib / (cell_name + ".sp")))
            spice_count += 1
        if lvs.is_file():
            shutil.copy2(str(lvs), str(lvs_lib / (cell_name + ".sp")))
    if gds_count < 10 or spice_count < 10:
        raise RuntimeError(
            "SKY130 SRAM cell overlay is incomplete: gds={} spice={}".format(gds_count, spice_count)
        )
    return overlay_root, cell_commit, {"gds": gds_count, "spice": spice_count}


def build_openram_source_overlay(openram_home, work):
    overlay = work / "openram_source"
    if overlay.exists():
        shutil.rmtree(str(overlay))
    shutil.copytree(
        str(openram_home), str(overlay),
        ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc")
    )
    patches = []
    router = overlay / "compiler/router/supply_router.py"
    text = router.read_text(encoding="utf-8")
    original = """        if self.pin_type in [\"top\", \"bottom\", \"right\", \"left\"]:
            self.add_side_pin(vdd_name)
            self.add_side_pin(gnd_name)
"""
    patched = """        if self.pin_type in [\"top\", \"bottom\", \"right\", \"left\"]:
            self.add_side_pin(vdd_name, self.pin_type)
            self.add_side_pin(gnd_name, self.pin_type)
"""
    if text.count(original) != 1:
        raise RuntimeError("OpenRAM side-pin compatibility patch no longer matches pinned source")
    router.write_text(text.replace(original, patched), encoding="utf-8")
    patches.append({
        "purpose": "supply_router_side_argument_compatibility",
        "file": "compiler/router/supply_router.py",
        "sha256": sha256(router),
    })

    sram = overlay / "compiler/modules/sram_1bank.py"
    text = sram.read_text(encoding="utf-8")
    import_anchor = "import datetime\n"
    if text.count(import_anchor) != 1:
        raise RuntimeError("OpenRAM supply exposure import patch no longer matches pinned source")
    text = text.replace(import_anchor, import_anchor + "import os\n")
    route_anchor = """        for pin_name in [\"vdd\", \"gnd\"]:
            for inst in self.insts:
                self.copy_power_pins(inst, pin_name, self.ext_supply[pin_name])

        from openram.router import supply_router as router
"""
    route_replacement = """        for pin_name in [\"vdd\", \"gnd\"]:
            for inst in self.insts:
                self.copy_power_pins(inst, pin_name, self.ext_supply[pin_name])

        if os.environ.get(\"RDTC_OPENRAM_EXPOSE_SUPPLY_PINS\") == \"1\":
            return

        from openram.router import supply_router as router
"""
    if text.count(route_anchor) != 1:
        raise RuntimeError("OpenRAM supply exposure patch no longer matches pinned source")
    sram.write_text(text.replace(route_anchor, route_replacement), encoding="utf-8")
    patches.append({
        "purpose": "expose_existing_internal_supply_shapes",
        "file": "compiler/modules/sram_1bank.py",
        "sha256": sha256(sram),
    })
    return overlay, patches


def audit_text_views(
    macro, required_pins, bus_pins, verilog, liberty, lef, power_pins=(),
    require_perimeter_signal_pins=False
):
    verilog_text = verilog.read_text(encoding="utf-8", errors="replace")
    liberty_text = liberty.read_text(encoding="utf-8", errors="replace")
    lef_text = lef.read_text(encoding="utf-8", errors="replace")
    if not re.search(r"\bmodule\s+{}\b".format(re.escape(macro)), verilog_text):
        raise RuntimeError("Verilog module name does not match {}".format(macro))
    for pin in required_pins:
        if not re.search(r"\b{}\b".format(re.escape(pin)), verilog_text):
            raise RuntimeError("Verilog view is missing pin {}".format(pin))
        if pin in bus_pins:
            liberty_pattern = r"\bbus\s*\(\s*{}\s*\)".format(re.escape(pin))
            lef_pattern = r"\bPIN\s+{}\[".format(re.escape(pin))
        else:
            liberty_pattern = r"\bpin\s*\(\s*{}\s*\)".format(re.escape(pin))
            lef_pattern = r"\bPIN\s+{}\b".format(re.escape(pin))
        if not re.search(liberty_pattern, liberty_text):
            raise RuntimeError("Liberty view is missing pin or bus {}".format(pin))
        if not re.search(lef_pattern, lef_text):
            raise RuntimeError("LEF view is missing pin or bus {}".format(pin))
    if not re.search(r"\bcell\s*\(\s*{}\s*\)".format(re.escape(macro)), liberty_text):
        raise RuntimeError("Liberty cell name does not match {}".format(macro))
    if not re.search(r"\btiming\s*\(", liberty_text) or ("cell_rise" not in liberty_text and "rise_constraint" not in liberty_text):
        raise RuntimeError("Liberty view has no usable timing tables")
    if not re.search(r"\bMACRO\s+{}\b".format(re.escape(macro)), lef_text):
        raise RuntimeError("LEF macro name does not match {}".format(macro))
    size = re.search(r"\bSIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)", lef_text)
    if not size:
        raise RuntimeError("LEF view has no macro SIZE")
    lef_width = float(size.group(1))
    lef_height = float(size.group(2))
    perimeter_pin_counts = {}
    if require_perimeter_signal_pins:
        pin_names = re.findall(r"(?m)^\s*PIN\s+(\S+)\s*$", lef_text)
        tolerance = 1e-6
        for pin in required_pins:
            matching_names = [
                name for name in pin_names
                if name == pin or (pin in bus_pins and name.startswith(pin + "["))
            ]
            perimeter_count = 0
            for name in matching_names:
                block = re.search(
                    r"(?ms)^\s*PIN\s+{}\s*$.*?^\s*END\s+{}\s*$".format(
                        re.escape(name), re.escape(name)
                    ),
                    lef_text,
                )
                if not block:
                    continue
                rectangles = re.findall(
                    r"\bRECT\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)",
                    block.group(0),
                )
                touches_perimeter = any(
                    abs(float(x1)) <= tolerance or
                    abs(float(y1)) <= tolerance or
                    abs(float(x2) - lef_width) <= tolerance or
                    abs(float(y2) - lef_height) <= tolerance
                    for x1, y1, x2, y2 in rectangles
                )
                if touches_perimeter:
                    perimeter_count += 1
            if perimeter_count != len(matching_names) or perimeter_count == 0:
                raise RuntimeError(
                    "LEF signal pin family {} is not fully routed to the macro perimeter "
                    "({}/{})".format(pin, perimeter_count, len(matching_names))
                )
            perimeter_pin_counts[pin] = perimeter_count
    power_pin_rectangles = {}
    for pin in power_pins:
        block = re.search(
            r"\bPIN\s+{}\b(.*?)\bEND\s+{}\b".format(re.escape(pin), re.escape(pin)),
            lef_text, re.DOTALL
        )
        rectangle_count = len(re.findall(r"\bRECT\b", block.group(1))) if block else 0
        if rectangle_count == 0:
            raise RuntimeError("LEF power pin {} has no physical rectangles".format(pin))
        power_pin_rectangles[pin] = rectangle_count
    library = re.search(r"\blibrary\s*\(\s*([^\s)]+)\s*\)", liberty_text)
    if not library:
        raise RuntimeError("Liberty library name was not found")
    voltage = re.search(r"\bnom_voltage\s*:\s*([0-9.]+)", liberty_text)
    return {
        "library_name": library.group(1).strip('"'),
        "liberty_nom_voltage_v": float(voltage.group(1)) if voltage else None,
        "lef_width": lef_width,
        "lef_height": lef_height,
        "lef_power_pin_rectangles": power_pin_rectangles,
        "lef_perimeter_signal_pin_counts": perimeter_pin_counts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--reuse-generated", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    build_root = Path(os.environ.get("RDTC_BUILD_ROOT", root / "build/rdtc_v1_45nm")).resolve()
    technology = os.environ.get("CONFIG_FLOW_TECHNOLOGY", "freepdk45_openram")
    if technology.startswith("sky130"):
        profile_name = "sky130"
    elif technology == "nangate45_openram_spice":
        profile_name = "freepdk45_spice"
    else:
        profile_name = "freepdk45"
    profile = PROFILES[profile_name]
    macro = profile["macro"]
    work = build_root / "sram_openram"
    output = work / "views"
    reuse_generated = args.reuse_generated
    reuse_root_value = os.environ.get("RDTC_OPENRAM_REUSE_DIR", "").strip()
    reuse_root = Path(reuse_root_value).expanduser().resolve() if reuse_root_value else None
    spice_characterized = profile_name == "freepdk45_spice"
    characterization_smoke = (
        os.environ.get("RDTC_OPENRAM_CHARACTERIZATION_SMOKE") == "1"
    )
    config_name = profile["config"]
    config = root / "flows/memory/openram" / config_name
    openram_compat = root / "flows/memory/openram/run_openram.py"
    compile_tcl = root / "flows/memory/openram/compile_lib.tcl"
    openram_home = Path(os.environ.get("RDTC_OPENRAM_HOME", "")).expanduser().resolve()
    openram_driver = openram_home / "sram_compiler.py"
    if not openram_driver.is_file():
        openram_driver = openram_home / "openram.py"

    if not args.dry_run:
        if not openram_driver.is_file():
            raise RuntimeError("RDTC_OPENRAM_HOME has no sram_compiler.py or openram.py: {}".format(openram_home))
        if work.exists() and not reuse_generated:
            shutil.rmtree(str(work))
        output.mkdir(parents=True, exist_ok=True)
        if reuse_root is not None and reuse_root != work and not reuse_generated:
            reuse_views = reuse_root / "views"
            reuse_manifest = reuse_root / "macro_manifest.json"
            if not reuse_views.is_dir() or not reuse_manifest.is_file():
                raise RuntimeError("RDTC_OPENRAM_REUSE_DIR has no audited views and manifest")
            shutil.rmtree(str(output))
            shutil.copytree(str(reuse_views), str(output))
            reuse_generated = True
            print("reusing audited OpenRAM views from {}".format(reuse_root))
    else:
        print("output: {}".format(output))

    environment = os.environ.copy()
    environment["RDTC_OPENRAM_OUTPUT"] = str(output)
    if profile_name == "sky130":
        pdk_root = Path(environment.get("RDTC_SKY130_PDK_ROOT", "")).expanduser().resolve()
        if not (pdk_root / "sky130A/libs.tech/ngspice/sky130.lib.spice").is_file():
            raise RuntimeError("SKY130 sram-prep requires RDTC_SKY130_PDK_ROOT containing sky130A")
        environment["PDK_ROOT"] = str(pdk_root)
    if (openram_home / "compiler").is_dir() and (openram_home / "technology").is_dir():
        environment["OPENRAM_HOME"] = str(openram_home / "compiler")
        environment["OPENRAM_TECH"] = str(openram_home / "technology")
        pythonpath = environment.get("PYTHONPATH", "")
        environment["PYTHONPATH"] = str(openram_home / "compiler") + (os.pathsep + pythonpath if pythonpath else "")
    openram_commit = git_commit(openram_home, "OpenRAM")
    if openram_commit != EXPECTED_OPENRAM_COMMIT and environment.get("RDTC_ALLOW_OPENRAM_COMMIT_MISMATCH") != "1":
        raise RuntimeError(
            "OpenRAM commit {} does not match pinned {}".format(openram_commit, EXPECTED_OPENRAM_COMMIT)
        )
    sky130_cell_commit = None
    sky130_overlay_counts = None
    openram_source_patch = None
    ngspice_provenance = None
    if spice_characterized and not args.dry_run:
        ngspice_real = Path(environment.get("RDTC_NGSPICE_REAL", "")).expanduser().resolve()
        ngspice_archive = Path(
            environment.get("RDTC_NGSPICE_SOURCE_ARCHIVE", "")
        ).expanduser().resolve()
        if not ngspice_real.is_file():
            raise RuntimeError("SPICE characterization requires RDTC_NGSPICE_REAL")
        if not ngspice_archive.is_file():
            raise RuntimeError("SPICE characterization requires RDTC_NGSPICE_SOURCE_ARCHIVE")
        archive_sha256 = sha256(ngspice_archive)
        if archive_sha256 != EXPECTED_NGSPICE_SOURCE_SHA256:
            raise RuntimeError(
                "ngspice source archive SHA256 {} does not match pinned {}".format(
                    archive_sha256, EXPECTED_NGSPICE_SOURCE_SHA256
                )
            )
        version_output = subprocess.check_output(
            [str(ngspice_real), "--version"], universal_newlines=True,
            stderr=subprocess.STDOUT
        )
        version_match = re.search(r"ngspice-([0-9.]+)", version_output)
        if not version_match or version_match.group(1) != EXPECTED_NGSPICE_VERSION:
            raise RuntimeError("SPICE characterization requires ngspice 46 with KLU")
        wrapper_source = root / "flows/memory/openram/ngspice_klu_wrapper.sh"
        wrapper_dir = work / "ngspice_wrapper"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        wrapper = wrapper_dir / "ngspice"
        shutil.copy2(str(wrapper_source), str(wrapper))
        wrapper.chmod(0o755)
        environment["RDTC_NGSPICE_REAL"] = str(ngspice_real)
        archive_dir = work / "ngspice_archive"
        archive_dir.mkdir(parents=True, exist_ok=True)
        environment["RDTC_NGSPICE_ARCHIVE_DIR"] = str(archive_dir)
        environment["PATH"] = str(wrapper_dir) + os.pathsep + environment.get("PATH", "")
        ngspice_provenance = {
            "version": version_match.group(1),
            "source_archive": ngspice_archive.name,
            "source_archive_sha256": archive_sha256,
            "binary_sha256": sha256(ngspice_real),
            "solver": "KLU",
            "wrapper_sha256": sha256(wrapper_source),
            "retry_archive": archive_dir.name,
        }
    if profile_name == "sky130" and not args.dry_run and not reuse_generated:
        cell_root = Path(environment.get("RDTC_SKY130_SRAM_CELL_ROOT", "")).expanduser().resolve()
        if not (cell_root / "cells/openram_dp_cell").is_dir():
            raise RuntimeError("SKY130 sram-prep requires RDTC_SKY130_SRAM_CELL_ROOT")
        overlay_root, sky130_cell_commit, sky130_overlay_counts = build_sky130_technology_overlay(
            openram_home, cell_root, work
        )
        environment["OPENRAM_TECH"] = str(overlay_root)
        source_overlay, openram_source_patch = build_openram_source_overlay(openram_home, work)
        openram_driver = source_overlay / openram_driver.name
        environment["OPENRAM_HOME"] = str(source_overlay / "compiler")
        pythonpath = environment.get("PYTHONPATH", "")
        environment["PYTHONPATH"] = str(source_overlay / "compiler") + (
            os.pathsep + pythonpath if pythonpath else ""
        )
        environment["RDTC_OPENRAM_EXPOSE_SUPPLY_PINS"] = "1"
    python_tool = tool_command(environment.get("RDTC_TOOL_OPENRAM_PYTHON", "python3"))
    lc_tool = tool_command(environment.get("RDTC_TOOL_LC", "lc_shell"))
    if not reuse_generated or args.dry_run:
        run(
            python_tool + [str(openram_compat), str(openram_driver), str(config)],
            work, work / "openram.log", environment, args.dry_run
        )
    if args.dry_run:
        run(lc_tool + ["-f", str(compile_tcl)], work, work / "lc.log", environment, True)
        return 0

    verilog = require_file(output / (macro + ".v"), "Verilog view")
    lef = require_file(output / (macro + ".lef"), "LEF view")
    gds = require_file(output / (macro + ".gds"), "GDS view")
    spice = require_file(output / (macro + ".sp"), "SPICE view")
    liberty_candidates = sorted(output.glob(macro + "*.lib"))
    if len(liberty_candidates) != 1:
        raise RuntimeError("expected one nominal Liberty view, found {}".format(len(liberty_candidates)))
    liberty = require_file(liberty_candidates[0], "Liberty view")
    audit = audit_text_views(
        macro, profile["required_pins"], profile["bus_pins"], verilog, liberty, lef,
        ("vccd1", "vssd1") if profile_name == "sky130" else (),
        require_perimeter_signal_pins=(profile_name == "freepdk45_spice")
    )
    if audit["liberty_nom_voltage_v"] is None:
        raise RuntimeError("Liberty view does not declare nom_voltage")
    if abs(audit["liberty_nom_voltage_v"] - profile["voltage"]) > 1e-6:
        raise RuntimeError(
            "Liberty nominal voltage {} V does not match requested {} V".format(
                audit["liberty_nom_voltage_v"], profile["voltage"]
            )
        )

    db = work / (macro + ".db")
    environment["RDTC_SRAM_LIB"] = str(liberty)
    environment["RDTC_SRAM_LIB_NAME"] = audit["library_name"]
    environment["RDTC_SRAM_DB"] = str(db)
    run(lc_tool + ["-f", str(compile_tcl)], work, work / "lc.log", environment, False)
    require_file(db, "Library Compiler DB")

    files = [verilog, liberty, lef, gds, spice, db]
    manifest = {
        "macro": macro,
        "organization": "64x128",
        "ports": profile["ports"],
        "technology": profile_name,
        "requested_corner": {"process": "TT", "voltage_v": profile["voltage"], "temperature_c": 25},
        "characterization": (
            "openram_ngspice_smoke"
            if spice_characterized and characterization_smoke
            else "openram_ngspice"
            if spice_characterized
            else "openram_analytical"
        ),
        "candidate_use": "diagnostic_only" if characterization_smoke else "implementation_candidate",
        "characterization_config": {
            "load_scales": [20] if characterization_smoke else [1, 4, 10, 20],
            "slew_scales": [16] if characterization_smoke else [1, 4, 8, 16],
            "trim_netlist": True if spice_characterized else None,
            "perimeter_pins": True if spice_characterized else None,
            "delay_chain_stages": (
                int(environment.get("RDTC_OPENRAM_DELAY_CHAIN_STAGES", "21"))
                if spice_characterized else None
            ),
            "delay_chain_fanout_per_stage": (
                int(environment.get("RDTC_OPENRAM_DELAY_CHAIN_FANOUT", "4"))
                if spice_characterized else None
            ),
        },
        "openram_commit": openram_commit,
        "spice_simulator": ngspice_provenance,
        "openram_source_patch": openram_source_patch,
        "sky130_sram_cell_commit": sky130_cell_commit,
        "sky130_technology_overlay": sky130_overlay_counts,
        "audit": audit,
        "files": [
            {"name": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
            for path in files
        ],
    }
    manifest_path = work / "macro_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("sram-prepare: PASS manifest={}".format(manifest_path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("sram-prepare: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
