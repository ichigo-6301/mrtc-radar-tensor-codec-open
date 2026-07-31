#!/usr/bin/env python3
"""Compile an admitted bounded-ring 32x128 OpenRAM Liberty into a pinned DB."""

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve()
SCRIPT_DIR = SCRIPT_PATH.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import fullblock_sram_db_prepare as _base  # noqa: E402


PreparationError = _base.PreparationError
EXPECTED_MACRO = "mrtc_rdtc_bounded_ring_1rw_32x128"
EXPECTED_ROLE = "bounded_ring_1rw128_candidate"
EXPECTED_CANDIDATES = frozenset(
    ["ring-32x128-wpr1", "ring-32x128-wpr2", "ring-32x128-wpr4"]
)
EXPECTED_VIEW_ROLES = frozenset(["verilog", "liberty", "lef", "gds", "spice"])
EXPECTED_OPERATIONS = ("write_0", "write_1", "read_0", "read_1")
EXPECTED_OPENRAM_COMMIT = "e16d9eb0b4495e8beee441ced3fcad68391155e6"
DERIVED_MANIFEST_NAME = "bounded_ring_sram_db_manifest.json"
DEFAULT_COMPILE_TCL = _base.DEFAULT_COMPILE_TCL
BASE_MODEL_PERIOD_NS = 3.333333
BASE_MODEL_HALF_PERIOD_NS = 1.666667


def require_sha256(value, label):
    value = str(value).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise PreparationError("{} is not a lowercase SHA256".format(label))
    return value


def validate_candidate(candidate, expected_manifest_sha256, expected_contract_sha256):
    expected_manifest_sha256 = require_sha256(
        expected_manifest_sha256, "expected source manifest SHA256"
    )
    expected_contract_sha256 = require_sha256(
        expected_contract_sha256, "expected candidate contract SHA256"
    )
    candidate_root, manifest_path = _base.resolve_manifest(candidate)
    manifest_sha256 = _base.sha256_file(manifest_path)
    _base.require_equal(
        manifest_sha256,
        expected_manifest_sha256,
        "source manifest SHA256",
    )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PreparationError("cannot parse candidate manifest: {}".format(error))
    if not isinstance(manifest, dict):
        raise PreparationError("candidate manifest root is not an object")
    for actual, expected, label in (
        (manifest.get("schema_version"), 2, "candidate schema version"),
        (manifest.get("status"), "generated_and_audited", "candidate status"),
        (
            manifest.get("maturity"),
            "fully_characterized_candidate",
            "candidate maturity",
        ),
        (manifest.get("phase"), "full", "candidate phase"),
        (
            manifest.get("candidate_contract_sha256"),
            expected_contract_sha256,
            "candidate contract SHA256",
        ),
    ):
        _base.require_equal(actual, expected, label)

    contract = manifest.get("candidate_contract")
    if not isinstance(contract, dict):
        raise PreparationError("candidate contract is missing")
    contract_for_hash = dict(contract)
    embedded_contract_sha256 = contract_for_hash.pop(
        "candidate_contract_sha256", None
    )
    computed_contract_sha256 = _base.canonical_sha256(contract_for_hash)
    _base.require_equal(
        embedded_contract_sha256,
        computed_contract_sha256,
        "embedded candidate contract SHA256",
    )
    _base.require_equal(
        computed_contract_sha256,
        expected_contract_sha256,
        "computed candidate contract SHA256",
    )
    candidate_id = contract.get("candidate_id")
    if candidate_id not in EXPECTED_CANDIDATES:
        raise PreparationError("candidate id is not an admitted bounded ring")
    _base.require_equal(contract.get("macro"), EXPECTED_MACRO, "candidate macro")
    _base.require_equal(contract.get("role"), EXPECTED_ROLE, "candidate role")
    words_per_row = int(candidate_id.rsplit("wpr", 1)[1])
    _base.require_equal(
        contract.get("organization"),
        {
            "address_width": 5,
            "columns": 128 * words_per_row,
            "num_words": 32,
            "rows": 32 // words_per_row,
            "word_size": 128,
            "words_per_row": words_per_row,
        },
        "candidate organization",
    )
    ports = contract.get("ports")
    expected_ports = {
        "num_rw_ports": 1,
        "num_r_ports": 0,
        "num_w_ports": 0,
        "clock_pins": ["clk0"],
        "read_control": {"csb0": 0, "web0": 1},
        "write_control": {"csb0": 0, "web0": 0},
    }
    if not isinstance(ports, dict) or {
        key: ports.get(key) for key in expected_ports
    } != expected_ports:
        raise PreparationError("candidate 1RW port contract mismatch")
    _base.require_equal(
        contract.get("delay_chain"),
        {"stages": 21, "fanout_per_stage": 4},
        "candidate delay chain",
    )
    _base.require_equal(
        contract.get("technology"),
        {
            "name": "freepdk45",
            "process": "TT",
            "voltage_v": 1.1,
            "temperature_c": 25,
            "openram_commit": EXPECTED_OPENRAM_COMMIT,
        },
        "candidate technology",
    )

    database = manifest.get("database")
    if not isinstance(database, dict):
        raise PreparationError("candidate database gate is missing")
    _base.require_equal(database.get("allowed"), True, "candidate database admission")
    _base.require_equal(database.get("status"), "not_compiled", "candidate database status")
    model_gate = manifest.get("model_gate")
    if not isinstance(model_gate, dict):
        raise PreparationError("candidate model gate is missing")
    _base.require_equal(
        model_gate.get("bounded_ring_allowed"), True, "bounded ring model gate"
    )
    _base.require_equal(
        model_gate.get("supports_300mhz"), True, "300 MHz model gate"
    )
    try:
        timing_values = (
            float(model_gate["candidate_tgov_ns"]),
            float(model_gate["maximum_high_pulse_ns"]),
            float(model_gate["maximum_low_pulse_ns"]),
        )
    except (KeyError, TypeError, ValueError):
        raise PreparationError("candidate timing gate is malformed")
    if not all(math.isfinite(value) for value in timing_values) or (
        timing_values[0] > BASE_MODEL_PERIOD_NS
        or timing_values[1] > BASE_MODEL_HALF_PERIOD_NS
        or timing_values[2] > BASE_MODEL_HALF_PERIOD_NS
    ):
        raise PreparationError("candidate timing gate does not support 300 MHz")

    spice_gate = manifest.get("spice_functional_gate")
    if not isinstance(spice_gate, dict):
        raise PreparationError("candidate SPICE operation gate is missing")
    _base.require_equal(spice_gate.get("status"), "pass", "SPICE gate status")
    _base.require_equal(
        spice_gate.get("required_operations"),
        list(EXPECTED_OPERATIONS),
        "required SPICE operations",
    )
    _base.require_equal(
        spice_gate.get("operations"),
        {name: "pass" for name in EXPECTED_OPERATIONS},
        "SPICE operation results",
    )
    guard_audit = manifest.get("ngspice_guard_audit")
    if not isinstance(guard_audit, dict) or guard_audit.get("status") != "pass":
        raise PreparationError("candidate ngspice guard audit is not PASS")

    files = manifest.get("files")
    if not isinstance(files, dict) or set(files) != EXPECTED_VIEW_ROLES:
        raise PreparationError("candidate view roles are incomplete")
    view_paths = {}
    view_records = {}
    for role in sorted(EXPECTED_VIEW_ROLES):
        record = files[role]
        path = _base.resolve_view(candidate_root, record, role)
        actual_sha256 = _base.sha256_file(path)
        _base.require_equal(
            record.get("sha256"), actual_sha256, "recorded {} SHA256".format(role)
        )
        _base.require_equal(
            record.get("bytes"), path.stat().st_size, "{} byte count".format(role)
        )
        view_paths[role] = path
        view_records[role] = {
            "path": record["path"],
            "bytes": path.stat().st_size,
            "sha256": actual_sha256,
        }

    view_text = {
        role: view_paths[role].read_text(encoding="utf-8", errors="replace")
        for role in ("verilog", "liberty", "lef", "spice")
    }
    declarations = {
        "verilog": r"\bmodule\s+{}\b",
        "liberty": r"\bcell\s*\(\s*{}\s*\)",
        "lef": r"\bMACRO\s+{}\b",
        "spice": r"(?im)^\s*\.subckt\s+{}(?:\s|$)",
    }
    for role, pattern in declarations.items():
        if not re.search(pattern.format(re.escape(EXPECTED_MACRO)), view_text[role]):
            raise PreparationError(
                "{} view does not declare the admitted macro".format(role)
            )
    library_match = re.search(
        r"\blibrary\s*\(\s*([^\s)]+)\s*\)", view_text["liberty"]
    )
    if not library_match:
        raise PreparationError("Liberty view has no library declaration")

    return {
        "candidate_root": candidate_root,
        "manifest_path": manifest_path,
        "manifest_sha256": manifest_sha256,
        "manifest": manifest,
        "contract": contract,
        "view_paths": view_paths,
        "view_records": view_records,
        "library_name": library_match.group(1).strip('"'),
    }


def prepare(
    candidate,
    output_dir,
    lc_command,
    expected_manifest_sha256,
    expected_contract_sha256,
    dry_run=False,
    compile_tcl=DEFAULT_COMPILE_TCL,
    environment=None,
    compile_timeout_seconds=1800,
    version_timeout_seconds=60,
):
    expected_manifest_sha256 = require_sha256(
        expected_manifest_sha256, "expected source manifest SHA256"
    )
    expected_contract_sha256 = require_sha256(
        expected_contract_sha256, "expected candidate contract SHA256"
    )
    _base.EXPECTED_MACRO = EXPECTED_MACRO
    _base.EXPECTED_SOURCE_MANIFEST_SHA256 = expected_manifest_sha256
    _base.EXPECTED_CONTRACT_SHA256 = expected_contract_sha256
    _base.DERIVED_MANIFEST_NAME = DERIVED_MANIFEST_NAME
    _base.SCRIPT_PATH = SCRIPT_PATH
    _base.validate_candidate = lambda selected: validate_candidate(
        selected, expected_manifest_sha256, expected_contract_sha256
    )
    return _base.prepare(
        candidate=candidate,
        output_dir=output_dir,
        lc_command=lc_command,
        dry_run=dry_run,
        compile_tcl=compile_tcl,
        environment=environment,
        compile_timeout_seconds=compile_timeout_seconds,
        version_timeout_seconds=version_timeout_seconds,
        display_name="bounded-ring-sram-db-prepare",
    )


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--expected-manifest-sha256", required=True)
    parser.add_argument("--expected-contract-sha256", required=True)
    parser.add_argument(
        "--lc-shell", default=os.environ.get("RDTC_TOOL_LC", "lc_shell")
    )
    parser.add_argument("--lc-shell-arg", action="append", default=[])
    parser.add_argument("--compile-timeout-seconds", type=int, default=1800)
    parser.add_argument("--version-timeout-seconds", type=int, default=60)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    prepare(
        candidate=args.candidate,
        output_dir=args.output_dir,
        lc_command=[args.lc_shell] + args.lc_shell_arg,
        expected_manifest_sha256=args.expected_manifest_sha256,
        expected_contract_sha256=args.expected_contract_sha256,
        dry_run=args.dry_run,
        compile_timeout_seconds=args.compile_timeout_seconds,
        version_timeout_seconds=args.version_timeout_seconds,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PreparationError as error:
        print("bounded-ring-sram-db-prepare: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
