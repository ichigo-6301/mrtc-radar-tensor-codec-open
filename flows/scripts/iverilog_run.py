#!/usr/bin/env python3
"""Compile and run a bounded Icarus smoke test with an explicit PASS marker."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def run(command, cwd, timeout, expect_failure=False):
    print("command: " + " ".join(str(item) for item in command))
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        if error.stdout:
            print(error.stdout, end="")
        if error.stderr:
            print(error.stderr, end="", file=sys.stderr)
        raise RuntimeError("command timed out after {} seconds".format(timeout))
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if expect_failure and result.returncode == 0:
        raise RuntimeError("command unexpectedly succeeded")
    if not expect_failure and result.returncode:
        raise RuntimeError("command failed with exit code {}".format(result.returncode))
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--filelist", required=True)
    parser.add_argument("--top", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--plusarg", action="append", default=[])
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--iverilog-base")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--expect-run-failure", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    filelist = (root / args.filelist).resolve()
    if not filelist.is_file():
        print("showcase-smoke: missing filelist: {}".format(filelist), file=sys.stderr)
        return 2

    iverilog = shutil.which(args.iverilog)
    vvp = shutil.which(args.vvp)
    if not iverilog or not vvp:
        print(
            "showcase-smoke: Icarus tools not found: iverilog={} vvp={}".format(
                bool(iverilog), bool(vvp)
            ),
            file=sys.stderr,
        )
        return 2

    output_dir = root / "build" / "showcase_smoke" / args.top
    output_dir.mkdir(parents=True, exist_ok=True)
    image = output_dir / "{}.vvp".format(args.top)

    try:
        compile_command = [iverilog]
        if args.iverilog_base:
            compile_command.extend(["-B", args.iverilog_base])
        compile_command.extend(
            [
                "-g2012",
                "-s",
                args.top,
                "-o",
                str(image),
                "-f",
                str(filelist),
            ]
        )
        run(
            compile_command,
            root,
            args.timeout,
        )
        output = run(
            [vvp, str(image)] + ["+" + item for item in args.plusarg],
            root,
            args.timeout,
            expect_failure=args.expect_run_failure,
        )
    except RuntimeError as error:
        print("showcase-smoke: FAIL: {}".format(error), file=sys.stderr)
        return 1

    if args.marker not in output:
        print(
            "showcase-smoke: FAIL: missing marker {!r}".format(args.marker),
            file=sys.stderr,
        )
        return 1
    print("showcase-smoke: PASS top={} marker={}".format(args.top, args.marker))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
