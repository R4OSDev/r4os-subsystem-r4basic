# R4BASIC v1 compatibility contract

Contract version: `1.0.0`

This document freezes the source-language surface accepted by the first
R4BASIC frontend. It is a deliberately bounded QuickBASIC 4.5 subset selected
for real compatibility work, not a Tiny BASIC dialect and not a claim of full
QuickBASIC implementation.

Parsing a construct means that its syntax, source span, nesting, and argument
shape are recognized. It does not claim executable semantics. Binding,
values, bytecode execution, display, input, time, files, and audio are added
by later subsystem layers against this same contract.

## Authority and source identity

The compatibility surface is derived in this order:

1. The unchanged local acceptance source identifies the features required by
   the first real program.
2. Microsoft QuickBASIC 4.5 Language Reference defines syntax and language
   meaning.
3. Microsoft QuickBASIC 4.5 Programming in BASIC provides the connected
   programming, graphics, animation, I/O, and error-handling model.
4. Original public R4BASIC fixtures make the selected subset executable as a
   permanent test contract.

The local acceptance source is expected at
`D:\R4OS\Artifacts\Distribution\Injection\Temp\gorilla.bas`, with exactly
29,434 bytes and SHA-256
`9926FC1F50C4B489EC4C1B0DA5BD2C497EBF4282B3259C28A835A743E24699F7`.
It is not stored in this repository and is not required by the normal build.

The Microsoft references are the PCjs transcriptions at revision
`67b950f7eed3447c5c056e3d048ba4f62a94aead`:

- [QuickBASIC 4.5 Language Reference](https://www.pcjs.org/documents/books/mspl13/basic/qblang/)
- [QuickBASIC 4.5 Programming in BASIC](https://www.pcjs.org/documents/books/mspl13/basic/qbprog/)

Local reference copies and their hashes are inventoried outside all public
repositories under `D:\R4OS\ExFiles\Reference\Basic\README.txt`.

## Source and lexical contract

- A source is a byte sequence of at most 256 KiB plus a caller-owned file
  name. The frontend does not open files itself.
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
- v1 numeric literals are decimal integers or decimal real values, with an
  optional decimal point, optional `E` or `D` exponent, and optional numeric
  suffix. A leading sign is an operator. Hexadecimal and octal literals are
  outside v1.
- String literals are delimited by double quotation marks and cannot cross a
  line or contain an embedded double quotation mark. Bytes `0x80` through
  `0xFF` are preserved inside a literal. NUL in source is rejected. Runtime
  strings remain byte strings; source decoding never silently replaces data.
- Apostrophe comments and statement-leading `REM` comments consume the rest
  of their logical line. `'$DYNAMIC`, `'$STATIC`, `REM $DYNAMIC`, and
  `REM $STATIC` are the only accepted metacommands. Other metacommands are
  diagnosed.
- A colon separates statements on one line. Empty lines and empty segments
  between separators are accepted. Optional statement arguments may be
  omitted only at grammar positions that explicitly allow an empty comma
  field.
- Traditional numbered program lines and numeric label declarations are not
  part of v1. Named labels are supported; a numeric `0` remains valid where
  the selected error-handling syntax requires it.

## Syntax matrix and fixture coverage

Every row below is a v1 promise. `positive_*` fixtures demonstrate accepted
forms; the paired `negative_*` fixture demonstrates a rejected boundary for
the same grammar family. All fixture paths are below `Tests/Fixtures/`.

| ID | v1 syntax promise | Required by local acceptance | Positive fixture | Negative fixture |
| --- | --- | --- | --- | --- |
| SRC-01 | CRLF/LF/CR, ASCII case folding, byte-preserving spans, 40-byte names, type suffixes, decimal literals, 8-bit string bytes | yes | `positive_source_contract.bas` plus inline span tests | `negative_lexical.bas` |
| SRC-02 | Apostrophe and `REM` comments; `DYNAMIC` and `STATIC` metacommands | `DYNAMIC` | `positive_source_contract.bas` | `negative_lexical.bas` |
| SRC-03 | Colon-separated statements and explicitly omitted comma arguments | yes | `positive_source_contract.bas`, `positive_io_graphics.bas` | `negative_statements.bas` |
| DECL-01 | `CONST`, `DEFINT`, `DIM`, `DIM SHARED`, `REDIM`, scalar and multidimensional array bounds | yes | `positive_declarations.bas` | `negative_structure.bas` |
| DECL-02 | `TYPE` blocks, elementary fields, user types, `AS ANY`, and empty array parameter dimensions | yes | `positive_declarations.bas` | `negative_structure.bas` |
| PROC-01 | `DECLARE SUB`, `DECLARE FUNCTION`, `SUB`, `FUNCTION`, `STATIC`, `EXIT`, explicit `CALL`, and implicit calls | yes | `positive_declarations.bas` | `negative_structure.bas`, `negative_statements.bas` |
| PROC-02 | One-line `DEF FN` and the selected `DEF SEG` compatibility form | yes | `positive_declarations.bas`, `positive_io_graphics.bas` | `negative_structure.bas` |
| DATA-01 | Numeric/string `DATA`, named data labels, `READ`, and `RESTORE` | yes | `positive_declarations.bas` | `negative_expressions.bas` |
| FLOW-01 | Named labels, `GOTO`, `GOSUB`, `RETURN`, `ON ERROR GOTO`, `RESUME`, and `RESUME NEXT` | yes | `positive_control_flow.bas` | `negative_structure.bas` |
| FLOW-02 | Block and single-line `IF`, `ELSEIF`, `ELSE`, `SELECT CASE`, ranges, and `CASE ELSE` | yes | `positive_control_flow.bas` | `negative_structure.bas` |
| FLOW-03 | `FOR`/`NEXT`, `WHILE`/`WEND`, `DO`/`LOOP`, leading conditions, trailing conditions, and `EXIT FOR`/`EXIT DO` | yes | `positive_control_flow.bas` | `negative_structure.bas`, `negative_statements.bas` |
| EXPR-01 | Parentheses; unary `+`, `-`, `NOT`; power, multiply, divide, integer divide, `MOD`, add, subtract, comparisons, `AND`, `OR`, and `XOR` | yes | all positive fixtures | `negative_expressions.bas` |
| EXPR-02 | `ABS`, `ATN`, `CHR$`, `CINT`, `COS`, `EOF`, `INKEY$`, `INSTR`, `INT`, `LEFT$`, `LEN`, `LTRIM$`, `MID$`, `PEEK`, coordinate `POINT`, `RND`, `SIN`, `SPACE$`, `STR$`, `TAB`, `TIMER`, `UCASE$`, and `VAL` with bounded v1 arities | yes | `positive_io_graphics.bas` | `negative_expressions.bas` |
| TEXT-01 | `SCREEN 0`, `WIDTH`, `COLOR`, `CLS`, `LOCATE`, `VIEW PRINT`, `PRINT`, `INPUT`, and `LINE INPUT` | yes | `positive_io_graphics.bas` | `negative_statements.bas` |
| TIME-01 | `RANDOMIZE`, `RND`, `TIMER`, `INKEY$`, and `SLEEP` syntax | yes | `positive_io_graphics.bas` | `negative_expressions.bas`, `negative_statements.bas` |
| GFX-01 | `SCREEN 1`/`9`, `PALETTE`, `PSET`, coordinate `POINT`, `LINE` including `B`/`BF`, `CIRCLE`, and `PAINT` | yes | `positive_io_graphics.bas` | `negative_statements.bas`, `negative_expressions.bas` |
| GFX-02 | Graphics `GET` and `PUT` with `PSET` and `XOR` actions | yes | `positive_io_graphics.bas` | `negative_statements.bas` |
| AUDIO-01 | `BEEP` and `PLAY` expression syntax | yes | `positive_io_graphics.bas` | `negative_statements.bas` |
| FILE-01 | Sequential `OPEN` for `INPUT`, `OUTPUT`, or `APPEND`; `CLOSE`, `PRINT #`, `INPUT #`, `LINE INPUT #`, and `EOF` | no, but v1 platform scope | `positive_io_graphics.bas` | `negative_statements.bas`, `negative_expressions.bas` |
| HW-01 | Selected `DEF SEG`, `PEEK`, and `POKE` syntax for a later private compatibility device | yes | `positive_io_graphics.bas` | `negative_expressions.bas` |

The optional `Tests/gorilla_acceptance.zig` step additionally verifies the
local file size and SHA-256 before passing the unchanged bytes through the
same public lexer and parser. Production sources contain no program-specific
names, source lines, or parsing branches.

## Built-in function arities

- One argument: `ABS`, `ATN`, `CHR$`, `CINT`, `COS`, `EOF`, `INT`, `LEN`,
  `LTRIM$`, `PEEK`, `SIN`, `SPACE$`, `STR$`, `TAB`, `UCASE$`, `VAL`.
- Two arguments: `LEFT$`, coordinate `POINT`.
- Two or three arguments: `INSTR`, `MID$`.
- Zero or one argument: `RND`; the bare form is accepted.
- Bare and without parentheses: `INKEY$`, `TIMER`.

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

## Explicit v1 non-goals

- Full QuickBASIC 4.5, BASICA/GW-BASIC line-number compatibility, QBX
  extensions, a compiler, IDE, debugger, or source editor.
- `COMMON`, `CHAIN`, `RUN`, `SHELL`, `SYSTEM`, printer/COM/device I/O,
  random/binary file records, directory mutation, and unrestricted hardware
  access.
- Hexadecimal/octal literals, fixed-length strings, `MID$` assignment,
  `PRINT USING`, `DRAW`, `PCOPY`, `BLOAD`, `BSAVE`, and general memory or port
  access.
- Runtime correctness merely from parse success. Type conversion, rounding,
  errors, scheduling, graphics pixels, file behavior, timing, and audio each
  require their later dedicated acceptance layers.

Changing a promise in this document requires a contract-version decision,
an original positive fixture, an original negative fixture, and an update to
the repository test inventory.
