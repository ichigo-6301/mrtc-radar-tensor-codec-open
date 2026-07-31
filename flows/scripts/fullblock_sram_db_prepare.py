#!/usr/bin/env python3
"""Compile the admitted full-block 1RW32 OpenRAM Liberty into a pinned DB."""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath


SCHEMA_VERSION = 1
EXPECTED_MACRO = "mrtc_rdtc_block_1rw_256x32"
EXPECTED_CONTRACT_SHA256 = (
    "4689e7b95ce64241368a1bb8f85e168854f8d98a72fc72b20ce065f663f445d0"
)
EXPECTED_SOURCE_MANIFEST_SHA256 = (
    "2f7a0e17f716e55d5e013d025d67983f1a7afccd23673f038653096ecc17630f"
)
EXPECTED_VIEW_SHA256 = {
    "verilog": "6218847fa319b571f7885715e56c9e8fa1bb646b322899cdf8de7934b1d09f46",
    "liberty": "72ba430fb75a09e0db454071a0fbdc15a4451259b62b360583740f5d47958bb3",
    "lef": "84d1a7621d890222d89fff9bf7030d43ec9e25e12bf3e74d58df25447bb4a2d3",
    "gds": "3cc59d0f5411af49996fef579e662f8c6877e2495489865fa50043a8e6fb03e4",
    "spice": "2d52eac378d1964cef5563756bf6e67dc2ec69c87ec9c225b484e0c16035d090",
}

SCRIPT_PATH = Path(__file__).resolve()
FLOW_ROOT = SCRIPT_PATH.parent.parent
DEFAULT_COMPILE_TCL = FLOW_ROOT / "memory" / "openram" / "compile_lib.tcl"
DERIVED_MANIFEST_NAME = "fullblock_sram_db_manifest.json"
OPTIONAL_LC_AUXILIARY_LOGS = {
    "command": "lc_command.log",
    "output": "lc_output.txt",
}


class PreparationError(RuntimeError):
    """A fail-closed source, tool, compilation, or cache error."""


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(payload):
    return hashlib.sha256(payload).hexdigest()


def canonical_sha256(payload):
    encoded = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return sha256_bytes(encoded)


def write_json(path, payload):
    with Path(path).open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")


def require_regular_file(path, label):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        raise PreparationError("missing or non-regular {}: {}".format(label, path))
    return path


def is_within(path, root):
    try:
        return os.path.commonpath((str(Path(path).resolve()), str(Path(root).resolve()))) == str(
            Path(root).resolve()
        )
    except ValueError:
        return False


def resolve_manifest(candidate):
    candidate = Path(candidate).expanduser().resolve()
    manifest = candidate / "candidate_manifest.json" if candidate.is_dir() else candidate
    manifest = require_regular_file(manifest, "candidate manifest")
    return manifest.parent.resolve(), manifest.resolve()


def resolve_view(candidate_root, record, role):
    if not isinstance(record, dict):
        raise PreparationError("candidate {} record is not an object".format(role))
    relative = record.get("path")
    if not isinstance(relative, str) or not relative:
        raise PreparationError("candidate {} record has no relative path".format(role))
    if "\\" in relative:
        raise PreparationError("candidate {} path must use '/' separators".format(role))
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise PreparationError("candidate {} path escapes the candidate".format(role))
    path = (candidate_root / Path(*pure.parts)).resolve()
    if not is_within(path, candidate_root):
        raise PreparationError("candidate {} path escapes the candidate".format(role))
    return require_regular_file(path, "{} view".format(role))


def require_equal(actual, expected, label):
    if actual != expected:
        raise PreparationError(
            "{} {} does not match approved {}".format(label, actual, expected)
        )


def validate_candidate(candidate):
    candidate_root, manifest_path = resolve_manifest(candidate)
    manifest_sha256 = sha256_file(manifest_path)
    require_equal(
        manifest_sha256,
        EXPECTED_SOURCE_MANIFEST_SHA256,
        "source manifest SHA256",
    )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PreparationError("cannot parse candidate manifest: {}".format(error))
    if not isinstance(manifest, dict):
        raise PreparationError("candidate manifest root is not an object")

    require_equal(manifest.get("schema_version"), 2, "candidate schema version")
    require_equal(manifest.get("status"), "generated_and_audited", "candidate status")
    require_equal(
        manifest.get("maturity"),
        "fully_characterized_candidate",
        "candidate maturity",
    )
    require_equal(manifest.get("phase"), "full", "candidate phase")
    require_equal(
        manifest.get("candidate_contract_sha256"),
        EXPECTED_CONTRACT_SHA256,
        "candidate contract SHA256",
    )

    contract = manifest.get("candidate_contract")
    if not isinstance(contract, dict):
        raise PreparationError("candidate contract is missing")
    require_equal(contract.get("macro"), EXPECTED_MACRO, "candidate macro")
    require_equal(
        contract.get("candidate_contract_sha256"),
        EXPECTED_CONTRACT_SHA256,
        "embedded candidate contract SHA256",
    )
    require_equal(contract.get("candidate_id"), "block-256x32-wpr4", "candidate id")
    require_equal(contract.get("role"), "full_block_1rw32_candidate", "candidate role")
    organization = contract.get("organization")
    expected_organization = {
        "address_width": 8,
        "columns": 128,
        "num_words": 256,
        "rows": 64,
        "word_size": 32,
        "words_per_row": 4,
    }
    require_equal(organization, expected_organization, "candidate organization")
    ports = contract.get("ports")
    if not isinstance(ports, dict):
        raise PreparationError("candidate port contract is missing")
    require_equal(ports.get("num_rw_ports"), 1, "candidate read/write port count")
    require_equal(ports.get("num_r_ports"), 0, "candidate read-only port count")
    require_equal(ports.get("num_w_ports"), 0, "candidate write-only port count")
    require_equal(ports.get("clock_pins"), ["clk0"], "candidate clock pins")

    database = manifest.get("database")
    if not isinstance(database, dict):
        raise PreparationError("candidate database gate is missing")
    require_equal(database.get("allowed"), True, "candidate database admission")
    require_equal(database.get("status"), "not_compiled", "candidate database status")
    model_gate = manifest.get("model_gate")
    if not isinstance(model_gate, dict):
        raise PreparationError("candidate model gate is missing")
    require_equal(model_gate.get("rtl_32x4_allowed"), True, "1RW32X4 RTL gate")
    require_equal(model_gate.get("supports_450mhz"), True, "450 MHz model gate")

    files = manifest.get("files")
    if not isinstance(files, dict):
        raise PreparationError("candidate files map is missing")
    require_equal(set(files), set(EXPECTED_VIEW_SHA256), "candidate view roles")
    view_paths = {}
    view_records = {}
    for role in sorted(EXPECTED_VIEW_SHA256):
        record = files[role]
        path = resolve_view(candidate_root, record, role)
        actual_sha256 = sha256_file(path)
        require_equal(record.get("sha256"), actual_sha256, "recorded {} SHA256".format(role))
        require_equal(
            actual_sha256,
            EXPECTED_VIEW_SHA256[role],
            "{} SHA256".format(role),
        )
        require_equal(record.get("bytes"), path.stat().st_size, "{} byte count".format(role))
        view_paths[role] = path
        view_records[role] = {
            "path": record["path"],
            "bytes": path.stat().st_size,
            "sha256": actual_sha256,
        }

    verilog_text = view_paths["verilog"].read_text(encoding="utf-8", errors="replace")
    liberty_text = view_paths["liberty"].read_text(encoding="utf-8", errors="replace")
    lef_text = view_paths["lef"].read_text(encoding="utf-8", errors="replace")
    spice_text = view_paths["spice"].read_text(encoding="utf-8", errors="replace")
    if not re.search(r"\bmodule\s+{}\b".format(re.escape(EXPECTED_MACRO)), verilog_text):
        raise PreparationError("Verilog view does not declare the approved macro")
    if not re.search(r"\bcell\s*\(\s*{}\s*\)".format(re.escape(EXPECTED_MACRO)), liberty_text):
        raise PreparationError("Liberty view does not declare the approved macro")
    if not re.search(r"\bMACRO\s+{}\b".format(re.escape(EXPECTED_MACRO)), lef_text):
        raise PreparationError("LEF view does not declare the approved macro")
    if not re.search(
        r"(?im)^\s*\.subckt\s+{}(?:\s|$)".format(re.escape(EXPECTED_MACRO)),
        spice_text,
    ):
        raise PreparationError("SPICE view does not declare the approved macro")
    library_match = re.search(r"\blibrary\s*\(\s*([^\s)]+)\s*\)", liberty_text)
    if not library_match:
        raise PreparationError("Liberty view has no library declaration")
    library_name = library_match.group(1).strip('"')

    return {
        "candidate_root": candidate_root,
        "manifest_path": manifest_path,
        "manifest_sha256": manifest_sha256,
        "manifest": manifest,
        "contract": contract,
        "view_paths": view_paths,
        "view_records": view_records,
        "library_name": library_name,
    }


def validate_compile_tcl(path):
    path = require_regular_file(Path(path).expanduser().resolve(), "Library Compiler Tcl")
    text = path.read_text(encoding="utf-8", errors="replace")
    for token in (
        "RDTC_SRAM_LIB",
        "RDTC_SRAM_LIB_NAME",
        "RDTC_SRAM_DB",
        "read_lib",
        "write_lib",
    ):
        if token not in text:
            raise PreparationError("Library Compiler Tcl is missing {}".format(token))
    return path


def resolve_lc_command(command):
    if not command:
        raise PreparationError("empty lc_shell command")
    command = [str(item) for item in command]
    executable = shutil.which(command[0])
    if executable is None and Path(command[0]).is_file():
        executable = str(Path(command[0]).absolute())
    if executable is None:
        raise PreparationError("lc_shell executable not found: {}".format(command[0]))
    launcher = Path(executable).expanduser().absolute()
    if not launcher.is_file():
        raise PreparationError("missing lc_shell launcher: {}".format(launcher))
    executable_target = require_regular_file(
        launcher.resolve(), "lc_shell executable target"
    )
    resolved = [str(launcher)] + command[1:]
    command_files = []
    for index, item in enumerate(resolved[1:], start=1):
        candidate = Path(item).expanduser()
        if candidate.is_file():
            candidate = require_regular_file(candidate.resolve(), "lc_shell command file")
            resolved[index] = str(candidate)
            command_files.append(
                {
                    "argument_index": index,
                    "name": candidate.name,
                    "sha256": sha256_file(candidate),
                }
            )
    return resolved, {
        "command": [launcher.name] + [Path(item).name if Path(item).is_file() else item for item in resolved[1:]],
        "executable": launcher.name,
        "executable_sha256": sha256_file(executable_target),
        "command_files": command_files,
    }


def run_owned_process(command, cwd, environment, timeout_seconds, log_path=None):
    stream = None
    popen_kwargs = {
        "cwd": str(cwd),
        "env": environment,
        "stderr": subprocess.STDOUT,
        "start_new_session": os.name != "nt",
    }
    if os.name == "nt":
        popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    if log_path is None:
        popen_kwargs["stdout"] = subprocess.PIPE
    else:
        stream = Path(log_path).open("wb")
        popen_kwargs["stdout"] = stream
    try:
        process = subprocess.Popen([str(item) for item in command], **popen_kwargs)
        try:
            output, _ = process.communicate(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                process.terminate()
            else:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                raise PreparationError(
                    "owned process did not exit within 30 seconds after SIGTERM: {}".format(
                        command[0]
                    )
                )
            raise PreparationError(
                "owned process exceeded {} seconds and was terminated: {}".format(
                    timeout_seconds, command[0]
                )
            )
        return process.returncode, output or b""
    except OSError as error:
        raise PreparationError("cannot execute {}: {}".format(command[0], error))
    finally:
        if stream is not None:
            stream.close()


def identify_lc(command, descriptor, cwd, environment, timeout_seconds):
    returncode, output = run_owned_process(
        command + ["-version"], cwd, environment, timeout_seconds
    )
    if returncode != 0:
        raise PreparationError("lc_shell -version failed with exit code {}".format(returncode))
    normalized = output.decode("utf-8", errors="replace").replace("\r\n", "\n").strip()
    if not normalized:
        raise PreparationError("lc_shell -version returned no version text")
    if len(normalized.encode("utf-8")) > 65536:
        raise PreparationError("lc_shell -version output exceeds 64 KiB")
    identified = dict(descriptor)
    identified["version"] = normalized
    identified["version_sha256"] = sha256_bytes((normalized + "\n").encode("utf-8"))
    return identified


def build_identity(audit, compile_tcl, lc_identity):
    return {
        "schema_version": SCHEMA_VERSION,
        "macro": EXPECTED_MACRO,
        "source_manifest_sha256": audit["manifest_sha256"],
        "candidate_contract_sha256": EXPECTED_CONTRACT_SHA256,
        "views": audit["view_records"],
        "runner": {
            "path": "flows/scripts/{}".format(SCRIPT_PATH.name),
            "sha256": sha256_file(SCRIPT_PATH),
        },
        "compile_tcl": {
            "path": "flows/memory/openram/{}".format(compile_tcl.name),
            "sha256": sha256_file(compile_tcl),
        },
        "library_compiler": lc_identity,
    }


def resolve_output_file(output_dir, relative, label):
    if not isinstance(relative, str) or not relative:
        raise PreparationError("cached {} path is invalid".format(label))
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or len(pure.parts) != 1:
        raise PreparationError("cached {} path escapes the output directory".format(label))
    path = (output_dir / pure.name).resolve()
    if not is_within(path, output_dir):
        raise PreparationError("cached {} path escapes the output directory".format(label))
    return require_regular_file(path, "cached {}".format(label))


def validate_cached_output(output_dir, identity):
    manifest_path = require_regular_file(
        output_dir / DERIVED_MANIFEST_NAME, "derived DB manifest"
    )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PreparationError("cannot parse derived DB manifest: {}".format(error))
    require_equal(manifest.get("schema_version"), SCHEMA_VERSION, "derived schema version")
    require_equal(manifest.get("status"), "compiled_and_audited", "derived status")
    require_equal(manifest.get("macro"), EXPECTED_MACRO, "derived macro")
    require_equal(manifest.get("cache_identity"), identity, "cache identity")
    require_equal(
        manifest.get("cache_identity_sha256"),
        canonical_sha256(identity),
        "cache identity SHA256",
    )
    database = manifest.get("database")
    log = manifest.get("log")
    if not isinstance(database, dict) or not isinstance(log, dict):
        raise PreparationError("derived manifest has no database or log record")
    db_path = resolve_output_file(output_dir, database.get("path"), "DB")
    log_path = resolve_output_file(output_dir, log.get("path"), "LC log")
    require_equal(database.get("bytes"), db_path.stat().st_size, "cached DB byte count")
    require_equal(database.get("sha256"), sha256_file(db_path), "cached DB SHA256")
    require_equal(log.get("bytes"), log_path.stat().st_size, "cached LC log byte count")
    require_equal(log.get("sha256"), sha256_file(log_path), "cached LC log SHA256")
    auxiliary_logs = manifest.get("auxiliary_logs", {})
    if not isinstance(auxiliary_logs, dict) or not set(auxiliary_logs).issubset(
        OPTIONAL_LC_AUXILIARY_LOGS
    ):
        raise PreparationError("derived manifest has invalid LC auxiliary logs")
    auxiliary_names = set()
    for role, record in sorted(auxiliary_logs.items()):
        if not isinstance(record, dict):
            raise PreparationError(
                "cached LC auxiliary {} record is malformed".format(role)
            )
        auxiliary_path = resolve_output_file(
            output_dir, record.get("path"), "LC auxiliary {}".format(role)
        )
        require_equal(
            auxiliary_path.name,
            OPTIONAL_LC_AUXILIARY_LOGS[role],
            "cached LC auxiliary {} name".format(role),
        )
        require_equal(
            record.get("bytes"),
            auxiliary_path.stat().st_size,
            "cached LC auxiliary {} byte count".format(role),
        )
        require_equal(
            record.get("sha256"),
            sha256_file(auxiliary_path),
            "cached LC auxiliary {} SHA256".format(role),
        )
        auxiliary_names.add(auxiliary_path.name)
    expected_names = {
        DERIVED_MANIFEST_NAME,
        db_path.name,
        log_path.name,
    } | auxiliary_names
    actual_names = {path.name for path in output_dir.iterdir()}
    require_equal(actual_names, expected_names, "cached output files")
    return manifest


def collect_lc_auxiliary_logs(directory):
    directory = Path(directory)
    records = {}
    for role, name in sorted(OPTIONAL_LC_AUXILIARY_LOGS.items()):
        path = directory / name
        if not path.exists():
            continue
        path = require_regular_file(
            path, "Library Compiler auxiliary {} log".format(role)
        )
        records[role] = {
            "path": path.name,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
    return records


def ensure_disjoint_output(candidate_root, output_dir):
    if is_within(output_dir, candidate_root):
        raise PreparationError("output directory must not be inside the source candidate")
    if is_within(candidate_root, output_dir):
        raise PreparationError("output directory must not contain the source candidate")


def prepare(
    candidate,
    output_dir,
    lc_command,
    dry_run=False,
    compile_tcl=DEFAULT_COMPILE_TCL,
    environment=None,
    compile_timeout_seconds=1800,
    version_timeout_seconds=60,
    display_name="fullblock-sram-db-prepare",
):
    if compile_timeout_seconds <= 0 or version_timeout_seconds <= 0:
        raise PreparationError("process timeouts must be positive")
    audit = validate_candidate(candidate)
    compile_tcl = validate_compile_tcl(compile_tcl)
    output_dir = Path(output_dir).expanduser().resolve()
    ensure_disjoint_output(audit["candidate_root"], output_dir)
    command_text = " ".join(shlex.quote(str(item)) for item in lc_command)
    if dry_run:
        print("{}: DRY-RUN".format(display_name))
        print("candidate_manifest={}".format(audit["manifest_path"]))
        print("source_manifest_sha256={}".format(audit["manifest_sha256"]))
        print("output_dir={}".format(output_dir))
        print("command={} -f {}".format(command_text, compile_tcl))
        return {"status": "dry_run", "source_manifest_sha256": audit["manifest_sha256"]}

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ if environment is None else environment)
    resolved_command, command_descriptor = resolve_lc_command(lc_command)
    lc_identity = identify_lc(
        resolved_command,
        command_descriptor,
        output_dir.parent,
        environment,
        version_timeout_seconds,
    )
    identity = build_identity(audit, compile_tcl, lc_identity)
    if output_dir.exists():
        if not output_dir.is_dir():
            raise PreparationError("output path exists and is not a directory: {}".format(output_dir))
        try:
            manifest = validate_cached_output(output_dir, identity)
        except PreparationError as error:
            raise PreparationError(
                "existing output is not an exact cache hit: {}".format(error)
            )
        print("{}: CACHE-HIT manifest={}".format(display_name,
            output_dir / DERIVED_MANIFEST_NAME
        ))
        return {"status": "cache_hit", "manifest": manifest}

    staging = Path(
        tempfile.mkdtemp(
            prefix=".{}.tmp-".format(output_dir.name), dir=str(output_dir.parent)
        )
    ).resolve()
    db_path = staging / (EXPECTED_MACRO + ".db")
    log_path = staging / "lc.log"
    compile_environment = dict(environment)
    compile_environment.update(
        {
            "RDTC_SRAM_LIB": str(audit["view_paths"]["liberty"]),
            "RDTC_SRAM_LIB_NAME": audit["library_name"],
            "RDTC_SRAM_DB": str(db_path),
        }
    )
    returncode, _ = run_owned_process(
        resolved_command + ["-f", str(compile_tcl)],
        staging,
        compile_environment,
        compile_timeout_seconds,
        log_path,
    )
    if returncode != 0:
        raise PreparationError(
            "Library Compiler failed with exit code {}; partial output={}".format(
                returncode, staging
            )
        )
    db_path = require_regular_file(db_path, "compiled SRAM DB")
    log_path = require_regular_file(log_path, "Library Compiler log")
    auxiliary_logs = collect_lc_auxiliary_logs(staging)

    final_audit = validate_candidate(candidate)
    if final_audit["manifest_sha256"] != audit["manifest_sha256"] or final_audit[
        "view_records"
    ] != audit["view_records"]:
        raise PreparationError("source candidate identity changed during DB compilation")
    if sha256_file(SCRIPT_PATH) != identity["runner"]["sha256"]:
        raise PreparationError("runner changed during DB compilation")
    if sha256_file(compile_tcl) != identity["compile_tcl"]["sha256"]:
        raise PreparationError("Library Compiler Tcl changed during DB compilation")
    _, final_command_descriptor = resolve_lc_command(lc_command)
    for field in ("command", "executable", "executable_sha256", "command_files"):
        if final_command_descriptor[field] != lc_identity[field]:
            raise PreparationError("lc_shell command identity changed during DB compilation")

    derived_manifest = {
        "schema_version": SCHEMA_VERSION,
        "status": "compiled_and_audited",
        "macro": EXPECTED_MACRO,
        "source": {
            "manifest": audit["manifest_path"].name,
            "manifest_sha256": audit["manifest_sha256"],
            "candidate_id": audit["contract"]["candidate_id"],
            "candidate_contract_sha256": EXPECTED_CONTRACT_SHA256,
            "phase": audit["manifest"]["phase"],
            "maturity": audit["manifest"]["maturity"],
        },
        "views": audit["view_records"],
        "database": {
            "path": db_path.name,
            "bytes": db_path.stat().st_size,
            "sha256": sha256_file(db_path),
        },
        "log": {
            "path": log_path.name,
            "bytes": log_path.stat().st_size,
            "sha256": sha256_file(log_path),
        },
        "auxiliary_logs": auxiliary_logs,
        "library_compiler": lc_identity,
        "runner": identity["runner"],
        "compile_tcl": identity["compile_tcl"],
        "cache_identity": identity,
        "cache_identity_sha256": canonical_sha256(identity),
    }
    manifest_path = staging / DERIVED_MANIFEST_NAME
    write_json(manifest_path, derived_manifest)
    validate_cached_output(staging, identity)
    try:
        staging.rename(output_dir)
    except OSError as error:
        raise PreparationError(
            "cannot publish derived DB directory atomically; staging={}: {}".format(
                staging, error
            )
        )
    validate_cached_output(output_dir, identity)
    print("{}: PASS manifest={}".format(display_name,
        output_dir / DERIVED_MANIFEST_NAME
    ))
    return {"status": "compiled", "manifest": derived_manifest}


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate",
        "--candidate-dir",
        "--candidate-manifest",
        required=True,
        help="approved candidate directory or its candidate_manifest.json",
    )
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--lc-shell",
        default=os.environ.get("RDTC_TOOL_LC", "lc_shell"),
        help="Library Compiler executable",
    )
    parser.add_argument(
        "--lc-shell-arg",
        action="append",
        default=[],
        help="argument placed before -version/-f; repeat for wrappers",
    )
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
        dry_run=args.dry_run,
        compile_timeout_seconds=args.compile_timeout_seconds,
        version_timeout_seconds=args.version_timeout_seconds,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PreparationError as error:
        print("fullblock-sram-db-prepare: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
