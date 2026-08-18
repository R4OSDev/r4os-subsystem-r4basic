# R4BASIC.R4X

R4BASIC is the QBasic-compatible subsystem host for R4OS. It is a normal GUI
R4X module with the subsystem identity `r4os.basic` and the guest format
`basic.qbasic-source`.

The current release keeps the versioned R4BASIC v1 source contract and adds
an instance-local indexed graphics screen to the one-time compiler and
cooperative VM. `SCREEN 1` and `SCREEN 9`, palettes, drawing, packed images,
and coordinate `POINT` now execute against guest memory and are published as
whole or damaged raster frames through `r4os.subsystem_host`.

The installed R4X does not load a guest file or open its final BASIC window
yet. Audio remains a separate later layer; its accepted source forms still
compile to visible deferred host guards rather than silently doing nothing.

## Package

- Module: `R4BASIC.R4X`
- Module version: `0.5.0`
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

The local compatibility acceptance uses the checksum-bound source file
documented in `COMPATIBILITY.md`:

    Build.bat gorilla-test

That step verifies and parses the unchanged file, binds its complete data and
procedure structure, and executes its intro, input path, city construction,
gorilla images, packed banana animation, collision queries, and one complete
graphical turn. The final 640 by 350 indexed image and programmed palette
have deterministic golden values. A test-only explicit host accepts only the
still-deferred audio statements. The file is not part of this repository and
is read directly from the ignored workspace injection tree. The normal test
step uses the permanent general BAS fixtures under `Tests/Fixtures`.

The build starters map the current local R4OS SDK and Contract checkouts from
`Settings.R4S`. The URL and hash in `build.zig.zon` record the last verified
standalone SDK identity; workspace builds replace it with the mapped local
checkout.

## Compatibility contract

`COMPATIBILITY.md` is the versioned R4BASIC v1 source-language contract. It
states exactly what the frontend accepts and what remains outside that
surface. `VM-CONTRACT.md` separately freezes the subset that is already
bound and executed, including value semantics, bytecode, diagnostics,
instruction budgets, and instance isolation. A construct does not become an
execution promise merely because its syntax parses.

Detailed German technical documentation is in `DOCUMENTATION.de.txt`.
Reference and implementation provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Reference provenance is recorded in `THIRD_PARTY_NOTICES.md`.
