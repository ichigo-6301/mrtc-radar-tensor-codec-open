#!/usr/bin/env python3

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load_module(
    "rdtc_bounded_ring_sram_db_prepare_test",
    SCRIPT_DIR / "bounded_ring_sram_db_prepare.py",
)


class BoundedRingSramDbPrepareTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.candidate = self.root / "candidate"
        self.views = self.candidate / "views"
        self.views.mkdir(parents=True)
        self.output = self.root / "derived"
        self.trace = self.root / "trace.jsonl"
        self.fake_lc = self.root / "fake_lc.py"
        self.fake_lc.write_text(
            r"""import hashlib
import json
import os
import sys
from pathlib import Path

trace = Path(os.environ["FAKE_LC_TRACE"])
action = "version" if "-version" in sys.argv else "compile"
with trace.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps({"action": action}) + "\n")
if action == "version":
    print("Fake Library Compiler 2026.07")
else:
    liberty = Path(os.environ["RDTC_SRAM_LIB"])
    destination = Path(os.environ["RDTC_SRAM_DB"])
    destination.write_bytes(
        b"FAKE-DB\n" + hashlib.sha256(liberty.read_bytes()).hexdigest().encode()
    )
    print("fake compile complete")
""",
            encoding="ascii",
        )
        macro = PREPARE.EXPECTED_MACRO
        contents = {
            "verilog": (macro + ".v", "module {}; endmodule\n".format(macro).encode()),
            "liberty": (
                macro + "_TT_1p1V_25C.lib",
                (
                    "library ({}_lib) {{\n  cell ({}) {{ area : 1; }}\n}}\n".format(
                        macro, macro
                    )
                ).encode(),
            ),
            "lef": (macro + ".lef", "MACRO {}\nEND {}\n".format(macro, macro).encode()),
            "gds": (macro + ".gds", b"fake-gds\x00\x01"),
            "spice": (
                macro + ".sp",
                ".SUBCKT {} clk0 csb0 web0 addr0 din0 dout0\n.ENDS\n".format(
                    macro
                ).encode(),
            ),
        }
        files = {}
        for role, (name, payload) in contents.items():
            path = self.views / name
            path.write_bytes(payload)
            files[role] = {
                "path": "views/" + name,
                "bytes": len(payload),
                "sha256": PREPARE._base.sha256_file(path),
            }
        contract = {
            "schema_version": 1,
            "candidate_id": "ring-32x128-wpr2",
            "role": PREPARE.EXPECTED_ROLE,
            "macro": macro,
            "organization": {
                "address_width": 5,
                "columns": 256,
                "num_words": 32,
                "rows": 16,
                "word_size": 128,
                "words_per_row": 2,
            },
            "ports": {
                "num_rw_ports": 1,
                "num_r_ports": 0,
                "num_w_ports": 0,
                "clock_pins": ["clk0"],
                "read_control": {"csb0": 0, "web0": 1},
                "write_control": {"csb0": 0, "web0": 0},
            },
            "delay_chain": {"stages": 21, "fanout_per_stage": 4},
            "technology": {
                "name": "freepdk45",
                "process": "TT",
                "voltage_v": 1.1,
                "temperature_c": 25,
                "openram_commit": PREPARE.EXPECTED_OPENRAM_COMMIT,
            },
        }
        self.contract_sha256 = PREPARE._base.canonical_sha256(contract)
        contract["candidate_contract_sha256"] = self.contract_sha256
        self.manifest = {
            "schema_version": 2,
            "status": "generated_and_audited",
            "maturity": "fully_characterized_candidate",
            "phase": "full",
            "attempt": 1,
            "candidate_contract": contract,
            "candidate_contract_sha256": self.contract_sha256,
            "database": {"allowed": True, "status": "not_compiled"},
            "model_gate": {
                "bounded_ring_allowed": True,
                "supports_300mhz": True,
                "supports_600mhz": True,
                "candidate_tgov_ns": 1.4,
                "maximum_high_pulse_ns": 0.7,
                "maximum_low_pulse_ns": 0.7,
            },
            "spice_functional_gate": {
                "status": "pass",
                "required_operations": list(PREPARE.EXPECTED_OPERATIONS),
                "operations": {
                    name: "pass" for name in PREPARE.EXPECTED_OPERATIONS
                },
            },
            "ngspice_guard_audit": {"status": "pass"},
            "files": files,
        }
        self.sync_manifest()
        self.environment = dict(os.environ)
        self.environment["FAKE_LC_TRACE"] = str(self.trace)
        self.command = [sys.executable, str(self.fake_lc)]

    def tearDown(self):
        self.temporary.cleanup()

    def sync_manifest(self):
        path = self.candidate / "candidate_manifest.json"
        PREPARE._base.write_json(path, self.manifest)
        self.manifest_sha256 = PREPARE._base.sha256_file(path)

    def run_prepare(self, **overrides):
        arguments = {
            "candidate": self.candidate,
            "output_dir": self.output,
            "lc_command": self.command,
            "expected_manifest_sha256": self.manifest_sha256,
            "expected_contract_sha256": self.contract_sha256,
            "environment": self.environment,
            "compile_timeout_seconds": 10,
            "version_timeout_seconds": 10,
        }
        arguments.update(overrides)
        return PREPARE.prepare(**arguments)

    def test_dry_run_admits_only_complete_ring_candidate(self):
        result = self.run_prepare(dry_run=True)
        self.assertEqual(result["status"], "dry_run")
        self.assertFalse(self.output.exists())

    def test_compile_and_exact_cache_hit_preserve_provenance(self):
        result = self.run_prepare()
        self.assertEqual(result["status"], "compiled")
        cached = self.run_prepare()
        self.assertEqual(cached["status"], "cache_hit")
        derived_path = self.output / PREPARE.DERIVED_MANIFEST_NAME
        derived = json.loads(derived_path.read_text(encoding="utf-8"))
        self.assertEqual(derived["macro"], PREPARE.EXPECTED_MACRO)
        self.assertEqual(
            derived["source"]["candidate_contract_sha256"],
            self.contract_sha256,
        )
        self.assertEqual(
            derived["runner"]["path"],
            "flows/scripts/bounded_ring_sram_db_prepare.py",
        )
        self.assertRegex(derived["log"]["sha256"], r"^[0-9a-f]{64}$")
        actions = [
            json.loads(line)["action"]
            for line in self.trace.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(actions, ["version", "compile", "version"])

    def test_operation_failure_is_rejected(self):
        self.manifest["spice_functional_gate"]["operations"]["read_1"] = "fail"
        self.sync_manifest()
        with self.assertRaisesRegex(
            PREPARE.PreparationError, "SPICE operation results"
        ):
            self.run_prepare(dry_run=True)

    def test_timing_gate_failure_is_rejected(self):
        self.manifest["model_gate"]["maximum_high_pulse_ns"] = 1.7
        self.sync_manifest()
        with self.assertRaisesRegex(
            PREPARE.PreparationError, "does not support 300 MHz"
        ):
            self.run_prepare(dry_run=True)

    def test_300mhz_candidate_can_compile_when_600mhz_is_blocked(self):
        self.manifest["model_gate"].update(
            {
                "supports_600mhz": False,
                "candidate_tgov_ns": 2.656,
                "maximum_high_pulse_ns": 1.328,
                "maximum_low_pulse_ns": 1.328,
            }
        )
        self.sync_manifest()
        result = self.run_prepare(dry_run=True)
        self.assertEqual(result["status"], "dry_run")

    def test_expected_manifest_and_contract_hashes_are_required(self):
        with self.assertRaisesRegex(
            PREPARE.PreparationError, "source manifest SHA256"
        ):
            self.run_prepare(
                dry_run=True, expected_manifest_sha256="0" * 64
            )
        with self.assertRaisesRegex(
            PREPARE.PreparationError, "candidate contract SHA256"
        ):
            self.run_prepare(
                dry_run=True, expected_contract_sha256="0" * 64
            )

    def test_changed_view_is_rejected(self):
        liberty = self.views / self.manifest["files"]["liberty"]["path"].split("/")[-1]
        liberty.write_bytes(liberty.read_bytes() + b"changed\n")
        with self.assertRaisesRegex(
            PREPARE.PreparationError, "recorded liberty SHA256"
        ):
            self.run_prepare(dry_run=True)


if __name__ == "__main__":
    unittest.main()
