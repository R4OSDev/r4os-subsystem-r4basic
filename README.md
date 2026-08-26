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
replaying old samples. Unavailable audio degrades visibly, clears the queued
PCM once, and leaves the audio deadline scheduler; guest time, input, and
graphics retain their normal bounded pacing without repeated scratch work.

## Package

- Module: `R4BASIC.R4X`
- Module version: `1.2.12`
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

R4BASIC 1.2.12 uses a shared 262,144-instruction ceiling with adaptive bounded
clock blocks and an 8-ms production time boundary. Active work requests a
scheduler yield at most once per 8-ms interval; input-only waits, pause and
static status windows block on the Desktop activity sequence. The first guest
surface is prepared only after BASIC output, an explicit SCREEN operation or
a bounded display-silent fallback, so an immediate mode switch no longer pays
for a preceding empty SCREEN-0 frame. `Tests/performance_test.zig` checks these
host-cycle, budget/time and lazy-display bounds alongside string ownership,
borrowed built-ins, retained lazy-local frame pools, compact numeric arrays,
atomic bounded `REDIM`, and bounded formatting/VAL storage. `/PERFTEST` prints
separate QEMU-readable numeric, 4-KB assignment, LEN, UCASE$, call and array
markers plus an exact summary. The productive artifact remains the canonical
GUI subsystem host and uses its measured module-local `OPTIMIZE=speed` profile.

The 1.2.12 input profile emits each printable key exactly once as text,
retains Enter and Backspace as keys, and filters pointer traffic before guest
coordinate mapping. Stable sequence/tick metadata follows accepted bytes to
consumption; bounded counters distinguish focus, invalid-code, unsupported,
full-queue and allocation drops and correlate consumed input with the next
published frame without per-event logging.

Text rows, lines, filled regions and flood fill now commit one accumulated
damage region per operation. Same-size `SCREEN` changes clear and reuse their
surface, invisible full-circle polygons are rejected before their segment
trigonometry, and numeric-array `GET`/`PUT` use only the packed image prefix
without a whole-array conversion buffer. Pixel-exact full-raster hashes and
the unchanged checksum-bound GORILLA acceptance guard the QBasic output.

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
