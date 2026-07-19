#!/usr/bin/env python3
"""Unit tests for profile-driven fail-closed PrimeTime verification."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


FLOWCTL_PATH = Path(__file__).with_name("flowctl.py")
SPEC = importlib.util.spec_from_file_location("rdtc_flowctl", str(FLOWCTL_PATH))
FLOWCTL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FLOWCTL)


class PrimeTimeVerifierTest(unittest.TestCase):
    @staticmethod
    def expected_pins():
        return [
            "u_dual_core/u_lane{}/u_engine/u_prefix_sample_buffer/u_sram/dout0[{}]".format(lane, bit)
            for lane in range(2)
            for bit in range(128)
        ]

    def write_policy(self, root, expected_count=256):
        path = root / "waiver.yaml"
        lines = [
            "schema_version: 1.0.0",
            "kind: primetime_waiver_policy",
            "policy_id: test_exact_policy",
            "profile_id: test_sram_profile",
            "maturity: reviewed_profile_specific",
            "constraint_type: min_capacitance",
            "expected_count: {}".format(expected_count),
            "object_scope: exact test pins",
            "match_mode: exact_set",
            "allow_extra: false",
            "allow_missing: false",
            "objects:",
        ]
        lines.extend("  - " + pin for pin in self.expected_pins())
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def write_reports(self, root, pins, extra=None):
        report_dir = root / "primetime"
        report_dir.mkdir(parents=True)
        (report_dir / "setup_summary.rpt").write_text("No setup violations found.\n", encoding="utf-8")
        (report_dir / "hold_summary.rpt").write_text("No hold violations found.\n", encoding="utf-8")
        (report_dir / "setup_timing.rpt").write_text("slack (MET) 0.57\n", encoding="utf-8")
        (report_dir / "hold_timing.rpt").write_text("slack (MET) 0.04\n", encoding="utf-8")
        lines = ["   min_capacitance", ""]
        for pin in pins:
            lines.extend(["   " + pin, "        0.21 0.00 -0.21 (VIOLATED)"])
        if extra:
            category, obj = extra
            lines.extend(["", "   " + category, "", "   " + obj, "        0.08 0.10 -0.02 (VIOLATED)"])
        (report_dir / "constraint_violations.rpt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def verify(self, root, policy=True, expected_count=256):
        path = self.write_policy(root, expected_count) if policy else None
        FLOWCTL.verify_primetime_result({"RDTC_BUILD_ROOT": str(root)}, path)

    def test_exact_policy_set_passes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, self.expected_pins())
            self.verify(root)
            summary = (root / "primetime/verification_summary.txt").read_text(encoding="utf-8")
            self.assertIn("status: PASS", summary)
            self.assertIn("waived_constraint_count: 256", summary)
            self.assertRegex(summary, r"waiver_policy_sha256: [0-9a-f]{64}")

    def test_missing_expected_object_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, self.expected_pins()[:-1])
            with self.assertRaisesRegex(RuntimeError, "waiver mismatch"):
                self.verify(root)

    def test_extra_active_violation_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, self.expected_pins(), ("max_transition", "u_example/A"))
            with self.assertRaisesRegex(RuntimeError, "1 unwaived"):
                self.verify(root)

    def test_policy_disabled_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, self.expected_pins())
            with self.assertRaisesRegex(RuntimeError, "256 unwaived"):
                self.verify(root, policy=False)

    def test_wrong_expected_count_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_reports(root, self.expected_pins())
            with self.assertRaisesRegex(RuntimeError, "expected_count=255"):
                self.verify(root, expected_count=255)

    def test_non_sram_profile_cannot_load_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            policy = self.write_policy(root)
            config = {
                "CONFIG_FLOW_PRODUCT_PROFILE": "register-expanded",
                "CONFIG_FLOW_MEMORY_MODE": "registers",
                "CONFIG_FLOW_TECHNOLOGY": "nangate45_registers",
                "CONFIG_FLOW_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER": "y",
                "CONFIG_FLOW_STA_WAIVER_POLICY": str(policy),
            }
            with self.assertRaisesRegex(RuntimeError, "register-expanded cannot enable an SRAM waiver"):
                FLOWCTL.validate_selected_config(root, config)


if __name__ == "__main__":
    unittest.main()
