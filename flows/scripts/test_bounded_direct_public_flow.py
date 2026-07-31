#!/usr/bin/env python3
"""Public integration checks for the opt-in bounded Direct-AXIS profiles."""

import importlib.util
import os
from pathlib import Path
import unittest
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location("rdtc_public_flowctl", SCRIPT_DIR / "flowctl.py")
FLOWCTL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FLOWCTL)


class BoundedDirectPublicFlowTest(unittest.TestCase):
    def load_config(self, name):
        return FLOWCTL.parse_config(ROOT / "configs" / name)

    def environment(self, name, stage="dc-baseline"):
        path = ROOT / "configs" / name
        config = FLOWCTL.parse_config(path)
        with mock.patch.dict(os.environ, {}, clear=True):
            return FLOWCTL.stage_environment(ROOT, path, config, stage)

    def test_register_and_sram_profiles_select_direct_contract(self):
        profiles = {
            "rdtc_v1_bounded_direct_register_dc315_pnr300_defconfig": (
                "register",
                "y",
                "n",
            ),
            "rdtc_v1_bounded_direct_sram_dc315_pnr300_defconfig": (
                "sram",
                "n",
                "y",
            ),
        }
        for name, (mode, register, sram) in profiles.items():
            config = self.load_config(name)
            self.assertEqual(mode, FLOWCTL.bounded_direct_mode(config))
            environment = self.environment(name)
            self.assertEqual(FLOWCTL.BOUNDED_DIRECT_TOP, environment["RDTC_TOP"])
            self.assertEqual(
                ROOT / FLOWCTL.BOUNDED_DIRECT_FILELIST,
                Path(environment["RDTC_FILELIST"]),
            )
            self.assertEqual(
                ROOT / FLOWCTL.BOUNDED_DIRECT_SDC,
                Path(environment["RDTC_SDC"]),
            )
            self.assertEqual(register, environment["RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED"])
            self.assertEqual(sram, environment["RDTC_BOUNDED_DIRECT_ASIC_SRAM"])
            self.assertEqual("y", environment["RDTC_DC_FORBID_RETIME"])

    def test_invalid_direct_combinations_fail_closed(self):
        config = self.load_config(
            "rdtc_v1_bounded_direct_register_dc315_pnr300_defconfig"
        )
        mutations = (
            ("CONFIG_FLOW_BOUNDED_DIRECT_ASIC_SRAM", "y", "mutually exclusive"),
            ("CONFIG_FLOW_MEMORY_MODE", "macro", "MEMORY_MODE=registers"),
            ("CONFIG_RDTC_TOP", "mrtc_top", "requires top"),
            ("CONFIG_FLOW_SDC_FILE", "flows/constraints/other.sdc", "requires SDC"),
            ("CONFIG_FLOW_DC_FORBID_RETIME", "n", "FORBID_RETIME=y"),
        )
        for symbol, value, message in mutations:
            changed = dict(config)
            changed[symbol] = value
            with self.assertRaisesRegex(RuntimeError, message):
                FLOWCTL.bounded_direct_mode(changed)

    def test_public_make_kconfig_and_dc_guards_are_present(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        kconfig = (ROOT / "Kconfig").read_text(encoding="utf-8")
        dc_script = (ROOT / "flows/synthesis/dc/baseline/run.tcl").read_text(
            encoding="utf-8"
        )
        for target in (
            "bounded-direct-register-modelsim-regression:",
            "bounded-direct-modelsim-regression:",
            "bounded-direct-modelsim-regression-dry-run:",
            "bounded-direct-rtl-smoke:",
            "bounded-direct-vivado-route200:",
        ):
            self.assertIn(target, makefile)
        for symbol in (
            "FLOW_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED",
            "FLOW_BOUNDED_DIRECT_ASIC_SRAM",
            "FLOW_DC_FORBID_RETIME",
            "FLOW_SDC_FILE",
        ):
            self.assertIn("config " + symbol, kconfig)
        self.assertIn("compile_ultra[^;\\n]*-retime", dc_script)
        self.assertIn("RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED", dc_script)
        self.assertIn("RDTC_BOUNDED_DIRECT_ASIC_SRAM", dc_script)

    def test_public_asic_points_exclude_sram_600mhz(self):
        expected = (
            "rdtc_v1_bounded_direct_register_dc315_pnr300_defconfig",
            "rdtc_v1_bounded_direct_register_dc315_pnr300_opensta2_defconfig",
            "rdtc_v1_bounded_direct_register_dc630_pnr600_defconfig",
            "rdtc_v1_bounded_direct_sram_dc315_pnr300_defconfig",
            "rdtc_v1_bounded_direct_sram_dc315_pnr300_eco1_defconfig",
        )
        for name in expected:
            self.assertTrue((ROOT / "configs" / name).is_file(), name)
        self.assertFalse(
            (ROOT / "configs/rdtc_v1_bounded_direct_sram_dc630_pnr600_defconfig").exists()
        )


if __name__ == "__main__":
    unittest.main()
