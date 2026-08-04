# RDTC v1 Fixed Vectors

This directory contains the small deterministic RDTC fixtures committed for C/RTL smoke tests and public evidence. It is not the default output directory for the MATLAB generator.

Expected generator:

```matlab
cd('<repository-root>')
addpath(fullfile(pwd, 'matlab', 'vector_gen'))
main_gen_rdtc_vectors('quick')
main_gen_rdtc_vectors('smoke')
```

By default, these commands write to ignored `build/matlab_vectors/<mode>/rdtc_v1/` and print `[RDTC]` progress lines. Each run also writes a timestamped log under `build/matlab_vectors/logs/`. To intentionally refresh the checked-in fixtures, pass the public vector directory explicitly and review the diff:

```matlab
main_gen_rdtc_vectors('quick', fullfile(pwd, 'vectors', 'rdtc_v1'))
```

The quick profile uses deterministic `zero_sparse` and `single_peak` inputs. The full smoke profile also uses fixed RNG seeds for its noise cases, so generated outputs are reproducible; they remain local by default to keep routine MATLAB runs out of the Git worktree.

Each generated case should contain:

- `manifest.json`
- `input_samples.csv`
- `axis_raw_in.hex`
- `axis_raw_in_ctrl.csv`
- `axis_comp_expected.hex`
- `axis_comp_expected_ctrl.csv`
- `decoded_samples.csv`
- `block_headers.csv`
- `block_summary.csv`
- `README_vector.md`

Large full-cube vectors should not be committed. Keep this directory focused on small deterministic block-level vectors.
