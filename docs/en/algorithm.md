# Algorithm

[中文](../zh-CN/algorithm.md) · [Back to README](../../README.en.md)

## One-Minute Model

RDTC v1 operates on block-organized complex Range-Doppler samples. The public reference block contains `1024` I16Q16 samples, or `4096` raw bytes. The Encoder creates an independent packet for each block, and the Decoder reconstructs the exact I/Q samples using only the 64-byte header and payload.

![OFDM sensing and RDTC system context](../assets/system_context.svg)

The objective is not the highest possible ratio in every scene. RDTC balances four properties needed by a streaming hardware implementation:

| Objective | RDTC v1 choice |
|---|---|
| Fidelity | bit-exact I/Q sample reconstruction |
| Hardware structure | predictors, add/shift operations, prefix costs, and regular Rice codes |
| Streaming transport | self-describing packets, exact payload-bit count, and `tkeep/tlast` |
| Worst case | explicit RAW mode; selected encoder paths support RAW fallback when coding has no benefit |

## ZERO and DELTA Prediction

I and Q are processed independently. For component $c \in \{I,Q\}$, current sample $x_c[n]$, and prediction $p_c[n]$:

$$
p_c[n] =
\begin{cases}
0, & \text{ZERO\_RICE} \\
0, & \text{DELTA\_RICE and } n=0 \\
x_c[n-1], & \text{DELTA\_RICE and } n>0
\end{cases}
$$

The residual is:

$$r_c[n] = x_c[n] - p_c[n]$$

The first DELTA_RICE I and Q samples therefore use zero as their predictor. Later samples use the previous value of the same component; predictor state is never shared between I and Q.

## Signed Mapping and Rice Coding

Each signed residual is reversibly mapped to a non-negative integer:

$$
m(r) =
\begin{cases}
2r, & r \ge 0 \\
-2r-1, & r < 0
\end{cases}
$$

For Rice parameter $k$, the mapped value is split into quotient and remainder:

$$q = m \gg k, \qquad s = m \mathbin{\&} (2^k-1)$$

The codeword contains $q$ one bits, one terminating zero, and a $k$-bit MSB-first remainder. Its length is:

$$L_k(m) = q + 1 + k$$

Block-adaptive mode evaluates the supported $k \in [0,15]$ values over all mapped I/Q values and selects:

$$k^* = \operatorname*{arg\,min}_{0 \le k \le 15} \sum_{n,c} L_k(m(r_c[n]))$$

Equal costs retain the smaller, first-scanned $k$. The Decoder obtains `rice_k` and the exact payload-bit count from the header, so padding in the final AXI beat is never decoded.

## Three Encoding Paths

| Mode | Datapath | Boundary |
|---|---|---|
| `RAW_BYPASS` | directly packs sample-major I16Q16 data | selectable per block and used as fallback by selected encoder paths |
| `ZERO_RICE` | predicts zero, then applies signed mapping and Rice coding | suited to spectra with many small or near-zero values |
| `DELTA_RICE` | predicts each I/Q component from its own previous sample | exploits correlation between adjacent samples of the same component |

ZERO_RICE and DELTA_RICE come from the block descriptor or configuration. The internal policy chooses `k`; it does not switch predictor modes. RAW fallback is also path-specific: the DDR-backed encoder implements coding-cost fallback, while the public AXIS32 small-buffer lane has internal RAW fallback disabled. Integration claims must identify the encoder path actually tested.

## MATLAB Synthetic Study

The algorithm study uses controlled synthetic Range-Doppler-beam scenes rather than measured radar captures. The public curve retains only the fixed SNR points and does not interpolate or infer unexecuted cases.

![Synthetic compression ratio versus SNR](../assets/compression_vs_snr.svg)

| Synthetic SNR (dB) | -20 | -10 | 0 | 10 | 20 | 30 |
|---|---:|---:|---:|---:|---:|---:|
| ZERO_RICE ratio | 1.5817 | 1.8774 | 2.3470 | 3.0979 | 4.3915 | 7.5588 |
| DELTA_RICE ratio | 1.4997 | 1.7871 | 2.1852 | 2.8083 | 3.9669 | 6.1779 |

All 12 recorded ZERO/DELTA cases have `NMSE=0`, `max_abs_error=0`, and point-cloud match ratio `1`. This point-cloud comparison is MATLAB analysis of the reconstructed spectrum; it does not imply PointCloud RTL.

The following is the unmodified MATLAB output from the fixed source commit. The panels show raw and ZERO_RICE-decoded Range-Doppler representations. It demonstrates reconstruction consistency for the recorded scene, not a measured-radar distribution or a compression-ratio upper bound.

![Original MATLAB raw and reconstructed Range-Doppler output](../assets/matlab/rdb_before_after_rdtc_zero_rice.png)

Sources: [MATLAB evidence](../../evidence/rdtc_v1_matlab_algorithm_study.yaml) · [public CSV](../../evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## Model-to-Bitstream Contract

The algorithm connects to the C model and RTL through these invariants:

- I/Q samples reconstruct bit-exactly;
- `selected_k`, payload-bit count, and packet-byte count match the reference model;
- `tkeep` and `tlast` identify the final beat exactly;
- backpressure may pause transfer but cannot change packet content;
- malformed headers, illegal modes, and out-of-range lengths are detected rather than silently decoded.

MATLAB supports algorithm study and vector generation. The authoritative public executable bit-exact entrypoint is `make -C ref_model/c test` together with the associated DPI-C/RTL regressions. Passing finite vectors is not formal exhaustiveness; see [Verification](verification.md) and [Limitations](limitations.md).
