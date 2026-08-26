# R4BASIC v1 core VM contract

Contract version: `1.12.0`

This document freezes the executable R4BASIC language layers. The broader
source syntax accepted by the frontend remains defined in
`COMPATIBILITY.md`; parse success alone does not extend this VM contract.

## Compilation model

- The caller supplies the source bytes and file name. The compiler owns
  immutable copies in the resulting program.
- Source is tokenized once. Parsing, symbol binding, type selection, jump
  resolution, and instruction emission then operate on that token stream.
- A successful program records one parse pass and one bind pass. VM
  instances reference the prepared program and never tokenize or parse it.
- The hot instruction stream contains only an opcode and two bounded
  operands (12 bytes). A parallel, equally long metadata stream contains the
  exact source span and statement bounds (24 bytes). Both streams use the
  same O(1) instruction index; branch operands are resolved instruction
  indices, not source labels or text offsets.
- A program with any compile diagnostic cannot initialize a VM.

## Symbols and scopes

- Module code owns globals, module constants, named labels, and procedure
  signatures.
- A `SUB` or `FUNCTION` owns its parameters, locals, hidden loop values, and
  labels. An unshared module variable is not silently captured by a normal
  procedure.
- `DIM SHARED` exposes a module variable to procedures. Constants are visible
  from procedure scopes and cannot be assigned after initialization.
- `DEFINT` changes the default type by initial letter. The suffixes `%`, `&`,
  `!`, `#`, and `$` override that default for INTEGER, LONG, SINGLE, DOUBLE,
  and String respectively. Without either rule the default is SINGLE.
- Names and labels compare case-insensitively in ASCII while their original
  source spans remain unchanged.
- Labels are local to module code or the containing procedure. Missing and
  duplicate labels are compile diagnostics.

Arrays and records are normal scoped variables. Array bounds and record
layouts are immutable program metadata; elements, bounds, data cursors,
aliases, and error-handler state belong to each VM instance.

## Arrays, records, and DATA

- `DIM` supports up to 60 dimensions with explicit signed lower and upper
  bounds. An omitted lower bound is zero. `DIM SHARED` exposes the same
  instance-local aggregate to procedures.
- `'$DYNAMIC` and `REM $DYNAMIC` mark following declarations dynamic;
  `REDIM` reallocates a dynamic array with the same rank and element type and
  resets every element. A VM limits one array to 16,777,216 elements before
  attempting allocation. INTEGER, LONG, SINGLE, and DOUBLE arrays use exact
  2-, 4-, 4-, and 8-byte typed payloads; strings and records retain generic
  Cells. The logical payload of all live arrays is limited to 128 MiB and an
  atomic resize transition, including old/new dimensions, to 192 MiB. A
  rejected `DIM` or `REDIM` reports out-of-memory before replacing the old
  dimensions or payload.
- `TYPE` layouts contain named scalar fields. Scalar records and arrays of
  records initialize every field independently. Qualified field access is
  bound to a field index; arbitrary byte offsets do not exist.
- Array and record references use storage aliases, including scalar array
  elements and record fields. Alias targets stay inside VM-owned global,
  frame, array, or record cells.
- All `DATA` items form one immutable source-ordered program table. Each VM
  owns its own cursor. `READ` converts into the bound scalar target and
  `RESTORE` selects item zero or a compile-resolved module data label.
- Signed LONG items retain their exact 32-bit value. `REDIM` and `READ` do
  not reinterpret numeric image data through floating point.
- Sequential file numbers retain O(1) lookup through a 256-byte direct index.
  Only open files own slots and buffers; the VM does not embed 256 complete
  optional file objects.

## Values and operations

- INTEGER is signed 16-bit, LONG is signed 32-bit, SINGLE is IEEE binary32,
  and DOUBLE is IEEE binary64.
- Strings are owned byte strings with a maximum length of 32,767 bytes. They
  are not Unicode-decoded and may contain bytes above ASCII. Concatenation or
  a literal beyond the limit reports overflow.
- Loading a string variable for assignment creates one distinct owner. A
  same-type store moves that owner into the target and does not clone it a
  second time; source and destination never share mutable ownership.
- Numeric assignment converts to the target type. Floating-to-integer
  conversion rounds the absolute half away from zero and then checks the
  target range. Non-finite input and an out-of-range result report overflow.
- Arithmetic promotes INTEGER to LONG to SINGLE to DOUBLE. `/` produces
  SINGLE unless a DOUBLE operand requires DOUBLE. `\` and `MOD` first apply
  the defined integer rounding to their operands; integer division truncates
  its quotient toward zero.
- Division by zero and numeric overflow are visible runtime errors. Numeric
  and string categories never convert implicitly into one another.
- Comparisons return INTEGER `-1` for true and `0` for false. The compiler
  records the bound operand type: INTEGER/LONG pairs compare without a
  floating conversion, while SINGLE/DOUBLE and mixed floating pairs retain
  the established binary64 comparison path. Conditions accept every nonzero
  numeric value as true and reject strings.
- `NOT`, `AND`, `OR`, and `XOR` use signed LONG bit operations. Power is
  right-associative, is evaluated by the injected math host, and rejects a
  negative base with a non-integral exponent.

## Executable statements

The VM executes:

- `CONST`, `DEFINT`, scalar and array `DIM`, `DIM SHARED`, `REDIM`, `TYPE`,
  qualified assignment, `DATA`, `READ`, and `RESTORE`;
- block and single-line `IF`, `ELSEIF`, and `ELSE`;
- `SELECT CASE`, comma alternatives, inclusive `TO` ranges, and `CASE ELSE`;
- positive, negative, and zero-step `FOR`/`NEXT`, including `EXIT FOR`;
- `WHILE`/`WEND`;
- unconditional, leading-`WHILE`, leading-`UNTIL`, trailing-`WHILE`, and
  trailing-`UNTIL` `DO`/`LOOP`, including `EXIT DO`;
- named `GOTO`, `GOSUB`, plain `RETURN`, and `RETURN` to a named label;
- `ON ERROR GOTO`, `ON ERROR GOTO 0`, `RESUME`, and `RESUME NEXT`;
- the restricted `DEF SEG`, `PEEK`, and `POKE` compatibility device;
- `SCREEN 0`, 80-column `WIDTH`, `COLOR`, `CLS`, `LOCATE`, and
  `VIEW PRINT` on the private text screen;
- screen and sequential-file `PRINT`, console and file `INPUT`, and
  `LINE INPUT`;
- `SCREEN 1`, `SCREEN 9`, `PALETTE`, `PSET`, coordinate `POINT`, `LINE`
  including `B` and `BF`, `CIRCLE`, `PAINT`, and packed `GET`/`PUT` with
  `PSET` and `XOR`;
- `BEEP` and `PLAY` with the bounded Music Macro Language described below;
- `RANDOMIZE`, `SLEEP`, and sequential `OPEN`/`CLOSE`;
- `END`.

Audio statements bind directly to instance-local bytecode operations. An
invalid Music Macro Language command raises catchable BASIC error 5 without
partially changing the queue or persistent music settings.

## Procedures and functions

- `DECLARE SUB`, `DECLARE FUNCTION`, `SUB`, `FUNCTION`, explicit `CALL`, and
  implicit SUB calls use validated signatures.
- Parameters default to ByRef. An exact-type scalar lvalue aliases its
  storage; an expression uses a converted temporary as QuickBASIC does.
  `BYVAL` always copies and converts a scalar value.
- Whole arrays use the required empty-parentheses call syntax and are passed
  ByRef. Declaration-side `AS ANY` suppresses only the element-type check;
  the concrete SUB or FUNCTION definition still fixes the runtime type.
  Records and scalar array elements are real aliases rather than copies.
- Every call owns a separate frame, local values, return address, and stack
  base. Local slot capacity is retained per active recursion depth, while a
  fresh generation initializes only parameters, returns and locals reached by
  executed bytecode. Teardown destroys exactly those initialized Cells.
  Recursion is supported up to 256 simultaneous frames.
- Functions own a typed return cell addressed by their function name.
  `EXIT SUB` and `EXIT FUNCTION` return immediately through the same frame
  teardown path as the matching terminator.
- One-line `DEF FN` parameters are always ByVal. The body can read module
  variables and returns the declared or inferred function type.
- GOSUB return addresses use a separate, frame-aware stack with a maximum
  depth of 1,024.

## Built-in functions and host services

The executable built-ins are `ABS`, `ATN`, `CHR$`, `CINT`, `COS`, `EOF`,
`INKEY$`, `INSTR`, `INT`, `LEFT$`, `LEN`, `LTRIM$`, `MID$`, coordinate
`POINT`, `RND`, `SIN`, `SPACE$`, `STR$`, `TIMER`, `UCASE$`, and `VAL` with
the arities and type categories defined by the source contract.

Simple scalar string lvalues are passed to read-only built-ins as non-owning
Cell references. Numeric and expression arguments remain owned stack values,
and every string result owns independent storage. Numeric PRINT and STR$ use
a bounded 128-byte format buffer; STR$ allocates only its final result. VAL parses
ordinary E/e text directly, normalizes short D/d text on the stack and reuses
one VM-owned scratch buffer only for longer D/d input.

`ATN`, `COS`, `SIN`, and power call an injected math service. Cancellation
polling, the SCREEN-mode availability probe, and sequential file I/O are
injected separately. A missing or failing required host result becomes a
deterministic VM error; tests do not depend on hidden process-global hooks.

`DEF SEG = 0` selects a private compatibility byte at offset 1047. `PEEK` and
`POKE` can read or replace that byte, including its NumLock bit. Omitting the
segment resets access. Every other segment or offset is a runtime error; no
guest address can become an R4OS or host pointer.

## Text screen and interactive input

- Every VM owns one 25-row cell screen with 80 active columns in modes 0 and
  9 and 40 active columns in mode 1. A cell contains one byte,
  foreground attribute 0 through 31, and background attribute 0 through 7.
  Cursor position, visibility, shape, print viewport, and revision are part
  of that same instance-local state.
- `SCREEN 0` resets the text screen. `WIDTH` accepts the active mode width
  and an optional 25 rows. In graphics modes text cells are rasterized into
  the same guest pixel buffer using a subsystem-local 8 by 8 ASCII font;
  mode 9 maps it deterministically onto 8 by 14 cells. `CLS 2` clears only
  the active text viewport. Invalid multi-argument `COLOR` or `LOCATE`
  updates are atomic.
- BASIC rows and columns are one-based. `VIEW PRINT top TO bottom` selects an
  inclusive scrolling region; bare `VIEW PRINT` restores rows 1 through 25.
  Output outside that region can be positioned with `LOCATE`, while newline
  scrolling remains confined to the region.
- `PRINT` preserves a trailing semicolon, advances commas through 14-column
  zones, applies one-based `TAB`, and emits a newline only without a trailing
  separator. Positive numbers carry leading and trailing spaces; negative
  numbers carry the sign and trailing space.
- Each VM owns a focused keyboard byte queue of at most 4,096 bytes. Every
  queued byte retains the stable host-input sequence and raw tick until it is
  consumed. Printable text, Enter, and Backspace are accepted only while
  focused.
- R4BASIC requests text-only printable keys and no pointer mapping from the
  generic subsystem host. Printable keys therefore enter the guest exactly
  once; Enter and Backspace retain their key form. Unfocused, invalid
  codepoint, unsupported key/event, full-queue, and allocation failures are
  distinct bounded drop results. Passive counters preserve raw/logical/
  accepted/consumed counts, queue high water and the last accepted, dropped,
  consumed and visibly presented input stamps without a hot-path log.
  `INKEY$` consumes at most one byte and returns an allocated empty string
  immediately when the queue is empty.
- Console `INPUT` and `LINE INPUT` retry the same instruction without
  blocking the host. Editing echoes printable bytes, erases one byte on
  Backspace, and completes on Enter. A line is limited to 255 bytes. All
  target values are parsed before any assignment; invalid or overflowing
  input prints `Redo from start` and leaves every target unchanged.

## Indexed graphics screen

- Each VM owns a host-visible 640 by 400 `SCREEN 0` text raster, a 320 by 200
  `SCREEN 1` surface with four attributes, or a 640 by 350 `SCREEN 9` surface
  with sixteen attributes. Graphics primitives remain illegal in mode 0.
  Pixels are indexed bytes and the mutable 256-entry XRGB palette is separate,
  so `PALETTE` recolors existing graphics pixels immediately.
- Mode changes reset the default CGA/EGA palette, current graphics point and
  text geometry, clear every target pixel, and mark one full damage rectangle.
  A same-size surface allocation is retained and cleared; a different size is
  allocated atomically before the previous surface is released. An injected
  unavailable mode raises catchable BASIC error 5 without replacing the
  previous surface, which permits the normal `ON ERROR` fallback from mode 9
  to mode 1.
- Coordinates apply BASIC numeric rounding before clipping. `PSET` clips
  silently, `POINT` returns the stored attribute or `-1` outside the screen,
  and `LINE` uses the current point for `STEP`. Boxes, filled boxes, arcs,
  aspect-scaled circles, and bounded flood fill modify only guest pixels.
- `GET` writes the four-byte QuickBASIC header followed by mode-appropriate
  packed data into the raw bytes of any numeric array. Mode 1 packs two bits
  per pixel; mode 9 stores four one-bit planes per scan line. `PUT` decodes
  the same representation with exact `PSET` or attribute-wise `XOR` and
  rejects an image extending outside the guest surface. LONG DATA therefore
  remains bit-exact and needs no program-specific conversion. On the x86_64
  target the compact numeric storage is already the required little-endian
  raw view: `GET` writes only the image prefix and `PUT` reads only the bytes
  named by its header, without serializing an oversized array.
- Pixel changes, palette changes, and text-cell rasterization merge into one
  damage rectangle. Text rows, clipped line pixels, solid spans, scanline
  flood-fill runs and decoded image rows accumulate that rectangle locally
  and advance the content revision once per changed operation. The runtime
  adapter hands an Indexed8 surface to
  `r4os.subsystem_host`; it never calls R4DRAW for individual primitives.
  A 640 by 350 full frame becomes fifteen bounded raster blocks, later
  changes use damage frames, and an unchanged guest image publishes no frame.
  Mode revisions remain distinct across VM reset so a presenter always binds
  the replacement pixel allocation before publishing it.

## Audio and Music Macro Language

- Every VM owns its music settings, queued events, oscillator phase,
  cumulative source-frame fences, and counters. Reset and teardown clear them
  without touching any other instance.
- `PLAY` accepts case-insensitive `O0` through `O6`, `<`, `>`, `L1` through
  `L64`, `T32` through `T255`, `MB`, `MF`, `MN`, `ML`, `MS`, notes `A` through
  `G` with `#`, `+`, or `-`, optional note lengths and dots, `P` pauses, and
  numeric notes `N0` through `N84`. Octave, default length, tempo, mode, and
  articulation persist within one VM.
- `MB` queues a sequence and lets the next BASIC instruction continue. A
  normal fast `END` keeps only the host transport alive until those frames
  have been accepted, suppressed as silence, or explicitly discarded. `MF`
  and the 800 Hz, 200 ms `BEEP` wait on the same cumulative source-frame
  fence. These are event-only waits; elapsed guest time cannot complete them,
  and neither wait spins or blocks host event polling.
- The generator emits deterministic 24,000 Hz, stereo, signed 16-bit little-
  endian square-wave PCM. HDA converts the stream to its 48 kHz hardware
  format. Hardware timbre is deliberately approximate; note, rest,
  articulation, and tempo durations are converted deterministically to source
  frames.
- The productive host keeps four 40 ms source quanta buffered and permits the
  same bounded catch-up depth. This covers the 160 ms HDA start window, so a
  delayed graphics or interpreter cycle cannot turn already-generated notes
  into alternating PCM and silence. Submission remains paced through R4AUDIO
  rather than being performed by the VM.
- Open, prefill, steady writes, deferred cleanup, and resync each perform at
  most one synchronous AudioService operation in a host cycle, after any
  pending video presentation. Successful prefill writes are interleaved over
  fresh cycles. Busy retains the exact caller-owned PCM and uses an independent
  10 ms retry deadline rather than advancing a complete 40 ms quantum.
  R4BASIC bounds one service call to 25 ms; a transient open timeout, full, or
  service-start race still gets at most three retries separated by 50 ms.
- If a host delay exceeds the complete catch-up window, queued source PCM is
  explicitly discarded before refill. The discarded frames resolve the same
  transport fence and are counted separately; unrendered note events are not
  silently advanced by guest time. Refill remains one service operation per
  cycle rather than a four-write burst.
- A missing or failing sink enters visible degraded mode; samples are
  discarded while the VM, guest clock, input, and video continue. Stream
  close and runtime shutdown are idempotent.
- Service acceptance is not hardware playback. The current R4AUDIO/AUDSVC
  contract exposes no per-stream hardware playback cursor, so the R4BASIC
  report states `playback=unavailable` and never fabricates a played-frame
  count. Passive counters separately expose active, silent, paused and muted
  cycles/bytes plus accepted, suppressed, discarded, resolved and unresolved
  source frames.

## Guest time, pacing, and random state

- `TIMER` is a SINGLE number of guest seconds modulo 86,400. Its source is
  the monotonic guest clock supplied by `r4os.subsystem_runtime`, not a host
  wall clock. Paused host time therefore cannot advance it.
- `SLEEP` records a guest-time deadline and returns `waiting`; it never spins
  inside one slice. No argument or zero waits for a newly arriving key.
  Positive values also wake for a new key. Host input and lifecycle commands
  wake the blocking Desktop activity wait. Console `INPUT`, bare `RANDOMIZE`,
  and zero-argument/zero-duration `SLEEP` carry no periodic retry deadline;
  positive `SLEEP` uses its one exact guest-time deadline.
- The runtime adapter uses the shared budget of at most 262,144 instructions.
  One scheduled step begins with a 256-instruction clock block and adapts
  subsequent blocks toward one millisecond, bounded to 64 through 16,384
  instructions. It ends at the first observed boundary at or beyond eight
  milliseconds. The instruction ceiling remains absolute, one adaptive block
  bounds deadline overshoot, and the production gate permits at most 20 clock
  reads per step (a full steady fast-budget probe uses 18). Runnable code
  returns `progress` without an artificial wake deadline. Zero-operation
  progress alone retains a one-tick defensive retry.
- Scheduled TIMER reads are admitted at most once per guest millisecond. An
  earlier repeated poll returns a cooperative wait until that deadline. This
  keeps historical `CalcDelay`/`Rest` loops reproducible without throttling
  unrelated computation, graphics, input, or audio bytecode.
- Every VM owns a 24-bit random state and last result. An injected initial
  seed makes tests byte-for-byte reproducible. `RND` with a positive or
  omitted argument advances, zero repeats the last result, and a negative
  argument reseeds reproducibly before returning a value. This contract
  promises QuickBASIC invocation semantics, not the exact Microsoft number
  sequence.
- `RANDOMIZE expression` reseeds from the converted SINGLE bit pattern.
  Bare `RANDOMIZE` requests a seed in the range -32768 through 32767 through
  the same editable, retrying console-input path.

## Sequential files

- File numbers 1 through 255 address VM-owned slots. `OPEN` supports only
  `INPUT`, `OUTPUT`, and `APPEND`; `CLOSE` accepts selected numbers or all
  slots. `PRINT #`, `INPUT #`, `LINE INPUT #`, and `EOF` require a compatible
  open mode.
- A relative path is resolved against the explicit guest directory or,
  when absent, the directory of the absolute BAS file name. An absolute
  drive path remains absolute. Empty paths, invalid path bytes, drive-relative
  forms, and DOS device names such as `CON`, `COM1`, and `LPT1` are rejected.
- Host reads and writes occur only through injected callbacks. The production
  adapter uses the asynchronous `r4os.Resources` facade and caches four typed
  `AbsoluteFilePath` values; the VM has no direct R4SYS, VFS, or kernel file
  path. Exactly one request may be outstanding, and its VM-owned buffer stays
  alive until terminal status and request close.
- Sequential input is fetched on demand in at most 64-KiB transfers. Consumed
  prefixes are compacted before later refills, so ordinary records retain a
  rolling buffer instead of the whole file; only the current unfinished INPUT
  statement or line may retain bytes toward the 4-MiB file limit. Quoted
  and unquoted comma fields, split CR/LF endings, whole-line input, and exact
  end-of-file state remain deterministic. Geometric capacity growth is
  clamped to the input limit; the reported peak is allocated capacity rather
  than only the logical byte count.
- `OUTPUT` and `APPEND` publish at most 64 KiB at a time. A partial host result
  advances only the confirmed prefix, while `CLOSE`, normal `END`, and a
  resumed error continue with the remaining bytes without duplication.
  Submission and polling return `waiting` to the subsystem runtime at a
  one-millisecond guest deadline; input polling, presentation, audio service,
  and lifecycle work therefore continue between file-I/O progress steps. The
  output allocation itself is clamped to the 64-KiB transfer limit.
- Reset and teardown wait for a non-cancellable outstanding request and close
  its binding before any VM-owned path or transfer buffer is released.
- Bad numbers, missing files, wrong modes, duplicate slots, input past end,
  bad names, permission failures, and path/I/O failures remain distinct VM
  codes with the BASIC numbers listed below. Random-access and binary records,
  devices, printer and COM I/O, file deletion, and directory mutation are
  outside v1.

## Error flow

- Each module or active procedure can install one handler. A catchable fault
  searches the current invocation path and never affects another VM.
- Parallel instruction metadata carries the containing statement start and
  successor. `RESUME` therefore rebuilds the complete failing statement,
  including its operands, while `RESUME NEXT` skips exactly that statement.
- A handler is inactive until `ON ERROR GOTO` executes and cannot catch a
  second error while it is already handling one. `ON ERROR GOTO 0` disables
  it; inside the active handler it rethrows the original fault.
- The trapped source diagnostic remains observable for tests, but only an
  unhandled fault changes the VM to terminal `runtime_error`.

## Cooperative execution and lifecycle

- `runSlice` executes no more than its caller-provided instruction budget and
  returns `yielded` when work remains. Scheduled execution combines adaptive
  bounded VM chunks into one GuestDriver step until the shared budget, the
  8-ms limit, a guest wait, cancellation, or a terminal state is reached.
- The directly set cancellation flag is checked before the first instruction
  and between every instruction, including for a zero budget. The injected
  host callback is checked once at each `runSlice`/adaptive-block boundary.
  Cancellation exits with code 130; host Close is polled before the next
  GuestDriver step and also sets the direct flag.
- `runtime_adapter.Adapter` implements the SDK `subsystem_runtime.GuestDriver`.
  The shared runtime polls bounded host events before invoking exactly one VM
  slice, so a Close command wins over the next guest instruction. A waiting
  VM supplies its next guest-time wake deadline or an event-only wait instead
  of busy-polling. Active execution requests a cooperative scheduler yield no
  more often than once per eight host milliseconds; paused and event-only
  states block on the existing Desktop activity sequence.
- The initial VM owns no pixel allocation. Text output or an explicit SCREEN
  mode prepares the first surface after guest execution; a still-running
  display-silent guest receives a delayed SCREEN 0 fallback, and an immediate
  terminal guest receives no unused blank frame. Reset still installs a fresh
  surface before the old presenter can be used again.
- Opcode performance groups use a complete compact lookup table. Text cells
  are synchronized after text operations and at host display boundaries, not
  after unrelated numeric instructions. VM, adapter, and runtime statistics
  expose observer, metadata, cell-resolution, conversion, comparison, TIMER,
  clock, adaptive-block, host-cycle, event-wait, yield, zero-progress,
  frame-age/backlog/result, file-host, and ns/instruction evidence. Raster
  statistics additionally expose allocation/reuse and clear bytes, logical
  pixel/span work, damage commits, text rows, clipped line work, flood-fill
  spans and queue bounds, requested/emitted/skipped circle segments, and the
  exact packed byte prefixes consumed by `GET` and `PUT`.
- Reset constructs a fresh global-value and aggregate set before discarding
  the old state, then clears stacks, DATA cursor, handlers, trapped error,
  private segment and byte, text screen, keyboard and input line, guest-time
  waits, random state, audio settings and queue, sequential files, instruction
  count, cancellation, and exit state.
- Audio rendering and video presentation are separate adapters over VM-owned
  state. Scheduling, buffered submission, paused time, and host event polling
  stay in the shared subsystem runtime rather than moving into the interpreter
  or video host.

## Instance and ownership contract

An immutable compiled program may be shared by multiple VMs. Each VM owns
its globals, strings, array bounds and elements, record fields, aliases, DATA
cursor, error handlers, compatibility byte, text cells and cursor, graphics
mode, current point, palette, pixels and damage, keyboard
and pending input, guest time and sleep deadline, random generator, music
settings, audio events and oscillator state, open files, evaluation stack,
frames, GOSUB stack, instruction pointer,
instruction count, status, diagnostic, cancellation flag, and exit code.
Mutating, cancelling, resetting, completing, or faulting one instance cannot
change another instance.

## Runtime diagnostics

The failing instruction supplies the unchanged file name and exact byte,
line, and column span. The stable v1 mappings are:

| Runtime code | QBasic-compatible exit/error number |
| --- | ---: |
| illegal function call | 5 |
| overflow | 6 |
| out of memory | 7 |
| division by zero | 11 |
| type mismatch | 13 |
| out of DATA | 4 |
| restricted compatibility memory | 5 |
| subscript out of range | 9 |
| array already dimensioned | 10 |
| RESUME without error | 20 |
| bad file number | 52 |
| file not found | 53 |
| bad file mode | 54 |
| file already open | 55 |
| input past end of file | 62 |
| bad file name | 64 |
| permission denied | 70 |
| path/file access failure | 75 |
| VM stack, frame, instruction, GOSUB, or host failure | 70 |

Normal completion exits with `0`; cooperative cancellation exits with `130`.
The first terminal state is sticky and subsequent slices execute no guest
instruction.

## Permanent acceptance set

The permanent general fixtures below are part of this contract:

- `vm_expressions.bas`: all five value types, constants, suffix/default
  types, promotion, conversion, rounding, truth, comparison, division,
  modulo, and concatenation.
- `vm_control_flow.bas`: every promised conditional and loop family, range
  selection, exits, labels, GOTO, GOSUB, and targeted RETURN.
- `vm_procedures.bas`: declarations, explicit and implicit calls, ByRef alias
  chains, ByVal, shared globals, early exits, recursion, and DEF FN.
- `vm_builtins.bas`: every executable math and byte-string built-in through
  an injected math probe.
- `vm_infinite.bas`: an intentional infinite procedure for instruction
  budgets, cancellation, reset, and runtime Close ordering.
- `vm_isolation.bas`: two simultaneous VMs with different stack, pointer,
  variable, diagnostic, and exit states.
- `vm_arrays_records_data.bas`: fixed and dynamic multidimensional arrays,
  signed LONG DATA, UDT arrays, SHARED state, scalar/array/record ByRef,
  declaration-side `AS ANY`, REDIM, READ, RESTORE, and two-instance isolation.
- `vm_error_resume.bas`: whole-statement retry and next-statement continuation
  through an injected unavailable graphics mode.
- `vm_private_memory.bas`: the private segment-zero byte and NumLock bit.
- `vm_text_input.bas`: SCREEN 0 text state, viewport scrolling, PRINT zones,
  TAB and SPACE$, editable prompts, atomic retry, and typed console input.
- `vm_time_random.bas`: explicit random seeding, all three RND argument modes,
  TIMER, and cooperative SLEEP deadlines.
- `vm_pacing.bas`: the public `CalcDelay`/`Rest` pattern under cooperative
  TIMER-poll pacing.
- `vm_sequential_files.bas`: relative and absolute sequential input, output,
  append, quoted fields, whole lines, and EOF.
- `vm_graphics.bas`: modes, palette, text-compatible drawing, clipping,
  circle, flood fill, GET/PUT, POINT, STEP, XOR reversibility, and
  two-instance pixel/palette isolation.
- `vm_packed_images.bas`: original synthetic LONG arrays in the mode 1 and
  mode 9 packed formats, including reversible PUT XOR.
- `vm_audio.bas`: stateful MML commands, MB continuation, transport-fenced MF
  and BEEP waits, PCM generation, buffering, sink teardown, and degraded
  audio.

`Tests/compiler_test.zig` also fixes negative binding cases, exact runtime
positions, QBasic error numbers, string overflow, host failure, and
`subsystem_runtime` lifecycle behavior. It additionally covers focus and
two-instance keyboard isolation, interactive RANDOMIZE retry, paused time,
host polling while asleep, storage-facade error classification, unsupported
file modes and device names, and atomic text-state errors.
`Tests/graphics_host_test.zig` fixes 128 by 128 raster bounds, the fifteen
blocks of a 640 by 350 full frame, real damage frames, unchanged-frame
suppression, a sustained 30-frame animation above 20 frames per second, and
resize letterboxing. The local GORILLA.BAS acceptance exercises the same
public compiler, VM, packed-image, presentation, timing, and audio paths
through a complete deterministic round.
