import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("bounded_direct_modelsim_regression.py")
SOURCE_ROOT = SCRIPT.parents[2]
FILELIST = SOURCE_ROOT / "flows/manifests/rdtc_v1_bounded_direct.f"
TESTBENCH = SOURCE_ROOT / "tb/sv/tb_mrtc_bounded_axis_multiengine_wrapper.sv"
MAKEFILE = SOURCE_ROOT / "Makefile"
SPEC = importlib.util.spec_from_file_location(
    "bounded_direct_modelsim_regression", SCRIPT
)
REGRESSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REGRESSION)


def write_candidate(root):
    root = Path(root)
    views = root / "views"
    views.mkdir(parents=True)
    model = views / (REGRESSION.MACRO + ".v")
    model.write_text(
        "// OpenRAM SRAM model\n"
        "module {}(clk0,csb0,web0,addr0,din0,dout0);\n"
        "  parameter DATA_WIDTH = 128;\n"
        "  parameter ADDR_WIDTH = 5;\n"
        "  parameter DELAY = 3;\n"
        "  input clk0, csb0, web0;\n"
        "  input [ADDR_WIDTH-1:0] addr0;\n"
        "  input [DATA_WIDTH-1:0] din0;\n"
        "  output [DATA_WIDTH-1:0] dout0;\n"
        "  reg [DATA_WIDTH-1:0] mem [0:31];\n"
        "  reg csb0_reg, web0_reg;\n"
        "  reg [ADDR_WIDTH-1:0] addr0_reg;\n"
        "  reg [DATA_WIDTH-1:0] din0_reg;\n"
        "  reg [DATA_WIDTH-1:0] dout0;\n"
        "  always @(posedge clk0) begin\n"
        "    csb0_reg = csb0; web0_reg = web0;\n"
        "    addr0_reg = addr0; din0_reg = din0;\n"
        "  end\n"
        "  always @(negedge clk0) begin\n"
        "    if (!csb0_reg && !web0_reg) mem[addr0_reg] = din0_reg;\n"
        "  end\n"
        "  always @(negedge clk0) begin\n"
        "    if (!csb0_reg && web0_reg) dout0 <= #(DELAY) mem[addr0_reg];\n"
        "  end\n"
        "endmodule\n".format(REGRESSION.MACRO),
        encoding="ascii",
    )
    view_paths = {
        "verilog": model,
        "liberty": views / (REGRESSION.MACRO + ".lib"),
        "lef": views / (REGRESSION.MACRO + ".lef"),
        "gds": views / (REGRESSION.MACRO + ".gds"),
        "spice": views / (REGRESSION.MACRO + ".sp"),
    }
    for role, path in view_paths.items():
        if role != "verilog":
            path.write_bytes((role + "-view\n").encode("ascii"))

    contract = {
        "schema_version": 2,
        "candidate_id": "ring-32x128-wpr4",
        "macro": REGRESSION.MACRO,
        "role": REGRESSION.ROLE,
        "organization": {
            "address_width": 5,
            "columns": 512,
            "num_words": 32,
            "rows": 8,
            "word_size": 128,
            "words_per_row": 4,
        },
        "ports": {
            "num_rw_ports": 1,
            "num_r_ports": 0,
            "num_w_ports": 0,
            "clock_pins": ["clk0"],
            "read_control": {"csb0": 0, "web0": 1},
            "write_control": {"csb0": 0, "web0": 0},
            "signal_pins": [
                "clk0",
                "csb0",
                "web0",
                "addr0",
                "din0",
                "dout0",
            ],
        },
        "delay_chain": {"stages": 21, "fanout_per_stage": 4},
        "technology": {
            "name": "freepdk45",
            "process": "TT",
            "voltage_v": 1.1,
            "temperature_c": 25,
            "openram_commit": REGRESSION.OPENRAM_COMMIT,
        },
    }
    contract_sha256 = REGRESSION.canonical_sha256(contract)
    contract["candidate_contract_sha256"] = contract_sha256
    manifest = {
        "schema_version": 2,
        "status": "generated_and_audited",
        "maturity": "fully_characterized_candidate",
        "phase": "full",
        "candidate_contract": contract,
        "candidate_contract_sha256": contract_sha256,
        "database": {"status": "not_compiled", "allowed": True},
        "model_gate": {
            "bounded_ring_allowed": True,
            "supports_300mhz": True,
            "supports_600mhz": True,
            "candidate_tgov_ns": 1.2,
            "maximum_high_pulse_ns": 0.6,
            "maximum_low_pulse_ns": 0.6,
        },
        "spice_functional_gate": {
            "status": "pass",
            "required_operations": list(REGRESSION.OPERATIONS),
            "operations": {name: "pass" for name in REGRESSION.OPERATIONS},
        },
        "ngspice_guard_audit": {"status": "pass"},
        "audit": {
            "verilog_signal_widths": {
                "addr0": 5,
                "clk0": 1,
                "csb0": 1,
                "din0": 128,
                "dout0": 128,
                "web0": 1,
            }
        },
        "files": {
            role: {
                "path": path.relative_to(root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": REGRESSION.sha256_file(path),
            }
            for role, path in view_paths.items()
        },
    }
    manifest_path = root / "candidate_manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return {
        "root": root,
        "model": model,
        "manifest": manifest,
        "manifest_path": manifest_path,
        "manifest_sha256": REGRESSION.sha256_file(manifest_path),
    }


def rewrite_manifest(candidate, manifest):
    candidate["manifest_path"].write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return REGRESSION.sha256_file(candidate["manifest_path"])


def packet_data(selected_k, packet, beat):
    value = (packet + 1) << 120
    value |= (beat + 1) << 8
    if beat == 1:
        value |= selected_k << (11 * 8)
    return "{:032x}".format(value)


def cycle_trace_marker(cycle, **overrides):
    row = {name: 0 for name in REGRESSION.CYCLE_FIELDS}
    row.update(
        {
            "cycle": cycle,
            "input_owner": -1,
            "input_block": -1,
            "e0_k": -1,
            "e0_ring_wr_addr": -1,
            "e0_ring_wr_block": -1,
            "e0_ring_rd_req_addr": -1,
            "e0_ring_rd_req_block": -1,
            "e0_ring_rd_rsp_addr": -1,
            "e0_ring_rd_rsp_block": -1,
            "e0_block": -1,
            "e1_k": -1,
            "e1_ring_wr_addr": -1,
            "e1_ring_wr_block": -1,
            "e1_ring_rd_req_addr": -1,
            "e1_ring_rd_req_block": -1,
            "e1_ring_rd_rsp_addr": -1,
            "e1_ring_rd_rsp_block": -1,
            "e1_block": -1,
            "m_tdata": "0" * 32,
            "m_tuser": "00",
            "output_owner": -1,
            "output_block": -1,
        }
    )
    row.update(overrides)
    return REGRESSION.CYCLE_PREFIX + " ".join(
        "{}={}".format(name, row[name]) for name in REGRESSION.CYCLE_FIELDS
    )


def cycle_trace_lines(cycle_shift=0, short_backpressure=False):
    base = 20 + cycle_shift
    if not short_backpressure:
        return [
            cycle_trace_marker(base),
            cycle_trace_marker(
                base + 1,
                m_tvalid=1,
                m_tready=1,
                m_tdata="1" * 32,
                m_tuser="0f",
                output_owner=0,
                output_block=0,
            ),
            cycle_trace_marker(base + 2),
        ]
    header = {
        "m_tvalid": 1,
        "m_tready": 0,
        "m_tdata": "2" * 32,
        "m_tuser": "0f",
        "output_owner": 0,
        "output_block": 0,
    }
    payload = {
        "m_tvalid": 1,
        "m_tready": 0,
        "m_tdata": "3" * 32,
        "m_tuser": "0f",
        "output_owner": 0,
        "output_block": 0,
    }
    return [
        cycle_trace_marker(base, **header),
        cycle_trace_marker(base + 1, **header),
        cycle_trace_marker(base + 2, **dict(header, m_tready=1)),
        cycle_trace_marker(base + 3),
        cycle_trace_marker(base + 4, **payload),
        cycle_trace_marker(base + 5, **payload),
        cycle_trace_marker(base + 6, **dict(payload, m_tready=1)),
        cycle_trace_marker(base + 7),
    ]


def valid_trace_log(cycle_shift=0, payload_xor=0, short_backpressure=False):
    lines = []
    lines.extend(cycle_trace_lines(cycle_shift, short_backpressure))
    for engine in range(2):
        base = 1000 + cycle_shift + (engine * 500)
        for address in range(REGRESSION.BLOCK_WORDS):
            lines.append(
                "DIRECT_AXIS_PROFILE_MEMORY kind=req cycle={} engine={} addr={}".format(
                    base + address, engine, address
                )
            )
        for address in range(REGRESSION.BLOCK_WORDS):
            lines.append(
                "DIRECT_AXIS_PROFILE_MEMORY kind=rsp cycle={} engine={} addr={}".format(
                    base + address + REGRESSION.READ_LATENCY_CYCLES,
                    engine,
                    address,
                )
            )
    for packet, selected_k in enumerate((0, 3)):
        for beat in range(4):
            data = int(packet_data(selected_k, packet, beat), 16)
            if packet == 1 and beat == 2:
                data ^= payload_xor
            final = beat == 3
            lines.append(
                "DIRECT_AXIS_PROFILE_BEAT packet={} beat={} data={:032x} user={} last={}".format(
                    packet, beat, data, "03" if final else "0f", int(final)
                )
            )
        lines.append(
            "DIRECT_AXIS_PACKET_DONE cycle={} packet={} beats=4 fifo=1".format(
                5000 + cycle_shift + packet, packet
            )
        )
        lines.append(
            "DIRECT_AXIS_PROFILE_PACKET packet={} selected_k={} expected_k={} beats=4".format(
                packet, selected_k, selected_k
            )
        )
    if short_backpressure:
        lines.extend(
            (
                "DIRECT_AXIS_TRACE_BP kind=header cycle={} packet=0 beat=1 stall_cycles=2".format(
                    20 + cycle_shift
                ),
                "DIRECT_AXIS_TRACE_BP kind=payload cycle={} packet=0 beat=4 stall_cycles=2".format(
                    24 + cycle_shift
                ),
            )
        )
    lines.append(
        "DIRECT_AXIS_STREAM blocks=2 bp={} cycles=700 cycles_per_block=350.000 "
        "fifo_max=2 hold_checks={} k_cycle=39/39 first_read=47/47".format(
            int(short_backpressure), 4 if short_backpressure else 0
        )
    )
    lines.append("DIRECT_AXIS_PROFILE_DECODER bit_exact=1 blocks=2 words=512")
    lines.append(
        "PASS tb_mrtc_bounded_axis_multiengine_wrapper blocks=2 bp={}".format(
            int(short_backpressure)
        )
    )
    return "\n".join(lines) + "\n"


class BoundedDirectModelsimRegressionTests(unittest.TestCase):
    def test_full_candidate_and_behavioral_model_are_admitted(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            result = REGRESSION.admit_sram_candidate(
                candidate["model"],
                candidate["manifest_path"],
                candidate["manifest_sha256"],
            )
        self.assertEqual(result["candidate_id"], "ring-32x128-wpr4")
        self.assertEqual(result["model_delay_ns"], 3.0)
        self.assertEqual(result["model_sha256"], candidate["manifest"]["files"]["verilog"]["sha256"])

    def test_candidate_is_admitted_by_explicit_target_period(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            manifest = copy.deepcopy(candidate["manifest"])
            manifest["model_gate"].update(
                {
                    "supports_600mhz": False,
                    "candidate_tgov_ns": 2.656,
                    "maximum_high_pulse_ns": 1.328,
                    "maximum_low_pulse_ns": 1.328,
                }
            )
            manifest_sha256 = rewrite_manifest(candidate, manifest)
            admitted = REGRESSION.admit_sram_candidate(
                candidate["model"],
                candidate["manifest_path"],
                manifest_sha256,
                3.333333,
            )
            self.assertEqual(admitted["timing"]["target_period_ns"], 3.333333)
            with self.assertRaisesRegex(RuntimeError, "target period 1.666667 ns"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"],
                    candidate["manifest_path"],
                    manifest_sha256,
                    1.666667,
                )

    def test_manifest_hash_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            with self.assertRaisesRegex(RuntimeError, "manifest SHA256 mismatch"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"],
                    candidate["manifest_path"],
                    "0" * 64,
                )

    def test_analytical_candidate_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            manifest = copy.deepcopy(candidate["manifest"])
            manifest["maturity"] = "analytical_candidate"
            manifest["phase"] = "analytical"
            manifest_sha256 = rewrite_manifest(candidate, manifest)
            with self.assertRaisesRegex(RuntimeError, "candidate maturity mismatch"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"], candidate["manifest_path"], manifest_sha256
                )

    def test_database_and_spice_gates_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            manifest = copy.deepcopy(candidate["manifest"])
            manifest["database"]["allowed"] = False
            manifest_sha256 = rewrite_manifest(candidate, manifest)
            with self.assertRaisesRegex(RuntimeError, "database admission mismatch"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"], candidate["manifest_path"], manifest_sha256
                )

            manifest = copy.deepcopy(candidate["manifest"])
            manifest["spice_functional_gate"]["operations"]["read_1"] = "fail"
            manifest_sha256 = rewrite_manifest(candidate, manifest)
            with self.assertRaisesRegex(RuntimeError, "SPICE operation results mismatch"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"], candidate["manifest_path"], manifest_sha256
                )

    def test_model_path_must_be_manifest_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            candidate = write_candidate(temporary / "candidate")
            copy_path = temporary / "copied_model.v"
            copy_path.write_bytes(candidate["model"].read_bytes())
            with self.assertRaisesRegex(RuntimeError, "path does not match"):
                REGRESSION.admit_sram_candidate(
                    copy_path,
                    candidate["manifest_path"],
                    candidate["manifest_sha256"],
                )

    def test_stale_behavioral_model_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            candidate["model"].write_text("module stale; endmodule\n", encoding="ascii")
            with self.assertRaisesRegex(RuntimeError, "verilog view SHA256 mismatch"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"],
                    candidate["manifest_path"],
                    candidate["manifest_sha256"],
                )

    def test_behavioral_model_width_is_checked_independently_of_manifest_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            model_text = candidate["model"].read_text(encoding="ascii").replace(
                "output [DATA_WIDTH-1:0] dout0",
                "output [DATA_WIDTH-2:0] dout0",
            )
            candidate["model"].write_text(model_text, encoding="ascii")
            manifest = copy.deepcopy(candidate["manifest"])
            manifest["files"]["verilog"]["bytes"] = candidate["model"].stat().st_size
            manifest["files"]["verilog"]["sha256"] = REGRESSION.sha256_file(
                candidate["model"]
            )
            manifest_sha256 = rewrite_manifest(candidate, manifest)
            with self.assertRaisesRegex(RuntimeError, "dout0 direction or width"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"], candidate["manifest_path"], manifest_sha256
                )

    def test_behavioral_model_semantics_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = write_candidate(Path(directory) / "candidate")
            model_text = candidate["model"].read_text(encoding="ascii").replace(
                "dout0 <= #(DELAY) mem[addr0_reg];",
                "dout0 <= mem[addr0_reg];",
            )
            candidate["model"].write_text(model_text, encoding="ascii")
            manifest = copy.deepcopy(candidate["manifest"])
            manifest["files"]["verilog"]["bytes"] = candidate["model"].stat().st_size
            manifest["files"]["verilog"]["sha256"] = REGRESSION.sha256_file(
                candidate["model"]
            )
            manifest_sha256 = rewrite_manifest(candidate, manifest)
            with self.assertRaisesRegex(RuntimeError, "negedge delayed read"):
                REGRESSION.admit_sram_candidate(
                    candidate["model"], candidate["manifest_path"], manifest_sha256
                )

    def test_profile_plans_use_independent_libraries_and_explicit_defines(self):
        build_root = Path("build") / "direct"
        common = dict(
            build_root=build_root,
            vlib=["vlib"],
            vlog=["vlog"],
            vsim=["vsim"],
            include_args=["+incdir+/rtl"],
            source_files=[Path("rtl.sv")],
            model_path=Path("candidate.v"),
            testbench=Path("tb.sv"),
            clock_half_period_ns=5.0,
        )
        register = REGRESSION.build_profile_plan(profile="register", **common)
        sram = REGRESSION.build_profile_plan(profile="sram", **common)
        self.assertNotEqual(register["library"], sram["library"])
        self.assertEqual(register["library_name"], "work")
        self.assertEqual(register["vlib"][-1], "work")
        self.assertEqual(
            register["compile"][register["compile"].index("-work") + 1],
            "work",
        )
        self.assertEqual(
            register["simulate"][register["simulate"].index("-lib") + 1],
            "work",
        )
        self.assertNotIn(str(register["library"]), register["simulate"])
        self.assertIn(
            "+define+RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED",
            register["compile"],
        )
        self.assertNotIn(str(Path("candidate.v").resolve()), register["compile"])
        self.assertIn(
            "+define+RDTC_BOUNDED_DIRECT_ASIC_SRAM", sram["compile"]
        )
        self.assertIn(str(Path("candidate.v").resolve()), sram["compile"])
        self.assertIn("-gCLOCK_HALF_PERIOD_NS=5.000000", sram["simulate"])
        self.assertIn("-gSHORT_BACKPRESSURE=0", register["simulate"])
        backpressure = REGRESSION.build_profile_plan(
            profile="register", short_backpressure=True, **common
        )
        self.assertIn("-gSHORT_BACKPRESSURE=1", backpressure["simulate"])

    def test_direct_filelist_requires_the_bounded_output_fifo(self):
        include_args, source_files = REGRESSION.parse_filelist(SOURCE_ROOT, FILELIST)
        self.assertTrue(include_args)
        required = (
            SOURCE_ROOT / "rtl/common/mrtc_axis_bounded_output_fifo.sv"
        ).resolve()
        self.assertIn(required, source_files)
        with self.assertRaisesRegex(RuntimeError, "filelist is incomplete"):
            REGRESSION.verify_filelist_contract(
                SOURCE_ROOT, [path for path in source_files if path != required]
            )

    def test_valid_trace_proves_two_cycle_interface_and_packet_contract(self):
        result = REGRESSION.parse_profile_trace(valid_trace_log(), "register")
        self.assertEqual(result["selected_k"], [0, 3])
        self.assertEqual(result["packet_beats"], [4, 4])
        self.assertEqual(
            result["trace"]["memory_interface"][0]["request_to_response_cycles"],
            2,
        )
        self.assertTrue(result["trace"]["decoder_bit_exact"])
        self.assertEqual(len(result["cycle_trace"]), 3)
        self.assertEqual(result["cycle_trace"][0]["cycle"], 20)

    def test_cycle_trace_requires_continuity_and_rejects_unknowns(self):
        text = valid_trace_log().replace("cycle=21 input_fire=", "cycle=22 input_fire=", 1)
        with self.assertRaisesRegex(RuntimeError, "not contiguous"):
            REGRESSION.parse_profile_trace(text, "register")

        text = valid_trace_log().replace("m_tdata=1111", "m_tdata=x111", 1)
        with self.assertRaisesRegex(RuntimeError, "contains X/Z"):
            REGRESSION.parse_profile_trace(text, "register")

    def test_cycle_trace_rejects_malformed_sentinels(self):
        text = valid_trace_log().replace(
            "input_fire=0 input_owner=-1 input_block=-1",
            "input_fire=0 input_owner=0 input_block=-1",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "input sentinel"):
            REGRESSION.parse_profile_trace(text, "register")

    def test_backpressure_trace_requires_both_markers_and_proves_hold(self):
        result = REGRESSION.parse_profile_trace(
            valid_trace_log(short_backpressure=True),
            "register",
            short_backpressure=True,
        )
        self.assertEqual(
            [marker["kind"] for marker in result["backpressure_markers"]],
            ["header", "payload"],
        )
        self.assertEqual(len(result["cycle_trace"]), 8)

        missing = valid_trace_log(short_backpressure=True).replace(
            "DIRECT_AXIS_TRACE_BP kind=payload cycle=24 packet=0 beat=4 stall_cycles=2\n",
            "",
        )
        with self.assertRaisesRegex(RuntimeError, "backpressure markers"):
            REGRESSION.parse_profile_trace(
                missing, "register", short_backpressure=True
            )

        changed = valid_trace_log(short_backpressure=True).replace(
            "cycle=21 input_fire=0", "cycle=21 input_fire=0", 1
        ).replace("m_tdata=22222222222222222222222222222222", "m_tdata=42222222222222222222222222222222", 1)
        with self.assertRaisesRegex(RuntimeError, "changed under backpressure"):
            REGRESSION.parse_profile_trace(
                changed, "register", short_backpressure=True
            )

    def test_trace_rejects_non_two_cycle_response(self):
        text = valid_trace_log().replace(
            "kind=rsp cycle=1002 engine=0 addr=0",
            "kind=rsp cycle=1003 engine=0 addr=0",
        )
        with self.assertRaisesRegex(RuntimeError, "latency is not two cycles"):
            REGRESSION.parse_profile_trace(text, "sram")

    def test_trace_requires_explicit_decoder_bit_exact_marker(self):
        text = valid_trace_log().replace(
            "DIRECT_AXIS_PROFILE_DECODER bit_exact=1 blocks=2 words=512\n", ""
        )
        with self.assertRaisesRegex(RuntimeError, "decoder bit-exact marker"):
            REGRESSION.parse_profile_trace(text, "register")

    def test_modelsim_suppressible_error_is_not_accepted(self):
        with self.assertRaisesRegex(RuntimeError, "compile log contains errors"):
            REGRESSION.verify_compile_log(
                "** Error (suppressible): bad binding\nErrors: 0, Warnings: 1\n",
                "sram",
            )

    def test_trace_rejects_sideband_and_selected_k_mismatch(self):
        text = valid_trace_log().replace(
            "packet=0 beat=2 data=", "packet=0 beat=2 data="
        ).replace("user=0f last=0", "user=00 last=0", 1)
        with self.assertRaisesRegex(RuntimeError, "TUSER sideband"):
            REGRESSION.parse_profile_trace(text, "register")

        text = valid_trace_log().replace(
            "packet=1 selected_k=3 expected_k=3",
            "packet=1 selected_k=2 expected_k=3",
        )
        with self.assertRaisesRegex(RuntimeError, "selected-k mismatch"):
            REGRESSION.parse_profile_trace(text, "register")

    def test_equivalence_ignores_absolute_cycles_but_detects_payload_change(self):
        register = REGRESSION.parse_profile_trace(valid_trace_log(), "register")
        sram = REGRESSION.parse_profile_trace(
            valid_trace_log(cycle_shift=77), "sram"
        )
        equivalence = REGRESSION.compare_profile_traces(register, sram)
        self.assertEqual(equivalence["status"], "verified")
        self.assertNotEqual(
            register["cycle_trace"][0]["cycle"],
            sram["cycle_trace"][0]["cycle"],
        )
        self.assertEqual(register["trace_sha256"], sram["trace_sha256"])

        changed = REGRESSION.parse_profile_trace(
            valid_trace_log(cycle_shift=77, payload_xor=1), "sram"
        )
        with self.assertRaisesRegex(RuntimeError, "normalized trace mismatch"):
            REGRESSION.compare_profile_traces(register, changed)

    def test_dry_run_validates_both_profiles_without_creating_build_output(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            candidate = write_candidate(temporary / "candidate")
            build_root = SOURCE_ROOT / "build/modelsim/test_dry_run_must_not_exist"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = REGRESSION.run_regression(
                    source_root=SOURCE_ROOT,
                    filelist=FILELIST,
                    testbench=TESTBENCH,
                    sram_model=candidate["model"],
                    sram_manifest=candidate["manifest_path"],
                    sram_manifest_sha256=candidate["manifest_sha256"],
                    build_root=build_root,
                    dry_run=True,
                )
            self.assertEqual(result["status"], "dry_run")
            self.assertFalse(build_root.exists())
            self.assertIn("profile: register", output.getvalue())
            self.assertIn("profile: sram", output.getvalue())
            self.assertIn("bounded-direct-modelsim: DRY-RUN", output.getvalue())

    def test_register_only_dry_run_does_not_require_an_sram_candidate(self):
        build_root = SOURCE_ROOT / "build/modelsim/test_register_only_dry_run"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = REGRESSION.run_regression(
                source_root=SOURCE_ROOT,
                filelist=FILELIST,
                testbench=TESTBENCH,
                sram_model=None,
                sram_manifest=None,
                sram_manifest_sha256=None,
                build_root=build_root,
                dry_run=True,
                profiles=("register",),
            )
        self.assertEqual(result["status"], "dry_run")
        self.assertEqual(set(result["plans"]), {"register"})
        self.assertIn("profiles=register", output.getvalue())
        self.assertIn("candidate=not_applicable", output.getvalue())

    def test_sram_profile_requires_a_complete_candidate_identity(self):
        with self.assertRaisesRegex(RuntimeError, "SRAM profile requires"):
            REGRESSION.run_regression(
                source_root=SOURCE_ROOT,
                filelist=FILELIST,
                testbench=TESTBENCH,
                sram_model=None,
                sram_manifest=None,
                sram_manifest_sha256=None,
                build_root=SOURCE_ROOT / "build/modelsim/test_missing_candidate",
                dry_run=True,
                profiles=("sram",),
            )

    def test_clock_half_period_must_exceed_openram_behavioral_delay(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            candidate = write_candidate(temporary / "candidate")
            with self.assertRaisesRegex(RuntimeError, "must exceed OpenRAM DELAY"):
                REGRESSION.run_regression(
                    source_root=SOURCE_ROOT,
                    filelist=FILELIST,
                    testbench=TESTBENCH,
                    sram_model=candidate["model"],
                    sram_manifest=candidate["manifest_path"],
                    sram_manifest_sha256=candidate["manifest_sha256"],
                    build_root=SOURCE_ROOT / "build/modelsim/test_clock_gate",
                    dry_run=True,
                    clock_half_period_ns=3.0,
                )

    def test_build_root_must_be_inside_ignored_repository_build(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            candidate = write_candidate(temporary / "candidate")
            with self.assertRaisesRegex(RuntimeError, "build root"):
                REGRESSION.run_regression(
                    source_root=SOURCE_ROOT,
                    filelist=FILELIST,
                    testbench=TESTBENCH,
                    sram_model=candidate["model"],
                    sram_manifest=candidate["manifest_path"],
                    sram_manifest_sha256=candidate["manifest_sha256"],
                    build_root=temporary / "unsafe",
                    dry_run=True,
                )

    def test_profile_cleanup_requires_matching_ownership_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            build_root = Path(directory)
            profile_dir = build_root / "register"
            profile_dir.mkdir()
            (profile_dir / "user-file.txt").write_text("keep\n", encoding="ascii")
            with self.assertRaisesRegex(RuntimeError, "unowned profile directory"):
                REGRESSION.prepare_profile_directory(
                    profile_dir, build_root, "register"
                )
            self.assertTrue((profile_dir / "user-file.txt").is_file())

            sentinel = {
                "schema_version": 1,
                "owner": REGRESSION.PROFILE_DIRECTORY_OWNER,
                "profile": "register",
            }
            (profile_dir / REGRESSION.PROFILE_DIRECTORY_SENTINEL).write_text(
                json.dumps(sentinel), encoding="utf-8"
            )
            REGRESSION.prepare_profile_directory(profile_dir, build_root, "register")
            self.assertFalse((profile_dir / "user-file.txt").exists())
            self.assertTrue(
                (profile_dir / REGRESSION.PROFILE_DIRECTORY_SENTINEL).is_file()
            )

    def test_testbench_trace_is_opt_in_and_makefile_has_dedicated_targets(self):
        testbench = TESTBENCH.read_text(encoding="utf-8")
        self.assertIn("`ifdef RDTC_DIRECT_PROFILE_TRACE", testbench)
        self.assertIn("DIRECT_AXIS_PROFILE_MEMORY kind=req", testbench)
        self.assertIn("DIRECT_AXIS_PROFILE_BEAT", testbench)
        self.assertIn("DIRECT_AXIS_PROFILE_DECODER", testbench)
        self.assertIn("DIRECT_AXIS_CYCLE cycle=", testbench)
        self.assertIn("DIRECT_AXIS_TRACE_BP kind=", testbench)
        self.assertIn("DIRECT_AXIS_TRACE_BP kind=header cycle=", testbench)
        self.assertIn("DIRECT_AXIS_TRACE_BP kind=payload cycle=", testbench)
        self.assertNotIn('bp_header_target ? "header" : "payload"', testbench)
        self.assertIn("#1step;", testbench)
        self.assertIn("parameter real CLOCK_HALF_PERIOD_NS = 2.5", testbench)
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn("bounded-direct-modelsim-regression:", makefile)
        self.assertIn("bounded-direct-register-modelsim-regression:", makefile)
        self.assertIn("bounded-direct-modelsim-regression-dry-run:", makefile)
        self.assertIn("direct-stream-timing-modelsim:", makefile)
        self.assertIn("direct-stream-timing-validate:", makefile)


if __name__ == "__main__":
    unittest.main()
