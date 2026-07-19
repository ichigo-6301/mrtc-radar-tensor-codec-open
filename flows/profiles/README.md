# RDTC Implementation Profiles

This directory is the machine-readable registry for reviewed public
implementation profiles. `schema.yaml` defines the allowed maturity values and
required profile fields.

- `rdtc_v1_register_nangate45_550.yaml` is the primary verified physical
  profile. It uses register-expanded prefix buffers and claims internal
  reg-to-reg timing only.
- `rdtc_v1_sram_nangate45_333.yaml` is the secondary partial profile. Its
  measured setup/hold result is retained, while analytical SRAM and physical
  signoff limitations keep the overall profile partial.

Profile maturity describes the completeness of a product profile. Individual
results inside an evidence file have their own status and do not implicitly
upgrade the profile.

