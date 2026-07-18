# Public RTL Regression

The public RDTC v1 regression contains three bounded, dependency-closed tests:

- `tb_mrtc_prefix_sample_buffer`: checks writes, one-cycle reads, consecutive
  accesses, and simultaneous different-address 1R1W operation. Same-cycle
  same-address read/write is prohibited and guarded when regression assertions
  are enabled.

- `tb_mrtc_rice_bitpacker_lane_axis`: compares the lane bitpacker against the
  combinational reference implementation for ZERO_RICE and DELTA_RICE,
  multiple Rice parameters, long-unary fallback, and AXI backpressure.
- `tb_mrtc_rdtc_encoder_axis_bp_smallbuf`: runs encoder/decoder loopback cases
  through the small-buffer streaming implementation.

Run the smoke suite with:

```text
make rdtc_v1_45nm_defconfig
make sim
```

Run the extended matrix with `make sim-full`. Both targets require
Questa/ModelSim `vlib`, `vlog`, and `vsim`; override their executable names in
the ignored `flows/local/toolchain.mk` when they are not on `PATH`. Generated
libraries, logs, and CSV summaries are written under `build/rtl_sim/`.

These regressions are finite engineering checks, not formal proof or coverage
closure.
