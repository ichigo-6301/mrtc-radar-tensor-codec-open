#!/usr/bin/env python3
"""Tests for the public bounded buffered versus Direct-AXIS DC A/B."""

import importlib.util
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
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
MANIFEST_SHA256 = "a" * 64


class BoundedBufferedDirectDcAbTest(unittest.TestCase):
    def config(self, name):
        return AB.flowctl.parse_config(ROOT / "configs" / name)

    def bind_run_integrity(self, run):
        run["input_manifest_sha256"] = MANIFEST_SHA256
        run["execution_input_manifest_sha256"] = MANIFEST_SHA256
        closure = run.setdefault("closure", {})
        family = closure.get("bounded_asic_family", "buffered")
        point = next(item for item in AB.POINTS if item["family"] == family)
        closure_defaults = {
            "status": "PASS",
            "setup_wns": "0.01",
            "setup_tns": "0.0",
            "setup_violating_paths": "0",
            "constraint_violating_checks": "0",
            "bounded_design_rule_repair_passes": "1",
            "seqgen_cell_count": "0",
            "gtech_cell_count": "0",
            "designware_cell_count": "0",
            "unmapped_cell_count": "0",
            "memory_macro_count": "0",
            "retiming": "disabled",
            "retiming_control": "tracked_compile_ultra_without_retime",
            "bounded_library_setup": "inline_hash_bound_register",
            "bounded_asic_family": family,
            "bounded_bulk_storage_bits": str(point["storage_bits"]),
            "bounded_register_storage_bits": str(point["storage_bits"]),
            "stdcell_db_sha256": AB.EXPECTED_DB_SHA256,
            "dc_max_cores": "4",
            "input_manifest_sha256": MANIFEST_SHA256,
        }
        for key, value in closure_defaults.items():
            closure.setdefault(key, value)
        contract = run.setdefault("contract", {})
        contract_defaults = {
            "status": "PASS",
            "product_profile": point["product_profile"],
            "technology": AB.EXPECTED_TECHNOLOGY,
            "top": (
                AB.flowctl.BOUNDED_BUFFERED_TOP
                if family == "buffered"
                else AB.flowctl.BOUNDED_DIRECT_TOP
            ),
            "documented_clock_period_ns": str(point["period_ns"]),
            "clock_period_library_units": str(point["period_ns"]),
            "sdc_time_scale": "1.0",
            "memory_mode": AB.EXPECTED_MEMORY_MODE,
            "bounded_dc_ab": "1",
            "bounded_asic_family": family,
            "bounded_bulk_storage_bits": str(point["storage_bits"]),
            "bounded_register_storage_bits": str(point["storage_bits"]),
            "setup_wns": closure["setup_wns"],
            "setup_tns": closure["setup_tns"],
            "setup_violating_paths": closure["setup_violating_paths"],
            "constraint_violating_checks": closure["constraint_violating_checks"],
            "bounded_design_rule_repair_passes": closure[
                "bounded_design_rule_repair_passes"
            ],
            "seqgen_cell_count": closure["seqgen_cell_count"],
            "gtech_cell_count": closure["gtech_cell_count"],
            "designware_cell_count": closure["designware_cell_count"],
            "unmapped_cell_count": closure["unmapped_cell_count"],
            "memory_macro_count": closure["memory_macro_count"],
            "retiming": closure["retiming"],
            "retiming_control": closure["retiming_control"],
            "bounded_library_setup": closure["bounded_library_setup"],
            "stdcell_db_sha256": closure["stdcell_db_sha256"],
            "dc_max_cores": closure["dc_max_cores"],
            "input_manifest_sha256": MANIFEST_SHA256,
        }
        for key, value in contract_defaults.items():
            contract.setdefault(key, value)
        area = run.setdefault("area", {})
        area.setdefault("cell_count", 100)
        area.setdefault("sequential_cell_count", 40)
        area.setdefault("total_cell_area_um2", 168.75)
        contract["total_cell_count"] = str(area["cell_count"])
        run["hierarchy_area"] = {"top_area_um2": area["total_cell_area_um2"]}
        report_hashes = {
            name: (str(index + 1) * 64)[:64]
            for index, name in enumerate(AB.REQUIRED_REPORTS)
        }
        run["execution_report_sha256"] = report_hashes
        run["artifacts"] = {
            name: {"sha256": digest} for name, digest in report_hashes.items()
        }
        return run

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
            ("CONFIG_FLOW_SDC_TIME_SCALE", "1000.0"),
            ("CONFIG_FLOW_DC_HANDOFF_BUILD_TAG", "wrong_handoff"),
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
            "RDTC_PRODUCT_PROFILE": "wrong-profile",
            "RDTC_TECHNOLOGY": "wrong-technology",
            "CONFIG_FLOW_TECHNOLOGY": "wrong-technology",
            "RDTC_SDC_TIME_SCALE": "1000.0",
            "RDTC_MEMORY_MODE": "macro",
            "RDTC_BOUNDED_ASIC_REGISTER_EXPANDED": "y",
            "RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED": "y",
            "RDTC_BOUNDED_DIRECT_ASIC_SRAM": "y",
            "RDTC_DC_FORBID_RETIME": "n",
            "RDTC_DC_CLOCK_PERIOD_NS": "99.0",
            "RDTC_PNR_CLOCK_PERIOD_NS": "99.0",
            "RDTC_STA_CLOCK_PERIOD_NS": "99.0",
            "RDTC_DC_AB_INPUT_MANIFEST_SHA256": MANIFEST_SHA256,
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
        self.assertEqual("", environment["RDTC_DC_SETUP"])
        self.assertEqual("32768", environment["RDTC_EXPECTED_BOUNDED_BULK_STORAGE_BITS"])
        self.assertEqual(AB.EXPECTED_DB_SHA256, environment["RDTC_EXPECTED_STDCELL_DB_SHA256"])
        self.assertEqual("4", environment["RDTC_DC_MAX_CORES"])
        self.assertEqual("bounded-direct-register-expanded", environment["RDTC_PRODUCT_PROFILE"])
        self.assertEqual("nangate45_registers", environment["RDTC_TECHNOLOGY"])
        self.assertEqual("nangate45_registers", environment["CONFIG_FLOW_TECHNOLOGY"])
        self.assertEqual("1.0", environment["RDTC_SDC_TIME_SCALE"])
        self.assertEqual("registers", environment["RDTC_MEMORY_MODE"])
        self.assertEqual("n", environment["RDTC_BOUNDED_ASIC_REGISTER_EXPANDED"])
        self.assertEqual("y", environment["RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED"])
        self.assertEqual("n", environment["RDTC_BOUNDED_DIRECT_ASIC_SRAM"])
        self.assertEqual("y", environment["RDTC_DC_FORBID_RETIME"])
        self.assertEqual(
            MANIFEST_SHA256, environment["RDTC_DC_AB_INPUT_MANIFEST_SHA256"]
        )
        for key in (
            "RDTC_CLOCK_PERIOD_NS",
            "RDTC_DC_CLOCK_PERIOD_NS",
            "RDTC_PNR_CLOCK_PERIOD_NS",
            "RDTC_STA_CLOCK_PERIOD_NS",
        ):
            self.assertEqual("3.174603", environment[key])

    def test_every_ab_point_overrides_inherited_build_roots(self):
        inherited = {
            "RDTC_BUILD_ROOT": str(ROOT / "build" / "parent_profile"),
            "RDTC_DC_HANDOFF_ROOT": str(ROOT / "build" / "parent_handoff"),
            "RDTC_BOUNDED_ASIC_REGISTER_EXPANDED": "y",
            "RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED": "y",
            "RDTC_BOUNDED_DIRECT_ASIC_SRAM": "y",
            "RDTC_SDC_TIME_SCALE": "1000.0",
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
                self.assertEqual("1.0", environment["RDTC_SDC_TIME_SCALE"])
                self.assertEqual(
                    "y" if point["family"] == "buffered" else "n",
                    environment["RDTC_BOUNDED_ASIC_REGISTER_EXPANDED"],
                )
                self.assertEqual(
                    "y" if point["family"] == "direct" else "n",
                    environment["RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED"],
                )
                self.assertEqual("n", environment["RDTC_BOUNDED_DIRECT_ASIC_SRAM"])

    def test_stage_command_uses_no_init(self):
        config = self.config("rdtc_v1_bounded_ab_buffered_dc315_defconfig")
        with mock.patch.dict(os.environ, {"RDTC_TOOL_DC": "dc_shell"}, clear=True):
            command = AB.flowctl.stage_command(ROOT, "dc-baseline", False, config)
        self.assertIn("-no_init", command)
        self.assertLess(command.index("-no_init"), command.index("-f"))

    def test_ab_stage_requires_db_but_not_local_dc_setup(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp) / "Nangate45.db"
            database.write_bytes(b"test-db")
            environment = {
                "RDTC_BOUNDED_DC_AB": "y",
                "RDTC_STDCELL_DB": str(database),
                "RDTC_DC_SETUP": "",
            }
            AB.flowctl.require_local_setup("dc-baseline", environment)
            database.unlink()
            with self.assertRaisesRegex(RuntimeError, "requires RDTC_STDCELL_DB"):
                AB.flowctl.require_local_setup("dc-baseline", environment)

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

    def test_hierarchy_parser_records_top_area(self):
        report = """mrtc_rdtc_ddr_multiengine_wrapper
                                      168.7500  100.0  1.0
u_engine.u_engine                     40.0000   23.7  1.0
"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "area_hier.rpt"
            path.write_text(report, encoding="utf-8")
            parsed = AB.parse_hierarchy_area(
                path, AB.flowctl.BOUNDED_BUFFERED_TOP
            )
        self.assertEqual(168.75, parsed["top_area_um2"])
        self.assertEqual(40.0, parsed["engine_area_um2"])

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
                "clock_period_library_units": "3.174603",
                "sdc_time_scale": "1.0",
            },
            "area": {"tool_version": AB.EXPECTED_DC_VERSION, "macro_count": 0},
        }
        self.assertEqual((True, []), AB.gate_run(self.bind_run_integrity(run), point))

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
                "clock_period_library_units": "3.174603",
                "sdc_time_scale": "1.0",
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
            ("clock_period_library_units", "nan"),
            ("sdc_time_scale", "nan"),
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
                "clock_period_library_units": "3.174603",
                "sdc_time_scale": "1.0",
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

    def test_gate_rejects_scaled_library_clock(self):
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
                "documented_clock_period_ns": "3.174603",
                "clock_period_library_units": "3174.603",
                "sdc_time_scale": "1000.0",
            },
            "area": {"tool_version": AB.EXPECTED_DC_VERSION, "macro_count": 0},
        }
        passed, failures = AB.gate_run(run, point)
        self.assertFalse(passed)
        self.assertTrue(any("library-unit clock period" in item for item in failures))
        self.assertTrue(any("SDC time scale" in item for item in failures))

    def test_gate_accepts_sub_microsecond_report_rounding(self):
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
                "documented_clock_period_ns": "3.1746034",
                "clock_period_library_units": "3.1746026",
                "sdc_time_scale": "1.0",
            },
            "area": {"tool_version": AB.EXPECTED_DC_VERSION, "macro_count": 0},
        }
        self.assertEqual((True, []), AB.gate_run(self.bind_run_integrity(run), point))

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

    def test_bound_input_manifest_rejects_newer_checkout_inputs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            orchestration = root / "orchestration"
            inputs = {"source": {"source_head": "old"}, "filelist": {}}
            record = AB.write_input_manifest(root, orchestration, inputs)
            execution = {
                "input_manifest": record,
                "input_manifest_sha256": record["sha256"],
                "runs": [],
            }
            bound, checked = AB.validate_bound_inputs(
                root, orchestration, inputs, execution
            )
            self.assertEqual(inputs, bound)
            self.assertEqual(record, checked)
            with self.assertRaisesRegex(RuntimeError, "as-run manifest"):
                AB.validate_bound_inputs(
                    root,
                    orchestration,
                    {"source": {"source_head": "new"}, "filelist": {}},
                    execution,
                )

    def test_comparison_inputs_pin_sdc_and_exclude_local_setup(self):
        inputs = AB.comparison_inputs(ROOT, {"source_head": "test"})
        self.assertEqual(AB.EXPECTED_SDC_SHA256, inputs["sdc"]["sha256"])
        self.assertEqual(
            AB.EXPECTED_SOURCE_SET_SHA256,
            inputs["expected_source_set_sha256"],
        )
        self.assertNotIn("dc_setup", inputs)

    def test_source_identity_rejects_changed_ordered_filelist_membership(self):
        entries = AB.filelist_sources(ROOT)
        with mock.patch.object(AB, "filelist_sources", return_value=entries[::-1]):
            with self.assertRaisesRegex(RuntimeError, "ordered source set"):
                AB.source_identity(ROOT)

    def test_comparison_inputs_rejects_changed_sdc(self):
        real_file_record = AB.file_record

        def changed_sdc_record(root, path):
            record = real_file_record(root, path)
            if Path(path).resolve() == (ROOT / AB.COMMON_SDC).resolve():
                record["sha256"] = "0" * 64
            return record

        with mock.patch.object(AB, "file_record", side_effect=changed_sdc_record):
            with self.assertRaisesRegex(RuntimeError, "SDC differs"):
                AB.comparison_inputs(ROOT, {"source_head": "test"})

    def test_collect_run_rejects_truncated_area_report(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            dc_root = root / "dc"
            dc_root.mkdir()
            reports = {
                name: dc_root / filename
                for name, filename in AB.REQUIRED_REPORTS.items()
            }
            reports["closure"].write_text("status=PASS\n", encoding="utf-8")
            reports["contract"].write_text("status=PASS\n", encoding="utf-8")
            reports["area"].write_text(
                "Version: {}\nNumber of cells: 100\n".format(
                    AB.EXPECTED_DC_VERSION
                ),
                encoding="utf-8",
            )
            reports["hierarchy"].write_text("truncated\n", encoding="utf-8")
            reports["timing"].write_text("timing\n", encoding="utf-8")
            with mock.patch.object(
                AB, "run_paths", return_value=(root / "build", dc_root)
            ), mock.patch.object(
                AB, "required_report_paths", return_value=reports
            ):
                run = AB.collect_run(
                    root, AB.POINTS[0], {}, MANIFEST_SHA256
                )
            self.assertEqual("REJECTED", run["status"])
            self.assertFalse(AB.gate_run(run, AB.POINTS[0])[0])

    def test_gate_requires_exactly_one_design_rule_repair(self):
        point = AB.POINTS[0]
        for report in ("closure", "contract"):
            run = self.bind_run_integrity(
                {
                    "status": "PASS",
                    "closure": {},
                    "contract": {},
                    "area": {
                        "tool_version": AB.EXPECTED_DC_VERSION,
                        "macro_count": 0,
                    },
                }
            )
            run[report]["bounded_design_rule_repair_passes"] = "0"
            with self.subTest(report=report):
                passed, failures = AB.gate_run(run, point)
                self.assertFalse(passed)
                self.assertTrue(
                    any("repair" in failure for failure in failures)
                )

    def test_validate_live_inputs_rechecks_bound_source_sdc_and_db(self):
        with tempfile.TemporaryDirectory() as temp:
            orchestration = Path(temp) / "orchestration"
            database = Path(temp) / "Nangate45.db"
            database.write_bytes(b"test-db")
            identity = {"tracked_worktree_clean": True, "source_head": "test"}
            inputs = {"source": identity, "sdc": {"sha256": "test"}}
            manifest = AB.write_input_manifest(ROOT, orchestration, inputs)
            execution = {
                "input_manifest": manifest,
                "input_manifest_sha256": manifest["sha256"],
                "runs": [],
            }
            real_sha256 = AB.sha256_file

            def hash_file(path):
                if Path(path) == database:
                    return AB.EXPECTED_DB_SHA256
                return real_sha256(path)

            with mock.patch.object(
                AB, "source_identity", return_value=identity
            ), mock.patch.object(
                AB, "comparison_inputs", return_value=inputs
            ), mock.patch.object(AB, "sha256_file", side_effect=hash_file):
                bound, checked = AB.validate_live_inputs(
                    ROOT, orchestration, database, execution
                )
            self.assertEqual(inputs, bound)
            self.assertEqual(manifest, checked)

    def test_run_all_rechecks_live_inputs_before_and_after_each_child(self):
        class FinishedProcess(object):
            pid = 12345

            @staticmethod
            def wait():
                return 0

        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp)
            orchestration = temp_root / "orchestration"
            database = temp_root / "Nangate45.db"
            database.write_bytes(b"test-db")
            args = SimpleNamespace(
                root=ROOT,
                orchestration_root=orchestration,
                stdcell_db=database,
                point=["buffered315"],
                resume=False,
                dc_tool="dc_shell",
                output=temp_root / "summary.json",
                markdown_output=temp_root / "summary.md",
            )
            input_manifest = {
                "path": "input_manifest.json",
                "bytes": 1,
                "sha256": MANIFEST_SHA256,
            }
            summary = {
                "status": "PASS_DC_ONLY",
                "execution_status": "COMPLETE",
            }
            with mock.patch.object(
                AB,
                "source_identity",
                return_value={"tracked_worktree_clean": True},
            ), mock.patch.object(
                AB, "comparison_inputs", return_value={"source": {}}
            ), mock.patch.object(
                AB, "sha256_file", return_value=AB.EXPECTED_DB_SHA256
            ), mock.patch.object(
                AB, "preflight_new_run_outputs"
            ), mock.patch.object(
                AB, "write_input_manifest", return_value=input_manifest
            ), mock.patch.object(
                AB, "validate_live_inputs", return_value=({}, input_manifest)
            ) as live_inputs, mock.patch.object(
                AB, "run_paths", return_value=(temp_root / "build", temp_root / "dc")
            ), mock.patch.object(
                AB.subprocess, "Popen", return_value=FinishedProcess()
            ), mock.patch.object(
                AB, "available_report_hashes", return_value={}
            ), mock.patch.object(
                AB, "collect", return_value=summary
            ), mock.patch.object(
                AB, "write_json"
            ), mock.patch.object(
                AB, "write_markdown"
            ):
                self.assertEqual(0, AB.run_all(args))
            self.assertEqual(2, live_inputs.call_count)

    def test_gate_binds_area_hierarchy_and_report_hashes(self):
        point = AB.POINTS[0]
        run = self.bind_run_integrity(
            {
                "status": "PASS",
                "closure": {},
                "contract": {},
                "area": {
                    "tool_version": AB.EXPECTED_DC_VERSION,
                    "macro_count": 0,
                },
            }
        )
        run["contract"]["total_cell_count"] = "101"
        run["hierarchy_area"]["top_area_um2"] = 170.0
        run["execution_report_sha256"]["area"] = "f" * 64
        _, failures = AB.gate_run(run, point)
        self.assertIn("area report cell count differs from run contract", failures)
        self.assertIn("hierarchy top area differs from total cell area", failures)
        self.assertIn(
            "collected report hashes differ from execution metadata", failures
        )

    def test_markdown_renders_invalid_wns_as_na(self):
        runs = {
            point["key"]: {"status": "INCOMPLETE"} for point in AB.POINTS
        }
        bad_run = self.bind_run_integrity(
            {
                "status": "PASS",
                "closure": {"setup_wns": "truncated"},
                "contract": {},
                "area": {
                    "tool_version": AB.EXPECTED_DC_VERSION,
                    "macro_count": 0,
                },
            }
        )
        runs[AB.POINTS[0]["key"]] = bad_run
        summary = {
            "status": "NOT_RESUME_READY",
            "runs": runs,
            "gates": {
                point["key"]: {"pass": False, "failures": ["test"]}
                for point in AB.POINTS
            },
            "dc315_comparison": None,
            "limitations": [],
        }
        markdown = AB.render_markdown(summary)
        self.assertIn("| buffered315 | n/a |", markdown)

    def test_markdown_writer_creates_missing_parent_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "new" / "reports" / "summary.md"
            with mock.patch.object(AB, "render_markdown", return_value="report\n"):
                AB.write_markdown(output, {})
            self.assertEqual("report\n", output.read_text(encoding="utf-8"))

    def test_execution_status_comes_from_all_final_gates(self):
        summary = {
            "gates": {
                point["key"]: {"pass": True, "failures": []}
                for point in AB.POINTS
            }
        }
        self.assertEqual("COMPLETE", AB.final_execution_status(summary))
        summary["gates"]["buffered630"]["pass"] = False
        self.assertEqual(
            "COMPLETE_WITH_STRESS_FAILURE", AB.final_execution_status(summary)
        )
        summary["gates"]["buffered315"]["pass"] = False
        self.assertEqual("FAILED_GATES", AB.final_execution_status(summary))

    def test_legacy_contract_does_not_claim_unmeasured_ab_audits(self):
        tcl = (ROOT / AB.RUN_TCL).read_text(encoding="utf-8")
        marker = 'if {$bounded_dc_ab} {\n    echo "constraint_violating_checks='
        self.assertIn(marker, tcl)

    def test_resume_skips_only_an_existing_gate_pass(self):
        point = AB.POINTS[0]
        execution = {point["key"]: {"returncode": 0}}
        with mock.patch.object(AB, "collect_run", return_value={"status": "PASS"}), mock.patch.object(
            AB, "gate_run", return_value=(False, ["failed closure"])
        ):
            self.assertFalse(
                AB.existing_run_passes(ROOT, point, execution, MANIFEST_SHA256)
            )
        with mock.patch.object(AB, "collect_run", return_value={"status": "PASS"}), mock.patch.object(
            AB, "gate_run", return_value=(True, [])
        ):
            self.assertTrue(
                AB.existing_run_passes(ROOT, point, execution, MANIFEST_SHA256)
            )

    def test_resume_never_reuses_input_drift_artifacts(self):
        point = AB.POINTS[0]
        execution = {
            point["key"]: {
                "returncode": 0,
                "status": "REJECTED_INPUT_DRIFT",
            }
        }
        with mock.patch.object(AB, "collect_run") as collect_run:
            self.assertFalse(
                AB.existing_run_passes(
                    ROOT, point, execution, MANIFEST_SHA256
                )
            )
        collect_run.assert_not_called()

    def test_resume_archives_and_invalidates_failed_closure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            closure = root / "build" / "dc_closure_summary.txt"
            closure.parent.mkdir(parents=True)
            closure.write_text("status=FAIL\n", encoding="utf-8")
            archive = AB.archive_retry_closure(root / "orchestration", AB.POINTS[0], closure)
            self.assertFalse(closure.exists())
            self.assertTrue(archive.is_file())
            self.assertEqual("status=FAIL\n", archive.read_text(encoding="utf-8"))

    def test_new_run_preflight_preserves_existing_execution_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            orchestration = root / "orchestration"
            orchestration.mkdir()
            execution_path = orchestration / "execution.json"
            sentinel = '{"status":"COMPLETE","runs":[{"key":"buffered315"}]}\n'
            execution_path.write_text(sentinel, encoding="utf-8")
            args = SimpleNamespace(
                root=root,
                orchestration_root=orchestration,
                stdcell_db=root / "Nangate45.db",
                point=["buffered315"],
                resume=False,
                dc_tool="dc_shell",
                output=root / "summary.json",
                markdown_output=root / "summary.md",
            )
            with mock.patch.object(
                AB,
                "source_identity",
                return_value={"tracked_worktree_clean": True},
            ), mock.patch.object(AB, "comparison_inputs"), mock.patch.object(
                AB, "sha256_file", return_value=AB.EXPECTED_DB_SHA256
            ), mock.patch.object(AB, "write_json") as write_json:
                with self.assertRaisesRegex(RuntimeError, "refusing to overwrite"):
                    AB.run_all(args)
            write_json.assert_not_called()
            self.assertEqual(sentinel, execution_path.read_text(encoding="utf-8"))

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
            "RDTC_DC_AB_INPUT_MANIFEST_SHA256",
            "input_manifest_sha256",
            "inline_hash_bound_register",
            "if {!$bounded_dc_ab} {\n  source $dc_setup",
            "bounded_register_storage_bits",
            "retiming_control=tracked_compile_ultra_without_retime",
        ):
            self.assertIn(marker, tcl)
        self.assertIn("bounded-dc-ab-run:", makefile)
        self.assertIn(
            "ifeq ($(strip $(CONFIG_FLOW_BOUNDED_ASIC_REGISTER_EXPANDED)),y)",
            makefile,
        )
        self.assertNotIn(
            "ifneq ($(strip $(CONFIG_FLOW_BOUNDED_ASIC_REGISTER_EXPANDED)),)",
            makefile,
        )
        self.assertIn("config FLOW_BOUNDED_ASIC_REGISTER_EXPANDED", kconfig)

    def test_runner_has_no_private_host_or_path_literals(self):
        text = (SCRIPT_DIR / "bounded_buffered_direct_dc_ab.py").read_text(
            encoding="utf-8"
        )
        for forbidden in ("private_host", "private_worktree", "license_server"):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
