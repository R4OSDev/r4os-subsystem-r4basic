# R4BASIC.R4X

R4BASIC is the QBasic-compatible subsystem host for R4OS. It is a normal GUI
R4X module with the subsystem identity `r4os.basic` and the guest format
`basic.qbasic-source`.

The installed R4X is the productive R4BASIC v2 foundation. Explorer passes one
absolute `.BAS` path through `R4SUBSYS1`; R4BASIC loads it through the storage
facade, compiles it once, and runs an isolated VM in a movable, resizable, and
maximizable window. The logical QuickBASIC `SCREEN` modes 0, 1, 2, and 7
through 13 are presented as whole or damaged indexed raster frames through
`r4os.subsystem_host`.

`BEEP`, `SOUND`, and the complete bounded QuickBASIC `PLAY` Music Macro
Language generate 24 kHz stereo PCM through the buffered subsystem runtime;
HDA converts it to the 48 kHz hardware format. Foreground and background
playback follow `MF` and `MB`. No service session is opened until the first
non-silent source quantum. The productive host buffers four 40 ms source
quanta, but performs at most one open, write, or close operation after video
publication in each host cycle. Busy retries use an independent 10 ms
deadline and late prefill is interleaved instead of emitted as one synchronous
burst. Foreground BASIC waits resolve on accepted, deliberately suppressed,
or explicitly discarded source frames—not elapsed guest time. The platform
exposes no per-stream hardware playback cursor, and R4BASIC does not infer one
from service acceptance. Unavailable audio degrades visibly without stopping
guest time, input, events, or graphics.

## Package

- Module: `R4BASIC.R4X`
- Module version: `1.2.27`
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

R4BASIC 1.2.22 allocates the exact source size once, fills that buffer with
range reads up to the 256 KiB source limit, and transfers the same allocation
to the compiler. The launch report records metadata calls, range-read calls,
and bytes so the productive GORILLA acceptance can require one source load
after a metadata-only Explorer/Desktop resolution.

Sequential BASIC files use the asynchronous R4SYS resource facade with one
outstanding request and 64-KiB transfers. INPUT keeps a rolling buffer and
normalizes each repeated path through a four-entry typed cache; OUTPUT and
APPEND publish confirmed prefixes incrementally, including partial and
positioned writes. `SEEK` drains earlier output before changing the 1-based
position, while APPEND initializes that position from the real EOF.
The VM yields at a one-millisecond guest deadline while a request is pending,
so input, presentation, audio, and lifecycle work continue between polls.
`CLOSE` and normal `END` drain the same bounded output state without duplicate
bytes. Reset and teardown quiesce a non-cancellable request before releasing
its VM-owned buffer. The `R4BASIC file-io` report makes submissions, polls,
path work, transfer maxima, compaction, and buffer peaks measurable.

RANDOM and BINARY files use the same single-request rule and bounded 64-KiB
chunks. Modern and legacy OPEN syntax support ACCESS, SHARED/LOCK and LEN;
GET/PUT serialize numeric scalars, strings, whole arrays and UDTs in canonical
little-endian guest layout. RANDOM enforces exact record lengths and FIELD
overlays a fixed record buffer whose bindings are invalidated by CLOSE/RESET.
BINARY supports sparse offset writes and `INPUT$`. `LOC`, `LOF`, `EOF`,
`SEEK`, `FILEATTR`, `FREEFILE`, exact range LOCK/UNLOCK and all classified
file errors operate on confirmed state. R4SYS supplies asynchronous write-at,
size-query and instance-owned range-lock operations; no DOS handle escapes.

R4BASIC 1.2.23 completes the R4OS platform boundary. `CHDIR`, `MKDIR`,
`RMDIR`, `FILES`, `KILL`, and `NAME` resolve VM-local per-drive working
directories into typed R4OS paths, reject root escape and reserved devices,
and keep wildcard directory work cooperative. `COMMAND$`, `ENVIRON`, and
`ENVIRON$` consume bounded `R4SUBSYS1` launch records and retain independent
state per VM. `DATE$`, `TIME$`, and `TIMER` use injected R4OS wall time while
all deadlines and host slices remain monotonic.

`RUN` and `CHAIN` replace a guest only after its complete bounded source graph
has loaded and compiled. The same R4X window host remains alive; `CHAIN`
deep-copies compatible COMMON state, supports the documented ALL transfer,
and applies the R4BASIC `DELETE first-last` extension to the target graph
before compilation. `SHELL` invokes the R4OS Terminal process facade with an
opaque `/C` argument and polls its process handle cooperatively. `SYSTEM`,
normal completion, error, cancellation, and Close share one idempotent
resource teardown.

R4BASIC 1.2.24 completes the logical QuickBASIC screen, page, palette, and
coordinate foundation. Every mode has its reference resolution, text grid,
attribute count, packed page layout, page limit, and deterministic default
palette. `SCREEN` selects independent active and visible pages, `PCOPY`
copies both text and graphics state, and hidden-page changes remain invisible
to the presenter until that page is selected. `PALETTE`, `PALETTE USING`,
mode-specific `COLOR`, `WIDTH`, `CLS`, `LOCATE`, `VIEW PRINT`, the text
`SCREEN` function, and every `POINT` form operate on the selected page with
validated atomic updates.

`VIEW` fill and its outside border, `WINDOW`/`WINDOW SCREEN`, `PMAP`, `STEP`,
and current-point queries share one reversible transform and clipping path.
PMAP physical coordinates remain viewport-relative, while `POINT(0..1)`
follows the coordinate convention selected by `VIEW` versus `VIEW SCREEN`.
Graphics mode changes and graphics `CLS` establish the center point; `PAINT`
preserves it.
Palette changes recolor existing indices without rewriting pixels. Page and
copy counters supplement the bounded eight-region damage ledger; a hidden or
unchanged page produces no false frame, visible-page rebinding is generation
safe, and the presentation path retains 128 by 128 maximum tiles without
per-pixel R4DRAW calls.

R4BASIC 1.2.25 completes the QuickBASIC graphics primitives and image-data
paths on that foundation. `PSET`/`PRESET`, omitted and independent `STEP`
line endpoints, boxes, 16-bit styles, circles, ellipses, radial arcs, solid
and tiled `PAINT`, and the complete bounded `DRAW` macro language share the
same coordinate, clipping, current-point, span, and damage contracts. Invalid
DRAW macros are fully parsed and validated before pixels or persistent macro
state can change. One combined primitive/pattern raster hash for every
graphics mode fixes the result independently of host presentation.

Graphics `GET` and `PUT` now cover every mode, INTEGER/LONG/SINGLE/DOUBLE
arrays, arbitrary complete index tuples including storage beyond 64 KiB, and
`PSET`, `PRESET`, `AND`, `OR`, and default `XOR`. They touch only the exact
packed image prefix. `BLOAD` and `BSAVE` resumably transfer the seven-byte
QuickBASIC memory-image format through the asynchronous Storage facade. Each
VM owns its real-mode guest address space; only active packed `A000`/`B800`
video ranges are mapped, and no guest address is ever a host pointer. Input
also accepts the validated BASICA and GW-BASIC trailer variants atomically.

R4BASIC 1.2.26 completes audio, keyboard, timer, and device-event behavior.
One fixed, VM-local dispatcher implements `ON ... GOSUB` and `ON`/`OFF`/`STOP`
for `KEY`, `TIMER`, `PLAY`, `COM`, `PEN`, `STRIG`, and `UEVENT`, including
coalescing, stable cross-source priority, nested handlers, and reference
`RETURN` reactivation. Event checks happen only at safe statement boundaries;
monotonic TIMER deadlines and input activity wake the cooperative scheduler
without polling.

Function-key traps, cursor and extended keys, user-defined modifier/scancode
keys, 15-byte soft-key macros, `KEY ON`/`OFF`/`LIST`, and exact one- or
two-byte `INKEY$` input share one bounded queue. Pointer input feeds a private
ten-value `PEN` device; two optional virtual joysticks feed `STICK` and
`STRIG`, while absent devices return deterministic neutral values. `PLAY`
now includes numeric and string-variable expansion, all note/rest/tempo/
octave/length/articulation commands, a 32-note background bound, `PLAY(n)`
events, and `PLAY(n)` queue inspection. `SOUND` uses the documented 18.2-Hz
tick duration and the same transport-confirmed `MF`/`MB` fences as `BEEP`.

R4BASIC 1.2.27 completes the private legacy and binary-interoperability
machine. Every VM owns an exact 1-MiB 20-bit address space with real-mode
segment wrapping, stable value/string/array descriptors, bounded near/far
heaps and no conversion from a BASIC number to a host pointer. `DEF SEG`,
`PEEK`/`POKE`, `SADD`, `VARPTR`/`VARSEG`/`VARPTR$`, `FRE`, `SETMEM`, and the
`CLEAR` memory parameters all operate on that private state. `CALL ABSOLUTE`
runs a cancellable, instruction-budgeted 16-bit x86 guest; declared
`CALL`/`CALLS` symbols and the INT86/INTERRUPT families reach only registered
private modules and virtual BIOS/DOS services.

`INP`, `OUT`, and cooperative `WAIT` share one sparse VM-local virtual port
bus. `OPEN COM`, `IOCTL`/`IOCTL$`, and COM events use bounded partial RX/TX
buffers without blocking host I/O. `LPRINT`, `LPRINT USING`, `LPOS`, and all
`WIDTH` forms use the common formatter on a bounded virtual spool or virtual
channel. Device faults update `ERDEV`/`ERDEV$`; all 43 Appendix-B numbers
round-trip through `ERROR`, `ERR`, `ERL`, `ON ERROR`, and `RESUME`.

R4BASIC 1.2.22 uses a shared 262,144-instruction ceiling with adaptive bounded
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

The 1.2.22 input profile emits each printable key exactly once as text,
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

R4BASIC 1.2.22 completes the declaration and storage foundation. All five
`DEFtype` statements, suffix/`AS` precedence, `OPTION BASE`, implicit arrays,
`$STATIC`/`$DYNAMIC`, `ERASE`, bounds queries, and atomic `REDIM PRESERVE`
now follow source order and the 60-dimension limit. Automatic, procedure-
static, explicitly static, shared, and COMMON-backed cells are isolated per
VM and reset deterministically. Nested records use canonical guest byte
offsets rather than host layouts; record assignment, `LEN`, `LSET`/`RSET`,
`SWAP`, and `CLEAR` operate on the same owned representation.

R4BASIC 1.2.22 also completes BASIC procedure and central error flow.
Declarations validate ByRef/ByVal scalars, dimensioned arrays, records,
fixed-string temporaries and AS ANY; SUB/FUNCTION recursion and STATIC remain
VM-local. One-line and multiline DEF FN support module scope, STATIC,
EXIT DEF and END DEF. Multi-NEXT, CASE IS and indexed ON GOTO/GOSUB use only
resolved bounded targets. ERROR, ERR, ERL, ON ERROR and every RESUME form
share exact diagnostics across call frames. STOP is an event-only pause and
TRON/TROFF emit visible markers while retaining only a 256-entry trace ring.

Text rows, styled lines, filled regions, tiled flood fill, decoded images and
packed video loads commit bounded accumulated damage per operation. Same-size
`SCREEN` changes clear and reuse their surface, invisible full-circle polygons
are rejected before their segment trigonometry, and numeric-array `GET`/`PUT`
use only the packed image prefix without a whole-array conversion buffer.
Pixel-exact per-mode full-raster hashes and the unchanged checksum-bound
GORILLA acceptance guard the QuickBASIC output.

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
