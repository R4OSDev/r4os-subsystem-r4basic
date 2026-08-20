# R4BASIC.R4X

R4BASIC is the QBasic-compatible subsystem host for R4OS. It is a normal GUI
R4X module with the subsystem identity `r4os.basic` and the guest format
`basic.qbasic-source`.

The installed R4X is the productive R4BASIC v1 host. Explorer passes one
absolute `.BAS` path through `R4SUBSYS1`; R4BASIC loads it through the storage
facade, compiles it once, and runs an isolated VM in a movable, resizable, and
maximizable window. `SCREEN 0`, `SCREEN 1`, and `SCREEN 9` are presented as
whole or damaged indexed raster frames through `r4os.subsystem_host`.

`BEEP` and the supported QuickBASIC `PLAY` Music Macro Language generate
24 kHz stereo PCM through the buffered subsystem runtime; HDA converts it to
the 48 kHz hardware format. Foreground and background playback follow `MF`
and `MB`. The productive host buffers four 40 ms source quanta, covering the
160 ms HDA start window so delayed interpreter or presentation cycles do not
fragment notes. Longer delays resynchronize the source timeline instead of
replaying old samples. Unavailable audio degrades visibly without stopping
guest time, input, or graphics.

## Package

- Module: `R4BASIC.R4X`
- Module version: `1.2.0`
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
procedure structure, and executes its intro, edited input, city construction,
banana flight, building collision, gorilla explosion, victory dance, and
updated score. The final 640 by 350 indexed image, palette, and twelve real
`PLAY` sequences have deterministic golden values. The file is not part of
this repository and is read directly from the ignored workspace injection
tree. The normal test step uses the permanent general BAS fixtures under
`Tests/Fixtures`, including the standalone audio contract.

R4BASIC 1.1 uses the shared 4,096-instruction runtime budget with an 8-ms
production time boundary instead of the former 26-instruction/2-ms throttle.
Runnable code returns without a fixed wake; repeated TIMER polls alone yield
cooperatively at a 1-ms guest-time boundary. `Tests/performance_test.zig`
checks budget and time bounds plus opcode-group counters. `/PERFTEST` prints a
QEMU-readable throughput marker. The verified Standard-QEMU run reached
2,329,098 instructions per second with 4,096 instructions per maximum slice
and no fixed sleep; the productive artifact remains the canonical GUI
subsystem host.

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
