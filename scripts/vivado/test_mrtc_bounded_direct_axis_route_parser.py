from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile


SCRIPT_DIR = Path(__file__).resolve().parent
MODULE_PATH = SCRIPT_DIR / "mrtc_bounded_direct_axis_route_parser.py"
SPEC = importlib.util.spec_from_file_location("bounded_direct_axis_route", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class ParserTests(unittest.TestCase):
    def test_parses_abbreviated_high_fanout_identity(self) -> None:
        text = """| Tool Version : Vivado v.2022.2 (win64) Build 3671981
| Design       : mrtc_rdtc_bounded_axis_multiengine_wrapper
| Device       : xc7z100
"""
        self.assertEqual(
            gate.parse_abbreviated_report_identity(text),
            {
                "vivado_version_short": "2022.2",
                "top": gate.TOP,
                "part": gate.PART,
            },
        )

    def test_rejects_wrong_abbreviated_high_fanout_device(self) -> None:
        text = """| Tool Version : Vivado v.2022.2 (win64) Build 3671981
| Design       : mrtc_rdtc_bounded_axis_multiengine_wrapper
| Device       : xc7z045
"""
        with self.assertRaisesRegex(gate.GateError, "identity is unexpected"):
            gate.parse_abbreviated_report_identity(text)

    def test_parse_setup_and_pulse_summary(self) -> None:
        text = """
    WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints
      0.471   0.000                     0                5000    1.858    0.000                      0                 4000
"""
        self.assertEqual(
            (0.471, 0.0, 0, 1.858, 0.0, 0),
            gate.parse_setup_pulse_summary(text),
        )

    def test_timing_check_gate_rejects_critical_findings(self) -> None:
        def report(overrides: dict[str, int] | None = None) -> str:
            values = {name: 0 for name in gate.REQUIRED_ZERO_TIMING_CHECKS}
            values.update({"no_input_delay": 10, "no_output_delay": 12})
            values.update(overrides or {})
            return "\n".join(
                f"{index}. checking {name} ({count})"
                for index, (name, count) in enumerate(values.items(), start=1)
            )

        parsed = gate.parse_timing_check_gate(report())
        self.assertEqual(10, parsed["no_input_delay"])
        with self.assertRaises(gate.GateError):
            gate.parse_timing_check_gate(report({"pulse_width_clock": 1}))

    def test_parse_hold_summary(self) -> None:
        text = """
    WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints
    -------      -------  ---------------------  -------------------
      0.076        0.000                      0                12000
"""
        self.assertEqual((0.076, 0.0, 0), gate.parse_hold_summary(text))

    def test_parse_route_errors(self) -> None:
        text = "# of nets with routing errors.......... :           0 :\n"
        self.assertEqual(0, gate.parse_route_errors(text))

    def test_parse_utilization_label_variants(self) -> None:
        template = """
| Slice LUTs{suffix} | 35000 | 0 | 0 | 277400 | 12.6 |
| Slice Registers | 25000 | 0 | 0 | 554800 | 4.5 |
| Slice Registers | 25000 | 0 | 0 | 554800 | 4.5 |
| Register as Latch | 0 | 0 | 0 | 554800 | 0.00 |
| LUT as Memory | 1024 | 0 | 0 | 108200 | 0.95 |
| LUT as Memory | 1024 | 0 | 0 | 108200 | 0.95 |
| RAMB18 | 0 | 0 | 0 | 1510 | 0.00 |
| RAMB36/FIFO* | 0 | 0 | 0 | 755 | 0.00 |
"""
        for suffix in ("", "*"):
            with self.subTest(suffix=suffix):
                parsed = gate.parse_utilization(template.format(suffix=suffix))
                self.assertEqual(35000, parsed["slice_luts"])
                self.assertEqual(0, parsed["ramb36"])

    def test_methodology_allowlist(self) -> None:
        text = """
| TIMING-18 | Warning | Missing input or output delay | 320 |
| SYNTH-6 | Warning | BRAM output register | 4 |
"""
        self.assertEqual(
            {"TIMING-18", "SYNTH-6"}, set(gate.parse_methodology_summary(text))
        )
        with self.assertRaises(gate.GateError):
            gate.parse_methodology_summary(
                text + "| LUTAR-1 | Warning | LUT equation | 1 |\n"
            )

    def test_old_feedback_path_detection_is_path_local(self) -> None:
        bad = """
Slack (VIOLATED) : -1.000ns
  Source: g_engine[0].u_engine/packet_abort_reg/Q
  Destination: g_engine[0].u_engine/u_bpack/p0_valid_reg/D
"""
        good = """
Slack (MET) : 0.100ns
  Source: g_engine[0].u_pktbuf/reserve_reg/Q
  Destination: g_engine[0].u_pktbuf/occupancy_reg/D
Slack (MET) : 0.200ns
  Source: g_engine[0].u_engine/u_bpack/p2_pair_len_reg/Q
  Destination: g_engine[0].u_engine/u_bpack/p3a_token_len_reg/D
"""
        self.assertEqual(1, len(gate.old_feedback_paths(bad)))
        self.assertEqual([], gate.old_feedback_paths(good))

    def test_removed_storage_path_detection_is_path_local(self) -> None:
        removed = """
Slack (MET) : 0.100ns
  Source: g_engine[0].u_feeder/count_reg/Q
  Destination: g_engine[0].u_engine/u_way_ring/mem/WE
"""
        direct = """
Slack (MET) : 0.200ns
  Source: g_engine[0].u_engine/u_bpack/p2_pair_len_reg/Q
  Destination: u_output_fifo/count_reg/D
"""
        self.assertEqual(1, len(gate.forbidden_removed_storage_paths(removed)))
        self.assertEqual([], gate.forbidden_removed_storage_paths(direct))

    def test_all_setup_endpoint_parser_classifies_complete_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "all_setup_violations.tsv"
            path.write_text(
                "slack_ns\tstartpoint\tendpoint\n"
                "-0.200\twrapper/input_count_reg/C\t"
                "g_engine[0].u_engine/u_way_ring/mem/WE\n"
                "-0.100\tg_engine[1].u_engine/packet_valid_reg/C\t"
                "u_output_fifo/data_mem_reg/CE\n",
                encoding="utf-8",
            )
            parsed = gate.parse_all_setup_violations(path)
            self.assertEqual(2, parsed["count"])
            self.assertEqual(-0.2, parsed["worst_slack_ns"])
            self.assertEqual(
                {"engine_to_output_fifo": 1, "wrapper_to_engine": 1},
                parsed["classification"],
            )

    def test_all_setup_endpoint_parser_rejects_duplicate_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "all_setup_violations.tsv"
            path.write_text(
                "slack_ns\tstartpoint\tendpoint\n"
                "-0.200\ta/C\tb/D\n"
                "-0.100\tc/C\tb/D\n",
                encoding="utf-8",
            )
            with self.assertRaises(gate.GateError):
                gate.parse_all_setup_violations(path)

    def test_dcp_identity_requires_routed_top(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "post_route.dcp"
            xml = f"""<?xml version="1.0"?>
<Checkpoint>
  <PRODUCT Name="Vivado v2022.2 (64-bit)"/>
  <Part Name="{gate.PART}"/>
  <Top Name="{gate.TOP}"/>
  <OutOfContext Name="1"/>
</Checkpoint>
"""
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("dcp.xml", xml)
                archive.writestr(f"{gate.TOP}.rdb", b"route")
            self.assertEqual(gate.TOP, gate.audit_dcp_identity(path)["top"])

    def test_artifact_manifest_detects_mixed_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            build_dir = Path(tmp)
            (build_dir / "input_identity.json").write_text("{}\n", encoding="ascii")
            for name in gate.RUN_BOUND_ARTIFACTS:
                (build_dir / name).write_text(f"{name}\n", encoding="ascii")
            gate.write_artifact_manifest(build_dir)
            gate.audit_artifact_manifest(build_dir)
            (build_dir / "route_status.rpt").write_text("mixed\n", encoding="ascii")
            with self.assertRaises(gate.GateError):
                gate.audit_artifact_manifest(build_dir)


class StaticContractTests(unittest.TestCase):
    def test_tcl_fixes_wrapper_identity_and_routes_once(self) -> None:
        text = (SCRIPT_DIR / f"{gate.FLOW_NAME}.tcl").read_text(encoding="utf-8")
        self.assertIn(f"set schema {gate.SCHEMA}", text)
        for token in (
            "AXIS_DATA_W=128",
            "NUM_ENGINES=2",
            "ENGINE_BOUNDED_WAY_COUNT=4",
            "PREFIX_SAMPLES=128",
            "OUTPUT_FIFO_DEPTH=16",
            "MRTC_DIRECT_TARGET_MHZ",
            "MRTC_DIRECT_CLOCK_PERIOD_NS",
            "set_property HD.CLK_SRC BUFGCTRL_X0Y0",
            "get_property HD.CLK_SRC",
            "place_design -directive Explore",
            "phys_opt_design -directive AggressiveExplore",
            "write_checkpoint -force",
            "report_timing_summary -delay_type min",
            "report_methodology",
            "report_route_status",
            "post_synth_timing_summary.rpt",
            "post_place_timing_summary.rpt",
            "post_route_high_fanout.rpt",
            "write_negative_setup_endpoints",
        ):
            self.assertIn(token, text)
        self.assertEqual(1, text.count("route_design -directive Explore"))
        self.assertNotIn("route_design -unroute", text)
        self.assertNotIn("-retiming", text)
        self.assertNotIn("ENGINE_BOUNDED_PAYLOAD_DEPTH", text)
        self.assertNotIn("mrtc_rdtc_ddr_multiengine_wrapper", text)

    def test_vivado_runs_inside_ignored_build_workspace(self) -> None:
        text = (SCRIPT_DIR / "mrtc_bounded_direct_axis_route_parser.py").read_text(
            encoding="utf-8"
        )
        self.assertIn('"tight_setup_hold_pins.txt"', text)
        self.assertIn("cwd=build_dir", text)
        self.assertNotIn("cwd=repo_root", text)

    def test_target_configuration_is_exact(self) -> None:
        gate.configure_target(200)

    def test_xdc_periods_are_exact(self) -> None:
        for target_mhz, period in ((200, "5.000"), (250, "4.000")):
            xdc = (SCRIPT_DIR / f"{gate.FLOW_NAME}_{target_mhz}m.xdc").read_text(
                encoding="utf-8"
            )
            self.assertEqual(
                f"create_clock -name clk -period {period} [get_ports clk]\n",
                xdc,
            )
        self.assertEqual("5.000", gate.CLOCK_PERIOD_NS)
        self.assertEqual("mrtc_bounded_direct_axis_route_200m", gate.NAME)
        gate.configure_target(250)
        self.assertEqual("4.000", gate.CLOCK_PERIOD_NS)
        self.assertEqual("mrtc_bounded_direct_axis_route_250m", gate.NAME)
        gate.configure_target(200)

    def test_identity_closes_over_nonempty_filelist(self) -> None:
        identity = gate.current_identity(gate.repo_root_from_script())
        self.assertEqual(gate.TOP, identity["top"])
        self.assertGreater(len(identity["inputs"]), 50)
        self.assertEqual(16, identity["generics"]["OUTPUT_FIFO_DEPTH"])
        self.assertNotIn("ENGINE_BOUNDED_PAYLOAD_DEPTH", identity["generics"])


if __name__ == "__main__":
    unittest.main()
