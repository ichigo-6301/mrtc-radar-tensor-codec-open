#!/usr/bin/env python3
"""Run and audit the local TSMC90 exact 64x128 two-port memory generator.

The generator and all outputs stay on the IC_EDA_FULL host. This script only
defines the reproducible command contract; it never copies proprietary views
into the repository.
"""

from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(generator, output, fmt):
    command = [str(generator), fmt, "-words", "64", "-bits", "128"]
    result = subprocess.run(command, cwd=str(output), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, universal_newlines=True)
    (output / (fmt + ".log")).write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("{} failed: {}".format(fmt, result.returncode))
    if "generator is not available" in result.stdout.lower():
        raise RuntimeError("{} generator is unavailable".format(fmt))


def compile_liberty(output):
    liberty = output / "RF_2P_ADV_tt_1.0_25.0_syn.lib"
    db = output / "RF_2P_ADV_tt_1.0_25.0_syn.db"
    lc = os.environ.get("RDTC_TOOL_LC", "lc_shell")
    script = output / "compile_lib.tcl"
    script.write_text(
        "read_lib {}\nwrite_lib USERLIB -format db -output {}\nquit\n".format(liberty, db),
        encoding="utf-8",
    )
    result = subprocess.run([lc, "-f", str(script)], cwd=str(output),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True)
    (output / "lc_shell.log").write_text(result.stdout, encoding="utf-8")
    if result.returncode or not db.is_file():
        raise RuntimeError("Library Compiler did not create {}".format(db))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", default=os.environ.get("RDTC_TSMC90_RF_GENERATOR", "rf_2p_adv"))
    parser.add_argument("--output", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    generator = Path(args.generator)
    if args.dry_run:
        print("generator={}".format(generator))
        print("output={}".format(output))
        for fmt in ("verilog", "synopsys", "vclef-fp"):
            print("command={} {} -words 64 -bits 128".format(generator, fmt))
        return
    if not generator.is_file():
        raise SystemExit("missing generator: {}".format(generator))

    manifest = {"generator": str(generator), "words": 64, "bits": 128, "formats": {}}
    for fmt in ("verilog", "synopsys", "vclef-fp"):
        run(generator, output, fmt)
    compile_liberty(output)

    required = [output / "RF_2P_ADV.v", output / "RF_2P_ADV.vclef"]
    required.extend(output.glob("RF_2P_ADV_*_syn.lib"))
    if len(required) < 6 or any(not path.is_file() for path in required):
        raise RuntimeError("required logical/physical views are incomplete")
    verilog = (output / "RF_2P_ADV.v").read_text(encoding="utf-8", errors="replace")
    checks = {
        "module": bool(re.search(r"\bmodule\s+RF_2P_ADV\b", verilog)),
        "word_depth_64": "WORD_DEPTH = 64" in verilog,
        "bits_128": "BITS = 128" in verilog,
        "read_port": all(token in verilog for token in ("CLKA", "CENA", "AA", "QA")),
        "write_port": all(token in verilog for token in ("CLKB", "CENB", "AB", "DB")),
    }
    if not all(checks.values()):
        raise RuntimeError("generated Verilog audit failed: {}".format(checks))
    for path in sorted(output.iterdir()):
        if path.is_file() and path.name not in {"manifest.json"}:
            manifest["formats"].setdefault(path.suffix or path.name, []).append({
                "file": path.name,
                "sha256": sha256(path),
                "bytes": path.stat().st_size,
            })
    manifest["audit"] = checks
    manifest["gds2"] = "not_available_from_installed_rf_2p_adv"
    manifest["lvs"] = "not_available_from_installed_rf_2p_adv"
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("tsmc90-rf-prepare: PASS manifest={}".format(output / "manifest.json"))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print("tsmc90-rf-prepare: error: {}".format(error), file=sys.stderr)
        sys.exit(2)
