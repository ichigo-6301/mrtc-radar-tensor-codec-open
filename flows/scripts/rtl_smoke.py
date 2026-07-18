#!/usr/bin/env python3
"""Elaborate the public RDTC source set with Icarus Verilog."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--filelist", required=True)
    parser.add_argument("--top", default="mrtc_rdtc_wb_wrapper")
    parser.add_argument("--tool", default="iverilog")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    filelist = Path(args.filelist).resolve()
    if not filelist.is_file():
        print("rtl-smoke: missing filelist: {}".format(filelist), file=sys.stderr)
        return 2
    tool = shutil.which(args.tool)
    if not tool:
        print("rtl-smoke: tool not found: {}".format(args.tool), file=sys.stderr)
        return 2

    output_dir = root / "build" / "rtl_smoke"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / "{}.vvp".format(args.top)
    command = [tool, "-g2012", "-s", args.top, "-o", str(output), "-f", str(filelist)]
    print("command: " + " ".join(command))
    subprocess.run(command, cwd=str(root), check=True)
    print("rtl-smoke: PASS ({})".format(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
