#!/usr/bin/env python3
"""Run OpenRAM on Python 3.6 without modifying the third-party checkout."""

import runpy
import sys
import time
from pathlib import Path


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: run_openram.py <driver.py> <config.py>")
    driver = sys.argv[1]
    sys.argv = [driver] + sys.argv[2:]
    sys.path.insert(0, str(Path(driver).resolve().parent))
    if not hasattr(time, "time_ns"):
        time.time_ns = lambda: int(time.time() * 1000000000)
    runpy.run_path(driver, run_name="__main__")


if __name__ == "__main__":
    main()
