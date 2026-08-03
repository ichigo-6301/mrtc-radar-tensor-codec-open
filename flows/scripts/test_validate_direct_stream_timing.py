#!/usr/bin/env python3
"""Tests for the fixed Direct-wrapper stream-timing evidence validator."""

from __future__ import print_function

import copy
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "flows/scripts/validate_direct_stream_timing.py"
SPEC = importlib.util.spec_from_file_location("validate_direct_stream_timing", str(SCRIPT))
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class DirectStreamTimingEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.nominal = VALIDATOR.read_trace_csv(
            ROOT / VALIDATOR.CSV_PATHS["nominal"], "nominal"
        )
        self.backpressure = VALIDATOR.read_trace_csv(
            ROOT / VALIDATOR.CSV_PATHS["backpressure"], "backpressure"
        )

    def test_published_evidence_passes(self):
        VALIDATOR.validate(ROOT)

    def test_cycle_gap_is_rejected(self):
        rows = copy.deepcopy(self.nominal)
        rows[10]["cycle"] += 1
        with self.assertRaisesRegex(ValueError, "not contiguous"):
            VALIDATOR.validate_trace(rows, "nominal")

    def test_backpressure_data_change_is_rejected(self):
        rows = copy.deepcopy(self.backpressure)
        by_cycle = {row["cycle"]: row for row in rows}
        by_cycle[52]["m_tdata"] = "f" * 32
        with self.assertRaisesRegex(ValueError, "changed under backpressure"):
            VALIDATOR.validate_trace(rows, "backpressure")

    def test_ring_latency_change_is_rejected(self):
        rows = copy.deepcopy(self.nominal)
        response = next(row for row in rows if row["e0_ring_rd_rsp_addr"] == 0)
        early = next(row for row in rows if row["cycle"] == response["cycle"] - 1)
        for suffix in ("ring_rd_rsp", "ring_rd_rsp_addr", "ring_rd_rsp_block"):
            early["e0_" + suffix] = response["e0_" + suffix]
        response["e0_ring_rd_rsp"] = 0
        response["e0_ring_rd_rsp_addr"] = -1
        response["e0_ring_rd_rsp_block"] = -1
        with self.assertRaisesRegex(ValueError, "response latency"):
            VALIDATOR._validate_engine(rows, "nominal", 0, 0)

    def test_packet_interleaving_is_rejected(self):
        rows = copy.deepcopy(self.nominal)
        first = next(row for row in rows if row["m_tvalid"] and row["output_block"] == 0)
        first["output_owner"] = 1
        with self.assertRaisesRegex(ValueError, "owner/block mismatch"):
            VALIDATOR._accepted_packets(rows, "nominal")

    def test_final_tuser_reserved_bits_are_rejected(self):
        rows = copy.deepcopy(self.nominal)
        final = next(row for row in rows if row["m_tlast"] and row["output_block"] == 1)
        final["m_tuser"] = "fe"
        with self.assertRaisesRegex(ValueError, "reserved bits"):
            VALIDATOR._accepted_packets(rows, "nominal")

    def test_final_tuser_byte_length_change_is_rejected(self):
        rows = copy.deepcopy(self.nominal)
        final = next(row for row in rows if row["m_tlast"] and row["output_block"] == 1)
        final["m_tuser"] = "0d"
        with self.assertRaisesRegex(ValueError, "byte length"):
            VALIDATOR._accepted_packets(rows, "nominal")

    def test_active_window_trims_decoder_idle_tail(self):
        rows = [
            {"cycle": 1, "input_fire": 0, "m_tvalid": 0, "m_tready": 1, "m_tlast": 0},
            {"cycle": 2, "input_fire": 1, "m_tvalid": 0, "m_tready": 1, "m_tlast": 0},
            {"cycle": 3, "input_fire": 0, "m_tvalid": 1, "m_tready": 1, "m_tlast": 1},
            {"cycle": 4, "input_fire": 0, "m_tvalid": 0, "m_tready": 1, "m_tlast": 0},
        ]
        self.assertEqual([row["cycle"] for row in VALIDATOR.active_window(rows)], [2, 3])


if __name__ == "__main__":
    unittest.main()
