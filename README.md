# R4BASIC.R4X

R4BASIC is the QBasic-compatible subsystem host for R4OS. It is a normal GUI
R4X module with the subsystem identity `r4os.basic` and the guest format
`basic.qbasic-source`.

The current frontend release defines and validates the R4BASIC v1 source
contract. It tokenizes and parses the required module, declaration,
procedure, control-flow, expression, text, graphics, audio, error, and
sequential-file syntax without executing guest code yet.

## Package

- Module: `R4BASIC.R4X`
- Module version: `0.1.0`
- Subsystem ID: `r4os.basic`
- Display name: `R4BASIC`
- Guest format: `basic.qbasic-source`
- Guest extension: `.bas`
- Image target: `/R4OS/SUBSYSTEMS/r4os.basic/R4BASIC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

## Build and test

On Windows:

    Build.bat test

On Linux or macOS:

    ./Build.sh test

The optional local compatibility acceptance uses the checksum-bound source
file documented in `COMPATIBILITY.md`:

    Build.bat gorilla-test

That file is not part of this repository and is never downloaded by the
build. The normal public test step uses only original, redistributable BAS
fixtures under `Tests/Fixtures`.

The build starters map the current local R4OS SDK and Contract checkouts from
`Settings.R4S`. The URL and hash in `build.zig.zon` record the last verified
standalone SDK identity; workspace builds replace it with the mapped local
checkout.

## Compatibility contract

`COMPATIBILITY.md` is the versioned R4BASIC v1 language-surface contract. It
states exactly what the source frontend accepts, what the public fixtures
cover, and what remains outside v1. Runtime semantics, bytecode execution,
graphics, input, time, files, and audio are implemented in later subsystem
layers and do not become promises merely because their syntax parses.

Detailed German technical documentation is in `DOCUMENTATION.de.txt`.
Reference and implementation provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. No third-party source or the local compatibility program is
redistributed in this repository; see `THIRD_PARTY_NOTICES.md`.
