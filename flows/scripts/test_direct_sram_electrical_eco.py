#!/usr/bin/env python3

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import direct_sram_electrical_eco  # noqa: E402


POLICY_PATH = (
    SCRIPT_DIR.parent
    / "physical/openroad/direct_sram_pt300_electrical_eco1.json"
)


class DirectSramElectricalEcoTest(unittest.TestCase):
    def write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    def fixture(self, root):
        policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        parent = root / "parent"
        pt = root / "pt"
        parent.mkdir(parents=True)
        pt.mkdir(parents=True)

        floorplan_path = parent / "openroad/floorplan_contract.json"
        floorplan_values = {
            "macro_count": 8,
            "macro_channel_um": 60.0,
            "macro_halo_um": 20.0,
            "local_buffer_channel_um": 20.0,
        }
        self.write_json(
            floorplan_path,
            {
                "schema_version": 1,
                "profile": "direct-sram",
                "floorplan": floorplan_values,
            },
        )
        rtl = {"source_set_sha256": "a" * 64, "files": []}
        physical_policy = {
            "setup_slack_margin_ns": "0.00",
            "cts_hold_slack_margin_ns": "0.06",
            "grt_hold_slack_margin_ns": "0.00",
            "cap_margin_percent": "60",
            "slew_margin_percent": "65",
            "post_grt_hold_repair_passes": "0",
            "post_grt_hold_slack_margin_ns": "0.00",
            "orfs_num_cores": "8",
        }
        profile = {
            "build_tag": policy["parent"]["build_tag"],
            "bounded_asic_family": "direct",
            "bounded_asic_profile": "sram",
            "top": "mrtc_rdtc_bounded_axis_multiengine_wrapper",
            "technology": "nangate45_openram_bounded_direct",
            "memory_mode": "macro",
            "clock_period_ns": "3.333333",
            "orfs_platform": "nangate45",
            "orfs_image": "image@sha256:" + "1" * 64,
            "orfs_commit": "b" * 40,
            "expected_bulk_storage_bits": 32768,
            "expected_sram_count": 8,
        }
        macro_instances = [
            {"engine": engine, "way": way, "instance": "e{}w{}".format(engine, way)}
            for engine in range(2)
            for way in range(4)
        ]
        sram_model = {
            "macro": policy["parent"]["sram_macro"],
            "manifest_sha256": "2" * 64,
            "views": {
                "lef": {
                    "path": "/parent/model/macro.lef",
                    "name": "macro.lef",
                    "bytes": 1,
                    "sha256": "4" * 64,
                }
            },
        }
        run_contract_path = parent / "openroad/run_contract.json"
        self.write_json(
            run_contract_path,
            {
                "schema_version": 1,
                "source_commit": policy["parent"]["source_commit"],
                "rtl": rtl,
                "profile": profile,
                "physical_policy": physical_policy,
                "dc_ring_macro_instances": macro_instances,
                "inputs": {"dc_netlist": {"sha256": "3" * 64}},
                "floorplan": {
                    "contract_sha256": direct_sram_electrical_eco.sha256_file(
                        floorplan_path
                    ),
                    "values": floorplan_values,
                },
                "sram_model": sram_model,
            },
        )
        source_record = (
            direct_sram_electrical_eco.pnr_sta_relocation.source_artifact_record
        )
        macro_raw_path = parent / "openroad/direct_macro_placement_raw.tsv"
        macro_raw_path.parent.mkdir(parents=True, exist_ok=True)
        macro_raw_path.write_text("schema_version\t2\n", encoding="ascii")
        metadata_path = (
            parent
            / "openroad/orfs/reports/nangate45/rdtc_v1/base/metadata.json"
        )
        self.write_json(metadata_path, {"finish__design__instance__count": 1})

        final_paths = {}
        for suffix in direct_sram_electrical_eco.pnr_sta_relocation.REQUIRED_FINAL_SUFFIXES:
            path = (
                parent
                / "openroad/orfs/results/nangate45/rdtc_v1/base"
                / ("6_final." + suffix)
            )
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("final {}\n".format(suffix), encoding="ascii")
            final_paths[suffix] = path
        handoff_paths = {}
        for suffix in direct_sram_electrical_eco.pnr_sta_relocation.REQUIRED_HANDOFF_SUFFIXES:
            path = (
                parent
                / "openroad/handoff"
                / ("mrtc_rdtc_bounded_axis_multiengine_wrapper_postroute." + suffix)
            )
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("handoff {}\n".format(suffix), encoding="ascii")
            handoff_paths[suffix] = path

        macro_audit_path = parent / "openroad/direct_macro_placement_audit.json"
        self.write_json(
            macro_audit_path,
            {
                "schema_version": 1,
                "status": "PASS",
                "profile": "sram",
                "observed_block_macro_count": 8,
                "run_contract": source_record(run_contract_path),
                "floorplan_contract": source_record(floorplan_path),
                "raw_audit": source_record(macro_raw_path),
            },
        )
        verification_path = parent / "openroad/verification.json"
        final_artifacts = {
            suffix: source_record(path) for suffix, path in final_paths.items()
        }
        handoff_artifacts = {
            suffix: source_record(path) for suffix, path in handoff_paths.items()
        }
        self.write_json(
            verification_path,
            {
                "schema_version": 1,
                "status": "PASS",
                "scope": "academic_openroad_route_tool",
                "metrics": {
                    "detailedroute__route__drc_errors": 0,
                    "detailedroute__antenna__violating__nets": 0,
                    "detailedroute__antenna__violating__pins": 0,
                    "detailedroute__route__unrouted_nets": 0,
                },
                "run_contract": source_record(run_contract_path),
                "direct_macro_placement_audit": source_record(macro_audit_path),
                "metadata": source_record(metadata_path),
                "final_artifacts": final_artifacts,
                "handoff_artifacts": handoff_artifacts,
            },
        )
        simple_parent_files = {
            "grt_odb": "odb\n",
            "grt_sdc": "sdc\n",
            "route_guide": "guide\n",
        }
        parent_paths = {
            "run_contract": run_contract_path,
            "floorplan_contract": floorplan_path,
            "macro_audit": macro_audit_path,
            "verification": verification_path,
        }
        for role, content in simple_parent_files.items():
            relative = Path(policy["parent"]["artifacts"][role]["relative_path"])
            path = parent / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="ascii")
            parent_paths[role] = path

        parent_relocation = parent / Path(
            policy["parent"]["artifacts"]["relocation_manifest"]["relative_path"]
        )
        pt_relocation = pt / Path(
            policy["pt_artifacts"]["relocation_manifest"]["relative_path"]
        )
        relocation_sources = {
            "run_contract": run_contract_path,
            "source_verification": verification_path,
            "source_macro_audit": macro_audit_path,
            "macro_raw": macro_raw_path,
            "floorplan_contract": floorplan_path,
            "metadata": metadata_path,
        }
        relocation_sources.update(
            {"final_" + suffix: path for suffix, path in final_paths.items()}
        )
        relocation_sources.update(
            {"handoff_" + suffix: path for suffix, path in handoff_paths.items()}
        )
        relocation_artifacts = {}
        for role, source in sorted(relocation_sources.items()):
            relative = Path("artifacts") / role / source.name
            for relocation_root in (parent_relocation.parent, pt_relocation.parent):
                destination = relocation_root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read_bytes())
            relocation_artifacts[role] = (
                direct_sram_electrical_eco.pnr_sta_relocation.artifact_record(
                    pt_relocation.parent / relative, pt_relocation.parent
                )
            )
        relocation = {
            "schema_version": 1,
            "kind": "rdtc_openroad_sta_relocation",
            "source_verification_sha256": direct_sram_electrical_eco.sha256_file(
                verification_path
            ),
            "source_paths": {
                "run_contract": str(run_contract_path.resolve()),
                "verification": str(verification_path.resolve()),
                "macro_audit": str(macro_audit_path.resolve()),
            },
            "artifacts": relocation_artifacts,
        }
        self.write_json(parent_relocation, relocation)
        self.write_json(pt_relocation, relocation)
        parent_paths["relocation_manifest"] = parent_relocation

        for role, path in parent_paths.items():
            policy["parent"]["artifacts"][role]["sha256"] = (
                direct_sram_electrical_eco.sha256_file(path)
            )

        addr_pins = [
            target["pin"] for target in policy["targets"] if target["kind"] == "addr"
        ]
        dout_pins = [
            target["pin"] for target in policy["targets"] if target["kind"] == "dout"
        ]
        all_pins = addr_pins + dout_pins
        pt_content = {
            "max_transition": "\n".join("   " + pin for pin in addr_pins) + "\n",
            "max_capacitance": "\n".join("   " + pin for pin in dout_pins) + "\n",
            "setup_summary": "No setup violations found.\n",
            "hold_summary": "No hold violations found.\n",
            "verification_summary": (
                "status: FAIL\n"
                "reason: PrimeTime max_transition report contains 11 unauthorized violation(s)\n"
            ),
            "analysis_coverage": (
                "setup 18276 18276 (100%) 0 (  0%) 0 (  0%)\n"
                "hold 18276 18276 (100%) 0 (  0%) 0 (  0%)\n"
            ),
            "check_timing": "Information: Checking 'unconstrained_endpoints'.\n0\n",
            "constraint_violations": "\n".join(
                "   {}\n(VIOLATED)".format(pin) for pin in all_pins
            )
            + "\n",
            "minimum_period": "Report : constraint\n-min_period\n0\n",
            "minimum_pulse_width": (
                "Report : constraint\n-min_pulse_width\n0\n"
            ),
            "pt_command_log": (
                "require_sha256 $approved_path\n"
                "read_verilog $rdtc_postroute_netlist\n"
                "read_sdc $rdtc_postroute_sdc\n"
                "read_parasitics $rdtc_postroute_spef\n"
                "puts \"INFO: PrimeTime post-route STA completed\"\n"
            ),
            "parasitics_command_log": (
                "Report : read_parasitics /work/{}\n".format(
                    handoff_paths["spef"].name
                )
                + "0 error(s)\nAnnotated nets : 124634\n"
            ),
        }
        for role, content in pt_content.items():
            path = pt / policy["pt_artifacts"][role]["relative_path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="ascii")
        self.write_json(
            pt / policy["pt_artifacts"]["sta_execution"]["relative_path"],
            {
                "stage": "sta",
                "status": "pass",
                "returncode": 0,
                "timed_out": False,
                "termination": "not_requested",
            },
        )
        for role, spec in policy["pt_artifacts"].items():
            path = pt / spec["relative_path"]
            spec["sha256"] = direct_sram_electrical_eco.sha256_file(path)

        policy_path = root / "policy.json"
        self.write_json(policy_path, policy)
        manifest_path = root / "resume.json"
        direct_sram_electrical_eco.create_resume_manifest(
            policy_path, parent, pt, manifest_path
        )
        return policy_path, manifest_path, pt

    def test_manifest_compatibility_and_checkpoint_seed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, manifest_path, _ = self.fixture(root)
            resume = direct_sram_electrical_eco.verify_resume_manifest(
                manifest_path, policy_path
            )
            parent = resume["parent_identity"]
            child = {
                "rtl": parent["rtl"],
                "profile": copy.deepcopy(parent["profile"]),
                "physical_policy": parent["physical_policy"],
                "dc_ring_macro_instances": parent["dc_ring_macro_instances"],
                "inputs": {
                    "dc_netlist": {"sha256": parent["dc_netlist_sha256"]}
                },
                "sram_model": copy.deepcopy(parent["sram_model"]),
                "floorplan": {"values": parent["floorplan_values"]},
            }
            child["profile"]["build_tag"] = "child-eco"
            child["sram_model"]["views"]["lef"]["path"] = "/child/model/macro.lef"
            direct_sram_electrical_eco.verify_child_compatibility(child, resume)

            changed_model = copy.deepcopy(child)
            changed_model["sram_model"]["views"]["lef"]["sha256"] = "5" * 64
            with self.assertRaisesRegex(RuntimeError, "SRAM model mismatch"):
                direct_sram_electrical_eco.verify_child_compatibility(
                    changed_model, resume
                )

            build_root = root / "child"
            staged = direct_sram_electrical_eco.stage_resume_manifest(
                resume, build_root
            )
            self.assertEqual(staged["sha256"], resume["manifest_sha256"])
            resume = dict(resume)
            resume["manifest_path"] = staged["path"]
            run_contract = build_root / "openroad/run_contract.json"
            self.write_json(run_contract, child)
            seed = direct_sram_electrical_eco.seed_resume_checkpoint(
                resume, build_root, run_contract
            )
            self.assertEqual(set(seed["copied"]), {"grt_odb", "grt_sdc", "route_guide"})
            result_root = build_root / "openroad/orfs/results/nangate45/rdtc_v1/base"
            self.assertTrue((result_root / "5_1_grt.odb").is_file())
            direct_sram_electrical_eco.seed_resume_checkpoint(
                resume, build_root, run_contract
            )

    def test_pt_target_mutation_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, manifest_path, pt = self.fixture(root)
            transition = pt / json.loads(policy_path.read_text(encoding="utf-8"))[
                "pt_artifacts"
            ]["max_transition"]["relative_path"]
            transition.write_text(
                "   g_engine[0].u_engine/u_way_ring/g_way[0].u_way/u_sram/addr0[0]\n",
                encoding="ascii",
            )
            with self.assertRaisesRegex(RuntimeError, "hash or size mismatch"):
                direct_sram_electrical_eco.verify_resume_manifest(
                    manifest_path, policy_path
                )

    def test_parent_relocation_handoff_mutation_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, _, pt = self.fixture(root)
            policy = json.loads(policy_path.read_text(encoding="utf-8"))
            parent_relocation = root / "parent" / Path(
                policy["parent"]["artifacts"]["relocation_manifest"][
                    "relative_path"
                ]
            )
            pt_relocation = pt / Path(
                policy["pt_artifacts"]["relocation_manifest"]["relative_path"]
            )
            relocation = json.loads(pt_relocation.read_text(encoding="utf-8"))
            relative = Path(relocation["artifacts"]["handoff_spef"]["path"])
            for relocation_root in (
                parent_relocation.parent,
                pt_relocation.parent,
            ):
                (relocation_root / relative).write_text(
                    "mutated handoff SPEF\n", encoding="ascii"
                )
            relocation["artifacts"]["handoff_spef"] = (
                direct_sram_electrical_eco.pnr_sta_relocation.artifact_record(
                    pt_relocation.parent / relative, pt_relocation.parent
                )
            )
            self.write_json(parent_relocation, relocation)
            self.write_json(pt_relocation, relocation)
            policy["parent"]["artifacts"]["relocation_manifest"]["sha256"] = (
                direct_sram_electrical_eco.sha256_file(parent_relocation)
            )
            policy["pt_artifacts"]["relocation_manifest"]["sha256"] = (
                direct_sram_electrical_eco.sha256_file(pt_relocation)
            )
            self.write_json(policy_path, policy)

            with self.assertRaisesRegex(
                RuntimeError, "handoff_spef source evidence identity mismatch"
            ):
                direct_sram_electrical_eco.create_resume_manifest(
                    policy_path,
                    root / "parent",
                    pt,
                    root / "mutated-resume.json",
                )

    def test_parent_pt_semantic_mutation_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, _, pt = self.fixture(root)
            policy = json.loads(policy_path.read_text(encoding="utf-8"))
            coverage = pt / Path(
                policy["pt_artifacts"]["analysis_coverage"]["relative_path"]
            )
            coverage.write_text(
                "setup 18276 18275 (100%) 1 (  0%) 0 (  0%)\n"
                "hold 18276 18276 (100%) 0 (  0%) 0 (  0%)\n",
                encoding="ascii",
            )
            policy["pt_artifacts"]["analysis_coverage"]["sha256"] = (
                direct_sram_electrical_eco.sha256_file(coverage)
            )
            self.write_json(policy_path, policy)

            with self.assertRaisesRegex(RuntimeError, "setup coverage is incomplete"):
                direct_sram_electrical_eco.create_resume_manifest(
                    policy_path,
                    root / "parent",
                    pt,
                    root / "mutated-resume.json",
                )

    def test_child_floorplan_change_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, manifest_path, _ = self.fixture(root)
            resume = direct_sram_electrical_eco.verify_resume_manifest(
                manifest_path, policy_path
            )
            parent = resume["parent_identity"]
            child = {
                "rtl": parent["rtl"],
                "profile": copy.deepcopy(parent["profile"]),
                "physical_policy": parent["physical_policy"],
                "dc_ring_macro_instances": parent["dc_ring_macro_instances"],
                "inputs": {
                    "dc_netlist": {"sha256": parent["dc_netlist_sha256"]}
                },
                "sram_model": parent["sram_model"],
                "floorplan": {"values": {"changed": True}},
            }
            with self.assertRaisesRegex(RuntimeError, "floorplan values"):
                direct_sram_electrical_eco.verify_child_compatibility(child, resume)

    def test_tracked_hook_targets_match_the_policy(self):
        policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        hook = (
            SCRIPT_DIR.parent
            / "physical/openroad/pre_detail_route_direct_sram_electrical_eco1.tcl"
        )
        binding = direct_sram_electrical_eco.verify_hook_targets(
            policy["targets"], policy["placement_policy"], hook
        )
        self.assertEqual(binding["target_count"], 14)
        self.assertEqual(
            binding["target_offsets_um"], {"addr": 30.0, "dout": 22.0}
        )
        hook_text = hook.read_text(encoding="utf-8")
        self.assertNotRegex(hook_text, r"(?m)^\s*global ")
        self.assertIn("rdtc_target_io rdtc_target_master", hook_text)

        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "hook.tcl"
            changed.write_text(
                hook.read_text(encoding="utf-8").replace(
                    "rdtc_direct_eco_addr_buf_00 top",
                    "rdtc_direct_eco_addr_buf_00 bottom",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "target set drifted"):
                direct_sram_electrical_eco.verify_hook_targets(
                    policy["targets"], policy["placement_policy"], changed
                )

            changed.write_text(
                hook.read_text(encoding="utf-8").replace(
                    "{g_engine[1].u_engine/place14478/Z} BUF_X8 OUTPUT",
                    "{g_engine[1].u_engine/place14478/A} BUF_X8 OUTPUT",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "target set drifted"):
                direct_sram_electrical_eco.verify_hook_targets(
                    policy["targets"], policy["placement_policy"], changed
                )

            first_addr_line = next(
                line
                for line in hook_text.splitlines()
                if "rdtc_direct_eco_addr_buf_00" in line
            )
            changed.write_text(
                hook_text.replace(first_addr_line + "\n", "", 1).replace(
                    "set rdtc_dout_targets [list \\\n",
                    "set rdtc_dout_targets [list \\\n" + first_addr_line + "\n",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "target set drifted"):
                direct_sram_electrical_eco.verify_hook_targets(
                    policy["targets"], policy["placement_policy"], changed
                )

            changed.write_text(
                hook_text.replace("-buffer_cell BUF_X4", "-buffer_cell BUF_X1", 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "buffer-cell policy drifted"):
                direct_sram_electrical_eco.verify_hook_targets(
                    policy["targets"], policy["placement_policy"], changed
                )

            changed.write_text(
                hook_text.replace(
                    "round(22.0 * $rdtc_dbu_per_micron)",
                    "round(30.0 * $rdtc_dbu_per_micron)",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "offset policy drifted"):
                direct_sram_electrical_eco.verify_hook_targets(
                    policy["targets"], policy["placement_policy"], changed
                )


if __name__ == "__main__":
    unittest.main()
