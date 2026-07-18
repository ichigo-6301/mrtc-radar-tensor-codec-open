# RDTC v1 Fixed Vectors

This directory is the target for Stage 8 generated RDTC vectors.

Expected generator:

```matlab
cd ref_model/matlab/vector_gen
main_gen_rdtc_vectors('quick')
main_gen_rdtc_vectors('smoke')
```

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
