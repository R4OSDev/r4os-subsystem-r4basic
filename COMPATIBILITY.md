# R4BASIC v2 QuickBASIC 4.5 target contract

Contract version: `2.9.0`

R4BASIC v2 targets the complete Microsoft QuickBASIC 4.5 interpreter language
and runtime. The target is not limited by GORILLA.BAS or by the historical v1
subset. IDE, editor, native compiler, linker, and librarian behavior remain
separate products; source-language and runtime compatibility do not.

`src/conformance.zig` is the machine-readable contract index. It assigns
stable IDs to seven Part-1 areas (`QB45-P1-*`), all 193 Part-2 reference
entries (`QB45-P2-001` through `QB45-P2-193`), `$INCLUDE`, `$STATIC`, and
`$DYNAMIC` (`QB45-META-*`), and all 43 Appendix-B runtime errors
(`QB45-ERR-*`). Every Part-1, Part-2, and metacommand target records lexer,
syntax, binder, VM, error, coverage, ownership, and delivery status.

The remainder of this document preserves the already implemented v1 baseline
that v2 must continue to accept while the catalog is completed. It is a
minimum compatibility floor, not the v2 scope ceiling.

The lexer performs lexical analysis only. The compiler Builder is the single
parser, binder, and emitter; syntax can no longer pass a second non-binding
grammar. A successful compilation therefore has no Deferred statement or
Deferred built-in opcode. Unimplemented catalog targets fail compilation with
`unsupported_core_feature` and, where the keyword is already uniquely known,
their stable catalog ID. Later 0.70.X packages replace those diagnostics with
the specified semantics.

## Authority and source identity

The compatibility surface is derived in this order:

1. The unchanged local acceptance source identifies the features required by
   the first real program.
2. Microsoft QuickBASIC 4.5 Language Reference defines syntax and language
   meaning.
3. Microsoft QuickBASIC 4.5 Programming in BASIC provides the connected
   programming, graphics, animation, I/O, and error-handling model.
4. Permanent general R4BASIC fixtures make the selected subset executable as a
   permanent test contract.

The local acceptance source is expected workspace-relatively at
`Artifacts/Distribution/Injection/Temp/gorilla.bas`, with exactly
29,434 bytes and SHA-256
`9926FC1F50C4B489EC4C1B0DA5BD2C497EBF4282B3259C28A835A743E24699F7`.
It is read directly from the ignored workspace injection tree and is not
required by the normal build. Publishing a release archive is a separate
manual operation outside this development roadmap.

The Microsoft references are the PCjs transcriptions at revision
`67b950f7eed3447c5c056e3d048ba4f62a94aead`:

- [QuickBASIC 4.5 Language Reference](https://www.pcjs.org/documents/books/mspl13/basic/qblang/)
- [QuickBASIC 4.5 Programming in BASIC](https://www.pcjs.org/documents/books/mspl13/basic/qbprog/)

Local reference copies and their hashes are inventoried outside all public
repositories under `ExFiles/Reference/Basic/README.txt`.

## Source and lexical contract

- A complete source graph is a byte sequence of at most 256 KiB plus bounded
  file-name and physical-line identity. The frontend does not open files;
  the owning loader uses the existing R4OS Storage facade.
- CRLF, lone LF, and lone CR each end one logical line. Lines and columns are
  one-based; byte spans are half-open offsets into the unchanged source.
- BASIC keywords and names compare case-insensitively in ASCII. The frontend
  preserves original bytes and spelling in every token span.
- A simple identifier starts with an ASCII letter, continues with ASCII
  letters or digits, and contains at most 40 bytes including an optional type
  suffix. Period-separated components are accepted for user-defined-type
  field access. `_` is not a v1 identifier character.
- The suffixes `$`, `%`, `&`, `!`, and `#` are accepted on identifiers.
  Numeric literals accept `%`, `&`, `!`, and `#`, but never `$`.
- Decimal numeric literals accept the reference decimal-point, `E`/`D`
  exponent and `%`/`&`/`!`/`#` suffix forms. Hexadecimal `&H` and octal
  `&O`/`&` constants use the documented 16-bit range; a trailing `&` selects
  the documented 32-bit LONG range. A leading sign remains an operator.
- String literals are delimited by double quotation marks and cannot cross a
  line or contain an embedded double quotation mark. Bytes `0x80` through
  `0xFF` are preserved inside a literal. NUL in source is rejected. Runtime
  strings remain byte strings; source decoding never silently replaces data.
- Apostrophe comments and statement-leading `REM` comments consume the rest
  of their logical line. A comment may contain multiple whitespace-separated
  `$DYNAMIC`, `$STATIC`, and `$INCLUDE: 'relative-file'` metacommands. Text
  before the first `$` makes the remainder an ordinary comment.
- A colon separates statements on one line. Empty lines and empty segments
  between separators are accepted. Optional statement arguments may be
  omitted only at grammar positions that explicitly allow an empty comma
  field.
- Numbered program lines range from 0 through 65,529, may be indented, and are
  labels only: execution remains in source order. Numeric and alphanumeric
  labels may be mixed, but a direct `IF ... THEN`/`ELSE` target must be a line
  number; named targets require an explicit `GOTO`.
- `_` as the final non-whitespace byte joins physical lines without erasing
  their original spans. `DATA` and `REM` cannot be continued. `?` is exactly
  the `PRINT` shorthand.
- `$INCLUDE` resolves only relative R4OS paths against the containing file.
  At most 64 physical sources and 16 include levels contribute to the
  256-KiB graph. Each file is physically loaded once; missing sources,
  cycles, invalid paths, depth, file-count, and aggregate-size failures are
  compile diagnostics and no partial program is executable.

## Syntax matrix and fixture coverage

Every row below is a v1 promise. `positive_*` fixtures demonstrate accepted
forms; the paired `negative_*` fixture demonstrates a rejected boundary for
the same grammar family. All fixture paths are below `Tests/Fixtures/`.

| ID | v1 syntax promise | Required by local acceptance | Positive fixture | Negative fixture |
| --- | --- | --- | --- | --- |
| SRC-01 | CRLF/LF/CR, ASCII case folding, byte-preserving spans, 40-byte names, type suffixes, decimal literals, 8-bit string bytes | yes | `positive_source_contract.bas` plus inline span tests | `negative_lexical.bas` |
| SRC-02 | Apostrophe and `REM` comments; `$INCLUDE`, `$DYNAMIC`, and `$STATIC` metacommands | `$DYNAMIC` | `positive_source_contract.bas` plus inline source-graph and allocation-mode vectors | `negative_lexical.bas` |
| SRC-03 | Colon-separated statements and explicitly omitted comma arguments | yes | `positive_source_contract.bas`, `positive_io_graphics.bas` | `negative_statements.bas` |
| DECL-01 | `CONST`, all five `DEFtype` forms, `OPTION BASE`, implicit arrays, `DIM`/`DIM SHARED`, `REDIM PRESERVE`, `ERASE`, `LBOUND`/`UBOUND`, fixed strings and up to 60 dimensions | yes | `positive_declarations.bas` plus inline declaration, allocation, preservation and failure-atomicity vectors | `negative_structure.bas` plus inline declaration diagnostics |
| DECL-02 | Nested `TYPE` blocks with canonical guest-byte layouts, elementary and fixed-string fields, record assignment, `LEN`, `LSET`/`RSET`, `SWAP`, `AS ANY`, and empty array parameter dimensions | yes | `positive_declarations.bas` plus inline record ownership and byte-layout vectors | `negative_structure.bas` plus inline type diagnostics |
| SCOPE-01 | automatic and static procedure locals, procedure-level and standalone `STATIC`, standalone `SHARED`, `DIM`/`REDIM SHARED`, and blank or named `COMMON` metadata | yes | inline recursive, reset, two-VM, shared and COMMON-layout vectors | `negative_structure.bas` plus inline scope diagnostics |
| PROC-01 | Full BASIC signatures for `DECLARE SUB`, `DECLARE FUNCTION`, `SUB`, `FUNCTION`, `STATIC`, `EXIT`, explicit `CALL`, implicit calls, recursion, dimensioned arrays, records, fixed-string temporaries, and `AS ANY` | yes | `positive_declarations.bas` plus inline 0.70.7 signature and recursion vectors | `negative_structure.bas`, `negative_statements.bas` plus inline dimension diagnostics |
| PROC-02 | One-line and multiline `DEF FN` with parameters, module scope, `STATIC`, `EXIT DEF`, `END DEF`, zero-argument calls, and the selected `DEF SEG` compatibility form | yes | `positive_declarations.bas`, `positive_io_graphics.bas`, plus inline 0.70.7 vectors | `negative_structure.bas` plus the recursive-DEF diagnostic vector |
| DATA-01 | Numeric/string `DATA`, named data labels, `READ`, and `RESTORE` | yes | `positive_declarations.bas` | `negative_expressions.bas` |
| FLOW-01 | Numeric/named `GOTO`, `GOSUB`, `RETURN`, indexed `ON GOTO`/`ON GOSUB`, `ON ERROR GOTO`, every `RESUME` form, and exact errors 3/19/20 | yes | `positive_control_flow.bas` plus inline 0.70.7 branch/error vectors | `negative_structure.bas` |
| FLOW-02 | Block and multi-statement single-line `IF`, `ELSEIF`, `ELSE`, `SELECT CASE`, value/range lists, `CASE IS`, and `CASE ELSE` | yes | `positive_control_flow.bas` plus inline 0.70.7 vectors | `negative_structure.bas` |
| FLOW-03 | `FOR`/`NEXT` including variable lists, `WHILE`/`WEND`, every leading/trailing `DO`/`LOOP` condition, and `EXIT FOR`/`EXIT DO` | yes | `positive_control_flow.bas` plus inline multi-NEXT vectors | `negative_structure.bas`, `negative_statements.bas` |
| DEBUG-01 | Cooperative `STOP`, productive host continuation, and visible bounded `TRON`/`TROFF` statement tracing | no | inline pause, reset, cancellation, host-input, and 256-entry ring vectors | inline lifecycle vectors |
| EXPR-01 | Parentheses; unary `+`, `-`, `NOT`; power, multiply, divide, integer divide, `MOD`, add, subtract, comparisons, `AND`, `OR`, `XOR`, `EQV`, and `IMP` with reference precedence and signed-LONG logic | yes | all positive fixtures and inline numeric vectors | `negative_expressions.bas` |
| EXPR-02 | Numeric conversion, IEEE/MBF byte conversion, math, string, time, graphics and host-query built-ins currently marked implemented in `src/conformance.zig` | yes | `positive_io_graphics.bas` and inline numeric/byte/error vectors | `negative_expressions.bas` |
| TEXT-01 | Per-page text `SCREEN`, mode-valid optional-axis `WIDTH`, mode-specific `COLOR`, exact `CLS`, `LOCATE`, `VIEW PRINT`, `PRINT`, `PRINT USING`, `WRITE`, `INPUT`, `LINE INPUT`, and `INPUT$` | yes | `positive_io_graphics.bas` plus inline formatting/input and 0.70.10 mode/page vectors | `negative_statements.bas` plus inline mode/color boundaries |
| TIME-01 | `RANDOMIZE`, `RND`, wall-clock `TIMER`, extended two-byte `INKEY$`, monotonic `SLEEP`, and nonpolling TIMER-event deadlines | yes | `positive_io_graphics.bas` plus inline queue, deadline, wake, and midnight vectors | `negative_expressions.bas`, `negative_statements.bas` plus inline range vectors |
| EVENT-01 | Module-level `ON KEY`/`TIMER`/`PLAY`/`COM`/`PEN`/`STRIG`/`UEVENT GOSUB`, ON/OFF/STOP, priority, nesting, coalescing, RETURN reactivation, soft keys, and private virtual devices | no | inline all-source, KEY macro/display, pointer, joystick, COM, UEVENT, reset, and two-VM vectors | inline selector, range, disabled-device, overflow, and error vectors |
| GFX-01 | Logical `SCREEN 0`, `1`, `2`, `7`-`13` mode matrices; APAGE/VPAGE/`PCOPY`; `PALETTE`/`USING`; `VIEW`, `WINDOW`, `PMAP`, all `POINT` forms; `PSET`/`PRESET`; styled `LINE`/`B`/`BF`; complete `CIRCLE`, `PAINT` tiling, and bounded `DRAW` | yes | `positive_io_graphics.bas` plus inline 0.70.10/0.70.11 mode, page, transform, primitive and macro vectors | `negative_statements.bas`, `negative_expressions.bas`, plus inline page, color, palette, macro and tile boundaries |
| GFX-02 | Graphics `GET` and `PUT` in every logical mode, from every numeric array type and element, with `PSET`, `PRESET`, `AND`, `OR`, and default `XOR` actions | yes | `positive_io_graphics.bas` plus inline all-mode/all-type/far-element vectors | `negative_statements.bas` plus inline header, capacity and surface-boundary vectors |
| AUDIO-01 | `BEEP`, 18.2-Hz `SOUND`, complete stateful `PLAY` MML with bounded variables, MF/MB fences, the 32-note queue function, and PLAY events | yes | `positive_io_graphics.bas`, `vm_audio.bas`, plus inline PCM, queue, variable, fence, and degraded-transport vectors | `negative_statements.bas` plus inline command and numeric boundaries |
| FILE-01 | Old/new `OPEN` for `INPUT`, `OUTPUT`, `APPEND`, `RANDOM`, or `BINARY`; access/lock/LEN, `CLOSE`/`RESET`, sequential formatting/input, FIELD/LSET/RSET, typed GET/PUT, BINARY `INPUT$`, SEEK/LOC/LOF/EOF/FILEATTR/FREEFILE, and exact LOCK/UNLOCK | yes | `vm_sequential_files.bas` plus inline one-byte, sparse, record/UDT, exact-64-KiB, positioned-output, metadata, lock and catchable-error vectors | inline bad-mode, bad-record, FIELD, path/storage and device-name vectors |
| MEM-01 | Asynchronous `BLOAD`/`BSAVE` with the seven-byte memory-image header, QuickBASIC/BASICA/GW-BASIC input variants, private real-mode guest segments, and packed active video segments | yes | `positive_io_graphics.bas` plus inline partial-transfer, malformed-input and byte-roundtrip vectors | `negative_statements.bas` plus inline bounds and storage-failure vectors |
| HW-01 | Exact 1-MiB private 20-bit memory, `DEF SEG`, `PEEK`/`POKE`, stable scalar/array/string pointers, heap queries, bounded x86 execution, virtual ports and virtual interrupts | yes | `positive_io_graphics.bas` plus inline 0.70.13 wrapping, pointer, CALL, port and interrupt vectors | `negative_expressions.bas` plus inline unknown-port/symbol/interrupt vectors |
| DEVICE-01 | `OPEN COM`, COM events, `IOCTL`/`IOCTL$`, partial bounded RX/TX, `LPRINT`/`LPRINT USING`, `LPOS`, and screen/file/device/printer `WIDTH` | no | inline 0.70.13 serial, partial-input, event, spool, formatting and ERDEV vectors | inline timeout, unavailable, overflow, invalid-option and out-of-paper vectors |
| ERROR-01 | All 43 Appendix-B error numbers preserve exact `ERR`/`ERL` identity and are resumable through the central handler model | no | inline all-number round-trip vector plus natural language, file and device faults | inline nested-handler and invalid-resume vectors |

The optional `Tests/gorilla_acceptance.zig` step additionally verifies the
local file size and SHA-256 before passing the unchanged bytes through the
same public lexer, parser, and typed binder. It then executes the intro and
initial interaction through two names, invalid and valid game/gravity input,
and edited angle and velocity input. It then completes one deterministic
round through city, packed banana flight, XOR animation, building collision,
gorilla explosion, victory dance, and an updated score. The same instance-
local audio engine executes all twelve reached `PLAY` statements and both
`BEEP` statements. Compiler and VM behavior remains general; the acceptance
source does not select a separate production path.

## Built-in function arities

- One argument: `ABS`, `ASC`, `ATN`, `CDBL`, `CHR$`, `CINT`, `CLNG`, `COS`, `CSNG`,
  `CVD`, `CVDMBF`, `CVI`, `CVL`, `CVS`, `CVSMBF`, `EOF`, `EXP`, `FIX`,
  `HEX$`, `INT`, `LCASE$`, `LEN`, `LOC`, `LOF`, `LOG`, `LTRIM$`, `MKD$`, `MKDMBF$`,
  `MKI$`, `MKL$`, `MKS$`, `MKSMBF$`, `OCT$`, `PEEK`, `POS`, `RTRIM$`,
  `SEEK`, `SGN`, `SIN`, `SPACE$`, `SQR`, `STR$`, `TAN`, `UCASE$`, `VAL`,
  `PEN`, `PLAY`, `STICK`, `STRIG`, `FRE`, `INP`, `IOCTL$`, `LPOS`, `SADD`,
  `SETMEM`, `VARPTR`, `VARPTR$`, and `VARSEG`.
- One or two arguments: `LBOUND` and `UBOUND` accept an array and an optional
  one-based dimension number.
- Two arguments: `FILEATTR`, `LEFT$`, `RIGHT$`, `STRING$`, coordinate `POINT`.
- Two or three arguments: `INSTR`, `MID$`.
- Two or three arguments: text `SCREEN`.
- One or two arguments: `INPUT$` accepts a count and an optional INPUT/BINARY
  file number.
- Bare and without parentheses: `FREEFILE` also accepts empty parentheses.
- Zero or one argument: `RND`; the bare form is accepted.
- Bare and without parentheses: `CSRLIN`, `ERDEV`, `ERDEV$`, `INKEY$`,
  `TIMER`.

`SPC` and `TAB` are PRINT-only positioning forms rather than ordinary
expression built-ins. `MID$` additionally has the reference in-place
assignment statement form.

Wrong arities are syntax diagnostics rather than deferred runtime behavior.
User-defined functions and array references remain syntactically
indistinguishable until binding and therefore receive their arity checks in
the typed-program phase.

## Diagnostic contract

- Each diagnostic carries the caller-provided file name, a stable code, an
  exact byte span, and one-based line and column.
- Lexical diagnostics are emitted in byte order. Parser diagnostics follow in
  deterministic statement order, followed by deterministic unclosed-block
  diagnostics.
- Recovery stops at the next newline, colon, or end of file. Independent bad
  statements can therefore produce independent messages without guessing
  through the rest of the line.
- Caller-owned token and diagnostic buffers are bounded. Exhaustion and
  source-size overflow are visible errors; a truncated diagnostic set can
  never be reported as success.
- Unsupported known statements and metacommands receive explicit diagnostic
  codes. Invalid bytes or malformed grammar never disappear as comments or
  successful empty input.

## Historical v1 exclusions under the v2 contract

- Full QuickBASIC 4.5 and BASICA/GW-BASIC line-number compatibility were not
  v1 promises. They are v2 implementation targets where the QuickBASIC 4.5
  references require them. QBX extensions, a native-code compiler, IDE,
  debugger, and source editor remain separate products.
- `CHAIN`, `RUN`, `SHELL`, `SYSTEM`, printer/COM/device I/O,
  random/binary file records, directory mutation, and unrestricted hardware
  access were not v1 promises. Contract 2.9.0 implements them through typed
  R4OS facades or private virtual devices; unrestricted hardware access stays
  intentionally impossible.
- `DRAW`, `PCOPY`, `BLOAD`, `BSAVE`, `SOUND`, complete `PLAY`, keyboard and
  event trapping, private pointer/joystick input, private 20-bit memory,
  serial data, printer and virtual ports were v1 exclusions and are
  implemented by contract 2.9.0.
- Runtime correctness merely from parse or bind success. Only the subset in
  `VM-CONTRACT.md` has executable semantics.

These bullets describe the preserved v1 boundary only and do not exclude the
items from v2. Their exact current state and owning 0.70.X package are recorded
in `src/conformance.zig`.

Changing a promise in this document or `VM-CONTRACT.md` requires a
contract-version decision, an original positive fixture, an original
negative or runtime-error fixture, and an update to the repository test
inventory.
