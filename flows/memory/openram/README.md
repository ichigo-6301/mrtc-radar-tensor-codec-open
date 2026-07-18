# RDTC Prefix SRAM

This directory defines the reproducible contract for one FreePDK45 OpenRAM
`64x128` 1R1W macro. The dual-engine top instantiates two copies through
`mrtc_prefix_sample_buffer` when `RDTC_USE_OPENRAM_PREFIX_SRAM` is defined.
The candidate pins OpenRAM commit `e16d9eb0b4495e8beee441ced3fcad68391155e6`;
the runner rejects an unreviewed commit mismatch.

The write port is `clk0/csb0/addr0/din0`; the read port is
`clk1/csb1/addr1/dout1`. Both chip selects are active low. Read data follows
the macro's one-cycle synchronous read contract. A same-cycle read and write
to the same address is prohibited by the wrapper contract.

Configure `RDTC_OPENRAM_HOME` to the OpenRAM checkout root and configure the local Synopsys Library Compiler path in
`flows/local/toolchain.mk`, then run `make sram-prep`. Generated views and the
SHA256 manifest are written under `build/` and remain untracked.

The default profile preserves the historical analytical 1R1W configuration.
The `nangate45_openram_spice` comparison profile uses the separately named
`mrtc_rdtc_prefix_1rw1r_64x128` macro, with its RW port tied to write-only mode
and its R port used for reads. This organization is used because transistor-level
tests showed that the pinned OpenRAM revision's pure 1W1R macro did not change
state on write-one, with both trimmed and complete SPICE netlists. The comparison
profile uses `config_spice.py` and ngspice at TT/1.1 V/25 C. Set
`RDTC_OPENRAM_CHARACTERIZATION_SMOKE=1` to characterize only the maximum
load/slew point before committing resources to the full 4x4 table.
The SPICE profile also uses a 21-stage, fanout-4 replica-bitline delay chain.
The generator's 9-stage default produced a sub-threshold write-enable pulse
for the 128-bit write-driver load and failed both write-one and readback checks.
`RDTC_OPENRAM_DELAY_CHAIN_STAGES` and `RDTC_OPENRAM_DELAY_CHAIN_FANOUT` remain
available for bounded diagnostic sweeps; only a setting that passes SPICE
write/read checks may be used to generate a candidate Liberty view.

The implementation candidate also requires `perimeter_pins = True`. Interior
signal pins are adequate for transistor-level diagnostics, but the generated
LEF cannot provide legal standard-cell routing access points. The view audit
rejects a SPICE-profile macro unless every required signal-pin family reaches
the LEF boundary. LEF, GDS, SPICE, and Liberty must come from the same
perimeter-pin generation; do not repair this failure by editing LEF alone.

Ubuntu's ngspice 36 limits a flattened subcircuit
node-translation table to 1005 entries, which is too small for this wide
dual-port macro. `ngspice36_large_subckt.patch` documents that parser limit,
but the legacy sparse solver remains impractically slow for a full table.

The executed comparison therefore uses a user-local ngspice 46 build with its
default KLU support enabled. Put `ngspice_klu_wrapper.sh` first on the OpenRAM
PATH and set `RDTC_NGSPICE_REAL` to the reviewed ngspice 46 executable. The
wrapper adds `option klu` to OpenRAM's generated `.spiceinit`; it does not
replace the system binary. When `RDTC_NGSPICE_ARCHIVE_DIR` is set, the wrapper
also preserves each retry's log, stimulus, and measurement deck so period
doubling cannot overwrite the failing evidence.

The parser diagnosis used Ubuntu `ngspice_36+ds.orig.tar.gz`, SHA256
`4f3a59a7b3528f25c5ac5a4fc6004e71a81b6b96b52b33e70e7f880ef51ac2a4`.
The selected simulator source is `ngspice-46.tar.gz`, SHA256
`a0d1699af1940b06649276dcd6ff5a566c8c0cad01b2f7b5e99dedbb4d64c19b`.
The generated Liberty corner, simulation logs, load/slew coverage, and the
absence of macro DRC/LVS must be reviewed before any result is promoted.
