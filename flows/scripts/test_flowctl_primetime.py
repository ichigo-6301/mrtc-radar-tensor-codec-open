#!/usr/bin/env python3
"""Unit tests for the fail-closed PrimeTime report verifier."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


FLOWCTL_PATH = Path(__file__).with_name("flowctl.py")
SPEC = importlib.util.spec_from_file_location("rdtc_flowctl", str(FLOWCTL_PATH))
FLOWCTL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FLOWCTL)


class PrimeTimeVerifierTest(unittest.TestCase):
    def write_reports(self, root, pins, extra=None):
        report_dir = root / "primetime"
        report_dir.mkdir(parents=True)
        (report_dir / "setup_summary.rpt").write_text(
            "No setup violations found.\n", encoding="utf-8"
        )
        (report_dir / "hold_summary.rpt").write_text(
            "No hold violations found.\n", encoding="utf-8"
        )
        (report_dir / "setup_timing.rpt").write_text(
            "slack (MET) 0.57\n", encoding="utf-8"
        )
        (report_dir / "hold_timing.rpt").write_text(
            "slack (MET) 0.04\n", encoding="utf-8"
        )

        lines = ["   min_capacitance", ""]
        for pin in pins:
            lines.extend(
                [
                    "   " + pin,
                    "        0.21 0.00 -0.21 (VIOLATED)",
                ]
            )
        if extra:
            category, obj = extra
            lines.extend(
                [
                    "",
                    "   " + category,
                    "",
                    "   " + obj,
                    "        0.08 0.10 -0.02 (VIOLATED)",
                ]
            )
        (report_dir / "constraint_violations.rpt").write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )

    def verify(self, root, waiver=True):
        FLOWCTL.verify_primetime_result(
            {"RDTC_BUILD_ROOT": str(root)}, waiver
        )

    def test_exact_unused_dout_waiver_passes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, sorted(FLOWCTL.unused_rw_dout_min_cap_pins()))
            self.verify(root)
            summary = (root / "primetime/verification_summary.txt").read_text(
                encoding="utf-8"
            )
            self.assertIn("status: PASS", summary)
            self.assertIn(
                "waived_unused_dout0_min_capacitance_count: 256", summary
            )

    def test_missing_waiver_pin_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pins = sorted(FLOWCTL.unused_rw_dout_min_cap_pins())[:-1]
            self.write_reports(root, pins)
            with self.assertRaisesRegex(RuntimeError, "waiver mismatch"):
                self.verify(root)

    def test_active_constraint_violation_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(
                root,
                sorted(FLOWCTL.unused_rw_dout_min_cap_pins()),
                ("max_transition", "u_example/A"),
            )
            with self.assertRaisesRegex(RuntimeError, "1 unwaived"):
                self.verify(root)

    def test_disabled_waiver_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, sorted(FLOWCTL.unused_rw_dout_min_cap_pins()))
            with self.assertRaisesRegex(RuntimeError, "256 unwaived"):
                self.verify(root, waiver=False)


if __name__ == "__main__":
    unittest.main()
