# R4BASIC.R4X

R4BASIC is the QBasic-compatible subsystem host for R4OS. It is a normal GUI
R4X module with the subsystem identity `r4os.basic` and the guest format
`basic.qbasic-source`.

The installed R4X is the productive R4BASIC v2 foundation. Explorer passes one
absolute `.BAS` path through `R4SUBSYS1`; R4BASIC loads it through the storage
facade, compiles it once, and runs an isolated VM in a movable, resizable, and
maximizable window. `SCREEN 0`, `SCREEN 1`, and `SCREEN 9` are presented as
whole or damaged indexed raster frames through `r4os.subsystem_host`.

`BEEP` and the supported QuickBASIC `PLAY` Music Macro Language generate
24 kHz stereo PCM through the buffered subsystem runtime; HDA converts it to
the 48 kHz hardware format. Foreground and background playback follow `MF`
and `MB`. No service session is opened until the first non-silent source
quantum. The productive host buffers four 40 ms source quanta, but performs
at most one open, write, or close operation after video publication in each
host cycle. Busy retries use an independent 10 ms deadline and late prefill
is interleaved instead of emitted as one synchronous burst. Foreground BASIC
waits resolve on accepted, deliberately suppressed, or explicitly discarded
source frames—not elapsed guest time. The platform exposes no per-stream
hardware playback cursor, and R4BASIC does not infer one from service
acceptance. Unavailable audio degrades visibly without stopping guest time,
input, or graphics.

## Package

- Module: `R4BASIC.R4X`
- Module version: `1.2.20`
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

R4BASIC 1.2.20 allocates the exact source size once, fills that buffer with
range reads up to the 256 KiB source limit, and transfers the same allocation
to the compiler. The launch report records metadata calls, range-read calls,
and bytes so the productive GORILLA acceptance can require one source load
after a metadata-only Explorer/Desktop resolution.

Sequential BASIC files use the asynchronous R4SYS resource facade with one
outstanding request and 64-KiB transfers. INPUT keeps a rolling buffer and
normalizes each repeated path through a four-entry typed cache; OUTPUT and
APPEND publish confirmed prefixes incrementally, including partial writes.
The VM yields at a one-millisecond guest deadline while a request is pending,
so input, presentation, audio, and lifecycle work continue between polls.
`CLOSE` and normal `END` drain the same bounded output state without duplicate
bytes. Reset and teardown quiesce a non-cancellable request before releasing
its VM-owned buffer. The `R4BASIC file-io` report makes submissions, polls,
path work, transfer maxima, compaction, and buffer peaks measurable.

R4BASIC 1.2.20 uses a shared 262,144-instruction ceiling with adaptive bounded
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

The 1.2.20 input profile emits each printable key exactly once as text,
retains Enter and Backspace as keys, maps supported extended keys atomically
to QuickBASIC null/scancode pairs, and filters pointer traffic before guest
coordinate mapping. Stable sequence/tick metadata follows every accepted byte
to consumption; bounded counters distinguish focus, invalid-code,
unsupported, full-queue and allocation drops and correlate consumed input
with the next published frame without per-event logging. `INPUT$` consumes an
exact byte count from console or sequential files without blocking the host.

Variable and fixed strings are independent byte owners up to 32,767 bytes.
Fixed scalar, array and record values pad or truncate on assignment and never
share mutable storage. `MID$` assignment and the completed string built-ins
operate on the same bounded representation. Screen and sequential-file
output share one QuickBASIC formatter for ordinary `PRINT`, `PRINT USING`,
`PRINT # USING`, `WRITE`, and `WRITE #`; WRITE output round-trips through the
same `INPUT #` field decoder.

R4BASIC 1.2.20 completes the declaration and storage foundation. All five
`DEFtype` statements, suffix/`AS` precedence, `OPTION BASE`, implicit arrays,
`$STATIC`/`$DYNAMIC`, `ERASE`, bounds queries, and atomic `REDIM PRESERVE`
now follow source order and the 60-dimension limit. Automatic, procedure-
static, explicitly static, shared, and COMMON-backed cells are isolated per
VM and reset deterministically. Nested records use canonical guest byte
offsets rather than host layouts; record assignment, `LEN`, `LSET`/`RSET`,
`SWAP`, and `CLEAR` operate on the same owned representation.

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

`COMPATIBILITY.md` is the versioned R4BASIC v2 target contract.
`src/conformance.zig` assigns stable, test-validated IDs and layer status to
Part 1, all 193 Part-2 entries, three metacommands, and 43 runtime errors.
The compiler Builder is the sole parser and binder; unimplemented targets are
compile diagnostics and never Deferred runtime opcodes. `VM-CONTRACT.md`
freezes the executable foundation, budgets, isolation, and lifecycle rules.

Detailed German technical documentation is in `DOCUMENTATION.de.txt`.
Reference and implementation provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Reference provenance is recorded in `THIRD_PARTY_NOTICES.md`.
