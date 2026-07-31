#!/usr/bin/env python3
"""Create and verify a hash-bound cross-host OpenROAD-to-STA relocation."""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath, PureWindowsPath


SCHEMA_VERSION = 1
KIND = "rdtc_openroad_sta_relocation"
REQUIRED_FINAL_SUFFIXES = ("odb", "v", "sdc", "spef")
REQUIRED_HANDOFF_SUFFIXES = ("v", "sdc", "spef")
REQUIRED_ARTIFACT_ROLES = frozenset(
    [
        "run_contract",
        "source_verification",
        "source_macro_audit",
        "macro_raw",
        "floorplan_contract",
        "metadata",
    ]
    + ["final_" + suffix for suffix in REQUIRED_FINAL_SUFFIXES]
    + ["handoff_" + suffix for suffix in REQUIRED_HANDOFF_SUFFIXES]
)
ECO_RESUME_ROLE = "eco_resume_manifest"


def required_artifact_roles(run_contract):
    roles = set(REQUIRED_ARTIFACT_ROLES)
    if run_contract.get("targeted_electrical_eco") is not None:
        roles.add(ECO_RESUME_ROLE)
    return frozenset(roles)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json_object(path, label):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing {}: {}".format(label, path))
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot read {} {}: {}".format(label, path, error))
    if not isinstance(value, dict):
        raise RuntimeError("{} root must be an object: {}".format(label, path))
    return value


def artifact_record(path, root):
    path = Path(path).resolve()
    root = Path(root).resolve()
    try:
        relative = path.relative_to(root)
    except ValueError:
        raise RuntimeError("relocation artifact escapes its root: {}".format(path))
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("relocation artifact is missing or unsafe: {}".format(path))
    return {
        "path": relative.as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def source_artifact_record(path):
    path = Path(path).resolve()
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("source evidence is missing or unsafe: {}".format(path))
    return {
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(str(temporary), str(path))


def _require_record(record, label):
    if not isinstance(record, dict) or set(record) != {"path", "bytes", "sha256"}:
        raise RuntimeError("{} artifact record is malformed".format(label))
    if not isinstance(record.get("path"), str) or not record["path"]:
        raise RuntimeError("{} artifact path is malformed".format(label))
    if type(record.get("bytes")) is not int or record["bytes"] <= 0:
        raise RuntimeError("{} artifact byte count is malformed".format(label))
    if re.fullmatch(r"[0-9a-f]{64}", str(record.get("sha256", ""))) is None:
        raise RuntimeError("{} artifact SHA256 is malformed".format(label))
    return record


def _require_source_record(record, label):
    if not isinstance(record, dict) or set(record) not in (
        {"path", "sha256"},
        {"path", "bytes", "sha256"},
    ):
        raise RuntimeError("{} source artifact record is malformed".format(label))
    if not isinstance(record.get("path"), str) or not record["path"]:
        raise RuntimeError("{} source artifact path is malformed".format(label))
    if "bytes" in record and (
        type(record["bytes"]) is not int or record["bytes"] <= 0
    ):
        raise RuntimeError("{} source artifact byte count is malformed".format(label))
    if re.fullmatch(r"[0-9a-f]{64}", str(record.get("sha256", ""))) is None:
        raise RuntimeError("{} source artifact SHA256 is malformed".format(label))
    return record


def _source_record_matches(actual, expected, label):
    _require_record(actual, label)
    _require_source_record(expected, label + " source")
    if actual["sha256"] != expected["sha256"] or (
        "bytes" in expected and actual["bytes"] != expected["bytes"]
    ):
        raise RuntimeError("{} source evidence identity mismatch".format(label))


def _source_records_equivalent(left, right, label):
    _require_source_record(left, label + " left")
    _require_source_record(right, label + " right")
    if left["path"] != right["path"] or left["sha256"] != right["sha256"]:
        raise RuntimeError("{} source records differ".format(label))
    if "bytes" in left and "bytes" in right and left["bytes"] != right["bytes"]:
        raise RuntimeError("{} source record byte counts differ".format(label))


def _resolve_local_record(root, record, label):
    _require_record(record, label)
    relative = Path(record["path"])
    if relative.is_absolute():
        raise RuntimeError("{} relocation path must be relative".format(label))
    root = Path(root).resolve()
    unresolved = root / relative
    resolved = unresolved.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        raise RuntimeError("{} relocation path escapes its root".format(label))
    if unresolved.is_symlink() or not resolved.is_file():
        raise RuntimeError("missing or unsafe relocated {}: {}".format(label, resolved))
    actual = {
        "path": record["path"],
        "bytes": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }
    if actual != record:
        raise RuntimeError("relocated {} hash or size mismatch".format(label))
    return resolved


def _is_absolute_source_path(value):
    return PurePosixPath(value).is_absolute() or PureWindowsPath(value).is_absolute()


def _validate_source_evidence(run_contract, verification, macro_audit):
    if run_contract.get("schema_version") != 1:
        raise RuntimeError("source P&R run contract schema mismatch")
    if (
        verification.get("schema_version") != 1
        or verification.get("status") != "PASS"
        or verification.get("scope") != "academic_openroad_route_tool"
    ):
        raise RuntimeError("source OpenROAD verification is not PASS")
    if macro_audit.get("schema_version") != 1 or macro_audit.get("status") != "PASS":
        raise RuntimeError("source direct macro audit is not PASS")

    run_record = _require_source_record(
        verification.get("run_contract"), "source verification run contract"
    )
    macro_run_record = _require_source_record(
        macro_audit.get("run_contract"), "source macro-audit run contract"
    )
    _source_records_equivalent(
        run_record, macro_run_record, "source verification and macro-audit contract"
    )

    floorplan_record = _require_source_record(
        macro_audit.get("floorplan_contract"), "source floorplan contract"
    )
    floorplan = run_contract.get("floorplan")
    if not isinstance(floorplan, dict) or (
        floorplan.get("contract_sha256") != floorplan_record["sha256"]
    ):
        raise RuntimeError("source floorplan is not bound by the P&R contract")

    _require_source_record(macro_audit.get("raw_audit"), "source macro raw audit")
    _require_source_record(verification.get("metadata"), "source OpenROAD metadata")
    final = verification.get("final_artifacts")
    handoff = verification.get("handoff_artifacts")
    if not isinstance(final, dict) or not isinstance(handoff, dict):
        raise RuntimeError("source OpenROAD verification artifact maps are missing")
    for suffix in REQUIRED_FINAL_SUFFIXES:
        _require_source_record(final.get(suffix), "source final " + suffix)
    for suffix in REQUIRED_HANDOFF_SUFFIXES:
        _require_source_record(handoff.get(suffix), "source handoff " + suffix)
    _require_source_record(
        verification.get("direct_macro_placement_audit"),
        "source direct macro audit",
    )
    targeted_eco = run_contract.get("targeted_electrical_eco")
    if targeted_eco is not None:
        if not isinstance(targeted_eco, dict):
            raise RuntimeError("source targeted ECO contract is malformed")
        resume = targeted_eco.get("resume_manifest")
        contract_resume = run_contract.get("inputs", {}).get(
            "direct_electrical_eco_resume_manifest"
        )
        _source_records_equivalent(
            _require_source_record(resume, "source ECO resume manifest"),
            _require_source_record(
                contract_resume, "source ECO resume manifest input"
            ),
            "source ECO resume manifest",
        )


def create_manifest(
    output_path,
    run_contract_path,
    verification_path,
    macro_audit_path,
    macro_raw_path,
    floorplan_contract_path,
):
    output_path = Path(output_path).resolve()
    root = output_path.parent
    run_contract_path = Path(run_contract_path).resolve()
    verification_path = Path(verification_path).resolve()
    macro_audit_path = Path(macro_audit_path).resolve()
    macro_raw_path = Path(macro_raw_path).resolve()
    floorplan_contract_path = Path(floorplan_contract_path).resolve()

    run_contract = read_json_object(run_contract_path, "source P&R run contract")
    verification = read_json_object(
        verification_path, "source OpenROAD verification"
    )
    macro_audit = read_json_object(macro_audit_path, "source direct macro audit")
    _validate_source_evidence(run_contract, verification, macro_audit)

    run_source = source_artifact_record(run_contract_path)
    _source_record_matches(
        run_source, verification["run_contract"], "P&R run contract"
    )
    verification_source = source_artifact_record(verification_path)
    macro_source = source_artifact_record(macro_audit_path)
    _source_record_matches(
        macro_source,
        verification["direct_macro_placement_audit"],
        "direct macro audit",
    )
    _source_record_matches(
        source_artifact_record(macro_raw_path),
        macro_audit["raw_audit"],
        "macro raw audit",
    )
    _source_record_matches(
        source_artifact_record(floorplan_contract_path),
        macro_audit["floorplan_contract"],
        "floorplan contract",
    )

    artifact_paths = {
        "run_contract": run_contract_path,
        "source_verification": verification_path,
        "source_macro_audit": macro_audit_path,
        "macro_raw": macro_raw_path,
        "floorplan_contract": floorplan_contract_path,
        "metadata": Path(verification["metadata"]["path"]),
    }
    for suffix in REQUIRED_FINAL_SUFFIXES:
        artifact_paths["final_" + suffix] = Path(
            verification["final_artifacts"][suffix]["path"]
        )
    for suffix in REQUIRED_HANDOFF_SUFFIXES:
        artifact_paths["handoff_" + suffix] = Path(
            verification["handoff_artifacts"][suffix]["path"]
        )
    if run_contract.get("targeted_electrical_eco") is not None:
        eco_resume = run_contract["inputs"][
            "direct_electrical_eco_resume_manifest"
        ]
        eco_resume_path = Path(eco_resume["path"])
        _source_record_matches(
            source_artifact_record(eco_resume_path),
            eco_resume,
            "ECO resume manifest",
        )
        artifact_paths[ECO_RESUME_ROLE] = eco_resume_path

    artifacts = {
        role: artifact_record(path, root)
        for role, path in sorted(artifact_paths.items())
    }
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "kind": KIND,
        "source_paths": {
            "run_contract": str(run_contract_path),
            "verification": str(verification_path),
            "macro_audit": str(macro_audit_path),
        },
        "source_verification_sha256": verification_source["sha256"],
        "artifacts": artifacts,
    }
    write_json(output_path, manifest)
    return manifest


def verify_manifest(manifest_path):
    manifest_path = Path(manifest_path).resolve()
    root = manifest_path.parent
    manifest = read_json_object(manifest_path, "P&R-to-STA relocation manifest")
    if set(manifest) != {
        "schema_version",
        "kind",
        "source_paths",
        "source_verification_sha256",
        "artifacts",
    }:
        raise RuntimeError("P&R-to-STA relocation manifest fields are malformed")
    if manifest.get("schema_version") != SCHEMA_VERSION or manifest.get("kind") != KIND:
        raise RuntimeError("P&R-to-STA relocation manifest identity mismatch")
    source_paths = manifest.get("source_paths")
    if not isinstance(source_paths, dict) or set(source_paths) != {
        "run_contract",
        "verification",
        "macro_audit",
    }:
        raise RuntimeError("P&R-to-STA source path records are malformed")
    if not all(
        isinstance(value, str) and _is_absolute_source_path(value)
        for value in source_paths.values()
    ):
        raise RuntimeError("P&R-to-STA source paths must be absolute")
    expected_verification_sha = str(manifest.get("source_verification_sha256", ""))
    if re.fullmatch(r"[0-9a-f]{64}", expected_verification_sha) is None:
        raise RuntimeError("source OpenROAD verification SHA256 is malformed")

    records = manifest.get("artifacts")
    if not isinstance(records, dict) or not REQUIRED_ARTIFACT_ROLES.issubset(records):
        raise RuntimeError("P&R-to-STA relocation artifact role set is incomplete")
    paths = {
        role: _resolve_local_record(root, record, role)
        for role, record in sorted(records.items())
    }

    run_contract = read_json_object(paths["run_contract"], "relocated run contract")
    if set(records) != required_artifact_roles(run_contract):
        raise RuntimeError("P&R-to-STA relocation artifact role set is incomplete")
    verification = read_json_object(
        paths["source_verification"], "relocated source verification"
    )
    macro_audit = read_json_object(
        paths["source_macro_audit"], "relocated source macro audit"
    )
    _validate_source_evidence(run_contract, verification, macro_audit)
    if records["source_verification"]["sha256"] != expected_verification_sha:
        raise RuntimeError("source OpenROAD verification hash binding mismatch")
    if verification["run_contract"]["path"] != source_paths["run_contract"]:
        raise RuntimeError("source run-contract path binding mismatch")
    if verification["direct_macro_placement_audit"]["path"] != source_paths["macro_audit"]:
        raise RuntimeError("source macro-audit path binding mismatch")

    expected_records = {
        "run_contract": verification["run_contract"],
        "source_macro_audit": verification["direct_macro_placement_audit"],
        "macro_raw": macro_audit["raw_audit"],
        "floorplan_contract": macro_audit["floorplan_contract"],
        "metadata": verification["metadata"],
    }
    for suffix in REQUIRED_FINAL_SUFFIXES:
        expected_records["final_" + suffix] = verification["final_artifacts"][suffix]
    for suffix in REQUIRED_HANDOFF_SUFFIXES:
        expected_records["handoff_" + suffix] = verification["handoff_artifacts"][suffix]
    if run_contract.get("targeted_electrical_eco") is not None:
        expected_records[ECO_RESUME_ROLE] = run_contract["inputs"][
            "direct_electrical_eco_resume_manifest"
        ]
    for role, expected in sorted(expected_records.items()):
        _source_record_matches(records[role], expected, role)

    return {
        "status": "PASS",
        "manifest_path": str(manifest_path),
        "manifest_sha256": sha256_file(manifest_path),
        "source_paths": source_paths,
        "paths": {role: str(path) for role, path in sorted(paths.items())},
        "run_contract": run_contract,
        "source_verification": verification,
        "source_macro_audit": macro_audit,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command")
    create = subparsers.add_parser("create")
    create.add_argument("--output", required=True, type=Path)
    create.add_argument("--run-contract", required=True, type=Path)
    create.add_argument("--verification", required=True, type=Path)
    create.add_argument("--macro-audit", required=True, type=Path)
    create.add_argument("--macro-raw", required=True, type=Path)
    create.add_argument("--floorplan-contract", required=True, type=Path)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    if args.command is None:
        parser.error("a command is required")

    if args.command == "create":
        result = create_manifest(
            args.output,
            args.run_contract,
            args.verification,
            args.macro_audit,
            args.macro_raw,
            args.floorplan_contract,
        )
        print(
            "pnr-sta-relocation: CREATED roles={} output={}".format(
                len(result["artifacts"]), args.output.resolve()
            )
        )
    else:
        result = verify_manifest(args.manifest)
        print(
            "pnr-sta-relocation: PASS contract_sha256={} manifest={}".format(
                result["source_verification"]["run_contract"]["sha256"],
                result["manifest_path"],
            )
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("pnr-sta-relocation: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
