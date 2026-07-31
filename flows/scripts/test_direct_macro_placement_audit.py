#!/usr/bin/env python3

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import bounded_floorplan  # noqa: E402
import direct_macro_placement_audit  # noqa: E402


RING_CELL = "mrtc_rdtc_bounded_ring_1rw_32x128"
ECO_POLICY = json.loads(
    (
        SCRIPT_DIR.parent
        / "physical/openroad/direct_sram_pt300_electrical_eco1.json"
    ).read_text(encoding="utf-8")
)


class DirectMacroPlacementAuditTest(unittest.TestCase):
    def write_contract(self, root, profile):
        area = root / "area.rpt"
        output_json = root / "floorplan.json"
        output_env = root / "floorplan.env"
        if profile == "register":
            area.write_text("Total cell area: 100000.0\n", encoding="ascii")
            bounded_floorplan.build_contract(
                area, output_json, output_env, profile="direct-register"
            )
        else:
            area.write_text(
                "Macro/Black Box area: 8000.0\n"
                "Total cell area: 250000.0\n",
                encoding="ascii",
            )
            lef = root / "ring.lef"
            lef.write_text(
                "MACRO {0}\n  SIZE 120 BY 180 ;\nEND {0}\n".format(
                    RING_CELL
                ),
                encoding="ascii",
            )
            bounded_floorplan.build_contract(
                area,
                output_json,
                output_env,
                profile="direct-sram",
                macro_lef=lef,
                macro_name=RING_CELL,
            )
        return output_json

    def write_raw(
        self,
        path,
        records,
        dbu=1000,
        reported_count=None,
        eco_records=None,
        reported_eco_count=None,
        schema=1,
        eco_connections=None,
    ):
        eco_records = [] if eco_records is None else eco_records
        eco_connections = [] if eco_connections is None else eco_connections
        lines = [
            "schema_version\t{}".format(schema),
            "dbu_per_micron\t{}".format(dbu),
        ]
        for record in records:
            lines.append("macro\t" + "\t".join(str(value) for value in record))
        lines.append(
            "macro_count\t{}".format(
                len(records) if reported_count is None else reported_count
            )
        )
        for record in eco_records:
            lines.append("eco_buffer\t" + "\t".join(str(value) for value in record))
        for connection in eco_connections:
            lines.append(
                "eco_connection\t"
                + "\t".join(str(value) for value in connection)
            )
        lines.append(
            "eco_buffer_count\t{}".format(
                len(eco_records)
                if reported_eco_count is None
                else reported_eco_count
            )
        )
        path.write_text("\n".join(lines) + "\n", encoding="ascii")

    def sram_records(self, contract_path, dbu=1000):
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        floorplan = contract["floorplan"]
        width = int(round(floorplan["macro_width_um"] * dbu))
        height = int(round(floorplan["macro_height_um"] * dbu))
        records = []
        for placement in floorplan["macro_placements"]:
            x_min = int(round(placement["x_um"] * dbu))
            y_min = int(round(placement["y_um"] * dbu))
            records.append(
                (
                    "top/g_engine[{}]/u_engine/u_way_ring/g_way[{}]/u_way/u_sram".format(
                        placement["engine"], placement["way"]
                    ),
                    RING_CELL,
                    x_min,
                    y_min,
                    x_min + width,
                    y_min + height,
                    placement["orientation"],
                    "FIRM",
                )
            )
        return records

    def write_eco_run_contract(self, path, floorplan_path):
        floorplan = json.loads(floorplan_path.read_text(encoding="utf-8"))
        value = {
            "schema_version": 1,
            "profile": {
                "bounded_asic_family": "direct",
                "bounded_asic_profile": "sram",
            },
            "floorplan": {
                "contract_sha256": direct_macro_placement_audit.sha256_file(
                    floorplan_path
                ),
                "values": floorplan["floorplan"],
            },
            "targeted_electrical_eco": {
                "buffer_cells": ECO_POLICY["buffer_cells"],
                "placement_policy": ECO_POLICY["placement_policy"],
                "targets": ECO_POLICY["targets"],
            },
        }
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        return path

    def eco_records(self, floorplan_path, dbu=1000):
        floorplan = json.loads(floorplan_path.read_text(encoding="utf-8"))[
            "floorplan"
        ]
        macros = {
            (placement["engine"], placement["way"]): placement
            for placement in floorplan["macro_placements"]
        }
        records = []
        connections = []
        for index, target in enumerate(ECO_POLICY["targets"]):
            macro = macros[(target["engine"], target["way"])]
            width = 2.0 if target["kind"] == "addr" else 1.0
            height = 1.4
            x_min = macro["x_um"] + 5.0 + index * 2.5
            target_offset = ECO_POLICY["placement_policy"]["target_offsets_um"][
                target["kind"]
            ]
            if target["side"] == "top":
                center_y = (
                    macro["y_um"]
                    + floorplan["macro_height_um"]
                    + target_offset
                )
            else:
                center_y = macro["y_um"] - target_offset
            buffer_instance = "g_engine[{}].u_engine/{}{}".format(
                target["engine"], target["buffer_name"], 33000 + index
            )
            a_net = "eco_a_{}".format(index)
            z_net = "eco_z_{}".format(index)
            records.append(
                (
                    buffer_instance,
                    ECO_POLICY["buffer_cells"][target["kind"]],
                    int(round(x_min * dbu)),
                    int(round((center_y - height / 2.0) * dbu)),
                    int(round((x_min + width) * dbu)),
                    int(round((center_y + height / 2.0) * dbu)),
                    "PLACED",
                    a_net,
                    z_net,
                )
            )
            target_instance, target_pin = target["pin"].rsplit("/", 1)
            buffer_cell = ECO_POLICY["buffer_cells"][target["kind"]]
            connections.extend(
                [
                    (
                        buffer_instance,
                        "A",
                        a_net,
                        "iterm",
                        buffer_instance,
                        "A",
                        buffer_cell,
                        "INPUT",
                    ),
                    (
                        buffer_instance,
                        "Z",
                        z_net,
                        "iterm",
                        buffer_instance,
                        "Z",
                        buffer_cell,
                        "OUTPUT",
                    ),
                ]
            )
            if target["kind"] == "addr":
                peer = target["peer"]
                connections.extend(
                    [
                        (
                            buffer_instance,
                            "A",
                            a_net,
                            "iterm",
                            peer["instance"],
                            peer["pin"],
                            peer["master"],
                            peer["io_type"],
                        ),
                        (
                            buffer_instance,
                            "Z",
                            z_net,
                            "iterm",
                            target_instance,
                            target_pin,
                            RING_CELL,
                            "INPUT",
                        ),
                    ]
                )
            else:
                peer = target["peer"]
                connections.extend(
                    [
                        (
                            buffer_instance,
                            "A",
                            a_net,
                            "iterm",
                            target_instance,
                            target_pin,
                            RING_CELL,
                            "OUTPUT",
                        ),
                        (
                            buffer_instance,
                            "Z",
                            z_net,
                            "iterm",
                            peer["instance"],
                            peer["pin"],
                            peer["master"],
                            peer["io_type"],
                        ),
                    ]
                )
        return records, connections

    def test_register_requires_zero_final_odb_block_macros(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contract = self.write_contract(root, "register")
            raw = root / "raw.tsv"
            output = root / "audit.json"
            self.write_raw(raw, [])
            result = direct_macro_placement_audit.verify_direct_macro_placement(
                raw, contract, "register", output
            )
            self.assertEqual(result["observed_block_macro_count"], 0)
            self.assertEqual(result["status"], "PASS")

            self.write_raw(
                raw,
                [("u_macro", "unexpected", 0, 0, 1000, 1000, "R0", "FIRM")],
            )
            with self.assertRaisesRegex(RuntimeError, "contains 1 block macros"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw, contract, "register", output
                )

    def test_sram_requires_exact_engine_way_placement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contract = self.write_contract(root, "sram")
            raw = root / "raw.tsv"
            output = root / "audit.json"
            records = self.sram_records(contract)
            self.write_raw(raw, records)
            result = direct_macro_placement_audit.verify_direct_macro_placement(
                raw, contract, "sram", output
            )
            self.assertEqual(result["observed_block_macro_count"], 8)
            self.assertEqual(
                {(item["engine"], item["way"]) for item in result["records"]},
                {(engine, way) for engine in range(2) for way in range(4)},
            )

            bad_records = list(records)
            bad = list(bad_records[3])
            bad[2] += 1000
            bad_records[3] = tuple(bad)
            self.write_raw(raw, bad_records)
            with self.assertRaisesRegex(RuntimeError, "macro x location mismatch"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw, contract, "sram", output
                )

    def test_sram_contract_cannot_relax_halo_or_island_channel(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contract_path = self.write_contract(root, "sram")
            raw = root / "raw.tsv"
            output = root / "audit.json"
            contract = json.loads(contract_path.read_text(encoding="utf-8"))
            floorplan = contract["floorplan"]
            core_x_min = float(floorplan["core_area"].split()[0])

            floorplan["macro_placements"][0]["x_um"] = (
                core_x_min + floorplan["macro_halo_um"] - 1.0
            )
            contract_path.write_text(
                json.dumps(contract, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            self.write_raw(raw, self.sram_records(contract_path))
            with self.assertRaisesRegex(RuntimeError, "violates macro halo"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw, contract_path, "sram", output
                )

            contract_path = self.write_contract(root, "sram")
            contract = json.loads(contract_path.read_text(encoding="utf-8"))
            floorplan = contract["floorplan"]
            lower = floorplan["macro_placements"][0]
            upper = floorplan["macro_placements"][1]
            upper["y_um"] = (
                lower["y_um"]
                + floorplan["macro_height_um"]
                + floorplan["macro_channel_um"]
                - 1.0
            )
            contract_path.write_text(
                json.dumps(contract, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            self.write_raw(raw, self.sram_records(contract_path))
            with self.assertRaisesRegex(RuntimeError, "island channel is below"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw, contract_path, "sram", output
                )

    def test_raw_count_and_schema_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contract = self.write_contract(root, "register")
            raw = root / "raw.tsv"
            output = root / "audit.json"
            self.write_raw(raw, [], reported_count=1)
            with self.assertRaisesRegex(RuntimeError, "count does not match"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw, contract, "register", output
                )

    def test_sram_eco_requires_exact_cells_and_reserved_channels(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            floorplan = self.write_contract(root, "sram")
            run_contract = self.write_eco_run_contract(
                root / "run_contract.json", floorplan
            )
            raw = root / "raw.tsv"
            output = root / "audit.json"
            macro_records = self.sram_records(floorplan)
            eco_records, eco_connections = self.eco_records(floorplan)
            self.write_raw(
                raw,
                macro_records,
                eco_records=eco_records,
                eco_connections=eco_connections,
                schema=2,
            )
            result = direct_macro_placement_audit.verify_direct_macro_placement(
                raw,
                floorplan,
                "sram",
                output,
                run_contract_path=run_contract,
            )
            self.assertEqual(len(result["eco_buffers"]), 14)

            wrong_cell = list(eco_records)
            changed = list(wrong_cell[0])
            changed[1] = "BUF_X1"
            wrong_cell[0] = tuple(changed)
            self.write_raw(
                raw,
                macro_records,
                eco_records=wrong_cell,
                eco_connections=eco_connections,
                schema=2,
            )
            with self.assertRaisesRegex(RuntimeError, "uses BUF_X1 instead of BUF_X4"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw,
                    floorplan,
                    "sram",
                    output,
                    run_contract_path=run_contract,
                )

            escaped = list(eco_records)
            changed = list(escaped[0])
            changed[3] += 25000
            changed[5] += 25000
            escaped[0] = tuple(changed)
            self.write_raw(
                raw,
                macro_records,
                eco_records=escaped,
                eco_connections=eco_connections,
                schema=2,
            )
            with self.assertRaisesRegex(RuntimeError, "reserved local channel"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw,
                    floorplan,
                    "sram",
                    output,
                    run_contract_path=run_contract,
                )

            broken_connections = list(eco_connections)
            changed = list(broken_connections[3])
            changed[6] = "addr0[1]"
            broken_connections[3] = tuple(changed)
            self.write_raw(
                raw,
                macro_records,
                eco_records=eco_records,
                eco_connections=broken_connections,
                schema=2,
            )
            with self.assertRaisesRegex(RuntimeError, "topology mismatch"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw,
                    floorplan,
                    "sram",
                    output,
                    run_contract_path=run_contract,
                )

            wrong_peer = list(eco_connections)
            changed = list(wrong_peer[2])
            changed[6] = "A"
            wrong_peer[2] = tuple(changed)
            self.write_raw(
                raw,
                macro_records,
                eco_records=eco_records,
                eco_connections=wrong_peer,
                schema=2,
            )
            with self.assertRaisesRegex(RuntimeError, "source topology mismatch"):
                direct_macro_placement_audit.verify_direct_macro_placement(
                    raw,
                    floorplan,
                    "sram",
                    output,
                    run_contract_path=run_contract,
                )


if __name__ == "__main__":
    unittest.main()
