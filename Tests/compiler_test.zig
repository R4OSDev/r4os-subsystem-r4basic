const std = @import("std");
const core = @import("core");

const fixture_paths = struct {
    const expressions = "Tests/Fixtures/vm_expressions.bas";
    const control_flow = "Tests/Fixtures/vm_control_flow.bas";
    const procedures = "Tests/Fixtures/vm_procedures.bas";
    const builtins = "Tests/Fixtures/vm_builtins.bas";
    const infinite = "Tests/Fixtures/vm_infinite.bas";
    const isolation = "Tests/Fixtures/vm_isolation.bas";
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

test "compiler rejects invalid ByRef labels and later-layer syntax" {
    const Case = struct {
        source: []const u8,
        expected: core.bytecode.DiagnosticCode,
    };
    const cases = [_]Case{
        .{ .source = "DECLARE SUB SetValue(BYREF Value AS INTEGER)\nCALL SetValue(1 + 2)\nEND\n", .expected = .invalid_byref_argument },
        .{ .source = "GOTO Missing\nEND\n", .expected = .unknown_label },
        .{ .source = "DIM Values(1 TO 3)\nEND\n", .expected = .unsupported_core_feature },
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
    polls: u32 = 0,

    fn driver(self: *RuntimeHostProbe) core.runtime_adapter.api.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn poll(context: *anyopaque) core.runtime_adapter.api.HostPollResult {
        const self: *RuntimeHostProbe = @ptrCast(@alignCast(context));
        self.polls += 1;
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

fn containsCompileDiagnostic(diagnostics: []const core.bytecode.Diagnostic, expected: core.bytecode.DiagnosticCode) bool {
    for (diagnostics) |diagnostic| if (diagnostic.code == expected) return true;
    return false;
}
