# RDTC Implementation Profiles

This directory is the machine-readable registry for reviewed public
implementation profiles. `schema.yaml` defines the allowed maturity values and
required profile fields.

- `rdtc_v1_register_nangate45_550.yaml` is the primary verified physical
  profile. It uses register-expanded prefix buffers and claims internal
  reg-to-reg timing only.
- `rdtc_v1_sram_nangate45_333.yaml` is the secondary academic macro profile.
  Its chip-level P&R and measured setup/hold result are verified; the public
  record does not claim a production PDK, macro signoff, or silicon readiness.
- `rdtc_v1_register_ics55_rvt_dc.yaml` is a verified DC-only profile using the
  reviewed ICsprout55 v1.10.100 H7CR RVT public-preview library. It does not
  imply ECOS P&R or post-route timing success.

Profile maturity describes the completeness of a product profile. Individual
results inside an evidence file have their own status and do not implicitly
upgrade the profile.
