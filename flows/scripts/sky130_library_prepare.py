#!/usr/bin/env python3
"""Audit SKY130HD views and compile the nominal Liberty for Synopsys tools."""

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


PDK_VERSION = "44a43c23c81b45b8e774ae7a84899a5a778b6b0b"
LIB_NAME = "sky130_fd_sc_hd__tt_025C_1v80"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tool_command(value):
    parts = shlex.split(value, posix=(os.name != "nt"))
    if not parts:
        raise RuntimeError("empty tool command")
    executable = shutil.which(parts[0]) or (parts[0] if Path(parts[0]).is_file() else None)
    if not executable:
        raise RuntimeError("tool executable not found: {}".format(parts[0]))
    return [str(executable)] + parts[1:]


def require_file(path, label):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing {}: {}".format(label, path))
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    pdk_root = Path(os.environ.get("RDTC_SKY130_PDK_ROOT", "")).expanduser().resolve()
    sky130 = pdk_root / "sky130A"
    build_root = Path(os.environ["RDTC_BUILD_ROOT"]).resolve()
    output = build_root / "sky130_libs"
    liberty = require_file(
        sky130 / "libs.ref/sky130_fd_sc_hd/lib/{}.lib".format(LIB_NAME), "SKY130HD Liberty"
    )
    required = {
        "standard_cell_lef": sky130 / "libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef",
        "standard_cell_gds": sky130 / "libs.ref/sky130_fd_sc_hd/gds/sky130_fd_sc_hd.gds",
        "standard_cell_cdl": sky130 / "libs.ref/sky130_fd_sc_hd/cdl/sky130_fd_sc_hd.cdl",
        "klayout_lvs": sky130 / "libs.tech/klayout/lvs/sky130.lylvs",
        "magic_rc": sky130 / "libs.tech/magic/sky130A.magicrc",
        "netgen_setup": sky130 / "libs.tech/netgen/sky130A_setup.tcl",
        "ngspice_models": sky130 / "libs.tech/ngspice/sky130.lib.spice",
    }
    for label, path in required.items():
        require_file(path, label)

    liberty_text = liberty.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"\blibrary\s*\(\s*([^\s)]+)\s*\)", liberty_text)
    if not match:
        raise RuntimeError("SKY130HD Liberty has no library declaration")

    db = output / (LIB_NAME + ".db")
    sanitized_liberty = output / (LIB_NAME + "_lc2018.lib")
    compile_tcl = root / "flows/memory/openram/compile_lib.tcl"
    sanitizer = root / "flows/scripts/sanitize_sky130_liberty.py"
    command = tool_command(os.environ.get("RDTC_TOOL_LC", "lc_shell")) + ["-f", str(compile_tcl)]
    sanitize_command = [sys.executable, str(sanitizer), "--input", str(liberty), "--output", str(sanitized_liberty)]
    print("command: {}".format(" ".join(shlex.quote(item) for item in sanitize_command)))
    print("command: {}".format(" ".join(shlex.quote(item) for item in command)))
    if args.dry_run:
        print("sky130-library-prepare: DRY-RUN output={}".format(output))
        return 0

    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(sanitize_command, cwd=str(output), check=True)
    require_file(sanitized_liberty, "LC-compatible SKY130HD Liberty")
    environment = os.environ.copy()
    environment.update({
        "RDTC_SRAM_LIB": str(sanitized_liberty),
        "RDTC_SRAM_LIB_NAME": match.group(1).strip('"'),
        "RDTC_SRAM_DB": str(db),
    })
    log = output / "lc.log"
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, cwd=str(output), env=environment, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError("Library Compiler failed; inspect {}".format(log))
    require_file(db, "SKY130HD DB")

    manifest = {
        "pdk_family": "sky130A",
        "open_pdks_commit": PDK_VERSION,
        "corner": "TT_1p8V_25C",
        "files": [
            {"role": "liberty", "path": str(liberty.relative_to(pdk_root)), "sha256": sha256(liberty)},
            {"role": "lc2018_liberty", "path": sanitized_liberty.name, "sha256": sha256(sanitized_liberty)},
            {"role": "compiled_db", "path": db.name, "sha256": sha256(db)},
        ] + [
            {"role": label, "path": str(path.relative_to(pdk_root)), "sha256": sha256(path)}
            for label, path in sorted(required.items())
        ],
    }
    manifest_path = output / "library_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("sky130-library-prepare: PASS manifest={}".format(manifest_path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("sky130-library-prepare: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
