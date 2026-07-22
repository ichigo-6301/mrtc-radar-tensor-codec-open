# Release Model

[中文](../zh-CN/release_model.md)

## RC3 And Current Main

`rdtc-v1-register550-rc3` is the immutable annotated public release tag. It fixes the RC3 source, public evidence, provenance, and checksum identity. Current `main` is the post-RC3 development line: it may add presentation, clarification, and later reviewed content, but it must not move, delete, recreate, or retarget the RC3 tag to the new main.

The distinction is:

- **RC3 release**: an immutable historical release that can be checked out and verified independently;
- **current main**: includes post-RC3 presentation and clarification updates and does not automatically become a new release;
- **future release**: exists only after separate authorization, review, and a new tag.

## Layered Sources

An RDTC public release separates functional source, private delivery metadata, and public packaging:

- `rtl_source_commit` fixes the functional RTL, reference model, MATLAB assets, and public interfaces;
- `private_delivery_commit` fixes claim/evidence review and allowlisted export configuration;
- the public packaging commit contains repository structure, CI, documentation, and reproduction scripts;
- the annotated public release tag is the final immutable release identity, resolved with `git rev-list -n 1 <tag>`.

The manifest does not embed a self-referential final public commit SHA in that same commit; the tag supplies final release identity. Documentation on current main may link to and explain existing evidence, but prose alone cannot introduce a new `verified` technical fact.

## Result And Profile Maturity

Maturity must be interpreted by dimension:

- a `verified` result has recorded configuration, tools, input identity, and evidence sufficient for that explicit result;
- `partial` must identify what is partial and must not blur a completed P&R or timing stage into a partial result;
- `experimental` is exploratory and cannot support a public verified claim;
- `planned` is roadmap-only;
- `not_claimed` means evidence or execution is absent and cannot be inferred from an adjacent stage.

The SRAM 333 MHz profile is the canonical example: chip-level P&R, routed handoff, same-run OpenRCX SPEF, and internal PT setup/hold results are verified. The macro timing model uses analytical characterization and macro DRC/LVS/PEX is not closed, so overall profile maturity remains `partial`. The exact reviewed 256-endpoint minimum-capacitance waiver must stay disclosed, but it is not a setup/hold waiver and does not automatically make the verified timing result partial.

FPGA maturity is likewise separated into simulation, elaboration, software build, implementation, timing, bitstream, board smoke, and workload validation. Current public claims cover AXIS32 XSim `3/3`, plus historical Zynq trial-copy elaboration with compatibility-copied RTL and its SDK/ELF build. Direct Vivado 2018.3 elaboration of the current public RTL, bitstream, board execution, MCDMA runtime, timing, and resources are `not_claimed`.

## Integrity

`provenance/checksums.sha256` records Git mode and the SHA256 of Git blob content in bytewise path order. It is independent of Windows or Linux checkout line endings. Current main must be checked against the manifest stored on main; immutable RC3 must be checked in an independent RC3 checkout against the manifest stored inside RC3.

`provenance/verify_release.py` checks the release tag, layered source references, profile/claim/evidence schemas, canonical checksums, and public leakage boundary. Presentation SVGs and documentation are public-packaging content. They cannot replace evidence or change original numbers, hashes, PVT, tool identity, or caveats.

RC3 adds verified ICS55 RVT DC-only evidence and documents a separate, incomplete ECOS full-RDTC routing attempt. The latter is not a physical profile or timing claim because it produced no routed handoff.

Verified internal reg-to-reg timing covers only the recorded internal single-clock paths. It is not complete top-level IO timing, reset recovery/removal closure, OCV/MMMC, foundry DRC/LVS/PEX, foundry signoff, or silicon readiness.
