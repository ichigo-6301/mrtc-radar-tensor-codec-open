#!/usr/bin/env python3
"""Compare bounded direct-AXIS register and OpenRAM ModelSim profiles."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve()
SCRIPT_DIR = SCRIPT_PATH.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import process_control


MACRO = "mrtc_rdtc_bounded_ring_1rw_32x128"
ROLE = "bounded_ring_1rw128_candidate"
OPENRAM_COMMIT = "e16d9eb0b4495e8beee441ced3fcad68391155e6"
CANDIDATES = frozenset(
    ("ring-32x128-wpr1", "ring-32x128-wpr2", "ring-32x128-wpr4")
)
VIEW_ROLES = frozenset(("verilog", "liberty", "lef", "gds", "spice"))
OPERATIONS = ("write_0", "write_1", "read_0", "read_1")
PROFILE_DEFINES = {
    "register": "RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED",
    "sram": "RDTC_BOUNDED_DIRECT_ASIC_SRAM",
}
TRACE_DEFINE = "RDTC_DIRECT_PROFILE_TRACE"
TOP = "tb_mrtc_bounded_axis_multiengine_wrapper"
BLOCK_COUNT = 2
BLOCK_WORDS = 256
READ_LATENCY_CYCLES = 2
DEFAULT_CLOCK_HALF_PERIOD_NS = 5.0
DEFAULT_SRAM_TARGET_PERIOD_NS = 3.333333
RUN_DO = "onerror {quit -code 1}; run -all; quit -code 0"
SHA256_RE = re.compile(r"[0-9a-f]{64}")

MEMORY_RE = re.compile(
    r"DIRECT_AXIS_PROFILE_MEMORY\s+kind=(req|rsp)\s+cycle=(\d+)\s+"
    r"engine=(\d+)\s+addr=(\d+)"
)
BEAT_RE = re.compile(
    r"DIRECT_AXIS_PROFILE_BEAT\s+packet=(\d+)\s+beat=(\d+)\s+"
    r"data=([0-9a-fA-FxXzZ]{32})\s+user=([0-9a-fA-FxXzZ]{2})\s+last=(\d+)"
)
PACKET_RE = re.compile(
    r"DIRECT_AXIS_PROFILE_PACKET\s+packet=(\d+)\s+selected_k=(\d+)\s+"
    r"expected_k=(\d+)\s+beats=(\d+)"
)
PACKET_DONE_RE = re.compile(
    r"DIRECT_AXIS_PACKET_DONE\s+cycle=(\d+)\s+packet=(\d+)\s+"
    r"beats=(\d+)\s+fifo=(\d+)"
)
STREAM_RE = re.compile(
    r"DIRECT_AXIS_STREAM\s+blocks=(\d+)\s+bp=(\d+)\s+cycles=(\d+)\s+"
    r"cycles_per_block=([^\s]+)\s+fifo_max=(\d+)\s+hold_checks=(\d+)\s+"
    r"k_cycle=(\d+)/(\d+)\s+first_read=(\d+)/(\d+)"
)
DECODER_RE = re.compile(
    r"DIRECT_AXIS_PROFILE_DECODER\s+bit_exact=(\d+)\s+blocks=(\d+)\s+"
    r"words=(\d+)"
)
PROFILE_DIRECTORY_SENTINEL = ".bounded_direct_modelsim_owned.json"
PROFILE_DIRECTORY_OWNER = "bounded-direct-modelsim-regression"


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_bytes(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def canonical_sha256(value):
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def command_text(command):
    return " ".join(shlex.quote(str(item)) for item in command)


def require_sha256(value, label):
    normalized = str(value).strip().lower()
    if not SHA256_RE.fullmatch(normalized):
        raise RuntimeError("{} must be a lowercase SHA256".format(label))
    return normalized


def require_equal(actual, expected, label):
    if actual != expected:
        raise RuntimeError(
            "{} mismatch: expected {!r}, got {!r}".format(label, expected, actual)
        )


def require_within(path, root, label):
    resolved = Path(path).resolve()
    root = Path(root).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        raise RuntimeError("{} escapes {}: {}".format(label, root, resolved))
    return resolved


def require_ignored_build_root(source_root, build_root):
    source_root = Path(source_root).resolve()
    repository_build = (source_root / "build").resolve()
    build_root = require_within(
        build_root, repository_build, "bounded direct ModelSim build root"
    )
    if build_root == repository_build:
        raise RuntimeError(
            "bounded direct ModelSim build root cannot equal the repository build root"
        )
    try:
        ignored_path = build_root.relative_to(source_root).as_posix()
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", "--", ignored_path],
            cwd=str(source_root),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as error:
        raise RuntimeError("cannot verify ignored build root: {}".format(error))
    if ignored.returncode != 0:
        raise RuntimeError(
            "bounded direct ModelSim build root is not Git-ignored: {}".format(
                build_root
            )
        )
    return build_root


def prepare_profile_directory(profile_dir, build_root, profile):
    profile_dir = require_within(
        profile_dir, build_root, "{} build directory".format(profile)
    )
    if profile_dir == Path(build_root).resolve():
        raise RuntimeError("profile build directory cannot equal the build root")
    expected_sentinel = {
        "schema_version": 1,
        "owner": PROFILE_DIRECTORY_OWNER,
        "profile": profile,
    }
    sentinel = profile_dir / PROFILE_DIRECTORY_SENTINEL
    if profile_dir.exists():
        try:
            actual_sentinel = json.loads(sentinel.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise RuntimeError(
                "refusing to remove unowned profile directory: {}".format(profile_dir)
            )
        if actual_sentinel != expected_sentinel:
            raise RuntimeError(
                "refusing to remove profile directory with a mismatched ownership sentinel: {}"
                .format(profile_dir)
            )
        shutil.rmtree(str(profile_dir))
    profile_dir.mkdir(parents=True)
    _write_json(profile_dir / PROFILE_DIRECTORY_SENTINEL, expected_sentinel)
    return profile_dir


def resolve_tool(environment_name, default, dry_run):
    value = os.environ.get(environment_name, default).strip()
    candidate = Path(value.strip('"'))
    if candidate.is_file():
        return [str(candidate.resolve())]
    parts = shlex.split(value, posix=(os.name != "nt"))
    if not parts:
        raise RuntimeError("empty tool setting: {}".format(environment_name))
    if dry_run:
        return parts
    executable = shutil.which(parts[0])
    if not executable:
        raise RuntimeError("tool executable not found: {}".format(parts[0]))
    return [str(Path(executable).resolve())] + parts[1:]


def parse_filelist(source_root, filelist):
    source_root = Path(source_root).resolve()
    filelist = Path(filelist).resolve()
    if not filelist.is_file():
        raise RuntimeError("missing RTL filelist: {}".format(filelist))
    include_args = []
    source_files = []
    for raw_line in filelist.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if not line:
            continue
        if line.startswith("+incdir+"):
            for entry in line[len("+incdir+") :].split("+"):
                include_dir = require_within(
                    source_root / entry, source_root, "filelist include directory"
                )
                if not include_dir.is_dir():
                    raise RuntimeError(
                        "missing include directory: {}".format(include_dir)
                    )
                include_args.append("+incdir+{}".format(include_dir))
            continue
        if line.startswith("+define+"):
            raise RuntimeError(
                "profile defines must not be hidden in the base filelist: {}".format(
                    line
                )
            )
        if line.startswith("+") or line.startswith("-"):
            raise RuntimeError("unsupported filelist directive: {}".format(line))
        source = require_within(
            source_root / line, source_root, "filelist RTL source"
        )
        if not source.is_file():
            raise RuntimeError("missing RTL source: {}".format(source))
        source_files.append(source)
    if not source_files:
        raise RuntimeError("no RTL sources found in {}".format(filelist))
    return include_args, source_files


def verify_filelist_contract(source_root, source_files):
    source_root = Path(source_root).resolve()
    required = {
        (source_root / path).resolve()
        for path in (
            "rtl/common/mrtc_pkg.sv",
            "rtl/common/mrtc_axis_bounded_output_fifo.sv",
            "rtl/rdtc/mrtc_shallow_1rw_way.sv",
            "rtl/rdtc/mrtc_shallow_way_ring_slice.sv",
            "rtl/rdtc/mrtc_rdtc_encoder_bounded_ht.sv",
            "rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv",
            "rtl/rdtc/mrtc_rdtc_decoder_top.sv",
        )
    }
    missing = sorted(str(path) for path in required - set(source_files))
    if missing:
        raise RuntimeError(
            "direct wrapper filelist is incomplete: {}".format(", ".join(missing))
        )
    macro_declaration = re.compile(r"(?m)^\s*module\s+{}\b".format(MACRO))
    duplicates = []
    for source in source_files:
        if macro_declaration.search(
            source.read_text(encoding="utf-8", errors="replace")
        ):
            duplicates.append(str(source))
    if duplicates:
        raise RuntimeError(
            "base filelist already defines the OpenRAM macro: {}".format(
                ", ".join(duplicates)
            )
        )


def _load_manifest(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot parse candidate manifest: {}".format(error))
    if not isinstance(value, dict):
        raise RuntimeError("candidate manifest root is not an object")
    return value


def _resolve_view(candidate_root, record, role):
    if not isinstance(record, dict) or set(record) != {"path", "bytes", "sha256"}:
        raise RuntimeError("candidate {} view record is malformed".format(role))
    relative_path = record.get("path")
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise RuntimeError("candidate {} view path is malformed".format(role))
    if Path(relative_path).is_absolute():
        raise RuntimeError("candidate {} view path must be relative".format(role))
    path = require_within(
        Path(candidate_root) / relative_path,
        candidate_root,
        "candidate {} view".format(role),
    )
    if not path.is_file():
        raise RuntimeError("candidate {} view is missing: {}".format(role, path))
    expected_sha256 = require_sha256(
        record.get("sha256", ""), "candidate {} view SHA256".format(role)
    )
    if sha256_file(path) != expected_sha256:
        raise RuntimeError("candidate {} view SHA256 mismatch".format(role))
    if not isinstance(record.get("bytes"), int) or record["bytes"] != path.stat().st_size:
        raise RuntimeError("candidate {} view byte count mismatch".format(role))
    return path


def _verify_behavioral_model(model_path):
    text = Path(model_path).read_text(encoding="utf-8", errors="replace")
    modules = re.findall(r"(?m)^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)\b", text)
    if modules != [MACRO]:
        raise RuntimeError(
            "behavioral Verilog must declare exactly one {} module".format(MACRO)
        )
    scalar_inputs = re.compile(
        r"\binput\s+(?:(?:wire|logic|reg)\s+)?([^;]+);", re.MULTILINE
    )
    scalar_input_text = " ".join(scalar_inputs.findall(text))
    for pin in ("clk0", "csb0", "web0"):
        if not re.search(r"\b{}\b".format(pin), scalar_input_text):
            raise RuntimeError(
                "behavioral Verilog is missing scalar input {}".format(pin)
            )
    interface_patterns = {
        "addr0": r"\binput\s+(?:(?:wire|logic|reg)\s+)?"
        r"\[\s*ADDR_WIDTH\s*-\s*1\s*:\s*0\s*\]\s+addr0\b",
        "din0": r"\binput\s+(?:(?:wire|logic|reg)\s+)?"
        r"\[\s*DATA_WIDTH\s*-\s*1\s*:\s*0\s*\]\s+din0\b",
        "dout0": r"\boutput\s+(?:(?:wire|logic|reg)\s+)?"
        r"\[\s*DATA_WIDTH\s*-\s*1\s*:\s*0\s*\]\s+dout0\b",
    }
    for pin, pattern in interface_patterns.items():
        if not re.search(pattern, text):
            raise RuntimeError(
                "behavioral Verilog {} direction or width is invalid".format(pin)
            )
    for parameter, expected in (("DATA_WIDTH", 128), ("ADDR_WIDTH", 5)):
        match = re.search(
            r"\bparameter\s+{}\s*=\s*(\d+)\b".format(parameter), text
        )
        if not match or int(match.group(1)) != expected:
            raise RuntimeError(
                "behavioral Verilog {} must be {}".format(parameter, expected)
            )
    delay_match = re.search(
        r"\bparameter\s+DELAY\s*=\s*"
        r"([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)",
        text,
    )
    if not delay_match:
        raise RuntimeError("behavioral Verilog DELAY parameter is missing")
    delay_ns = float(delay_match.group(1))
    if not math.isfinite(delay_ns) or delay_ns < 0.0:
        raise RuntimeError("behavioral Verilog DELAY parameter is invalid")
    semantic_patterns = {
        "posedge command capture": (
            r"always\s*@\s*\(\s*posedge\s+clk0\s*\).*?"
            r"addr0_reg\s*=\s*addr0\s*;.*?din0_reg\s*=\s*din0\s*;"
        ),
        "negedge write": (
            r"always\s*@\s*\(\s*negedge\s+clk0\s*\).*?"
            r"!\s*csb0_reg\s*&&\s*!\s*web0_reg.*?"
            r"mem\s*\[\s*addr0_reg\s*\].*?=\s*din0_reg"
        ),
        "negedge delayed read": (
            r"always\s*@\s*\(\s*negedge\s+clk0\s*\).*?"
            r"!\s*csb0_reg\s*&&\s*web0_reg.*?"
            r"dout0\s*<=\s*#\s*\(\s*DELAY\s*\)\s*"
            r"mem\s*\[\s*addr0_reg\s*\]"
        ),
    }
    for label, pattern in semantic_patterns.items():
        if not re.search(pattern, text, re.DOTALL):
            raise RuntimeError(
                "behavioral Verilog is missing OpenRAM {} semantics".format(label)
            )
    return {
        "delay_ns": delay_ns,
        "module": MACRO,
        "command_capture_edge": "posedge",
        "memory_access_edge": "negedge",
        "read_delay_parameter": "DELAY",
    }


def admit_sram_candidate(
    model_path,
    manifest_path,
    expected_manifest_sha256,
    target_period_ns=DEFAULT_SRAM_TARGET_PERIOD_NS,
):
    model_path = Path(model_path).resolve()
    manifest_path = Path(manifest_path).resolve()
    if manifest_path.name != "candidate_manifest.json":
        raise RuntimeError("SRAM manifest must be named candidate_manifest.json")
    if not manifest_path.is_file():
        raise RuntimeError("missing SRAM candidate manifest: {}".format(manifest_path))
    expected_manifest_sha256 = require_sha256(
        expected_manifest_sha256, "expected SRAM manifest SHA256"
    )
    actual_manifest_sha256 = sha256_file(manifest_path)
    if actual_manifest_sha256 != expected_manifest_sha256:
        raise RuntimeError(
            "SRAM manifest SHA256 mismatch: expected {} got {}".format(
                expected_manifest_sha256, actual_manifest_sha256
            )
        )
    manifest = _load_manifest(manifest_path)
    for actual, expected, label in (
        (manifest.get("schema_version"), 2, "candidate schema version"),
        (manifest.get("status"), "generated_and_audited", "candidate status"),
        (
            manifest.get("maturity"),
            "fully_characterized_candidate",
            "candidate maturity",
        ),
        (manifest.get("phase"), "full", "candidate phase"),
    ):
        require_equal(actual, expected, label)

    contract = manifest.get("candidate_contract")
    if not isinstance(contract, dict):
        raise RuntimeError("candidate contract is missing")
    contract_for_hash = dict(contract)
    embedded_contract_sha256 = contract_for_hash.pop(
        "candidate_contract_sha256", None
    )
    computed_contract_sha256 = canonical_sha256(contract_for_hash)
    require_equal(
        embedded_contract_sha256,
        computed_contract_sha256,
        "embedded candidate contract SHA256",
    )
    require_equal(
        manifest.get("candidate_contract_sha256"),
        computed_contract_sha256,
        "manifest candidate contract SHA256",
    )
    require_equal(contract.get("schema_version"), 2, "candidate contract schema")
    candidate_id = contract.get("candidate_id")
    if candidate_id not in CANDIDATES:
        raise RuntimeError("candidate id is not an admitted bounded ring")
    require_equal(contract.get("macro"), MACRO, "candidate macro")
    require_equal(contract.get("role"), ROLE, "candidate role")
    words_per_row = int(candidate_id.rsplit("wpr", 1)[1])
    require_equal(
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
        "signal_pins": ["clk0", "csb0", "web0", "addr0", "din0", "dout0"],
    }
    if not isinstance(ports, dict) or {
        key: ports.get(key) for key in expected_ports
    } != expected_ports:
        raise RuntimeError("candidate 1RW port contract mismatch")
    require_equal(
        contract.get("delay_chain"),
        {"stages": 21, "fanout_per_stage": 4},
        "candidate delay chain",
    )
    require_equal(
        contract.get("technology"),
        {
            "name": "freepdk45",
            "process": "TT",
            "voltage_v": 1.1,
            "temperature_c": 25,
            "openram_commit": OPENRAM_COMMIT,
        },
        "candidate technology",
    )

    database = manifest.get("database")
    if not isinstance(database, dict):
        raise RuntimeError("candidate database gate is missing")
    require_equal(database.get("allowed"), True, "candidate database admission")
    require_equal(database.get("status"), "not_compiled", "candidate database status")

    model_gate = manifest.get("model_gate")
    if not isinstance(model_gate, dict):
        raise RuntimeError("candidate model gate is missing")
    require_equal(
        model_gate.get("bounded_ring_allowed"), True, "bounded ring model gate"
    )
    require_equal(model_gate.get("supports_300mhz"), True, "300 MHz model gate")
    try:
        target_period_ns = float(target_period_ns)
        timing = {
            "governing_period_ns": float(model_gate["candidate_tgov_ns"]),
            "maximum_high_pulse_ns": float(model_gate["maximum_high_pulse_ns"]),
            "maximum_low_pulse_ns": float(model_gate["maximum_low_pulse_ns"]),
        }
    except (KeyError, TypeError, ValueError):
        raise RuntimeError("candidate timing gate is malformed")
    if not math.isfinite(target_period_ns) or target_period_ns <= 0.0:
        raise RuntimeError("SRAM target period must be finite and positive")
    target_half_period_ns = target_period_ns / 2.0
    if not all(math.isfinite(value) for value in timing.values()) or (
        timing["governing_period_ns"] > target_period_ns
        or timing["maximum_high_pulse_ns"] > target_half_period_ns
        or timing["maximum_low_pulse_ns"] > target_half_period_ns
    ):
        raise RuntimeError(
            "candidate timing gate does not support target period {:.6f} ns".format(
                target_period_ns
            )
        )
    timing.update(
        {
            "target_period_ns": target_period_ns,
            "target_half_period_ns": target_half_period_ns,
        }
    )

    spice_gate = manifest.get("spice_functional_gate")
    if not isinstance(spice_gate, dict):
        raise RuntimeError("candidate SPICE operation gate is missing")
    require_equal(spice_gate.get("status"), "pass", "SPICE gate status")
    require_equal(
        spice_gate.get("required_operations"),
        list(OPERATIONS),
        "required SPICE operations",
    )
    require_equal(
        spice_gate.get("operations"),
        {name: "pass" for name in OPERATIONS},
        "SPICE operation results",
    )
    guard_audit = manifest.get("ngspice_guard_audit")
    if not isinstance(guard_audit, dict) or guard_audit.get("status") != "pass":
        raise RuntimeError("candidate ngspice guard audit is not PASS")

    audit = manifest.get("audit")
    if not isinstance(audit, dict) or audit.get("verilog_signal_widths") != {
        "addr0": 5,
        "clk0": 1,
        "csb0": 1,
        "din0": 128,
        "dout0": 128,
        "web0": 1,
    }:
        raise RuntimeError("candidate Verilog interface audit is incomplete")

    files = manifest.get("files")
    if not isinstance(files, dict) or set(files) != VIEW_ROLES:
        raise RuntimeError("candidate view roles are incomplete")
    candidate_root = manifest_path.parent.resolve()
    view_paths = {
        role: _resolve_view(candidate_root, files[role], role)
        for role in sorted(VIEW_ROLES)
    }
    expected_model = view_paths["verilog"]
    if not model_path.is_file():
        raise RuntimeError("missing SRAM behavioral Verilog: {}".format(model_path))
    if model_path != expected_model:
        raise RuntimeError(
            "behavioral Verilog path does not match the candidate manifest"
        )
    model_audit = _verify_behavioral_model(model_path)

    return {
        "candidate_id": candidate_id,
        "candidate_root": candidate_root,
        "candidate_contract_sha256": computed_contract_sha256,
        "manifest": manifest,
        "manifest_path": manifest_path,
        "manifest_sha256": actual_manifest_sha256,
        "model_path": model_path,
        "model_sha256": files["verilog"]["sha256"],
        "model_bytes": files["verilog"]["bytes"],
        "model_delay_ns": model_audit["delay_ns"],
        "timing": timing,
        "view_paths": view_paths,
    }


def verify_testbench_contract(testbench):
    text = Path(testbench).read_text(encoding="utf-8", errors="replace")
    required = (
        "parameter real CLOCK_HALF_PERIOD_NS = 2.5",
        "DIRECT_AXIS_PROFILE_MEMORY kind=req",
        "DIRECT_AXIS_PROFILE_MEMORY kind=rsp",
        "DIRECT_AXIS_PROFILE_BEAT",
        "DIRECT_AXIS_PROFILE_PACKET",
        "DIRECT_AXIS_PROFILE_DECODER",
        "PASS tb_mrtc_bounded_axis_multiengine_wrapper",
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(
            "direct wrapper testbench trace contract is incomplete: {}".format(
                ", ".join(missing)
            )
        )


def source_record(path, source_root):
    path = Path(path).resolve()
    source_root = Path(source_root).resolve()
    try:
        name = path.relative_to(source_root).as_posix()
    except ValueError:
        name = path.name
    return {"path": name, "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def aggregate_source_sha256(records):
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: item["path"]):
        digest.update(record["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(record["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def build_profile_plan(
    profile,
    build_root,
    vlib,
    vlog,
    vsim,
    include_args,
    source_files,
    model_path,
    testbench,
    clock_half_period_ns,
):
    if profile not in PROFILE_DEFINES:
        raise RuntimeError("unknown direct ModelSim profile: {}".format(profile))
    profile_dir = (Path(build_root) / profile).resolve()
    library = profile_dir / "work"
    library_name = "work"
    compile_sources = list(source_files)
    if profile == "sram":
        compile_sources.append(Path(model_path).resolve())
    compile_sources.append(Path(testbench).resolve())
    defines = [TRACE_DEFINE, PROFILE_DEFINES[profile]]
    return {
        "profile": profile,
        "profile_dir": profile_dir,
        "library": library,
        "library_name": library_name,
        "defines": defines,
        "vlib": list(vlib) + [library_name],
        "compile": list(vlog)
        + ["-sv", "-timescale", "1ns/1ps", "-work", library_name]
        + ["+define+{}".format(define) for define in defines]
        + list(include_args)
        + [str(path) for path in compile_sources],
        "simulate": list(vsim)
        + [
            "-c",
            "-lib",
            library_name,
            "-gBLOCK_COUNT={}".format(BLOCK_COUNT),
            "-gSHORT_BACKPRESSURE=0",
            "-gEXPECT_SCHEDULER_FAILURE=0",
            "-gCLOCK_HALF_PERIOD_NS={:.6f}".format(clock_half_period_ns),
            TOP,
            "-do",
            RUN_DO,
        ],
    }


def run_logged(command, cwd, log_path, timeout_seconds):
    rendered = command_text(command)
    print("command: {}".format(rendered))
    with Path(log_path).open("w", encoding="utf-8") as stream:
        stream.write("command: {}\n".format(rendered))
        stream.flush()
        try:
            returncode = process_control.run_bounded_process(
                [str(item) for item in command],
                Path(cwd),
                stream,
                timeout_seconds,
            )
        except process_control.ProcessTimeoutError as error:
            raise RuntimeError("{}; log={}".format(error, log_path))
    text = Path(log_path).read_text(encoding="utf-8", errors="replace")
    if returncode != 0:
        tail = "\n".join(text.splitlines()[-50:])
        raise RuntimeError("command failed; log={}\n{}".format(log_path, tail))
    return text


def verify_compile_log(text, profile):
    if re.search(
        r"(?im)^.*\*\*\s+(?:Error|Fatal)(?:\s+\([^)]*\))?:", text
    ) or re.search(
        r"(?i)Errors:\s*[1-9]\d*", text
    ):
        raise RuntimeError("{} ModelSim compile log contains errors".format(profile))


def _reject_bad_run_markers(text, profile):
    if re.search(
        r"(?im)^.*\*\*\s+(?:Error|Fatal)(?:\s+\([^)]*\))?:", text
    ):
        raise RuntimeError("{} simulation contains a tool-native error".format(profile))
    if "TIMEOUT tb_mrtc_bounded_axis_multiengine_wrapper" in text:
        raise RuntimeError("{} simulation timed out in the testbench".format(profile))
    if "DIRECT_AXIS_SCHEDULER_LIMIT" in text:
        raise RuntimeError("{} two-block run entered scheduler-limit mode".format(profile))


def parse_profile_trace(text, profile):
    _reject_bad_run_markers(text, profile)
    pass_marker = (
        "PASS tb_mrtc_bounded_axis_multiengine_wrapper blocks={} bp=0".format(
            BLOCK_COUNT
        )
    )
    if text.count(pass_marker) != 1:
        raise RuntimeError(
            "{} simulation must contain exactly one PASS marker".format(profile)
        )

    streams = list(STREAM_RE.finditer(text))
    if len(streams) != 1 or tuple(map(int, streams[0].groups()[:2])) != (
        BLOCK_COUNT,
        0,
    ):
        raise RuntimeError("{} stream summary is missing or malformed".format(profile))

    decoder_markers = list(DECODER_RE.finditer(text))
    expected_decoder = (1, BLOCK_COUNT, BLOCK_COUNT * BLOCK_WORDS)
    if len(decoder_markers) != 1 or tuple(
        map(int, decoder_markers[0].groups())
    ) != expected_decoder:
        raise RuntimeError(
            "{} decoder bit-exact marker is missing or malformed".format(profile)
        )

    memory = {engine: {"req": [], "rsp": []} for engine in range(2)}
    for kind, cycle, engine, address in MEMORY_RE.findall(text):
        engine = int(engine)
        if engine not in memory:
            raise RuntimeError("{} trace contains an invalid engine".format(profile))
        memory[engine][kind].append((int(cycle), int(address)))

    normalized_memory = []
    for engine in range(2):
        requests = memory[engine]["req"]
        responses = memory[engine]["rsp"]
        if len(requests) != BLOCK_WORDS or len(responses) != BLOCK_WORDS:
            raise RuntimeError(
                "{} engine {} requires {}/{} requests/responses, got {}/{}".format(
                    profile,
                    engine,
                    BLOCK_WORDS,
                    BLOCK_WORDS,
                    len(requests),
                    len(responses),
                )
            )
        expected_addresses = list(range(BLOCK_WORDS))
        request_addresses = [item[1] for item in requests]
        response_addresses = [item[1] for item in responses]
        if request_addresses != expected_addresses or response_addresses != expected_addresses:
            raise RuntimeError(
                "{} engine {} read address sequence is not 0..255".format(
                    profile, engine
                )
            )
        if any(
            current[0] - previous[0] != 1
            for previous, current in zip(requests, requests[1:])
        ):
            raise RuntimeError(
                "{} engine {} read request cadence is not II=1".format(
                    profile, engine
                )
            )
        for request, response in zip(requests, responses):
            if response[0] - request[0] != READ_LATENCY_CYCLES:
                raise RuntimeError(
                    "{} engine {} request-to-response latency is not two cycles at addr {}"
                    .format(profile, engine, request[1])
                )
        normalized_memory.append(
            {
                "engine": engine,
                "request_count": BLOCK_WORDS,
                "response_count": BLOCK_WORDS,
                "request_addresses": request_addresses,
                "response_addresses": response_addresses,
                "request_issue_interval_cycles": 1,
                "request_to_response_cycles": READ_LATENCY_CYCLES,
            }
        )

    beat_groups = {packet: [] for packet in range(BLOCK_COUNT)}
    for packet, beat, data, user, last in BEAT_RE.findall(text):
        packet = int(packet)
        if packet not in beat_groups:
            raise RuntimeError("{} trace contains an invalid packet".format(profile))
        if re.search(r"[xXzZ]", data + user):
            raise RuntimeError("{} packet trace contains unknown data".format(profile))
        beat_groups[packet].append(
            {
                "beat": int(beat),
                "data": data.lower(),
                "user": user.lower(),
                "last": int(last),
            }
        )

    packet_markers = {}
    for packet, selected_k, expected_k, beats in PACKET_RE.findall(text):
        packet = int(packet)
        if packet in packet_markers:
            raise RuntimeError("{} has duplicate packet markers".format(profile))
        packet_markers[packet] = {
            "selected_k": int(selected_k),
            "expected_k": int(expected_k),
            "beats": int(beats),
        }
    done_markers = {}
    for _cycle, packet, beats, _fifo in PACKET_DONE_RE.findall(text):
        packet = int(packet)
        if packet in done_markers:
            raise RuntimeError("{} has duplicate packet-done markers".format(profile))
        done_markers[packet] = int(beats)

    if set(packet_markers) != set(range(BLOCK_COUNT)) or set(done_markers) != set(
        range(BLOCK_COUNT)
    ):
        raise RuntimeError("{} packet completion coverage is incomplete".format(profile))

    normalized_packets = []
    for packet in range(BLOCK_COUNT):
        beats = beat_groups[packet]
        if not beats or [entry["beat"] for entry in beats] != list(range(len(beats))):
            raise RuntimeError(
                "{} packet {} beat sequence is incomplete".format(profile, packet)
            )
        marker = packet_markers[packet]
        if marker["beats"] != len(beats) or done_markers[packet] != len(beats):
            raise RuntimeError(
                "{} packet {} beat count markers disagree".format(profile, packet)
            )
        if marker["selected_k"] != marker["expected_k"] or not (
            0 <= marker["selected_k"] <= 15
        ):
            raise RuntimeError("{} packet {} selected-k mismatch".format(profile, packet))
        if len(beats) < 4:
            raise RuntimeError("{} packet {} is shorter than the header".format(profile, packet))
        header_word_1 = int(beats[1]["data"], 16)
        header_k = (header_word_1 >> (11 * 8)) & 0xFF
        if header_k != marker["selected_k"]:
            raise RuntimeError(
                "{} packet {} header selected-k mismatch".format(profile, packet)
            )
        for index, beat in enumerate(beats):
            is_final = index == len(beats) - 1
            if beat["last"] != int(is_final):
                raise RuntimeError(
                    "{} packet {} TLAST is malformed".format(profile, packet)
                )
            user = int(beat["user"], 16)
            if (user & 0xF0) != 0 or (not is_final and user != 0x0F):
                raise RuntimeError(
                    "{} packet {} TUSER sideband is malformed".format(
                        profile, packet
                    )
                )
        normalized_packets.append(
            {
                "packet": packet,
                "selected_k": marker["selected_k"],
                "beat_count": len(beats),
                "beats": beats,
            }
        )

    trace = {
        "schema_version": 1,
        "block_count": BLOCK_COUNT,
        "decoder_bit_exact": True,
        "decoder_blocks": BLOCK_COUNT,
        "decoder_axis_words": BLOCK_COUNT * BLOCK_WORDS,
        "memory_interface": normalized_memory,
        "packets": normalized_packets,
    }
    return {
        "trace": trace,
        "trace_sha256": canonical_sha256(trace),
        "selected_k": [packet["selected_k"] for packet in normalized_packets],
        "packet_beats": [packet["beat_count"] for packet in normalized_packets],
    }


def first_difference(left, right, path="$"):
    if type(left) is not type(right):
        return "{} type differs".format(path)
    if isinstance(left, dict):
        if set(left) != set(right):
            return "{} keys differ".format(path)
        for key in sorted(left):
            difference = first_difference(left[key], right[key], "{}.{}".format(path, key))
            if difference:
                return difference
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return "{} length differs".format(path)
        for index, (left_item, right_item) in enumerate(zip(left, right)):
            difference = first_difference(
                left_item, right_item, "{}[{}]".format(path, index)
            )
            if difference:
                return difference
        return None
    if left != right:
        return "{} differs: {!r} != {!r}".format(path, left, right)
    return None


def compare_profile_traces(register_result, sram_result):
    difference = first_difference(register_result["trace"], sram_result["trace"])
    if difference:
        raise RuntimeError("register/SRAM normalized trace mismatch: {}".format(difference))
    if register_result["trace_sha256"] != sram_result["trace_sha256"]:
        raise RuntimeError("register/SRAM normalized trace SHA256 mismatch")
    return {
        "status": "verified",
        "packet_data": "exact",
        "packet_sideband": "exact",
        "selected_k": "exact",
        "fixed_read_latency_cycles": READ_LATENCY_CYCLES,
        "normalized_trace_sha256": register_result["trace_sha256"],
    }


def _command_record(command):
    return {"argv": [str(item) for item in command], "text": command_text(command)}


def _write_json(path, value):
    Path(path).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _git_head(source_root):
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=str(source_root),
            universal_newlines=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def run_regression(
    source_root,
    filelist,
    testbench,
    sram_model,
    sram_manifest,
    sram_manifest_sha256,
    build_root,
    dry_run=False,
    timeout_seconds=2700,
    clock_half_period_ns=DEFAULT_CLOCK_HALF_PERIOD_NS,
    sram_target_period_ns=DEFAULT_SRAM_TARGET_PERIOD_NS,
    profiles=("register", "sram"),
):
    if timeout_seconds <= 0:
        raise RuntimeError("timeout must be positive")
    if not math.isfinite(clock_half_period_ns) or clock_half_period_ns <= 0.0:
        raise RuntimeError("clock half-period must be finite and positive")
    source_root = Path(source_root).resolve()
    if not (source_root / "rtl/rdtc").is_dir():
        raise RuntimeError("source root does not contain RDTC RTL: {}".format(source_root))
    filelist = Path(filelist).resolve()
    require_within(filelist, source_root, "direct wrapper RTL filelist")
    testbench = Path(testbench).resolve()
    if not testbench.is_file():
        raise RuntimeError("missing direct wrapper testbench: {}".format(testbench))
    require_within(testbench, source_root, "direct wrapper testbench")
    verify_testbench_contract(testbench)
    include_args, source_files = parse_filelist(source_root, filelist)
    verify_filelist_contract(source_root, source_files)
    if isinstance(profiles, str):
        profiles = (profiles,)
    profiles = tuple(profiles)
    if not profiles or len(set(profiles)) != len(profiles) or any(
        profile not in PROFILE_DEFINES for profile in profiles
    ):
        raise RuntimeError("direct ModelSim profile selection is invalid")

    candidate = None
    if "sram" in profiles:
        if not all(
            value is not None and str(value).strip()
            for value in (sram_model, sram_manifest, sram_manifest_sha256)
        ):
            raise RuntimeError(
                "SRAM profile requires model, manifest, and manifest SHA256"
            )
        candidate = admit_sram_candidate(
            sram_model,
            sram_manifest,
            sram_manifest_sha256,
            sram_target_period_ns,
        )
        if clock_half_period_ns <= candidate["model_delay_ns"]:
            raise RuntimeError(
                "functional simulation half-period must exceed OpenRAM DELAY={} ns"
                .format(candidate["model_delay_ns"])
            )

    build_root = require_ignored_build_root(source_root, build_root)
    vlib = resolve_tool("RDTC_TOOL_VLIB", "vlib", dry_run)
    vlog = resolve_tool("RDTC_TOOL_VLOG", "vlog", dry_run)
    vsim = resolve_tool("RDTC_TOOL_VSIM", "vsim", dry_run)
    plans = {
        profile: build_profile_plan(
            profile,
            build_root,
            vlib,
            vlog,
            vsim,
            include_args,
            source_files,
            candidate["model_path"] if candidate is not None else None,
            testbench,
            clock_half_period_ns,
        )
        for profile in profiles
    }
    if set(profiles) == {"register", "sram"} and (
        plans["register"]["library"] == plans["sram"]["library"]
    ):
        raise RuntimeError("register and SRAM ModelSim libraries must be independent")

    source_records = [source_record(filelist, source_root)] + [
        source_record(path, source_root) for path in source_files
    ] + [source_record(testbench, source_root), source_record(SCRIPT_PATH, source_root)]
    source_identity = {
        "git_commit": _git_head(source_root),
        "aggregate_sha256": aggregate_source_sha256(source_records),
        "files": sorted(source_records, key=lambda item: item["path"]),
    }

    if dry_run:
        for profile in profiles:
            print("profile: {}".format(profile))
            for stage in ("vlib", "compile", "simulate"):
                print("{}: {}".format(stage, command_text(plans[profile][stage])))
        print(
            "bounded-direct-modelsim: DRY-RUN profiles={} candidate={} "
            "manifest_sha256={} clock_period_ns={:.6f}".format(
                ",".join(profiles),
                candidate["candidate_id"] if candidate is not None else "not_applicable",
                candidate["manifest_sha256"] if candidate is not None else "not_applicable",
                clock_half_period_ns * 2.0,
            )
        )
        return {
            "status": "dry_run",
            "candidate": candidate,
            "plans": plans,
            "source_identity": source_identity,
        }

    build_root.mkdir(parents=True, exist_ok=True)
    profile_results = {}
    parsed_results = {}
    for profile in profiles:
        plan = plans[profile]
        profile_dir = prepare_profile_directory(
            plan["profile_dir"], build_root, profile
        )
        vlib_log = profile_dir / "vlib.log"
        compile_log = profile_dir / "compile.log"
        run_log = profile_dir / "run.log"
        run_logged(plan["vlib"], profile_dir, vlib_log, timeout_seconds)
        compile_text = run_logged(
            plan["compile"], profile_dir, compile_log, timeout_seconds
        )
        verify_compile_log(compile_text, profile)
        run_text = run_logged(
            plan["simulate"], profile_dir, run_log, timeout_seconds
        )
        parsed = parse_profile_trace(run_text, profile)
        trace_path = profile_dir / "normalized_trace.json"
        _write_json(trace_path, parsed["trace"])
        parsed_results[profile] = parsed
        profile_results[profile] = {
            "define": PROFILE_DEFINES[profile],
            "library": str(plan["library"]),
            "commands": {
                stage: _command_record(plan[stage])
                for stage in ("vlib", "compile", "simulate")
            },
            "logs": {
                "vlib": {"path": str(vlib_log), "sha256": sha256_file(vlib_log)},
                "compile": {
                    "path": str(compile_log),
                    "sha256": sha256_file(compile_log),
                },
                "run": {"path": str(run_log), "sha256": sha256_file(run_log)},
            },
            "normalized_trace": {
                "path": str(trace_path),
                "sha256": sha256_file(trace_path),
                "canonical_sha256": parsed["trace_sha256"],
            },
            "selected_k": parsed["selected_k"],
            "packet_beats": parsed["packet_beats"],
        }

    if set(profiles) == {"register", "sram"}:
        equivalence = compare_profile_traces(
            parsed_results["register"], parsed_results["sram"]
        )
    else:
        only_profile = profiles[0]
        equivalence = {
            "status": "not_applicable_single_profile",
            "profile": only_profile,
            "normalized_trace_sha256": parsed_results[only_profile]["trace_sha256"],
        }
    result = {
        "schema_version": 1,
        "status": "verified",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "testbench": TOP,
        "profiles_requested": list(profiles),
        "block_count": BLOCK_COUNT,
        "functional_clock_period_ns": clock_half_period_ns * 2.0,
        "timing_claim": "not_applicable_behavioral_functional_simulation",
        "source_identity": source_identity,
        "sram_candidate": (
            {
                "candidate_id": candidate["candidate_id"],
                "candidate_contract_sha256": candidate["candidate_contract_sha256"],
                "manifest_path": str(candidate["manifest_path"]),
                "manifest_sha256": candidate["manifest_sha256"],
                "behavioral_verilog_path": str(candidate["model_path"]),
                "behavioral_verilog_sha256": candidate["model_sha256"],
                "behavioral_delay_ns": candidate["model_delay_ns"],
                "target_period_ns": candidate["timing"]["target_period_ns"],
                "target_half_period_ns": candidate["timing"][
                    "target_half_period_ns"
                ],
            }
            if candidate is not None
            else None
        ),
        "profiles": profile_results,
        "equivalence": equivalence,
    }
    manifest_path = build_root / "regression_manifest.json"
    _write_json(manifest_path, result)
    print(
        "bounded-direct-modelsim: PASS trace_sha256={} manifest={}".format(
            equivalence["normalized_trace_sha256"], manifest_path
        )
    )
    return result


def build_argument_parser():
    source_root = SCRIPT_PATH.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(source_root))
    parser.add_argument("--filelist")
    parser.add_argument("--testbench")
    parser.add_argument("--sram-model")
    parser.add_argument("--sram-manifest")
    parser.add_argument("--sram-manifest-sha256")
    parser.add_argument(
        "--sram-target-period-ns",
        type=float,
        default=DEFAULT_SRAM_TARGET_PERIOD_NS,
    )
    parser.add_argument(
        "--profiles",
        choices=("register", "sram", "both"),
        default="both",
    )
    parser.add_argument("--build-dir")
    parser.add_argument("--clock-half-period-ns", type=float, default=DEFAULT_CLOCK_HALF_PERIOD_NS)
    parser.add_argument("--timeout-seconds", type=int, default=2700)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv=None):
    args = build_argument_parser().parse_args(argv)
    source_root = Path(args.root).resolve()
    filelist = (
        Path(args.filelist).resolve()
        if args.filelist
        else source_root / "flows/manifests/rdtc_v1_bounded_direct.f"
    )
    testbench = (
        Path(args.testbench).resolve()
        if args.testbench
        else source_root / "tb/sv/tb_mrtc_bounded_axis_multiengine_wrapper.sv"
    )
    build_root = (
        Path(args.build_dir).resolve()
        if args.build_dir
        else source_root / "build/modelsim/bounded_direct_profile_equivalence"
    )
    run_regression(
        source_root=source_root,
        filelist=filelist,
        testbench=testbench,
        sram_model=args.sram_model,
        sram_manifest=args.sram_manifest,
        sram_manifest_sha256=args.sram_manifest_sha256,
        build_root=build_root,
        dry_run=args.dry_run,
        timeout_seconds=args.timeout_seconds,
        clock_half_period_ns=args.clock_half_period_ns,
        sram_target_period_ns=args.sram_target_period_ns,
        profiles=("register", "sram") if args.profiles == "both" else (args.profiles,),
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("bounded-direct-modelsim: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
