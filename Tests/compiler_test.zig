const std = @import("std");
const core = @import("core");

const fixture_paths = struct {
    const expressions = "Tests/Fixtures/vm_expressions.bas";
    const control_flow = "Tests/Fixtures/vm_control_flow.bas";
    const procedures = "Tests/Fixtures/vm_procedures.bas";
    const builtins = "Tests/Fixtures/vm_builtins.bas";
    const infinite = "Tests/Fixtures/vm_infinite.bas";
    const isolation = "Tests/Fixtures/vm_isolation.bas";
    const arrays_records_data = "Tests/Fixtures/vm_arrays_records_data.bas";
    const error_resume = "Tests/Fixtures/vm_error_resume.bas";
    const private_memory = "Tests/Fixtures/vm_private_memory.bas";
    const text_input = "Tests/Fixtures/vm_text_input.bas";
    const time_random = "Tests/Fixtures/vm_time_random.bas";
    const pacing = "Tests/Fixtures/vm_pacing.bas";
    const sequential_files = "Tests/Fixtures/vm_sequential_files.bas";
};

test "core compiler emits a bound instruction program" {
    var program = try core.compiler.compile(std.testing.allocator, "smoke.bas", "DEFINT A-Z\nAnswer = 6 * 7\nEND\n");
    defer program.deinit();
    if (!program.ok()) {
        for (program.diagnostics) |diagnostic| {
            std.debug.print("{s}:{d}:{d}: {s}\n", .{
                diagnostic.file_name,
                diagnostic.span.line,
                diagnostic.span.column,
                @tagName(diagnostic.code),
            });
        }
    }
    try std.testing.expect(program.ok());
    try std.testing.expectEqual(@as(u32, 1), program.parse_passes);
    try std.testing.expectEqual(@as(u32, 1), program.bind_passes);
    try std.testing.expect(program.instructions.len != 0);
    try std.testing.expectEqual(@as(usize, 1), program.globals.len);
}

test "core VM executes the prepared instruction program" {
    var program = try core.compiler.compile(std.testing.allocator, "answer.bas", "DEFINT A-Z\nAnswer = 6 * 7\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(32, 8));
    const answer = machine.global("Answer") orelse return error.MissingAnswer;
    try std.testing.expectEqual(@as(i16, 42), answer.integer);
}

test "typed expressions preserve QBasic values and conversions" {
    var program = try compileFixture(fixture_paths.expressions);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 16));

    try expectInteger(&machine, "IntegerValue%", 14);
    try expectLong(&machine, "LongValue&", 70_000);
    try expectSingle(&machine, "SingleValue!", 2.5);
    try expectDouble(&machine, "DoubleValue#", 8.0);
    try expectInteger(&machine, "ConstantValue%", 6);
    try expectInteger(&machine, "RoundedHigh%", 3);
    try expectInteger(&machine, "RoundedLow%", -3);
    try expectInteger(&machine, "TruthValue%", -1);
    try expectInteger(&machine, "FalseValue%", 0);
    try expectInteger(&machine, "StringOrder%", -1);
    try expectDouble(&machine, "MixedValue#", 14.5);
    try expectInteger(&machine, "IntegerQuotient%", 2);
    try expectInteger(&machine, "Remainder%", 2);
    try expectString(&machine, "TextValue$", "R4OS");
}

test "bound jumps loops selection and gosub return are deterministic" {
    var program = try compileFixture(fixture_paths.control_flow);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 128));
    try expectInteger(&machine, "Total", 265);
    try expectInteger(&machine, "Count", 1);
}

test "ByRef ByVal FUNCTION implicit CALL and DEF FN use isolated frames" {
    var program = try compileFixture(fixture_paths.procedures);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 64));
    try expectInteger(&machine, "GlobalValue", 11);
    try expectInteger(&machine, "TouchCount", 2);
    try expectInteger(&machine, "FunctionResult", 22);
    try expectLong(&machine, "FactorialResult&", 120);
    try expectInteger(&machine, "DefResult", 23);
}

const MathProbe = struct {
    calls: u32 = 0,
};

fn probingMath(context: ?*anyopaque, operation: core.vm.MathOperation, first: f64, second: f64) core.vm.HostMathError!f64 {
    const probe: *MathProbe = @ptrCast(@alignCast(context.?));
    probe.calls += 1;
    return switch (operation) {
        .atn => std.math.atan(first),
        .cos => @cos(first),
        .sin => @sin(first),
        .power => std.math.pow(f64, first, second),
    };
}

fn failingMath(_: ?*anyopaque, _: core.vm.MathOperation, _: f64, _: f64) core.vm.HostMathError!f64 {
    return error.MathFault;
}

test "math and byte-string builtins use injectable host services" {
    var program = try compileFixture(fixture_paths.builtins);
    defer program.deinit();
    try expectProgramOk(&program);
    var probe: MathProbe = .{};
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .context = &probe,
        .math = probingMath,
    });
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 32));
    try std.testing.expectEqual(@as(u32, 3), probe.calls);
    try expectInteger(&machine, "AbsoluteValue", 5);
    try expectInteger(&machine, "RoundedValue", 3);
    try expectInteger(&machine, "FloorValue", -3);
    try expectString(&machine, "TextValue$", "AR4BASICCORE  7");
    try expectInteger(&machine, "TextLength", 15);
    try expectInteger(&machine, "FoundAt", 4);
    try expectDouble(&machine, "Angle#", std.math.atan(@as(f64, 1.0)) + 1.0);
    try expectDouble(&machine, "Parsed#", 12.5);
}

test "runtime faults keep stable source positions and QBasic error numbers" {
    const Case = struct {
        source: []const u8,
        code: core.vm.RuntimeCode,
        qbasic_number: i32,
        line: u32,
        column: u32,
    };
    const cases = [_]Case{
        .{ .source = "DEFINT A-Z\nValue = 1 / 0\nEND\n", .code = .division_by_zero, .qbasic_number = 11, .line = 2, .column = 11 },
        .{ .source = "DEFINT A-Z\nValue = CINT(40000)\nEND\n", .code = .overflow, .qbasic_number = 6, .line = 2, .column = 9 },
        .{ .source = "DEFINT A-Z\nText$ = CHR$(256)\nEND\n", .code = .illegal_function_call, .qbasic_number = 5, .line = 2, .column = 9 },
        .{ .source = "DEFINT A-Z\nText$ = SPACE$(20000) + SPACE$(20000)\nEND\n", .code = .overflow, .qbasic_number = 6, .line = 2, .column = 23 },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "runtime-error.bas", case.source);
        defer program.deinit();
        try expectProgramOk(&program);
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(32, 8));
        const diagnostic = machine.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
        try std.testing.expectEqual(case.code, diagnostic.code);
        try std.testing.expectEqual(case.qbasic_number, machine.exit_code);
        try std.testing.expectEqual(case.line, diagnostic.span.line);
        try std.testing.expectEqual(case.column, diagnostic.span.column);
        try std.testing.expectEqualStrings("runtime-error.bas", diagnostic.file_name);
    }
}

test "injected host failures become deterministic runtime diagnostics" {
    var program = try core.compiler.compile(std.testing.allocator, "host-error.bas", "DEFINT A-Z\nValue# = COS(0#)\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{ .math = failingMath });
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(32, 8));
    const diagnostic = machine.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
    try std.testing.expectEqual(core.vm.RuntimeCode.host_failure, diagnostic.code);
    try std.testing.expectEqual(@as(i32, 70), machine.exit_code);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.span.line);
    try std.testing.expectEqual(@as(u32, 10), diagnostic.span.column);
}

test "compiler rejects invalid bindings labels and array shapes" {
    const Case = struct {
        source: []const u8,
        expected: core.bytecode.DiagnosticCode,
    };
    const cases = [_]Case{
        .{ .source = "DECLARE SUB SetValues(Values() AS INTEGER)\nDIM Value AS INTEGER\nCALL SetValues(Value)\nEND\nSUB SetValues(Values() AS INTEGER)\nEND SUB\n", .expected = .invalid_array_argument },
        .{ .source = "GOTO Missing\nEND\n", .expected = .unknown_label },
        .{ .source = "DIM Values(1 TO 3)\nValue = Values(1, 2)\nEND\n", .expected = .wrong_dimension_count },
        .{ .source = "CONST Fixed = 1\nFixed = 2\nEND\n", .expected = .constant_assignment },
        .{ .source = "IF \"text\" THEN Value = 1\nEND\n", .expected = .type_mismatch },
        .{ .source = "FOR Index = \"text\" TO 3\nNEXT Index\nEND\n", .expected = .type_mismatch },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "compile-error.bas", case.source);
        defer program.deinit();
        try std.testing.expect(!program.ok());
        try std.testing.expect(containsCompileDiagnostic(program.diagnostics, case.expected));
    }
}

test "dynamic arrays records DATA and aggregate ByRef remain instance local" {
    var program = try compileFixture(fixture_paths.arrays_records_data);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expectEqual(@as(usize, 1), program.record_types.len);
    try std.testing.expectEqual(@as(usize, 3), program.data_items.len);
    try std.testing.expectEqual(@as(i32, -2_134_835_200), program.data_items[1].constant.long);

    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();

    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(128, 64));
    try expectArrayLong(&first, "Image&", &.{0}, 458_758);
    try expectArrayLong(&first, "Image&", &.{1}, -2_134_835_200);
    try expectArrayLong(&first, "Image&", &.{2}, 1_886_416_900);
    try expectArrayLong(&first, "Grid&", &.{ -1, 2 }, 458_758);
    try expectArrayLong(&first, "Grid&", &.{ 0, 3 }, 458_759);
    try expectArrayRecordInteger(&first, "Points", &.{2}, "XCoor", 23);
    try expectArrayRecordInteger(&first, "Points", &.{2}, "YCoor", 55);
    try expectInteger(&first, "SharedCount", 1);

    try std.testing.expect(second.globalArrayElement("Image&", &.{0}) == null);
    try std.testing.expectEqual(core.vm.Status.halted, second.runToCompletion(128, 64));
    try expectArrayLong(&second, "Image&", &.{1}, -2_134_835_200);
    try expectInteger(&second, "SharedCount", 1);

    try first.reset();
    try std.testing.expect(first.globalArrayElement("Image&", &.{0}) == null);
    try expectInteger(&first, "SharedCount", 0);
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(128, 64));
    try expectArrayRecordInteger(&first, "Points", &.{2}, "YCoor", 55);
}

test "fixed bounds REDIM reset and RESTORE preserve typed DATA order" {
    const source =
        "DEFINT A-Z\n" ++
        "DIM Fixed(-2 TO -1, 4 TO 5)\n" ++
        "Fixed(-2, 4) = 17\n" ++
        "'$DYNAMIC\n" ++
        "DIM Dynamic&(1)\n" ++
        "Dynamic&(0) = 99\n" ++
        "REDIM Dynamic&(-1 TO 1)\n" ++
        "ResetValue& = Dynamic&(0)\n" ++
        "READ First, Word$, Signed&\n" ++
        "RESTORE\n" ++
        "READ NumericText$\n" ++
        "END\n" ++
        "Items:\n" ++
        "DATA 7, hello, -8\n";
    var program = try core.compiler.compile(std.testing.allocator, "array-data.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 32));
    const fixed = machine.globalArrayElement("Fixed", &.{ -2, 4 }) orelse return error.MissingFixedElement;
    try std.testing.expectEqual(@as(i16, 17), fixed.integer);
    try expectLong(&machine, "ResetValue&", 0);
    try expectInteger(&machine, "First", 7);
    try expectString(&machine, "Word$", "hello");
    try expectLong(&machine, "Signed&", -8);
    try expectString(&machine, "NumericText$", "7");
}

test "aggregate runtime errors are bounded and deterministic" {
    const cases = [_]struct {
        source: []const u8,
        expected: core.vm.RuntimeCode,
        number: i32,
    }{
        .{ .source = "DEFINT A-Z\nDIM Values(1 TO 2)\nValue = Values(3)\nEND\n", .expected = .subscript_out_of_range, .number = 9 },
        .{ .source = "DEFINT A-Z\nREAD Value\nEND\n", .expected = .out_of_data, .number = 4 },
        .{ .source = "DEFINT A-Z\nRESUME NEXT\nEND\n", .expected = .resume_without_error, .number = 20 },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "aggregate-error.bas", case.source);
        defer program.deinit();
        try expectProgramOk(&program);
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(32, 8));
        try std.testing.expectEqual(case.expected, machine.runtime_diagnostic.?.code);
        try std.testing.expectEqual(case.number, machine.exit_code);
    }
}

const ScreenProbe = struct {
    calls: u32 = 0,

    fn screenMode(context: ?*anyopaque, mode: i32) core.vm.ScreenModeError!void {
        const self: *ScreenProbe = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (mode == 9) return error.ModeUnavailable;
    }
};

test "ON ERROR retries or skips whole statements and unhandled faults stay local" {
    var program = try compileFixture(fixture_paths.error_resume);
    defer program.deinit();
    try expectProgramOk(&program);
    var probe: ScreenProbe = .{};
    var handled = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .context = &probe,
        .screen_mode = ScreenProbe.screenMode,
    });
    defer handled.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, handled.runToCompletion(64, 64));
    try std.testing.expectEqual(@as(u32, 3), probe.calls);
    try expectInteger(&handled, "RetryCount", 1);
    try expectInteger(&handled, "NextCount", 1);
    try expectInteger(&handled, "AfterRetry", 1);
    try expectInteger(&handled, "AfterNext", 1);
    try std.testing.expect(handled.runtime_diagnostic == null);
    try std.testing.expectEqual(core.vm.RuntimeCode.illegal_function_call, handled.trapped_diagnostic.?.code);

    var unhandled_program = try core.compiler.compile(std.testing.allocator, "unhandled.bas", "DEFINT A-Z\nSCREEN 9\nEND\n");
    defer unhandled_program.deinit();
    try expectProgramOk(&unhandled_program);
    var failing_probe: ScreenProbe = .{};
    var unhandled = try core.vm.Vm.init(std.testing.allocator, &unhandled_program, .{
        .context = &failing_probe,
        .screen_mode = ScreenProbe.screenMode,
    });
    defer unhandled.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, unhandled.runToCompletion(16, 8));
    try std.testing.expectEqual(core.vm.RuntimeCode.illegal_function_call, unhandled.runtime_diagnostic.?.code);
    try std.testing.expectEqual(@as(i32, 5), unhandled.exit_code);
    try std.testing.expectEqual(core.vm.Status.halted, handled.status);

    var handler_fault_program = try core.compiler.compile(std.testing.allocator, "handler-fault.bas", "DEFINT A-Z\nON ERROR GOTO Handler\nSCREEN 9\nEND\nHandler:\nValue = 1 / 0\nRESUME NEXT\n");
    defer handler_fault_program.deinit();
    try expectProgramOk(&handler_fault_program);
    var handler_probe: ScreenProbe = .{};
    var handler_fault = try core.vm.Vm.init(std.testing.allocator, &handler_fault_program, .{
        .context = &handler_probe,
        .screen_mode = ScreenProbe.screenMode,
    });
    defer handler_fault.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, handler_fault.runToCompletion(32, 8));
    try std.testing.expectEqual(core.vm.RuntimeCode.division_by_zero, handler_fault.runtime_diagnostic.?.code);
    try std.testing.expectEqual(@as(i32, 11), handler_fault.exit_code);
}

test "DEF SEG PEEK and POKE expose only the private NumLock byte" {
    var program = try compileFixture(fixture_paths.private_memory);
    defer program.deinit();
    try expectProgramOk(&program);
    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(32, 16));
    try expectInteger(&first, "Original", 0);
    try expectInteger(&first, "Enabled", 32);
    try std.testing.expectEqual(@as(u8, 32), first.virtualNumLockByte());
    try std.testing.expectEqual(@as(u8, 0), second.virtualNumLockByte());
    try first.reset();
    try std.testing.expectEqual(@as(u8, 0), first.virtualNumLockByte());

    const invalid_sources = [_][]const u8{
        "DEFINT A-Z\nDEF SEG = 0\nValue = PEEK(1046)\nEND\n",
        "DEFINT A-Z\nValue = PEEK(1047)\nEND\n",
        "DEFINT A-Z\nDEF SEG = 1\nEND\n",
    };
    for (invalid_sources) |source| {
        var invalid_program = try core.compiler.compile(std.testing.allocator, "restricted-memory.bas", source);
        defer invalid_program.deinit();
        try expectProgramOk(&invalid_program);
        var invalid = try core.vm.Vm.init(std.testing.allocator, &invalid_program, .{});
        defer invalid.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, invalid.runToCompletion(16, 8));
        try std.testing.expectEqual(core.vm.RuntimeCode.restricted_memory, invalid.runtime_diagnostic.?.code);
        try std.testing.expectEqual(@as(i32, 5), invalid.exit_code);
    }
}

test "instruction slices cancellation and two instances remain independent" {
    var program = try compileFixture(fixture_paths.infinite);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expectEqual(@as(u32, 1), program.parse_passes);
    try std.testing.expectEqual(@as(u32, 1), program.bind_passes);

    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 0), first.callDepth());
    try std.testing.expectEqual(@as(usize, 0), second.callDepth());
    try std.testing.expectEqual(core.vm.Status.yielded, first.runSlice(7).status);
    try std.testing.expectEqual(@as(usize, 1), first.callDepth());
    try std.testing.expectEqual(@as(usize, 0), second.callDepth());

    var index: usize = 0;
    while (index < 12) : (index += 1) {
        const result = first.runSlice(7);
        try std.testing.expectEqual(core.vm.Status.yielded, result.status);
        try std.testing.expectEqual(@as(u32, 7), result.instructions);
    }
    const second_result = second.runSlice(7);
    try std.testing.expectEqual(core.vm.Status.yielded, second_result.status);
    const first_counter = (first.global("Counter") orelse return error.MissingCounter).integer;
    const second_counter = (second.global("Counter") orelse return error.MissingCounter).integer;
    try std.testing.expect(first_counter > second_counter);
    try std.testing.expect(first.instruction_pointer != second.instruction_pointer or first.total_instructions != second.total_instructions);

    second.requestCancel();
    try std.testing.expectEqual(core.vm.Status.cancelled, second.runSlice(0).status);
    try std.testing.expectEqual(@as(i32, 130), second.exit_code);
    try std.testing.expectEqual(core.vm.Status.yielded, first.runSlice(7).status);
    try std.testing.expect(first.runtime_diagnostic == null);
    try std.testing.expectEqual(@as(i32, 0), first.exit_code);
    try std.testing.expectEqual(@as(usize, 1), first.callDepth());
    try std.testing.expectEqual(@as(u32, 1), program.parse_passes);
    try std.testing.expectEqual(@as(u32, 1), program.bind_passes);
}

test "simultaneous instances isolate stacks instruction pointers errors and exit codes" {
    var program = try compileFixture(fixture_paths.isolation);
    defer program.deinit();
    try expectProgramOk(&program);
    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();

    try std.testing.expectEqual(core.vm.Status.yielded, first.runSlice(7).status);
    try std.testing.expectEqual(@as(usize, 1), first.callDepth());
    try std.testing.expectEqual(@as(usize, 0), second.callDepth());
    try std.testing.expectEqual(core.vm.Status.runtime_error, second.runToCompletion(128, 8));

    try expectInteger(&first, "Counter", 1);
    try expectInteger(&second, "Counter", 4);
    try std.testing.expectEqual(@as(usize, 1), first.callDepth());
    try std.testing.expectEqual(@as(usize, 1), second.callDepth());
    try std.testing.expect(first.instruction_pointer != second.instruction_pointer);
    try std.testing.expect(first.valueStackDepth() != second.valueStackDepth());
    try std.testing.expect(first.runtime_diagnostic == null);
    try std.testing.expectEqual(@as(i32, 0), first.exit_code);
    const second_diagnostic = second.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
    try std.testing.expectEqual(core.vm.RuntimeCode.division_by_zero, second_diagnostic.code);
    try std.testing.expectEqual(@as(i32, 11), second.exit_code);

    first.requestCancel();
    try std.testing.expectEqual(core.vm.Status.cancelled, first.runSlice(0).status);
    try std.testing.expectEqual(@as(i32, 130), first.exit_code);
    try std.testing.expectEqual(core.vm.Status.runtime_error, second.runSlice(7).status);
    try std.testing.expectEqual(@as(i32, 11), second.exit_code);
}

const RuntimeHostProbe = struct {
    close_next: bool = false,
    handled_left: u32 = 0,
    polls: u32 = 0,

    fn driver(self: *RuntimeHostProbe) core.runtime_adapter.api.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn poll(context: *anyopaque) core.runtime_adapter.api.HostPollResult {
        const self: *RuntimeHostProbe = @ptrCast(@alignCast(context));
        self.polls += 1;
        if (self.handled_left != 0) {
            self.handled_left -= 1;
            return .handled;
        }
        if (self.close_next) {
            self.close_next = false;
            return .{ .command = .close };
        }
        return .idle;
    }

    fn present(_: *anyopaque) i32 {
        return 0;
    }
};

test "subsystem runtime polls close before the next bounded BASIC slice" {
    var program = try compileFixture(fixture_paths.infinite);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = RuntimeHostProbe{};
    var runtime = try core.runtime_adapter.api.Runtime.init(.{
        .slice_budget = 7,
        .max_input_events = 4,
        .max_wait_ticks = 1,
    }, 100, 0, null);

    _ = runtime.cycle(0, adapter.driver(), host.driver());
    try std.testing.expectEqual(@as(u64, 7), machine.total_instructions);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.slices);
    try std.testing.expectEqual(@as(usize, 1), machine.callDepth());

    runtime.request(.reset, 0, adapter.driver());
    try std.testing.expectEqual(@as(u64, 0), machine.total_instructions);
    try std.testing.expectEqual(@as(usize, 0), machine.callDepth());
    try expectInteger(&machine, "Counter", 0);
    _ = runtime.cycle(1, adapter.driver(), host.driver());
    const before_close = machine.total_instructions;

    host.close_next = true;
    const result = runtime.cycle(2, adapter.driver(), host.driver());
    switch (result) {
        .finished => |finished| {
            try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.closed, finished.state);
            try std.testing.expectEqual(@as(i32, 0), finished.exit_code);
        },
        .wait => return error.ExpectedClosedRuntime,
    }
    try std.testing.expectEqual(before_close, machine.total_instructions);
    try std.testing.expectEqual(@as(u64, 2), runtime.stats.slices);
    try std.testing.expect(runtime.resources_closed);
}

test "text screen PRINT and interactive INPUT preserve editing and redo semantics" {
    var program = try compileFixture(fixture_paths.text_input);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();

    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    const initial_screen = machine.textScreen();
    try std.testing.expectEqual(@as(u8, 'R'), initial_screen.cell(1, 2).?.character);
    try std.testing.expectEqual(@as(u8, 14), initial_screen.cell(1, 2).?.foreground);
    try std.testing.expectEqual(@as(u8, 1), initial_screen.cell(1, 2).?.background);
    try std.testing.expect(!initial_screen.cursor_visible);

    try feedInput(&machine, "Alix");
    try std.testing.expect(try machine.enqueueKeyCode(8));
    try feedInput(&machine, "ce\r");
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    try expectString(&machine, "Name$", "Alice");

    try feedInput(&machine, "not-a-number\r");
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    var found_redo = false;
    var row_bytes: [core.text_screen.columns]u8 = undefined;
    for (0..core.text_screen.rows) |row| {
        try std.testing.expect(machine.textScreen().copyRow(row, &row_bytes));
        if (std.mem.indexOf(u8, &row_bytes, "Redo from start") != null) found_redo = true;
    }
    try std.testing.expect(found_redo);

    try feedInput(&machine, "3\r");
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    try feedInput(&machine, "9.8\r");
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 32));
    try expectInteger(&machine, "Count", 3);
    try expectDouble(&machine, "Gravity#", 9.8);
    try std.testing.expect(machine.textScreen().cursor_visible);
}

test "INKEY is nonblocking focus-aware and isolated per VM" {
    const source = "First$ = INKEY$\nSecond$ = INKEY$\nEND\n";
    var program = try core.compiler.compile(std.testing.allocator, "inkey.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();

    first.setInputFocused(false);
    try std.testing.expect(!try first.enqueueTextCodepoint('X'));
    first.setInputFocused(true);
    try std.testing.expect(try first.enqueueTextCodepoint('A'));
    try std.testing.expect(try second.enqueueTextCodepoint('B'));
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(32, 8));
    try std.testing.expectEqual(core.vm.Status.halted, second.runToCompletion(32, 8));
    try expectString(&first, "First$", "A");
    try expectString(&first, "Second$", "");
    try expectString(&second, "First$", "B");
    try expectString(&second, "Second$", "");

    var adapter = core.runtime_adapter.Adapter.init(&first);
    try std.testing.expect(adapter.handleInput(.{ .focus = .{ .focused = false, .tick = 1 } }));
    try std.testing.expect(!adapter.handleInput(.{ .text = .{ .codepoint = 'Z', .modifiers = 0, .tick = 2 } }));
}

test "TIMER SLEEP and RND use injected pause-free guest state" {
    var program = try compileFixture(fixture_paths.time_random);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    machine.setGuestTime(10 * std.time.ns_per_s);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    const first_value = machine.global("First!").?.single;
    try expectSingle(&machine, "Held!", first_value);
    const negative_value = machine.global("NegativeA!").?.single;
    try expectSingle(&machine, "NegativeB!", negative_value);
    try expectSingle(&machine, "Before!", 10.0);

    machine.setGuestTime(10 * std.time.ns_per_s + 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runSlice(128).status);
    machine.setGuestTime(11 * std.time.ns_per_s);
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 32));
    try expectSingle(&machine, "After!", 11.0);

    const timer_seed_source = "RANDOMIZE TIMER\nValue! = RND\nEND\n";
    var seeded_program = try core.compiler.compile(std.testing.allocator, "timer-seed.bas", timer_seed_source);
    defer seeded_program.deinit();
    try expectProgramOk(&seeded_program);
    var early = try core.vm.Vm.init(std.testing.allocator, &seeded_program, .{});
    defer early.deinit();
    var late = try core.vm.Vm.init(std.testing.allocator, &seeded_program, .{});
    defer late.deinit();
    early.setGuestTime(1 * std.time.ns_per_s);
    late.setGuestTime(2 * std.time.ns_per_s);
    try std.testing.expectEqual(core.vm.Status.halted, early.runToCompletion(32, 8));
    try std.testing.expectEqual(core.vm.Status.halted, late.runToCompletion(32, 8));
    try std.testing.expect(early.global("Value!").?.single != late.global("Value!").?.single);
}

test "SLEEP yields cooperatively and a new key interrupts it" {
    var program = try core.compiler.compile(std.testing.allocator, "sleep.bas", "DEFINT A-Z\nSLEEP 5\nDone = 1\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    machine.setGuestTime(3 * std.time.ns_per_s);
    const waiting = machine.runToCompletion(32, 8);
    try std.testing.expectEqual(core.vm.Status.waiting, waiting);
    try std.testing.expect(try machine.enqueueTextCodepoint('X'));
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(32, 8));
    try expectInteger(&machine, "Done", 1);
}

test "bare RANDOMIZE prompts retries invalid seeds and stays reproducible" {
    var program = try core.compiler.compile(std.testing.allocator, "randomize.bas", "RANDOMIZE\nValue! = RND\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();

    for ([_]*core.vm.Vm{ &first, &second }) |machine| {
        try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(32, 8));
        try std.testing.expect(screenContainsText(machine, "Random Number Seed"));
        try feedInput(machine, "invalid\r");
        try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(32, 8));
        try std.testing.expect(screenContainsText(machine, "Redo from start"));
        try feedInput(machine, "42\r");
        try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(32, 8));
    }
    try std.testing.expectEqual(first.global("Value!").?.single, second.global("Value!").?.single);
}

test "runtime guest clock excludes pause time and polls host actions while BASIC waits" {
    var program = try core.compiler.compile(std.testing.allocator, "pause.bas", "Before! = TIMER\nSLEEP 1\nAfter! = TIMER\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = RuntimeHostProbe{};
    var runtime = try core.runtime_adapter.api.Runtime.init(.{
        .slice_budget = 4096,
        .max_input_events = 8,
        .max_wait_ticks = 1,
    }, 1000, 0, null);

    _ = runtime.cycle(0, adapter.driver(), host.driver());
    try std.testing.expectEqual(core.vm.Status.waiting, machine.status);
    const slices_before_pause = runtime.stats.slices;
    runtime.request(.pause, 100, adapter.driver());
    host.handled_left = 3;
    _ = runtime.cycle(1000, adapter.driver(), host.driver());
    try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.paused, runtime.state);
    try std.testing.expectEqual(slices_before_pause, runtime.stats.slices);
    try std.testing.expectEqual(@as(u64, 3), runtime.stats.input_events);

    runtime.request(.resume_running, 5000, adapter.driver());
    _ = runtime.cycle(5000, adapter.driver(), host.driver());
    const finished = runtime.cycle(5900, adapter.driver(), host.driver());
    switch (finished) {
        .finished => |result| {
            try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.completed, result.state);
            try std.testing.expectEqual(@as(i32, 0), result.exit_code);
        },
        .wait => return error.ExpectedCompletedRuntime,
    }
    try expectSingle(&machine, "Before!", 0.0);
    try expectSingle(&machine, "After!", 1.0);
}

test "CalcDelay and Rest use reproducible bounded guest pacing" {
    var first_program = try compileFixture(fixture_paths.pacing);
    defer first_program.deinit();
    try expectProgramOk(&first_program);
    var second_program = try compileFixture(fixture_paths.pacing);
    defer second_program.deinit();
    try expectProgramOk(&second_program);

    const first = try runPacingProgram(&first_program);
    const second = try runPacingProgram(&second_program);
    try std.testing.expectEqual(first.finish_tick, second.finish_tick);
    try std.testing.expectEqual(first.machine_speed, second.machine_speed);
    try std.testing.expectApproxEqAbs(first.elapsed, second.elapsed, 0.000001);
    try std.testing.expect(first.machine_speed >= 450 and first.machine_speed <= 550);
    try std.testing.expect(first.elapsed >= 0.09 and first.elapsed <= 0.12);
}

const PacingResult = struct {
    finish_tick: u64,
    machine_speed: f32,
    elapsed: f64,
};

fn runPacingProgram(program: *const core.bytecode.Program) !PacingResult {
    var machine = try core.vm.Vm.init(std.testing.allocator, program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = RuntimeHostProbe{};
    var runtime = try core.runtime_adapter.api.Runtime.init(.{
        .slice_budget = 4096,
        .max_input_events = 4,
        .max_wait_ticks = 1,
    }, 1000, 0, null);

    var finish_tick: u64 = 0;
    for (0..3000) |raw_tick| {
        const tick: u64 = @intCast(raw_tick);
        const result = runtime.cycle(tick, adapter.driver(), host.driver());
        if (result == .finished) {
            try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.completed, result.finished.state);
            finish_tick = tick;
            break;
        }
    }
    if (finish_tick == 0) return error.PacingProgramDidNotFinish;
    return .{
        .finish_tick = finish_tick,
        .machine_speed = machine.global("MachSpeed").?.single,
        .elapsed = machine.global("After#").?.double - machine.global("Before#").?.double,
    };
}

const MemoryFiles = struct {
    input: []const u8 = "\"Alice\",3\r\nLine two\r\n",
    output: std.ArrayList(u8) = .empty,
    appended: std.ArrayList(u8) = .empty,
    absolute_output: std.ArrayList(u8) = .empty,
    reads: u32 = 0,
    writes: u32 = 0,

    fn deinit(self: *MemoryFiles) void {
        self.output.deinit(std.testing.allocator);
        self.appended.deinit(std.testing.allocator);
        self.absolute_output.deinit(std.testing.allocator);
    }

    fn read(context: ?*anyopaque, path: []const u8, offset: u32, out: []u8) core.vm.FileReadResult {
        const self: *MemoryFiles = @ptrCast(@alignCast(context.?));
        self.reads += 1;
        if (!std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\input.txt")) return .{ .failure = .not_found };
        if (offset >= self.input.len) return .end;
        const count = @min(out.len, self.input.len - offset);
        @memcpy(out[0..count], self.input[offset..][0..count]);
        return .{ .bytes = @intCast(count) };
    }

    fn write(context: ?*anyopaque, path: []const u8, bytes: []const u8, append: bool) core.vm.FileWriteResult {
        const self: *MemoryFiles = @ptrCast(@alignCast(context.?));
        self.writes += 1;
        const target = if (std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\output.txt"))
            &self.output
        else if (std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\append.txt"))
            &self.appended
        else if (std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\absolute.txt"))
            &self.absolute_output
        else
            return .{ .failure = .path_error };
        if (!append) target.clearRetainingCapacity();
        target.appendSlice(std.testing.allocator, bytes) catch return .{ .failure = .too_large };
        return .ok;
    }
};

test "sequential files resolve guest paths and preserve INPUT PRINT and EOF" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_paths.sequential_files, std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\PROGRAM.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var files = MemoryFiles{};
    defer files.deinit();
    try files.appended.appendSlice(std.testing.allocator, "head\r\n");
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 32));
    try expectString(&machine, "Name$", "Alice");
    try expectInteger(&machine, "Score", 3);
    try expectString(&machine, "Message$", "Line two");
    try expectInteger(&machine, "AtEnd", -1);
    try expectString(&machine, "AbsoluteName$", "\"Alice\",3");
    try std.testing.expectEqualStrings("Alice 3 \r\nLine two", files.output.items);
    try std.testing.expectEqualStrings("head\r\ntail\r\n", files.appended.items);
    try std.testing.expectEqualStrings("\"Alice\",3", files.absolute_output.items);
    try std.testing.expect(files.reads != 0);
    try std.testing.expect(files.writes >= 4);
}

test "file modes numbers devices and missing paths fail visibly" {
    const Case = struct {
        source: []const u8,
        expected: core.vm.RuntimeCode,
        number: i32,
    };
    const cases = [_]Case{
        .{ .source = "OPEN \"input.txt\" FOR INPUT AS #0\nEND\n", .expected = .bad_file_number, .number = 52 },
        .{ .source = "OPEN \"missing.txt\" FOR INPUT AS #1\nEND\n", .expected = .file_not_found, .number = 53 },
        .{ .source = "OPEN \"input.txt\" FOR INPUT AS #1\nPRINT #1, \"bad\"\nEND\n", .expected = .bad_file_mode, .number = 54 },
        .{ .source = "OPEN \"COM1:\" FOR OUTPUT AS #1\nEND\n", .expected = .bad_file_name, .number = 64 },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\NEGATIVE.BAS", case.source);
        defer program.deinit();
        try expectProgramOk(&program);
        var files = MemoryFiles{};
        defer files.deinit();
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
            .file_context = &files,
            .file_read = MemoryFiles.read,
            .file_write = MemoryFiles.write,
        });
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(64, 16));
        const diagnostic = machine.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
        try std.testing.expectEqual(case.expected, diagnostic.code);
        try std.testing.expectEqual(case.number, diagnostic.qbasicErrorNumber());
    }

    var bridge = core.storage_adapter.Adapter.init(undefined);
    var services = core.vm.HostServices{};
    bridge.install(&services);
    try std.testing.expect(services.file_context != null);
}

fn feedInput(machine: *core.vm.Vm, bytes: []const u8) !void {
    for (bytes) |byte| {
        const accepted = switch (byte) {
            '\r', '\n', 8 => try machine.enqueueKeyCode(byte),
            else => try machine.enqueueTextCodepoint(byte),
        };
        try std.testing.expect(accepted);
    }
}

fn screenContainsText(machine: *const core.vm.Vm, needle: []const u8) bool {
    var row_bytes: [core.text_screen.columns]u8 = undefined;
    for (0..core.text_screen.rows) |row| {
        if (!machine.textScreen().copyRow(row, &row_bytes)) return false;
        if (std.mem.indexOf(u8, &row_bytes, needle) != null) return true;
    }
    return false;
}

fn compileFixture(path: []const u8) !core.bytecode.Program {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    return core.compiler.compile(std.testing.allocator, path, source);
}

fn expectProgramOk(program: *const core.bytecode.Program) !void {
    if (!program.ok()) {
        for (program.diagnostics) |diagnostic| {
            std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{
                diagnostic.file_name,
                diagnostic.span.line,
                diagnostic.span.column,
                @tagName(diagnostic.code),
                diagnostic.span.bytes(program.source),
            });
        }
    }
    try std.testing.expect(program.ok());
}

fn expectInteger(machine: *const core.vm.Vm, name: []const u8, expected: i16) !void {
    const actual = machine.global(name) orelse return error.MissingGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.integer, actual.valueType());
    try std.testing.expectEqual(expected, actual.integer);
}

fn expectLong(machine: *const core.vm.Vm, name: []const u8, expected: i32) !void {
    const actual = machine.global(name) orelse return error.MissingGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.long, actual.valueType());
    try std.testing.expectEqual(expected, actual.long);
}

fn expectSingle(machine: *const core.vm.Vm, name: []const u8, expected: f32) !void {
    const actual = machine.global(name) orelse return error.MissingGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.single, actual.valueType());
    try std.testing.expectApproxEqAbs(expected, actual.single, 0.00001);
}

fn expectDouble(machine: *const core.vm.Vm, name: []const u8, expected: f64) !void {
    const actual = machine.global(name) orelse return error.MissingGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.double, actual.valueType());
    try std.testing.expectApproxEqAbs(expected, actual.double, 0.0000001);
}

fn expectString(machine: *const core.vm.Vm, name: []const u8, expected: []const u8) !void {
    const actual = machine.global(name) orelse return error.MissingGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.string, actual.valueType());
    try std.testing.expectEqualStrings(expected, actual.string);
}

fn expectArrayLong(machine: *const core.vm.Vm, name: []const u8, indices: []const i32, expected: i32) !void {
    const actual = machine.globalArrayElement(name, indices) orelse return error.MissingArrayElement;
    try std.testing.expectEqual(core.bytecode.ValueType.long, actual.valueType());
    try std.testing.expectEqual(expected, actual.long);
}

fn expectArrayRecordInteger(
    machine: *const core.vm.Vm,
    name: []const u8,
    indices: []const i32,
    field: []const u8,
    expected: i16,
) !void {
    const actual = machine.globalArrayRecordField(name, indices, field) orelse return error.MissingRecordField;
    try std.testing.expectEqual(core.bytecode.ValueType.integer, actual.valueType());
    try std.testing.expectEqual(expected, actual.integer);
}

fn containsCompileDiagnostic(diagnostics: []const core.bytecode.Diagnostic, expected: core.bytecode.DiagnosticCode) bool {
    for (diagnostics) |diagnostic| if (diagnostic.code == expected) return true;
    return false;
}
