# Release Model

An RDTC public release separates functional source, private delivery metadata, and public packaging:

- `rtl_source_commit` fixes the functional RTL, reference model, MATLAB assets, and public interfaces;
- `private_delivery_commit` fixes claim/evidence review and allowlisted export configuration;
- the public packaging commit contains repository structure, CI, documentation, and reproduction scripts;
- the annotated public release tag is the immutable release identity, resolved with `git rev-list -n 1 <tag>`.

The `register550-rc2` tag is `rdtc-v1-register550-rc2`. The manifest does not embed a self-referential final public commit SHA in that same commit; the tag identifies the final public commit.

## Maturity

- A `verified` profile has recorded configuration, tools, evidence, and caveats sufficient for its explicit claims;
- A `partial` profile may contain independently verified results while model or implementation stages remain incomplete;
- `experimental` is exploratory and cannot support a public verified claim;
- `planned` is roadmap-only;
- `private_not_claimed` is excluded from public result claims.

Profile maturity and evidence/result maturity are recorded separately. The SRAM 333 MHz internal setup/hold measurements remain verified, but analytical characterization, the minimum-capacitance waiver, and missing macro DRC/LVS/PEX keep the overall profile `partial`.

## Integrity

`provenance/checksums.sha256` records Git mode and the SHA256 of Git blob content in bytewise path order. It is independent of Windows or Linux checkout line endings. `provenance/verify_release.py` checks the release tag, layered source references, profile/claim/evidence schemas, canonical checksums, and public leakage boundary.

Verified internal reg-to-reg timing covers only the recorded internal single-clock paths. It is not complete top-level IO timing, reset recovery/removal closure, OCV/MMMC, foundry DRC/LVS/PEX, foundry signoff, or silicon readiness.

