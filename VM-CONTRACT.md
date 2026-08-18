# R4BASIC v1 core VM contract

Contract version: `1.0.0`

This document freezes the first executable R4BASIC subset. The broader
source syntax accepted by the frontend remains defined in
`COMPATIBILITY.md`; parse success alone does not extend this VM contract.

## Compilation model

- The caller supplies the source bytes and file name. The compiler owns
  immutable copies in the resulting program.
- Source is tokenized once. Parsing, symbol binding, type selection, jump
  resolution, and instruction emission then operate on that token stream.
- A successful program records one parse pass and one bind pass. VM
  instances reference the prepared program and never tokenize or parse it.
- Instructions contain an opcode, two bounded operands, and the exact source
  span responsible for the operation. Branch operands are resolved
  instruction indices, not source labels or text offsets.
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

Arrays, user-defined types, `DATA`, `READ`, `RESTORE`, and BASIC error-handler
state belong to later VM layers.

## Values and operations

- INTEGER is signed 16-bit, LONG is signed 32-bit, SINGLE is IEEE binary32,
  and DOUBLE is IEEE binary64.
- Strings are owned byte strings with a maximum length of 32,767 bytes. They
  are not Unicode-decoded and may contain bytes above ASCII. Concatenation or
  a literal beyond the limit reports overflow.
- Numeric assignment converts to the target type. Floating-to-integer
  conversion rounds the absolute half away from zero and then checks the
  target range. Non-finite input and an out-of-range result report overflow.
- Arithmetic promotes INTEGER to LONG to SINGLE to DOUBLE. `/` produces
  SINGLE unless a DOUBLE operand requires DOUBLE. `\` and `MOD` first apply
  the defined integer rounding to their operands; integer division truncates
  its quotient toward zero.
- Division by zero and numeric overflow are visible runtime errors. Numeric
  and string categories never convert implicitly into one another.
- Comparisons return INTEGER `-1` for true and `0` for false. Conditions
  accept every nonzero numeric value as true and reject strings.
- `NOT`, `AND`, `OR`, and `XOR` use signed LONG bit operations. Power is
  right-associative, is evaluated by the injected math host, and rejects a
  negative base with a non-integral exponent.

## Executable statements

The core VM executes:

- scalar `CONST`, `DEFINT`, `DIM`, `DIM SHARED`, `LET`, and assignment;
- block and single-line `IF`, `ELSEIF`, and `ELSE`;
- `SELECT CASE`, comma alternatives, inclusive `TO` ranges, and `CASE ELSE`;
- positive, negative, and zero-step `FOR`/`NEXT`, including `EXIT FOR`;
- `WHILE`/`WEND`;
- unconditional, leading-`WHILE`, leading-`UNTIL`, trailing-`WHILE`, and
  trailing-`UNTIL` `DO`/`LOOP`, including `EXIT DO`;
- named `GOTO`, `GOSUB`, plain `RETURN`, and `RETURN` to a named label;
- `END`.

The core compiler deliberately diagnoses array syntax and every accepted
frontend statement assigned to a later layer instead of pretending to
execute it.

## Procedures and functions

- `DECLARE SUB`, `DECLARE FUNCTION`, `SUB`, `FUNCTION`, explicit `CALL`, and
  implicit SUB calls use validated signatures.
- Scalar parameters default to ByRef. `BYVAL` copies and converts a value;
  `BYREF` requires an exact-type scalar variable and aliases its storage.
  Alias chains are resolved to their owning frame or global.
- Every call owns a separate frame, local values, return address, and stack
  base. Recursion is supported up to 256 simultaneous frames.
- Functions own a typed return cell addressed by their function name.
  `EXIT SUB` and `EXIT FUNCTION` return immediately through the same frame
  teardown path as the matching terminator.
- One-line `DEF FN` parameters are always ByVal. The body can read module
  variables and returns the declared or inferred function type.
- GOSUB return addresses use a separate, frame-aware stack with a maximum
  depth of 1,024.

## Built-in functions and host services

The executable built-ins are `ABS`, `ATN`, `CHR$`, `CINT`, `COS`, `INSTR`,
`INT`, `LEFT$`, `LEN`, `LTRIM$`, `MID$`, `SIN`, `SPACE$`, `STR$`, `UCASE$`,
and `VAL` with the arities and type categories defined by the source
contract.

`ATN`, `COS`, `SIN`, and power call an injected math service. Cancellation
polling is injected separately. A missing or failing host result becomes a
deterministic VM error; tests do not depend on hidden process-global hooks.

## Cooperative execution and lifecycle

- `runSlice` executes no more than its instruction budget and returns
  `yielded` when work remains. The default budget is 4,096 instructions.
- Cancellation is checked before the first instruction and between every
  instruction, including for a zero budget. Cancellation exits with code
  130.
- `runtime_adapter.Adapter` implements the SDK `subsystem_runtime.GuestDriver`.
  The shared runtime polls bounded host events before invoking exactly one VM
  slice, so a Close command wins over the next guest instruction.
- Reset constructs a fresh global-value set before discarding the old state,
  then clears value, call, and GOSUB stacks, instruction count, diagnostic,
  cancellation, and exit state.
- This layer does not invent waits, frames, guest time, or audio samples.
  Later text, graphics, timing, and audio layers extend the adapter without
  moving scheduling into the interpreter.

## Instance and ownership contract

An immutable compiled program may be shared by multiple VMs. Each VM owns
its globals, strings, evaluation stack, frames, GOSUB stack, instruction
pointer, instruction count, status, diagnostic, cancellation flag, and exit
code. Mutating, cancelling, resetting, completing, or faulting one instance
cannot change another instance.

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
| VM stack, frame, instruction, GOSUB, or host failure | 70 |

Normal completion exits with `0`; cooperative cancellation exits with `130`.
The first terminal state is sticky and subsequent slices execute no guest
instruction.

## Permanent acceptance set

The original, redistributable fixtures below are part of this contract:

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

`Tests/compiler_test.zig` also fixes negative binding cases, exact runtime
positions, QBasic error numbers, string overflow, host failure, and
`subsystem_runtime` lifecycle behavior. None of these fixtures contains code
from the local GORILLA.BAS acceptance source.
