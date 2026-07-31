#!/usr/bin/env python3
"""Verify final-ODB block macro placement against the direct ASIC contract."""

import argparse
import hashlib
import json
import math
import os
import re
import sys
from pathlib import Path


DIRECT_RING_MACRO = "mrtc_rdtc_bounded_ring_1rw_32x128"
DIRECT_INSTANCE_RE = re.compile(
    r"g_engine(?:\\)?\[([01])(?:\\)?\].*"
    r"g_way(?:\\)?\[([0-3])(?:\\)?\].*u_sram$"
)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json_object(path, label):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing {}: {}".format(label, path))
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot read {} {}: {}".format(label, path, error))
    if not isinstance(value, dict):
        raise RuntimeError("{} root must be an object".format(label))
    return value


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(str(temporary), str(path))


def parse_raw_audit(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing final-ODB macro audit: {}".format(path))
    schema_version = None
    dbu_per_micron = None
    reported_count = None
    reported_eco_count = None
    records = []
    eco_records = []
    eco_connections = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8", errors="strict").splitlines(), 1
    ):
        fields = raw_line.split("\t")
        if fields[0] == "schema_version" and len(fields) == 2:
            schema_version = fields[1]
        elif fields[0] == "dbu_per_micron" and len(fields) == 2:
            dbu_per_micron = fields[1]
        elif fields[0] == "macro_count" and len(fields) == 2:
            reported_count = fields[1]
        elif fields[0] == "eco_buffer_count" and len(fields) == 2:
            reported_eco_count = fields[1]
        elif fields[0] == "macro" and len(fields) == 9:
            try:
                coordinates = [int(value) for value in fields[3:7]]
            except ValueError:
                raise RuntimeError(
                    "nonnumeric macro bbox at raw audit line {}".format(line_number)
                )
            records.append(
                {
                    "instance": fields[1],
                    "master": fields[2],
                    "x_min_dbu": coordinates[0],
                    "y_min_dbu": coordinates[1],
                    "x_max_dbu": coordinates[2],
                    "y_max_dbu": coordinates[3],
                    "orientation": fields[7],
                    "placement_status": fields[8],
                }
            )
        elif fields[0] == "eco_buffer" and len(fields) in (8, 10):
            try:
                coordinates = [int(value) for value in fields[3:7]]
            except ValueError:
                raise RuntimeError(
                    "nonnumeric ECO buffer bbox at raw audit line {}".format(
                        line_number
                    )
                )
            record = {
                "instance": fields[1],
                "master": fields[2],
                "x_min_dbu": coordinates[0],
                "y_min_dbu": coordinates[1],
                "x_max_dbu": coordinates[2],
                "y_max_dbu": coordinates[3],
                "placement_status": fields[7],
            }
            if len(fields) == 10:
                record.update({"a_net": fields[8], "z_net": fields[9]})
            eco_records.append(record)
        elif fields[0] == "eco_connection" and len(fields) == 9:
            if fields[2] not in ("A", "Z") or fields[4] not in (
                "iterm",
                "bterm",
            ):
                raise RuntimeError(
                    "invalid ECO connection at raw audit line {}".format(
                        line_number
                    )
                )
            eco_connections.append(
                {
                    "buffer_instance": fields[1],
                    "buffer_port": fields[2],
                    "net": fields[3],
                    "endpoint_kind": fields[4],
                    "endpoint_instance": fields[5],
                    "endpoint_pin": fields[6],
                    "endpoint_master": fields[7],
                    "endpoint_io_type": fields[8],
                }
            )
        else:
            raise RuntimeError(
                "malformed final-ODB macro audit line {}".format(line_number)
            )
    if schema_version not in ("1", "2"):
        raise RuntimeError("unsupported final-ODB macro audit schema")
    if schema_version == "1" and eco_connections:
        raise RuntimeError("schema-1 final-ODB audit cannot contain ECO connections")
    try:
        dbu_per_micron = int(dbu_per_micron)
        reported_count = int(reported_count)
        reported_eco_count = (
            0 if reported_eco_count is None else int(reported_eco_count)
        )
    except (TypeError, ValueError):
        raise RuntimeError("final-ODB macro audit summary is malformed")
    if dbu_per_micron <= 0 or reported_count < 0 or reported_eco_count < 0:
        raise RuntimeError("final-ODB macro audit summary is invalid")
    if reported_count != len(records):
        raise RuntimeError("final-ODB macro audit count does not match its records")
    if reported_eco_count != len(eco_records):
        raise RuntimeError(
            "final-ODB ECO buffer audit count does not match its records"
        )
    eco_by_instance = {}
    for record in eco_records:
        instance = record["instance"]
        if instance in eco_by_instance:
            raise RuntimeError("duplicate final-ODB ECO buffer record")
        record["connections"] = []
        eco_by_instance[instance] = record
    for connection in eco_connections:
        record = eco_by_instance.get(connection["buffer_instance"])
        if record is None:
            raise RuntimeError("ECO connection references an unknown buffer")
        record["connections"].append(connection)
    for record in eco_records:
        record["connections"] = sorted(
            record["connections"],
            key=lambda item: (
                item["buffer_port"],
                item["endpoint_kind"],
                item["endpoint_instance"],
                item["endpoint_pin"],
            ),
        )
    return int(schema_version), dbu_per_micron, records, eco_records


def _microns(value, dbu_per_micron):
    return float(value) / float(dbu_per_micron)


def _canonical_odb_name(value):
    value = str(value)
    while True:
        normalized = re.sub(r"\\([\\/\[\]])", r"\1", value)
        if normalized == value:
            return normalized
        value = normalized


def _match_eco_target(expected_eco, instance):
    canonical_instance = _canonical_odb_name(instance)
    leaf = canonical_instance.rsplit("/", 1)[-1]
    matches = [
        (buffer_name, target)
        for buffer_name, target in expected_eco.items()
        if re.fullmatch(re.escape(buffer_name) + r"\d*", leaf)
    ]
    if len(matches) != 1:
        raise RuntimeError(
            "unexpected or ambiguous direct SRAM ECO buffer {}".format(instance)
        )
    return matches[0][0], matches[0][1], canonical_instance


def _verify_eco_connectivity(record, target, buffer_cell, macro_cell):
    if "a_net" not in record or "z_net" not in record:
        raise RuntimeError("targeted ECO requires schema-2 A/Z net records")
    if not record["a_net"] or not record["z_net"] or record["a_net"] == record["z_net"]:
        raise RuntimeError("direct SRAM ECO buffer A/Z nets are malformed")
    by_port = {"A": [], "Z": []}
    for connection in record.get("connections", []):
        port = connection["buffer_port"]
        expected_net = record["a_net"] if port == "A" else record["z_net"]
        if connection["net"] != expected_net:
            raise RuntimeError("direct SRAM ECO connection/net binding mismatch")
        by_port[port].append(connection)
    if not by_port["A"] or not by_port["Z"]:
        raise RuntimeError("direct SRAM ECO A/Z connectivity is incomplete")

    def endpoint_key(connection):
        return (
            connection["endpoint_kind"],
            _canonical_odb_name(connection["endpoint_instance"]),
            connection["endpoint_pin"],
            connection["endpoint_master"],
            connection["endpoint_io_type"],
        )

    endpoint_sets = {}
    for port, connections in by_port.items():
        keys = [endpoint_key(connection) for connection in connections]
        if len(keys) != len(set(keys)):
            raise RuntimeError("direct SRAM ECO connectivity contains duplicates")
        endpoint_sets[port] = set(keys)

    buffer_instance = _canonical_odb_name(record["instance"])
    target_instance, target_pin = target["pin"].rsplit("/", 1)
    target_instance = _canonical_odb_name(target_instance)
    peer = target.get("peer")
    if not isinstance(peer, dict) or set(peer) != {
        "instance",
        "io_type",
        "master",
        "pin",
    }:
        raise RuntimeError("direct SRAM ECO target peer is malformed")
    buffer_a = ("iterm", buffer_instance, "A", buffer_cell, "INPUT")
    buffer_z = ("iterm", buffer_instance, "Z", buffer_cell, "OUTPUT")
    peer_endpoint = (
        "iterm",
        _canonical_odb_name(peer["instance"]),
        peer["pin"],
        peer["master"],
        peer["io_type"],
    )
    if buffer_a not in endpoint_sets["A"] or buffer_z not in endpoint_sets["Z"]:
        raise RuntimeError("direct SRAM ECO buffer endpoints are incomplete")

    if target["kind"] == "addr":
        target_endpoint = (
            "iterm",
            target_instance,
            target_pin,
            macro_cell,
            "INPUT",
        )
        if endpoint_sets["Z"] != {buffer_z, target_endpoint}:
            raise RuntimeError("direct SRAM ECO addr isolation topology mismatch")
        if endpoint_sets["A"] != {buffer_a, peer_endpoint}:
            raise RuntimeError("direct SRAM ECO addr source topology mismatch")
    elif target["kind"] == "dout":
        target_endpoint = (
            "iterm",
            target_instance,
            target_pin,
            macro_cell,
            "OUTPUT",
        )
        if endpoint_sets["A"] != {buffer_a, target_endpoint}:
            raise RuntimeError("direct SRAM ECO dout driver topology mismatch")
        if endpoint_sets["Z"] != {buffer_z, peer_endpoint}:
            raise RuntimeError("direct SRAM ECO dout load topology mismatch")
    else:
        raise RuntimeError("direct SRAM ECO target kind is invalid")


def _require_close(actual, expected, tolerance, label):
    if not math.isclose(actual, expected, rel_tol=0.0, abs_tol=tolerance):
        raise RuntimeError(
            "{} mismatch: expected {} got {}".format(label, expected, actual)
        )


def verify_run_contract_binding(run_contract_path, floorplan_contract_path):
    run_contract_path = Path(run_contract_path).resolve()
    floorplan_contract_path = Path(floorplan_contract_path).resolve()
    run_contract = read_json_object(run_contract_path, "direct P&R run contract")
    floorplan_record = run_contract.get("floorplan")
    if run_contract.get("schema_version") != 1 or not isinstance(
        floorplan_record, dict
    ):
        raise RuntimeError("direct P&R run contract has no floorplan binding")
    actual_floorplan_sha256 = sha256_file(floorplan_contract_path)
    if floorplan_record.get("contract_sha256") != actual_floorplan_sha256:
        raise RuntimeError("direct P&R floorplan contract SHA256 mismatch")
    profile = run_contract.get("profile")
    if not isinstance(profile, dict) or profile.get("bounded_asic_family") != "direct":
        raise RuntimeError("direct P&R run contract profile mismatch")
    return run_contract, actual_floorplan_sha256


def verify_direct_macro_placement(
    raw_audit_path,
    floorplan_contract_path,
    profile,
    output_path,
    expected_master=DIRECT_RING_MACRO,
    run_contract_path=None,
):
    raw_audit_path = Path(raw_audit_path).resolve()
    floorplan_contract_path = Path(floorplan_contract_path).resolve()
    output_path = Path(output_path).resolve()
    if profile not in ("register", "sram"):
        raise RuntimeError("direct macro audit profile must be register or sram")
    contract = read_json_object(floorplan_contract_path, "floorplan contract")
    expected_contract_profile = "direct-" + profile
    if contract.get("schema_version") != 1 or contract.get("profile") != expected_contract_profile:
        raise RuntimeError("direct macro audit floorplan profile mismatch")
    floorplan = contract.get("floorplan")
    if not isinstance(floorplan, dict):
        raise RuntimeError("direct macro audit floorplan values are missing")
    run_contract = None
    run_contract_sha256 = None
    if run_contract_path is not None:
        run_contract_path = Path(run_contract_path).resolve()
        run_contract, _ = verify_run_contract_binding(
            run_contract_path, floorplan_contract_path
        )
        expected_mode = run_contract["profile"].get("bounded_asic_profile")
        if expected_mode != profile:
            raise RuntimeError("direct macro audit run-contract mode mismatch")
        run_contract_sha256 = sha256_file(run_contract_path)

    raw_schema, dbu_per_micron, raw_records, raw_eco_records = parse_raw_audit(
        raw_audit_path
    )
    if profile == "register":
        if raw_records:
            raise RuntimeError(
                "direct register final ODB contains {} block macros".format(
                    len(raw_records)
                )
            )
        verified_records = []
    else:
        placements = floorplan.get("macro_placements")
        if not isinstance(placements, list) or len(placements) != 8:
            raise RuntimeError("direct SRAM floorplan must contain eight placements")
        if len(raw_records) != 8:
            raise RuntimeError(
                "direct SRAM final ODB must contain eight block macros, got {}".format(
                    len(raw_records)
                )
            )
        expected = {
            (int(item["engine"]), int(item["way"])): item for item in placements
        }
        if set(expected) != {
            (engine, way) for engine in range(2) for way in range(4)
        }:
            raise RuntimeError("direct SRAM floorplan ownership is incomplete")
        tolerance_um = max(1.0 / dbu_per_micron, 1.0e-6)
        verified_records = []
        observed_keys = set()
        for record in raw_records:
            match = DIRECT_INSTANCE_RE.search(record["instance"])
            if match is None:
                raise RuntimeError(
                    "unexpected direct SRAM hierarchy: {}".format(record["instance"])
                )
            key = (int(match.group(1)), int(match.group(2)))
            if key in observed_keys:
                raise RuntimeError(
                    "duplicate direct SRAM Engine/way ownership: {}".format(key)
                )
            observed_keys.add(key)
            if record["master"] != expected_master:
                raise RuntimeError(
                    "unexpected direct SRAM master {}".format(record["master"])
                )
            placement = expected[key]
            x_min = _microns(record["x_min_dbu"], dbu_per_micron)
            y_min = _microns(record["y_min_dbu"], dbu_per_micron)
            x_max = _microns(record["x_max_dbu"], dbu_per_micron)
            y_max = _microns(record["y_max_dbu"], dbu_per_micron)
            _require_close(
                x_min, float(placement["x_um"]), tolerance_um, "macro x location"
            )
            _require_close(
                y_min, float(placement["y_um"]), tolerance_um, "macro y location"
            )
            _require_close(
                x_max - x_min,
                float(floorplan["macro_width_um"]),
                tolerance_um,
                "macro width",
            )
            _require_close(
                y_max - y_min,
                float(floorplan["macro_height_um"]),
                tolerance_um,
                "macro height",
            )
            if record["orientation"] != placement["orientation"]:
                raise RuntimeError(
                    "direct SRAM orientation mismatch for Engine {}/way {}".format(
                        key[0], key[1]
                    )
                )
            if record["placement_status"] not in ("PLACED", "FIRM", "LOCKED"):
                raise RuntimeError(
                    "direct SRAM macro is not placed: {}".format(record["instance"])
                )
            verified_records.append(
                {
                    **record,
                    "engine": key[0],
                    "way": key[1],
                    "x_min_um": x_min,
                    "y_min_um": y_min,
                    "x_max_um": x_max,
                    "y_max_um": y_max,
                }
            )
        if observed_keys != set(expected):
            raise RuntimeError("direct SRAM final ODB ownership is incomplete")

        core_values = [float(value) for value in floorplan["core_area"].split()]
        if len(core_values) != 4:
            raise RuntimeError("direct SRAM core area is malformed")
        core_x_min, core_y_min, core_x_max, core_y_max = core_values
        halo = float(floorplan["macro_halo_um"])
        channel = float(floorplan["macro_channel_um"])
        for record in verified_records:
            if (
                record["x_min_um"] < core_x_min + halo - tolerance_um
                or record["y_min_um"] < core_y_min + halo - tolerance_um
                or record["x_max_um"] > core_x_max - halo + tolerance_um
                or record["y_max_um"] > core_y_max - halo + tolerance_um
            ):
                raise RuntimeError("direct SRAM final ODB violates macro halo")
        for index, left in enumerate(verified_records):
            for right in verified_records[index + 1 :]:
                horizontal_gap = max(
                    right["x_min_um"] - left["x_max_um"],
                    left["x_min_um"] - right["x_max_um"],
                )
                vertical_gap = max(
                    right["y_min_um"] - left["y_max_um"],
                    left["y_min_um"] - right["y_max_um"],
                )
                horizontal_overlap = horizontal_gap < -tolerance_um
                vertical_overlap = vertical_gap < -tolerance_um
                if horizontal_overlap and vertical_overlap:
                    raise RuntimeError("direct SRAM final ODB macros overlap")
                if left["engine"] == right["engine"]:
                    if horizontal_overlap and vertical_gap < channel - tolerance_um:
                        raise RuntimeError(
                            "direct SRAM final ODB island channel is below policy"
                        )
                elif vertical_overlap and horizontal_gap < channel - tolerance_um:
                    raise RuntimeError(
                        "direct SRAM final ODB center channel is below policy"
                    )

    targeted_eco = run_contract.get("targeted_electrical_eco") if run_contract else None
    if targeted_eco is None:
        if raw_eco_records:
            raise RuntimeError("final ODB contains unbound direct SRAM ECO buffers")
        verified_eco_records = []
    else:
        if profile != "sram" or not isinstance(targeted_eco, dict):
            raise RuntimeError("direct SRAM ECO is bound to an incompatible profile")
        targets = targeted_eco.get("targets")
        buffer_cells = targeted_eco.get("buffer_cells")
        placement_policy = targeted_eco.get("placement_policy")
        if (
            not isinstance(targets, list)
            or len(targets) != 14
            or buffer_cells != {"addr": "BUF_X4", "dout": "BUF_X1"}
            or placement_policy
            != {
                "macro_halo_um": 20.0,
                "macro_channel_um": 60.0,
                "target_offsets_um": {"addr": 30.0, "dout": 22.0},
            }
        ):
            raise RuntimeError("direct SRAM ECO run-contract policy is malformed")
        if raw_schema != 2:
            raise RuntimeError("targeted direct SRAM ECO requires raw audit schema 2")
        expected_eco = {target["buffer_name"]: target for target in targets}
        if len(expected_eco) != 14 or len(raw_eco_records) != 14:
            raise RuntimeError("direct SRAM final ODB must contain exactly 14 ECO buffers")
        macro_by_key = {
            (record["engine"], record["way"]): record
            for record in verified_records
        }
        observed_names = set()
        verified_eco_records = []
        halo = float(placement_policy["macro_halo_um"])
        channel = float(placement_policy["macro_channel_um"])
        for record in raw_eco_records:
            buffer_name, target, canonical_instance = _match_eco_target(
                expected_eco, record["instance"]
            )
            if buffer_name in observed_names:
                raise RuntimeError(
                    "unexpected or duplicate direct SRAM ECO buffer {}".format(
                        record["instance"]
                    )
                )
            observed_names.add(buffer_name)
            expected_cell = buffer_cells[target["kind"]]
            if record["master"] != expected_cell:
                raise RuntimeError(
                    "direct SRAM ECO buffer {} uses {} instead of {}".format(
                        record["instance"], record["master"], expected_cell
                    )
                )
            if record["placement_status"] not in ("PLACED", "FIRM", "LOCKED"):
                raise RuntimeError(
                    "direct SRAM ECO buffer is not placed: {}".format(
                        record["instance"]
                    )
                )
            macro = macro_by_key.get((target["engine"], target["way"]))
            if macro is None:
                raise RuntimeError("direct SRAM ECO target macro is missing")
            x_min = _microns(record["x_min_dbu"], dbu_per_micron)
            y_min = _microns(record["y_min_dbu"], dbu_per_micron)
            x_max = _microns(record["x_max_dbu"], dbu_per_micron)
            y_max = _microns(record["y_max_dbu"], dbu_per_micron)
            if (
                x_min < macro["x_min_um"] - tolerance_um
                or x_max > macro["x_max_um"] + tolerance_um
            ):
                raise RuntimeError(
                    "direct SRAM ECO buffer escaped its macro-width channel"
                )
            if target["side"] == "top":
                channel_min = macro["y_max_um"] + halo
                channel_max = macro["y_max_um"] + channel - halo
            elif target["side"] == "bottom":
                channel_min = macro["y_min_um"] - channel + halo
                channel_max = macro["y_min_um"] - halo
            else:
                raise RuntimeError("direct SRAM ECO target side is invalid")
            if (
                y_min < channel_min - tolerance_um
                or y_max > channel_max + tolerance_um
            ):
                raise RuntimeError(
                    "direct SRAM ECO buffer escaped its reserved local channel"
                )
            expected_engine_prefix = "g_engine[{}].u_engine/".format(
                target["engine"]
            )
            if not canonical_instance.startswith(expected_engine_prefix):
                raise RuntimeError(
                    "direct SRAM ECO buffer is outside its target Engine hierarchy"
                )
            _verify_eco_connectivity(
                record, target, expected_cell, expected_master
            )
            verified_eco_records.append(
                {
                    **record,
                    "buffer_name": buffer_name,
                    "canonical_instance": canonical_instance,
                    "engine": target["engine"],
                    "way": target["way"],
                    "kind": target["kind"],
                    "target_pin": target["pin"],
                    "side": target["side"],
                    "x_min_um": x_min,
                    "y_min_um": y_min,
                    "x_max_um": x_max,
                    "y_max_um": y_max,
                }
            )
        if observed_names != set(expected_eco):
            raise RuntimeError("direct SRAM final ODB ECO buffer set is incomplete")

    result = {
        "schema_version": 1,
        "status": "PASS",
        "profile": profile,
        "expected_block_macro_count": 8 if profile == "sram" else 0,
        "observed_block_macro_count": len(raw_records),
        "dbu_per_micron": dbu_per_micron,
        "raw_audit": {
            "path": str(raw_audit_path),
            "bytes": raw_audit_path.stat().st_size,
            "sha256": sha256_file(raw_audit_path),
        },
        "floorplan_contract": {
            "path": str(floorplan_contract_path),
            "bytes": floorplan_contract_path.stat().st_size,
            "sha256": sha256_file(floorplan_contract_path),
        },
        "records": sorted(
            verified_records, key=lambda item: (item.get("engine", 0), item.get("way", 0))
        ),
        "eco_buffers": sorted(
            verified_eco_records, key=lambda item: item["buffer_name"]
        ),
    }
    if run_contract is not None:
        result["run_contract"] = {
            "path": str(run_contract_path),
            "bytes": run_contract_path.stat().st_size,
            "sha256": run_contract_sha256,
        }
    write_json(output_path, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-audit", type=Path)
    parser.add_argument("--floorplan-contract", required=True, type=Path)
    parser.add_argument("--profile", choices=("register", "sram"))
    parser.add_argument("--expected-master", default=DIRECT_RING_MACRO)
    parser.add_argument("--run-contract", type=Path)
    parser.add_argument("--check-contract-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.check_contract_only:
        if args.run_contract is None:
            raise RuntimeError("--check-contract-only requires --run-contract")
        _, floorplan_sha256 = verify_run_contract_binding(
            args.run_contract, args.floorplan_contract
        )
        print(
            "direct-macro-placement-audit: CONTRACT-PASS floorplan_sha256={}".format(
                floorplan_sha256
            )
        )
        return 0
    if args.raw_audit is None or args.profile is None or args.output is None:
        raise RuntimeError(
            "final audit requires --raw-audit, --profile and --output"
        )
    result = verify_direct_macro_placement(
        args.raw_audit,
        args.floorplan_contract,
        args.profile,
        args.output,
        expected_master=args.expected_master,
        run_contract_path=args.run_contract,
    )
    print(
        "direct-macro-placement-audit: PASS profile={} macros={} output={}".format(
            result["profile"], result["observed_block_macro_count"], args.output.resolve()
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("direct-macro-placement-audit: error: {}".format(error), file=sys.stderr)
        raise SystemExit(2)
