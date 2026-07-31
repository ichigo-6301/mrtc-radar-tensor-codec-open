#!/usr/bin/env python3
"""Tests for the public bounded buffered versus Direct-AXIS DC A/B."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import yaml


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location(
    "bounded_buffered_direct_dc_ab",
    SCRIPT_DIR / "bounded_buffered_direct_dc_ab.py",
)
AB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AB)


class BoundedBufferedDirectDcAbTest(unittest.TestCase):
    def config(self, name):
        return AB.flowctl.parse_config(ROOT / "configs" / name)

    def test_four_fixed_points_are_unique(self):
        self.assertEqual(4, len(AB.POINTS))
        self.assertEqual(4, len({point["key"] for point in AB.POINTS}))
        self.assertEqual({315, 630}, {point["frequency_mhz"] for point in AB.POINTS})

    def test_only_315mhz_points_are_mandatory(self):
        mandatory = {point["key"] for point in AB.POINTS if AB.is_mandatory_point(point)}
        self.assertEqual({"buffered315", "direct315"}, mandatory)

    def test_all_configs_pass_fixed_contract(self):
        for point in AB.POINTS:
            spec = AB.flowctl.bounded_dc_ab_spec(self.config(point["config"]))
            self.assertEqual(point["family"], spec["family"])
            self.assertEqual(point["storage_bits"], spec["storage_bits"])

    def test_family_mismatch_fails_closed(self):
        config = self.config("rdtc_v1_bounded_ab_buffered_dc315_defconfig")
        config["CONFIG_FLOW_BOUNDED_ASIC_REGISTER_EXPANDED"] = "n"
        config["CONFIG_FLOW_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED"] = "y"
        with self.assertRaisesRegex(RuntimeError, "family"):
            AB.flowctl.bounded_dc_ab_spec(config)

    def test_library_hash_and_period_mutations_fail(self):
        original = self.config("rdtc_v1_bounded_ab_direct_dc315_defconfig")
        for field, value in (
            ("CONFIG_FLOW_EXPECTED_STDCELL_DB_SHA256", "0" * 64),
            ("CONFIG_FLOW_DC_CLOCK_PERIOD_NS", "3.200000"),
            ("CONFIG_FLOW_DC_MAX_CORES", "8"),
            ("CONFIG_FLOW_PNR", "y"),
        ):
            changed = dict(original)
            changed[field] = value
            with self.assertRaises(RuntimeError):
                AB.flowctl.bounded_dc_ab_spec(changed)

    def test_stage_environment_is_hash_bound(self):
        name = "rdtc_v1_bounded_ab_direct_dc315_defconfig"
        path = ROOT / "configs" / name
        config = self.config(name)
        inherited = {
            "RDTC_BUILD_ROOT": str(ROOT / "build" / "wrong_parent"),
            "RDTC_DC_HANDOFF_ROOT": str(ROOT / "build" / "wrong_handoff"),
        }
        with mock.patch.dict(os.environ, inherited, clear=True):
            environment = AB.flowctl.stage_environment(
                ROOT, path, config, "dc-baseline"
            )
        expected_build = str(ROOT / "build" / "rdtc_v1_bounded_ab_direct_dc315")
        self.assertEqual(expected_build, environment["RDTC_BUILD_ROOT"])
        self.assertEqual(expected_build, environment["RDTC_DC_HANDOFF_ROOT"])
        self.assertEqual(str(ROOT / AB.FILELIST), environment["RDTC_FILELIST"])
        self.assertEqual(str(ROOT / AB.COMMON_SDC), environment["RDTC_SDC"])
        self.assertEqual("y", environment["RDTC_BOUNDED_DC_AB"])
        self.assertEqual("y", environment["RDTC_DC_NO_INIT"])
        self.assertEqual("32768", environment["RDTC_EXPECTED_BOUNDED_BULK_STORAGE_BITS"])
        self.assertEqual(AB.EXPECTED_DB_SHA256, environment["RDTC_EXPECTED_STDCELL_DB_SHA256"])
        self.assertEqual("4", environment["RDTC_DC_MAX_CORES"])

    def test_every_ab_point_overrides_inherited_build_roots(self):
        inherited = {
            "RDTC_BUILD_ROOT": str(ROOT / "build" / "parent_profile"),
            "RDTC_DC_HANDOFF_ROOT": str(ROOT / "build" / "parent_handoff"),
        }
        for point in AB.POINTS:
            path = ROOT / "configs" / point["config"]
            with self.subTest(point=point["key"]), mock.patch.dict(
                os.environ, inherited, clear=True
            ):
                environment = AB.flowctl.stage_environment(
                    ROOT, path, self.config(point["config"]), "dc-baseline"
                )
                expected = str(ROOT / "build" / point["build_tag"])
                self.assertEqual(expected, environment["RDTC_BUILD_ROOT"])
                self.assertEqual(expected, environment["RDTC_DC_HANDOFF_ROOT"])

    def test_stage_command_uses_no_init(self):
        config = self.config("rdtc_v1_bounded_ab_buffered_dc315_defconfig")
        with mock.patch.dict(os.environ, {"RDTC_TOOL_DC": "dc_shell"}, clear=True):
            command = AB.flowctl.stage_command(ROOT, "dc-baseline", False, config)
        self.assertIn("-no_init", command)
        self.assertLess(command.index("-no_init"), command.index("-f"))

    def test_dc_uses_single_define_list_for_o2018(self):
        tcl = (ROOT / AB.RUN_TCL).read_text(encoding="utf-8")
        self.assertIn("lappend analyze_command -define $rdtc_rtl_defines", tcl)
        self.assertNotIn("foreach define $rdtc_rtl_defines", tcl)

    def test_source_identity_binds_public_rtl(self):
        identity = AB.source_identity(ROOT)
        self.assertTrue(identity["fixed_public_rtl_match"])
        self.assertEqual(69, identity["source_count"])
        self.assertEqual(64, len(identity["source_set_sha256"]))

    def test_area_parser(self):
        report = """Version: O-2018.06-SP1
Number of cells: 100
Number of combinational cells: 60
Number of sequential cells: 40
Number of macros/black boxes: 0
Number of buf/inv: 12
Combinational area: 123.500
Noncombinational area: 45.250
Total cell area: 168.750
"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "area.rpt"
            path.write_text(report, encoding="utf-8")
            parsed = AB.parse_area_report(path)
        self.assertEqual(100, parsed["cell_count"])
        self.assertEqual(168.75, parsed["total_cell_area_um2"])

    def test_gate_accepts_complete_closed_run(self):
        point = AB.POINTS[0]
        expected = {
            "status": "PASS",
            "setup_wns": "0.01",
            "setup_tns": "0.0",
            "setup_violating_paths": "0",
            "constraint_violating_checks": "0",
            "seqgen_cell_count": "0",
            "gtech_cell_count": "0",
            "designware_cell_count": "0",
            "unmapped_cell_count": "0",
            "memory_macro_count": "0",
            "retiming": "disabled",
            "bounded_asic_family": "buffered",
            "bounded_bulk_storage_bits": "180224",
            "bounded_register_storage_bits": "180224",
            "stdcell_db_sha256": AB.EXPECTED_DB_SHA256,
            "dc_max_cores": "4",
        }
        run = {
            "status": "PASS",
            "closure": expected,
            "contract": {
                "top": AB.flowctl.BOUNDED_BUFFERED_TOP,
                "documented_clock_period_ns": "3.174603",
            },
            "area": {"tool_version": AB.EXPECTED_DC_VERSION, "macro_count": 0},
        }
        self.assertEqual((True, []), AB.gate_run(run, point))

    def test_gate_rejects_mismatched_report_period(self):
        point = AB.POINTS[0]
        closure = {
            "status": "PASS",
            "setup_wns": "0.01",
            "setup_tns": "0.0",
            "setup_violating_paths": "0",
            "constraint_violating_checks": "0",
            "seqgen_cell_count": "0",
            "gtech_cell_count": "0",
            "designware_cell_count": "0",
            "unmapped_cell_count": "0",
            "memory_macro_count": "0",
            "retiming": "disabled",
            "bounded_asic_family": "buffered",
            "bounded_bulk_storage_bits": "180224",
            "bounded_register_storage_bits": "180224",
            "stdcell_db_sha256": AB.EXPECTED_DB_SHA256,
            "dc_max_cores": "4",
        }
        run = {
            "status": "PASS",
            "closure": closure,
            "contract": {
                "top": AB.flowctl.BOUNDED_BUFFERED_TOP,
                "documented_clock_period_ns": "1.587302",
            },
            "area": {"tool_version": AB.EXPECTED_DC_VERSION, "macro_count": 0},
        }
        passed, failures = AB.gate_run(run, point)
        self.assertFalse(passed)
        self.assertTrue(any("clock period" in failure for failure in failures))

    def test_gate_rejects_nonfinite_timing_values(self):
        point = AB.POINTS[0]
        for field, value in (
            ("setup_wns", "nan"),
            ("setup_tns", "nan"),
            ("documented_clock_period_ns", "nan"),
        ):
            closure = {
                "status": "PASS",
                "setup_wns": "0.01",
                "setup_tns": "0.0",
                "setup_violating_paths": "0",
                "constraint_violating_checks": "0",
                "seqgen_cell_count": "0",
                "gtech_cell_count": "0",
                "designware_cell_count": "0",
                "unmapped_cell_count": "0",
                "memory_macro_count": "0",
                "retiming": "disabled",
                "bounded_asic_family": "buffered",
                "bounded_bulk_storage_bits": "180224",
                "bounded_register_storage_bits": "180224",
                "stdcell_db_sha256": AB.EXPECTED_DB_SHA256,
                "dc_max_cores": "4",
            }
            contract = {
                "top": AB.flowctl.BOUNDED_BUFFERED_TOP,
                "documented_clock_period_ns": "3.174603",
            }
            if field in closure:
                closure[field] = value
            else:
                contract[field] = value
            run = {
                "status": "PASS",
                "closure": closure,
                "contract": contract,
                "area": {
                    "tool_version": AB.EXPECTED_DC_VERSION,
                    "macro_count": 0,
                },
            }
            with self.subTest(field=field):
                self.assertFalse(AB.gate_run(run, point)[0])

    def test_public_summary_field_allowlists_drop_local_db_path(self):
        local_db = "/licensed/local/path/Nangate45.db"
        closure = AB.select_public_fields(
            {"status": "PASS", "stdcell_db": local_db}, AB.PUBLIC_CLOSURE_FIELDS
        )
        contract = AB.select_public_fields(
            {
                "top": AB.flowctl.BOUNDED_BUFFERED_TOP,
                "documented_clock_period_ns": "3.174603",
                "stdcell_db": local_db,
            },
            AB.PUBLIC_CONTRACT_FIELDS,
        )
        self.assertEqual({"status": "PASS"}, closure)
        self.assertNotIn("stdcell_db", contract)
        self.assertNotIn(local_db, str({"closure": closure, "contract": contract}))

    def test_legacy_contract_does_not_claim_unmeasured_ab_audits(self):
        tcl = (ROOT / AB.RUN_TCL).read_text(encoding="utf-8")
        marker = 'if {$bounded_dc_ab} {\n    echo "constraint_violating_checks='
        self.assertIn(marker, tcl)

    def test_gate_rejects_negative_slack(self):
        point = AB.POINTS[0]
        run = {
            "status": "PASS",
            "closure": {"setup_wns": "-0.01", "setup_tns": "-0.01"},
            "contract": {},
            "area": {"tool_version": AB.EXPECTED_DC_VERSION, "macro_count": 0},
        }
        passed, failures = AB.gate_run(run, point)
        self.assertFalse(passed)
        self.assertTrue(failures)

    def test_percent_reduction(self):
        self.assertAlmostEqual(75.0, AB.percent_reduction(100.0, 25.0))
        with self.assertRaises(RuntimeError):
            AB.percent_reduction(0.0, 0.0)

    def test_public_evidence_recomputes_published_reductions(self):
        path = ROOT / "evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml"
        evidence = yaml.safe_load(path.read_text(encoding="utf-8"))
        dc315 = evidence["dc315"]
        comparison = dc315["comparison"]
        self.assertAlmostEqual(
            AB.percent_reduction(
                dc315["buffered"]["total_cell_area_um2"],
                dc315["direct"]["total_cell_area_um2"],
            ),
            comparison["total_cell_area_reduction_percent"],
        )
        self.assertAlmostEqual(
            AB.percent_reduction(
                dc315["buffered"]["cell_count"],
                dc315["direct"]["cell_count"],
            ),
            comparison["cell_count_reduction_percent"],
        )
        self.assertEqual("PASS_DC_ONLY", evidence["classification"])

    def test_public_surface_contains_fail_closed_guards(self):
        tcl = (ROOT / AB.RUN_TCL).read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        kconfig = (ROOT / "Kconfig").read_text(encoding="utf-8")
        for marker in (
            "RDTC_EXPECTED_STDCELL_DB_SHA256",
            "RDTC_BOUNDED_HT_WAY_RING",
            "compile_ultra -incremental -only_design_rule",
            "bounded_register_storage_bits",
            "dc_closure_summary.txt",
        ):
            self.assertIn(marker, tcl)
        self.assertIn("bounded-dc-ab-run:", makefile)
        self.assertIn("config FLOW_BOUNDED_ASIC_REGISTER_EXPANDED", kconfig)

    def test_runner_has_no_private_host_or_path_literals(self):
        text = (SCRIPT_DIR / "bounded_buffered_direct_dc_ab.py").read_text(
            encoding="utf-8"
        )
        for forbidden in ("private_host", "private_worktree", "license_server"):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
