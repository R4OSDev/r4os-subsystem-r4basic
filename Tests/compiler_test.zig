const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

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
    const graphics = "Tests/Fixtures/vm_graphics.bas";
    const packed_images = "Tests/Fixtures/vm_packed_images.bas";
    const audio = "Tests/Fixtures/vm_audio.bas";
};

const SourceInfo = struct {
    is_dir: u8 = 0,
    size: u64 = 0,
};

const SourceInfoResult = union(enum) {
    value: SourceInfo,
    missing,
    failure: i32,
};

const SourceTransfer = union(enum) {
    bytes: u32,
    end,
    failure: i32,
};

const SourceReader = struct {
    size: u64,
    info_calls: u32 = 0,
    read_calls: u32 = 0,
    read_bytes: u64 = 0,

    pub fn info(self: *@This(), _: []const u8) SourceInfoResult {
        self.info_calls += 1;
        return .{ .value = .{ .size = self.size } };
    }

    pub fn readAt(self: *@This(), _: []const u8, offset: u32, out: []u8) SourceTransfer {
        self.read_calls += 1;
        if (offset >= self.size) return .end;
        const count: usize = @intCast(@min(self.size - offset, out.len));
        @memset(out[0..count], 'P');
        self.read_bytes += count;
        return .{ .bytes = @intCast(count) };
    }
};

const GraphFile = struct {
    path: []const u8,
    source: []const u8,
};

const GraphSourceReader = struct {
    files: []const GraphFile,
    info_calls: u32 = 0,
    read_calls: u32 = 0,
    read_bytes: u64 = 0,

    pub fn info(self: *@This(), path: []const u8) SourceInfoResult {
        self.info_calls += 1;
        const file = self.find(path) orelse return .missing;
        return .{ .value = .{ .size = file.source.len } };
    }

    pub fn readAt(self: *@This(), path: []const u8, offset: u32, out: []u8) SourceTransfer {
        self.read_calls += 1;
        const file = self.find(path) orelse return .{ .failure = -1 };
        if (offset >= file.source.len) return .end;
        const count = @min(out.len, file.source.len - offset);
        @memcpy(out[0..count], file.source[offset .. offset + count]);
        self.read_bytes += count;
        return .{ .bytes = @intCast(count) };
    }

    fn find(self: *const @This(), path: []const u8) ?GraphFile {
        for (self.files) |file| if (std.ascii.eqlIgnoreCase(file.path, path)) return file;
        return null;
    }
};

test "source loader performs one exact load across the 128 KiB boundary through 256 KiB" {
    const sizes = [_]usize{
        128 * 1024 - 1,
        128 * 1024,
        128 * 1024 + 1,
        core.frontend.maximum_source_bytes,
    };
    for (sizes) |size| {
        var reader = SourceReader{ .size = size };
        const loaded = try core.source_loader.load(std.testing.allocator, &reader, "C:\\TEMP\\BOUNDARY.BAS");
        defer std.testing.allocator.free(loaded.bytes);
        try std.testing.expectEqual(size, loaded.bytes.len);
        try std.testing.expectEqual(@as(u8, 'P'), loaded.bytes[0]);
        try std.testing.expectEqual(@as(u8, 'P'), loaded.bytes[loaded.bytes.len - 1]);
        try std.testing.expectEqual(@as(u32, 1), loaded.stats.info_calls);
        try std.testing.expectEqual(@as(u32, 1), loaded.stats.read_calls);
        try std.testing.expectEqual(@as(u64, size), loaded.stats.read_bytes);
        try std.testing.expectEqual(@as(u32, 1), reader.info_calls);
        try std.testing.expectEqual(@as(u32, 1), reader.read_calls);
        try std.testing.expectEqual(@as(u64, size), reader.read_bytes);
    }

    var oversized = SourceReader{ .size = core.frontend.maximum_source_bytes + 1 };
    try std.testing.expectError(error.TooLarge, core.source_loader.load(std.testing.allocator, &oversized, "C:\\TEMP\\TOO-LARGE.BAS"));
    try std.testing.expectEqual(@as(u32, 1), oversized.info_calls);
    try std.testing.expectEqual(@as(u32, 0), oversized.read_calls);
}

test "$INCLUDE builds one bounded relative source graph with exact file identity" {
    const files = [_]GraphFile{
        .{
            .path = "C:\\GAME\\MAIN.BAS",
            .source =
            \\'$DYNAMIC $INCLUDE: 'INC\\ONE.BI' $STATIC
            \\'$INCLUDE: 'INC\\ONE.BI'
            \\Result = One + Two
            \\END
            ,
        },
        .{
            .path = "C:\\GAME\\INC\\ONE.BI",
            .source =
            \\One = 20
            \\'$INCLUDE: '..\\SHARED\\TWO.BI'
            ,
        },
        .{ .path = "C:\\GAME\\SHARED\\TWO.BI", .source = "Two = 22\n" },
    };
    var reader = GraphSourceReader{ .files = &files };
    var graph = try core.source_loader.loadGraph(std.testing.allocator, &reader, files[0].path);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.ok());
    try std.testing.expectEqual(@as(usize, 3), graph.file_names.len);
    try std.testing.expectEqual(@as(u32, 3), reader.info_calls);
    try std.testing.expectEqual(@as(u32, 3), reader.read_calls);

    var program = try core.compiler.compileGraphOwnedObserved(std.testing.allocator, &graph, null);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expectEqualStrings(files[0].path, program.file_name);
    try std.testing.expectEqual(@as(usize, 2), program.included_file_names.len);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 16));
    try expectSingle(&machine, "Result", 42);
}

test "$INCLUDE token identity reaches nested runtime diagnostics" {
    const files = [_]GraphFile{
        .{ .path = "C:\\RUN\\MAIN.BAS", .source = "'$INCLUDE: 'NESTED\\FAULT.BI'\nEND\n" },
        .{ .path = "C:\\RUN\\NESTED\\FAULT.BI", .source = "Zero = 0\nValue = 1 / Zero\n" },
    };
    var reader = GraphSourceReader{ .files = &files };
    var graph = try core.source_loader.loadGraph(std.testing.allocator, &reader, files[0].path);
    defer graph.deinit(std.testing.allocator);
    var program = try core.compiler.compileGraphOwnedObserved(std.testing.allocator, &graph, null);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(64, 8));
    const diagnostic = machine.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
    try std.testing.expectEqualStrings(files[1].path, diagnostic.file_name);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.span.line);
    try std.testing.expectEqual(@as(u16, 1), diagnostic.span.file_id);
}

test "CHAIN DELETE filters numbered target lines before atomic compilation" {
    const files = [_]GraphFile{.{
        .path = "C:\\RUN\\DELETE.BAS",
        .source =
        \\100 Removed = 1
        \\150 Removed = 2
        \\250 Kept = 3
        \\END
        ,
    }};
    var reader = GraphSourceReader{ .files = &files };
    var graph = try core.source_loader.loadGraph(std.testing.allocator, &reader, files[0].path);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), try core.source_loader.deleteNumberedLines(
        std.testing.allocator,
        &graph,
        100,
        200,
    ));
    try std.testing.expectEqual(@as(usize, 2), graph.line_origins.len);
    var program = try core.compiler.compileGraphOwnedObserved(std.testing.allocator, &graph, null);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 8));
    try std.testing.expect(machine.global("Removed") == null);
    try expectSingle(&machine, "Kept", 3);
}

test "$INCLUDE missing cycle depth and aggregate size failures remain atomic diagnostics" {
    const missing_files = [_]GraphFile{
        .{ .path = "C:\\SRC\\MAIN.BAS", .source = "'$INCLUDE: 'MISSING.BI'\nEND\n" },
    };
    var missing_reader = GraphSourceReader{ .files = &missing_files };
    var missing = try core.source_loader.loadGraph(std.testing.allocator, &missing_reader, missing_files[0].path);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.ok());
    try std.testing.expectEqual(core.frontend.DiagnosticCode.include_missing, missing.diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 1), missing.diagnostics[0].span.line);
    try std.testing.expectEqualStrings(missing_files[0].path, missing.diagnostics[0].file_name);
    var missing_program = try core.compiler.compileGraphOwnedObserved(std.testing.allocator, &missing, null);
    defer missing_program.deinit();
    try std.testing.expect(!missing_program.ok());
    try std.testing.expectEqual(@as(usize, 0), missing_program.instructions.len);

    const cycle_files = [_]GraphFile{
        .{ .path = "C:\\SRC\\MAIN.BAS", .source = "'$INCLUDE: 'A.BI'\nEND\n" },
        .{ .path = "C:\\SRC\\A.BI", .source = "Value = 1\n'$INCLUDE: 'MAIN.BAS'\n" },
    };
    var cycle_reader = GraphSourceReader{ .files = &cycle_files };
    var cycle = try core.source_loader.loadGraph(std.testing.allocator, &cycle_reader, cycle_files[0].path);
    defer cycle.deinit(std.testing.allocator);
    try std.testing.expect(!cycle.ok());
    try std.testing.expectEqual(core.frontend.DiagnosticCode.include_cycle, cycle.diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 2), cycle.diagnostics[0].span.line);
    try std.testing.expectEqualStrings(cycle_files[1].path, cycle.diagnostics[0].file_name);

    var depth_paths: [core.source_loader.maximum_include_depth + 2][32]u8 = undefined;
    var depth_sources: [core.source_loader.maximum_include_depth + 2][48]u8 = undefined;
    var depth_files: [core.source_loader.maximum_include_depth + 2]GraphFile = undefined;
    for (0..depth_files.len) |index| {
        const path = try std.fmt.bufPrint(&depth_paths[index], "C:\\DEPTH\\F{d}.BI", .{index});
        const source = if (index + 1 < depth_files.len)
            try std.fmt.bufPrint(&depth_sources[index], "'$INCLUDE: 'F{d}.BI'\n", .{index + 1})
        else
            try std.fmt.bufPrint(&depth_sources[index], "END\n", .{});
        depth_files[index] = .{ .path = path, .source = source };
    }
    var depth_reader = GraphSourceReader{ .files = &depth_files };
    var depth = try core.source_loader.loadGraph(std.testing.allocator, &depth_reader, depth_files[0].path);
    defer depth.deinit(std.testing.allocator);
    try std.testing.expect(!depth.ok());
    try std.testing.expectEqual(core.frontend.DiagnosticCode.include_depth_exceeded, depth.diagnostics[0].code);

    const large_source = try std.testing.allocator.alloc(u8, core.frontend.maximum_source_bytes);
    defer std.testing.allocator.free(large_source);
    @memset(large_source, ' ');
    const size_files = [_]GraphFile{
        .{ .path = "C:\\SIZE\\MAIN.BAS", .source = "'$INCLUDE: 'LARGE.BI'\nEND\n" },
        .{ .path = "C:\\SIZE\\LARGE.BI", .source = large_source },
    };
    var size_reader = GraphSourceReader{ .files = &size_files };
    var size = try core.source_loader.loadGraph(std.testing.allocator, &size_reader, size_files[0].path);
    defer size.deinit(std.testing.allocator);
    try std.testing.expect(!size.ok());
    try std.testing.expectEqual(core.frontend.DiagnosticCode.include_graph_too_large, size.diagnostics[0].code);
    try std.testing.expect(size.source.len <= core.frontend.maximum_source_bytes);
}

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

test "numbered lines preserve source order and share control-flow labels" {
    const source =
        \\20 Value = 1
        \\10 GOTO 40
        \\30 Value = 999
        \\40 GOSUB 100
        \\50 IF Value = 3 THEN 70 ELSE 60
        \\60 Value = -1
        \\70 GOTO Done
        \\100 Value = Value + 2
        \\110 RETURN 50
        \\Done:
        \\120 Result = Value
        \\130 END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "numbered.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expect(program.instruction_metadata.len != 0);
    try std.testing.expectEqual(@as(u16, 20), program.instruction_metadata[0].basic_line);
    var saw_line_100 = false;
    var saw_line_120 = false;
    for (program.instruction_metadata) |metadata| {
        saw_line_100 = saw_line_100 or metadata.basic_line == 100;
        saw_line_120 = saw_line_120 or metadata.basic_line == 120;
    }
    try std.testing.expect(saw_line_100 and saw_line_120);

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 16));
    try expectSingle(&machine, "Result", 3);

    const invalid_lines = [_][]const u8{
        "65530 END\n",
        "10.0 END\n",
    };
    for (invalid_lines) |invalid| {
        var rejected = try core.compiler.compile(std.testing.allocator, "bad-line.bas", invalid);
        defer rejected.deinit();
        try std.testing.expect(!rejected.ok());
        try std.testing.expect(containsCompileDiagnostic(rejected.diagnostics, .invalid_line_number));
    }
    var boundaries = try core.compiler.compile(std.testing.allocator, "line-boundaries.bas", "  0 GOTO 65529\n  65529 END\n");
    defer boundaries.deinit();
    try expectProgramOk(&boundaries);

    var named_then = try core.compiler.compile(std.testing.allocator, "named-then.bas", "IF 1 THEN Named\nNamed:\nEND\n");
    defer named_then.deinit();
    try std.testing.expect(!named_then.ok());
}

test "numeric RESTORE ON ERROR RESUME and question-mark PRINT accept numbered targets" {
    const source =
        \\10 ON ERROR GOTO 100
        \\20 Value = 1 / 0
        \\30 RESTORE 200
        \\40 READ Result
        \\50 ? "NUMBERED TARGETS"
        \\60 END
        \\100 ErrorLine& = ERL
        \\110 RESUME 30
        \\200 DATA 42
    ;
    var program = try core.compiler.compile(std.testing.allocator, "numbered-errors.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 16));
    try expectSingle(&machine, "Result", 42);
    try expectLong(&machine, "ErrorLine&", 20);
    try std.testing.expect(screenContainsText(&machine, "NUMBERED TARGETS"));
}

test "line continuation preserves physical spans and rejects DATA continuation" {
    const source = "Value = 1 + _\r\n2 + _\n3 + _\r4\n? \"CONTINUED\"\nEND\n";
    var program = try core.compiler.compile(std.testing.allocator, "continuation.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 8));
    try expectSingle(&machine, "Value", 10);
    try std.testing.expect(screenContainsText(&machine, "CONTINUED"));

    var data_program = try core.compiler.compile(std.testing.allocator, "data-continuation.bas", "10 DATA 1, _\n2\nEND\n");
    defer data_program.deinit();
    try std.testing.expect(!data_program.ok());
    try std.testing.expect(containsFrontendDiagnostic(data_program.diagnostics, .invalid_line_continuation));

    var comment_program = try core.compiler.compile(std.testing.allocator, "comment-continuation.bas", "10 REM ignored _\n20 Value = 1\n30 END\n");
    defer comment_program.deinit();
    try expectProgramOk(&comment_program);
}

test "hexadecimal octal exponent and suffix literals use QuickBASIC reference types" {
    const source =
        \\A = &HFFFF
        \\B = &HFFFFFFFF&
        \\C = &O177777
        \\D = &177777
        \\E = 2147483648
        \\F = 123456789012345
        \\G = 1.234567890123456
        \\H = 1E2
        \\I = 1D2
        \\J = 2%
        \\K = 2&
        \\L = 2!
        \\M = 2#
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "literals.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expect(hasIntegerConstant(program.constants, -1));
    try std.testing.expect(hasLongConstant(program.constants, -1));
    try std.testing.expect(hasSingleConstant(program.constants, 2_147_483_648));
    try std.testing.expect(hasDoubleConstant(program.constants, 123_456_789_012_345));
    try std.testing.expect(hasDoubleConstant(program.constants, 1.234567890123456));
    try std.testing.expect(hasSingleConstant(program.constants, 100));
    try std.testing.expect(hasDoubleConstant(program.constants, 100));
    try std.testing.expect(hasIntegerConstant(program.constants, 2));
    try std.testing.expect(hasLongConstant(program.constants, 2));
    try std.testing.expect(hasSingleConstant(program.constants, 2));
    try std.testing.expect(hasDoubleConstant(program.constants, 2));

    var rejected = try core.compiler.compile(std.testing.allocator, "literal-overflow.bas", "Value = &H10000\nEND\n");
    defer rejected.deinit();
    try std.testing.expect(!rejected.ok());
    try std.testing.expect(containsCompileDiagnostic(rejected.diagnostics, .invalid_number));
}

test "R4BASIC v2 conformance catalog is complete stable and machine readable" {
    try std.testing.expectEqual(core.conformance.part1_count, core.conformance.part1_targets.len);
    try std.testing.expectEqual(core.conformance.part2_count, core.conformance.part2_targets.len);
    try std.testing.expectEqual(core.conformance.metacommand_count, core.conformance.metacommand_targets.len);
    try std.testing.expectEqual(core.conformance.runtime_error_count, core.conformance.runtime_error_targets.len);

    var identifiers = std.StringHashMap(void).init(std.testing.allocator);
    defer identifiers.deinit();
    for (core.conformance.part1_targets) |target| try validateCatalogTarget(&identifiers, target);
    for (core.conformance.metacommand_targets) |target| try validateCatalogTarget(&identifiers, target);
    for (core.conformance.part2_targets, 1..) |target, number| {
        try validateCatalogTarget(&identifiers, target);
        var expected_storage: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_storage, "QB45-P2-{d:0>3}", .{number});
        try std.testing.expectEqualStrings(expected, target.id);
    }

    var previous_error: u8 = 0;
    for (core.conformance.runtime_error_targets) |target| {
        try std.testing.expect(target.number > previous_error);
        previous_error = target.number;
        try std.testing.expect(target.name.len != 0);
        try std.testing.expect(!identifiers.contains(target.id));
        try identifiers.put(target.id, {});
        var expected_storage: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_storage, "QB45-ERR-{d:0>3}", .{target.number});
        try std.testing.expectEqualStrings(expected, target.id);
    }
    try std.testing.expectEqual(core.conformance.Status.implemented, core.conformance.runtime_error_targets[1].status);
    try std.testing.expectEqual(core.conformance.Status.implemented, core.conformance.runtime_error_targets[12].status);
    try std.testing.expectEqual(core.conformance.Status.implemented, core.conformance.runtime_error_targets[13].status);

    try std.testing.expectEqual(
        core.conformance.part1_count + core.conformance.part2_count +
            core.conformance.metacommand_count + core.conformance.runtime_error_count,
        identifiers.count(),
    );
    try expectTargetImplemented(core.conformance.part1_targets[0]);
    try expectTargetImplemented(core.conformance.part1_targets[1]);
    try expectTargetImplemented(core.conformance.part1_targets[3]);
    try expectTargetImplemented(core.conformance.part1_targets[5]);
    try expectTargetImplemented(core.conformance.metacommand_targets[0]);
    try expectTargetImplemented(core.conformance.metacommand_targets[1]);
    try expectTargetImplemented(core.conformance.metacommand_targets[2]);
    for ([_]usize{
        0,   1,   2,   6,   11,  15,  17,  18,  26,  27,  28,  29,  30,  34,  36,  38,  39,  40,  46,  48,
        49,  50,  51,  55,  56,  59,  62,  64,  65,  66,  68,  69,  71,  72,  78,  79,  80,  81,  84,  87,
        90,  94,  95,  96,  97,  99,  101, 102, 104, 108, 122, 124, 125, 130, 132, 136, 137, 138, 140, 142,
        145, 149, 151, 152, 154, 157, 158, 159, 160, 162, 163, 166, 167, 168, 170, 171, 176, 177, 178, 179,
        182, 186, 188, 191,
    }) |index| {
        try expectTargetImplemented(core.conformance.part2_targets[index]);
    }
}

test "ERROR has crossed the catalog boundary into executable bytecode" {
    var program = try core.compiler.compile(std.testing.allocator, "error.bas", "ERROR 5\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());
    var found = false;
    for (program.instructions) |instruction| if (instruction.op == .raise_error) {
        found = true;
        break;
    };
    try std.testing.expect(found);
}

test "procedure signatures preserve BASIC ByRef arrays records fixed strings and recursion" {
    const source =
        \\DEFINT A-Z
        \\TYPE Pair
        \\  A AS INTEGER
        \\  B AS INTEGER
        \\END TYPE
        \\DECLARE SUB Touch(ByRef X AS INTEGER, ByVal Y AS INTEGER, A(2) AS ANY, P AS Pair, S AS STRING)
        \\DECLARE SUB Bump(X AS INTEGER)
        \\DECLARE SUB Loose
        \\DECLARE FUNCTION Fact%(ByVal N AS INTEGER)
        \\DIM Matrix(1, 1) AS INTEGER
        \\DIM Rec AS Pair
        \\DIM Fixed AS STRING * 4
        \\X = 2
        \\Fixed = "AB"
        \\CALL Touch(X, 3, Matrix(), Rec, Fixed)
        \\RecordA = Rec.A
        \\Original = 10
        \\CALL Bump((Original))
        \\Bump Original
        \\Loose Original, 4
        \\Result = Fact%(5)
        \\END
        \\SUB Touch(ByRef X AS INTEGER, ByVal Y AS INTEGER, A() AS INTEGER, P AS Pair, S AS STRING)
        \\  X = X + Y
        \\  A(1, 1) = X
        \\  P.A = X + 1
        \\  S = S + "Z"
        \\END SUB
        \\SUB Bump(X AS INTEGER)
        \\  X = X + 1
        \\END SUB
        \\SUB Loose(X AS INTEGER, Y AS INTEGER)
        \\  X = X + Y
        \\END SUB
        \\FUNCTION Fact%(ByVal N AS INTEGER)
        \\  IF N <= 1 THEN Fact% = 1: EXIT FUNCTION
        \\  Fact% = N * Fact%(N - 1)
        \\END FUNCTION
    ;
    var program = try core.compiler.compile(std.testing.allocator, "procedures-0707.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
    try expectInteger(&machine, "X", 5);
    try std.testing.expectEqual(@as(i16, 5), machine.globalArrayElement("Matrix", &.{ 1, 1 }).?.integer);
    try expectInteger(&machine, "RecordA", 6);
    try expectString(&machine, "Fixed", "AB  ");
    try expectInteger(&machine, "Original", 15);
    try expectInteger(&machine, "Result", 120);
    try std.testing.expectEqual(@as(usize, 0), machine.valueStackDepth());
    try std.testing.expectEqual(@as(usize, 0), machine.callDepth());

    const wrong_dimensions =
        \\DEFINT A-Z
        \\DECLARE SUB NeedsTwo(A(2) AS INTEGER)
        \\DIM One(3) AS INTEGER
        \\CALL NeedsTwo(One())
        \\END
        \\SUB NeedsTwo(A() AS INTEGER)
        \\END SUB
    ;
    var invalid = try core.compiler.compile(std.testing.allocator, "wrong-dimensions.bas", wrong_dimensions);
    defer invalid.deinit();
    try std.testing.expect(!invalid.ok());
    try std.testing.expect(containsCompileDiagnostic(invalid.diagnostics, .wrong_dimension_count));

    const explicit_empty_signature =
        \\DECLARE SUB Empty()
        \\END
        \\SUB Empty(X AS INTEGER)
        \\END SUB
    ;
    var mismatched = try core.compiler.compile(std.testing.allocator, "explicit-empty-signature.bas", explicit_empty_signature);
    defer mismatched.deinit();
    try std.testing.expect(!mismatched.ok());
    try std.testing.expect(containsCompileDiagnostic(mismatched.diagnostics, .wrong_argument_count));
}

test "multiline DEF FN shares module scope supports STATIC EXIT DEF and zero argument calls" {
    const source =
        \\DEFINT A-Z
        \\BaseValue = 4
        \\DEF FNBlock(X) STATIC
        \\  STATIC Counter
        \\  Counter = Counter + 1
        \\  IF X < 0 THEN EXIT DEF
        \\  FNBlock = BaseValue + X + Counter
        \\END DEF
        \\DEF FNOne(X) = X * 2
        \\DEF FNZero = 7
        \\First = FNBlock(2)
        \\Second = FNBlock(3)
        \\Exited = FNBlock(-1)
        \\OneLine = FNOne(4)
        \\Zero = FNZero
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "def-fn-0707.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 32));
    try expectInteger(&machine, "First", 7);
    try expectInteger(&machine, "Second", 9);
    try expectInteger(&machine, "Exited", 0);
    try expectInteger(&machine, "OneLine", 8);
    try expectInteger(&machine, "Zero", 7);

    const recursive =
        \\DEFINT A-Z
        \\DEF FNLoop(X)
        \\  FNLoop = FNLoop(X)
        \\END DEF
        \\END
    ;
    var invalid = try core.compiler.compile(std.testing.allocator, "recursive-def-fn.bas", recursive);
    defer invalid.deinit();
    try std.testing.expect(!invalid.ok());
    try std.testing.expect(containsCompileDiagnostic(invalid.diagnostics, .symbol_kind_conflict));
}

test "control flow covers multi NEXT CASE IS inline arms and ON GOTO GOSUB" {
    const source =
        \\DEFINT A-Z
        \\FOR I = 1 TO 2
        \\  FOR J = 1 TO 3
        \\    Total = Total + 1
        \\NEXT J, I
        \\X = 5
        \\SELECT CASE X
        \\CASE IS < 3
        \\  Selected = 1
        \\CASE IS >= 5
        \\  Selected = 2
        \\CASE ELSE
        \\  Selected = 3
        \\END SELECT
        \\IF 0 THEN Inline = 1: Inline = 2 ELSE Inline = 3: Inline = Inline + 1
        \\Choice = 2
        \\ON Choice GOSUB AddOne, AddTwo, AddThree
        \\AfterGosub = 1
        \\ON 3 GOTO BadOne, BadTwo, Good
        \\BadOne:
        \\Branch = -1
        \\GOTO Finished
        \\BadTwo:
        \\Branch = -2
        \\GOTO Finished
        \\Good:
        \\Branch = 3
        \\GOTO Finished
        \\AddOne:
        \\Added = 1
        \\RETURN
        \\AddTwo:
        \\Added = 2
        \\RETURN
        \\AddThree:
        \\Added = 3
        \\RETURN
        \\Finished:
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "flow-0707.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
    try expectInteger(&machine, "Total", 6);
    try expectInteger(&machine, "Selected", 2);
    try expectInteger(&machine, "Inline", 4);
    try expectInteger(&machine, "Added", 2);
    try expectInteger(&machine, "AfterGosub", 1);
    try expectInteger(&machine, "Branch", 3);
    try std.testing.expectEqual(@as(usize, 0), machine.gosubDepth());
}

test "runtime errors preserve ERR ERL nested propagation RESUME and atomic stacks" {
    const source =
        \\10 DEFINT A-Z
        \\20 DECLARE SUB Child()
        \\30 ChildErr = 0
        \\40 ON ERROR GOTO 80
        \\50 CALL Child
        \\60 AfterChild = 1
        \\70 GOTO 120
        \\80 OuterErr = ERR
        \\90 OuterLine = ERL
        \\100 RESUME NEXT
        \\120 END
        \\140 SUB Child
        \\150 SHARED ChildErr
        \\160 ON ERROR GOTO 190
        \\170 ERROR 42
        \\180 EXIT SUB
        \\190 ChildErr = ERR
        \\200 ERROR 43
        \\220 END SUB
    ;
    var program = try core.compiler.compile(std.testing.allocator, "errors-0707.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
    try expectInteger(&machine, "ChildErr", 42);
    try expectInteger(&machine, "OuterErr", 43);
    try expectInteger(&machine, "OuterLine", 200);
    try expectInteger(&machine, "AfterChild", 1);
    try std.testing.expectEqual(@as(usize, 0), machine.valueStackDepth());
    try std.testing.expectEqual(@as(usize, 0), machine.callDepth());

    const return_without_gosub =
        \\DEFINT A-Z
        \\ON ERROR GOTO Handler
        \\RETURN
        \\After = 1
        \\END
        \\Handler:
        \\Number = ERR
        \\RESUME NEXT
    ;
    var return_program = try core.compiler.compile(std.testing.allocator, "return-error.bas", return_without_gosub);
    defer return_program.deinit();
    try expectProgramOk(&return_program);
    var return_machine = try core.vm.Vm.init(std.testing.allocator, &return_program, .{});
    defer return_machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, return_machine.runToCompletion(128, 16));
    try expectInteger(&return_machine, "Number", 3);
    try expectInteger(&return_machine, "After", 1);

    const no_resume =
        \\DECLARE SUB Bad()
        \\CALL Bad
        \\END
        \\SUB Bad
        \\  ON ERROR GOTO Handler
        \\  ERROR 5
        \\Handler:
        \\  Seen = ERR
        \\END SUB
    ;
    var no_resume_program = try core.compiler.compile(std.testing.allocator, "no-resume.bas", no_resume);
    defer no_resume_program.deinit();
    try expectProgramOk(&no_resume_program);
    var no_resume_machine = try core.vm.Vm.init(std.testing.allocator, &no_resume_program, .{});
    defer no_resume_machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, no_resume_machine.runToCompletion(128, 16));
    try std.testing.expectEqual(@as(i32, 19), no_resume_machine.runtime_diagnostic.?.qbasicErrorNumber());
}

test "STOP and bounded trace remain cooperative resumable resettable and cancellable" {
    const source =
        \\5 DEFINT A-Z
        \\10 TRON
        \\20 A = 1
        \\30 A = A + 1
        \\40 TROFF
        \\50 B = 3
        \\60 STOP
        \\70 C = 4
        \\80 END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "stop-trace-0707.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runSlice(256).status);
    try std.testing.expect(machine.isStopped());
    try expectInteger(&machine, "A", 2);
    try expectInteger(&machine, "B", 3);
    try expectInteger(&machine, "C", 0);
    try std.testing.expectEqual(@as(usize, 3), machine.traceCount());
    try std.testing.expectEqual(@as(u16, 20), machine.traceEntry(0).?.basic_line);
    try std.testing.expectEqual(@as(u16, 40), machine.traceEntry(2).?.basic_line);
    try std.testing.expect(screenContainsText(&machine, "[20][30][40]"));
    try std.testing.expect(machine.continueStopped());
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 8));
    try expectInteger(&machine, "C", 4);

    try machine.reset();
    try std.testing.expectEqual(@as(usize, 0), machine.traceCount());
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runSlice(256).status);
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    const continued = adapter.handleInput(.{ .text = .{ .codepoint = 'X', .modifiers = 0, .tick = 1, .sequence = 1 } });
    try std.testing.expectEqual(core.runtime_adapter.InputDeliveryStatus.control, continued.status);
    try std.testing.expect(!machine.isStopped());
    try std.testing.expectEqual(@as(usize, 0), machine.queuedInputBytes());
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 8));

    try machine.reset();
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runSlice(256).status);
    machine.requestCancel();
    try std.testing.expectEqual(core.vm.Status.cancelled, machine.runSlice(0).status);

    const bounded =
        \\DEFINT A-Z
        \\TRON
        \\FOR I = 1 TO 400
        \\  Count = Count + 1
        \\NEXT I
        \\TROFF
        \\END
    ;
    var bounded_program = try core.compiler.compile(std.testing.allocator, "bounded-trace.bas", bounded);
    defer bounded_program.deinit();
    try expectProgramOk(&bounded_program);
    var bounded_machine = try core.vm.Vm.init(std.testing.allocator, &bounded_program, .{});
    defer bounded_machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, bounded_machine.runToCompletion(1024, 16));
    try expectInteger(&bounded_machine, "Count", 400);
    try std.testing.expectEqual(core.vm.maximum_trace_entries, bounded_machine.traceCount());
    try std.testing.expect(bounded_machine.traceDropped() != 0);
}

test "compiler indices scale across symbols records procedures and label fixups" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "DEFINT A-Z\n");

    for (0..128) |record_index| {
        try appendSource(&source, "TYPE T{d}\n", .{record_index});
        for (0..8) |field_index| try appendSource(&source, "F{d} AS INTEGER\n", .{field_index});
        try source.appendSlice(allocator, "END TYPE\n");
        try appendSource(&source, "DIM R{d} AS T{d}\n", .{ record_index, record_index });
        try appendSource(&source, "R{d}.F0 = {d}\n", .{ record_index, record_index });
    }
    for (0..512) |variable_index| {
        try appendSource(&source, "DIM A{d}(1) AS INTEGER\n", .{variable_index});
        try appendSource(&source, "A{d}(0) = {d}\n", .{ variable_index, variable_index });
        try appendSource(&source, "A{d}(1) = A{d}(0) + 1\n", .{ variable_index, variable_index });
    }
    for (0..256) |procedure_index| {
        try appendSource(&source, "SUB P{d}()\nL{d} = {d}\nEND SUB\n", .{ procedure_index, procedure_index, procedure_index });
    }
    for (0..256) |procedure_index| try appendSource(&source, "P{d}\n", .{procedure_index});
    try source.appendSlice(allocator, "GOTO B0\n");
    for (0..1024) |label_index| {
        try appendSource(&source, "B{d}:\n", .{label_index});
        if (label_index + 1 < 1024) try appendSource(&source, "GOTO B{d}\n", .{label_index + 1});
    }
    try source.appendSlice(allocator, "END\n");
    try std.testing.expect(source.items.len < core.frontend.maximum_source_bytes);

    const Probe = struct {
        seen: [3]bool = .{ false, false, false },
        calls: u32 = 0,

        fn update(context: *anyopaque, progress: core.compiler.CompileProgress) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.seen[@intFromEnum(progress.phase)] = true;
            return true;
        }
    };
    var probe: Probe = .{};
    var program = try core.compiler.compileObserved(allocator, "index-stress.bas", source.items, .{
        .context = &probe,
        .update_fn = Probe.update,
    });
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expect(probe.seen[0] and probe.seen[1] and probe.seen[2]);
    try std.testing.expect(probe.calls != 0);
    try std.testing.expectEqual(@as(u32, 1024), program.compile_stats.label_fixups);
    try std.testing.expect(program.compile_stats.reused_statement_bindings >= 1152);
    try std.testing.expect(program.compile_stats.keyword_max_probe <= core.frontend.keyword_lookup_probe_bound);
    try std.testing.expect(program.compile_stats.name_max_probe <= 64);
    try std.testing.expect(
        program.compile_stats.name_probes <=
            (program.compile_stats.name_lookups + program.compile_stats.name_insertions) * 64,
    );

    var repeated = try core.compiler.compile(allocator, "index-stress.bas", source.items);
    defer repeated.deinit();
    try expectProgramOk(&repeated);
    try std.testing.expectEqualSlices(core.bytecode.Instruction, program.instructions, repeated.instructions);
    try std.testing.expectEqualSlices(
        core.bytecode.InstructionMetadata,
        program.instruction_metadata,
        repeated.instruction_metadata,
    );
    try std.testing.expectEqual(program.compile_stats.name_lookups, repeated.compile_stats.name_lookups);
    try std.testing.expectEqual(program.compile_stats.name_probes, repeated.compile_stats.name_probes);

    const CancelProbe = struct {
        phase: core.compiler.CompilePhase,
        cancelled: bool = false,

        fn update(context: *anyopaque, progress: core.compiler.CompileProgress) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (progress.phase == self.phase and progress.completed >= 256) {
                self.cancelled = true;
                return false;
            }
            return true;
        }
    };
    for ([_]core.compiler.CompilePhase{ .binding, .resolution }) |phase| {
        var cancel_probe = CancelProbe{ .phase = phase };
        try std.testing.expectError(error.Cancelled, core.compiler.compileObserved(allocator, "index-stress.bas", source.items, .{
            .context = &cancel_probe,
            .update_fn = CancelProbe.update,
        }));
        try std.testing.expect(cancel_probe.cancelled);
    }
}

test "maximum source compilation remains cooperatively cancellable" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, core.frontend.maximum_source_bytes);
    defer allocator.free(source);
    @memset(source, ' ');
    @memcpy(source[0..4], "END\n");

    const Probe = struct {
        calls: u32 = 0,
        last_completed: usize = 0,

        fn update(context: *anyopaque, progress: core.compiler.CompileProgress) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.last_completed = progress.completed;
            return progress.phase != .lexical or progress.completed < 4096;
        }
    };
    var probe: Probe = .{};
    try std.testing.expectError(error.Cancelled, core.compiler.compileObserved(allocator, "maximum.bas", source, .{
        .context = &probe,
        .update_fn = Probe.update,
    }));
    try std.testing.expect(probe.calls >= 3);
    try std.testing.expect(probe.last_completed >= 4096);

    const owned_source = try allocator.dupe(u8, source);
    var owned_probe: Probe = .{};
    try std.testing.expectError(error.Cancelled, core.compiler.compileOwnedObserved(allocator, "maximum-owned.bas", owned_source, .{
        .context = &owned_probe,
        .update_fn = Probe.update,
    }));
    try std.testing.expect(owned_probe.last_completed >= 4096);

    var completed = try core.compiler.compile(allocator, "maximum.bas", source);
    defer completed.deinit();
    try expectProgramOk(&completed);
    try std.testing.expectEqual(@as(u32, core.frontend.maximum_source_bytes), completed.compile_stats.source_bytes);
}

test "compiler storage follows token demand and bounds the dense 256 KiB case" {
    const allocator = std.testing.allocator;

    const sparse = try allocator.alloc(u8, core.frontend.maximum_source_bytes);
    @memset(sparse, 'A');
    @memcpy(sparse[0..4], "REM ");
    const sparse_pointer = sparse.ptr;
    var sparse_program = try core.compiler.compileOwned(allocator, "sparse-maximum.bas", sparse);
    defer sparse_program.deinit();
    try expectProgramOk(&sparse_program);
    try std.testing.expect(sparse_program.source.ptr == sparse_pointer);
    try std.testing.expectEqual(@as(u32, 1), sparse_program.compile_stats.token_capacity);
    try std.testing.expectEqual(@as(u64, @sizeOf(core.frontend.Token)), sparse_program.compile_stats.token_bytes);
    try std.testing.expectEqual(
        @as(u32, core.frontend.maximum_source_bytes),
        sparse_program.compile_stats.adopted_source_bytes,
    );
    try std.testing.expect(sparse_program.compile_stats.compiler_peak_bytes <= 512 * 1024);

    const dense = try allocator.alloc(u8, core.frontend.maximum_source_bytes);
    for (0..dense.len / 4) |index| @memcpy(dense[index * 4 ..][0..4], "A=1:");
    const dense_pointer = dense.ptr;
    var dense_program = try core.compiler.compileOwned(allocator, "dense-maximum.bas", dense);
    defer dense_program.deinit();
    try expectProgramOk(&dense_program);
    try std.testing.expect(dense_program.source.ptr == dense_pointer);
    try std.testing.expectEqual(
        @as(u32, core.frontend.maximum_source_bytes + 1),
        dense_program.compile_stats.token_capacity,
    );
    try std.testing.expectEqual(@as(usize, 196_609), dense_program.instructions.len);
    try std.testing.expectEqual(dense_program.instructions.len, dense_program.instruction_metadata.len);
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(core.bytecode.Instruction));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(core.bytecode.InstructionMetadata));
    try std.testing.expectEqual(
        @as(u64, @intCast(dense_program.instructions.len * @sizeOf(core.bytecode.Instruction))),
        dense_program.compile_stats.instruction_hot_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, @intCast(dense_program.instruction_metadata.len * @sizeOf(core.bytecode.InstructionMetadata))),
        dense_program.compile_stats.instruction_metadata_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), dense_program.constants.len);
    try std.testing.expectEqual(@as(u32, 65_536), dense_program.compile_stats.constant_lookups);
    try std.testing.expectEqual(@as(u32, 65_535), dense_program.compile_stats.constant_reuses);
    try std.testing.expect(dense_program.compile_stats.allocator_allocations <= 128);
    try std.testing.expect(dense_program.compile_stats.allocator_copy_bytes <= 8 * 1024 * 1024);
    try std.testing.expect(dense_program.compile_stats.compiler_peak_bytes <= 20 * 1024 * 1024);
    try std.testing.expect(dense_program.compile_stats.program_bytes <= 9 * 1024 * 1024);
}

test "constant interning is bit exact and floating parsing leaves source unchanged" {
    const source =
        "A%=1\n" ++
        "B%=1\n" ++
        "C!=1.5\n" ++
        "D!=1.5\n" ++
        "E#=1D2\n" ++
        "F#=1d2\n" ++
        "S$=\"same\"\n" ++
        "T$=\"same\"\n" ++
        "END\n";
    var program = try core.compiler.compile(std.testing.allocator, "intern.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expectEqualStrings(source, program.source);
    try std.testing.expectEqual(@as(usize, 4), program.constants.len);
    try std.testing.expectEqual(@as(u32, 8), program.compile_stats.constant_lookups);
    try std.testing.expectEqual(@as(u32, 4), program.compile_stats.constant_reuses);
    try std.testing.expect(program.compile_stats.constant_max_probe <= 16);

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 16));
    try expectInteger(&machine, "A%", 1);
    try expectInteger(&machine, "B%", 1);
    try expectSingle(&machine, "C!", 1.5);
    try expectSingle(&machine, "D!", 1.5);
    try expectDouble(&machine, "E#", 100.0);
    try expectDouble(&machine, "F#", 100.0);
    try expectString(&machine, "S$", "same");
    try expectString(&machine, "T$", "same");
}

test "compiler diagnostics retain twenty details and count the truncated remainder" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    for (0..1_000) |_| try source.appendSlice(allocator, "A=\n");

    var program = try core.compiler.compile(allocator, "diagnostics.bas", source.items);
    defer program.deinit();
    try std.testing.expect(!program.ok());
    try std.testing.expectEqual(core.compiler.maximum_stored_diagnostics, program.diagnostics.len);
    try std.testing.expect(program.diagnostics_total > program.diagnostics.len);
    try std.testing.expect(program.diagnostics_truncated);
    try std.testing.expectEqual(program.diagnostics_total, program.compile_stats.diagnostics_total);
    try std.testing.expectEqual(
        @as(u16, @intCast(program.diagnostics.len)),
        program.compile_stats.diagnostics_stored,
    );
    try std.testing.expect(program.compile_stats.diagnostics_truncated);
    for (program.diagnostics) |diagnostic| try std.testing.expectEqual(core.bytecode.DiagnosticCode.expected_expression, diagnostic.code);
}

test "compiler expression depth is deterministic for parentheses unary and power" {
    const allocator = std.testing.allocator;
    const Shape = enum { parentheses, unary, power };
    for ([_]Shape{ .parentheses, .unary, .power }) |shape| {
        for ([_]bool{ true, false }) |accepted| {
            const nested = core.frontend.maximum_expression_depth - 1 + @intFromBool(!accepted);
            var source: std.ArrayList(u8) = .empty;
            defer source.deinit(allocator);
            try source.appendSlice(allocator, "A%=");
            switch (shape) {
                .parentheses => {
                    try source.appendNTimes(allocator, '(', nested);
                    try source.append(allocator, '1');
                    try source.appendNTimes(allocator, ')', nested);
                },
                .unary => {
                    try source.appendNTimes(allocator, '+', nested);
                    try source.append(allocator, '1');
                },
                .power => {
                    try source.append(allocator, '1');
                    for (0..nested) |_| try source.appendSlice(allocator, "^1");
                },
            }
            try source.append(allocator, '\n');

            var program = try core.compiler.compile(allocator, "depth.bas", source.items);
            defer program.deinit();
            if (accepted) {
                try expectProgramOk(&program);
                try std.testing.expectEqual(
                    @as(u16, @intCast(core.frontend.maximum_expression_depth)),
                    program.compile_stats.maximum_expression_depth,
                );
            } else {
                try std.testing.expect(!program.ok());
                try std.testing.expect(containsCompileDiagnostic(program.diagnostics, .expression_too_deep));
            }
        }
    }
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
    try expectInteger(&machine, "RoundedHigh%", 2);
    try expectInteger(&machine, "RoundedLow%", -2);
    try expectInteger(&machine, "TruthValue%", -1);
    try expectInteger(&machine, "FalseValue%", 0);
    try expectInteger(&machine, "StringOrder%", -1);
    try expectDouble(&machine, "MixedValue#", 14.5);
    try expectInteger(&machine, "IntegerQuotient%", 2);
    try expectInteger(&machine, "Remainder%", 2);
    try expectString(&machine, "TextValue$", "R4OS");
}

test "QuickBASIC numeric promotion rounding and logical precedence use signed LONG semantics" {
    const source =
        \\EvenLow% = CINT(2.5)
        \\EvenHigh% = CINT(3.5)
        \\EvenNegativeLow% = CINT(-2.5)
        \\EvenNegativeHigh% = CINT(-3.5)
        \\LongEven& = CLNG(2147483646.5#)
        \\SingleValue! = CSNG(1.25#)
        \\DoubleValue# = CDBL(1.25!)
        \\Fixed! = FIX(-2.9!)
        \\Floored! = INT(-2.1!)
        \\NegativeSign% = SGN(-.01#)
        \\ZeroSign% = SGN(0)
        \\PositiveSign% = SGN(.01#)
        \\EqvValue& = 5 EQV 3
        \\ImpValue& = 5 IMP 3
        \\Precedence& = 1 OR 2 EQV 3
        \\NotEven& = NOT 2.5
        \\NotOdd& = NOT 3.5
        \\RoundedDivide% = 5.5 \ 2
        \\RoundedModulo% = 6.5 MOD 4
        \\RightPower! = 2 ^ 3 ^ 2
        \\UnaryPower! = -2 ^ 2
        \\NegativeExponent! = 2 ^ -2
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "numeric-model.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 16));

    try expectInteger(&machine, "EvenLow%", 2);
    try expectInteger(&machine, "EvenHigh%", 4);
    try expectInteger(&machine, "EvenNegativeLow%", -2);
    try expectInteger(&machine, "EvenNegativeHigh%", -4);
    try expectLong(&machine, "LongEven&", 2_147_483_646);
    try expectSingle(&machine, "SingleValue!", 1.25);
    try expectDouble(&machine, "DoubleValue#", 1.25);
    try expectSingle(&machine, "Fixed!", -2);
    try expectSingle(&machine, "Floored!", -3);
    try expectInteger(&machine, "NegativeSign%", -1);
    try expectInteger(&machine, "ZeroSign%", 0);
    try expectInteger(&machine, "PositiveSign%", 1);
    try expectLong(&machine, "EqvValue&", -7);
    try expectLong(&machine, "ImpValue&", -5);
    try expectLong(&machine, "Precedence&", -1);
    try expectLong(&machine, "NotEven&", -3);
    try expectLong(&machine, "NotOdd&", -5);
    try expectInteger(&machine, "RoundedDivide%", 3);
    try expectInteger(&machine, "RoundedModulo%", 2);
    try expectSingle(&machine, "RightPower!", 512);
    try expectSingle(&machine, "UnaryPower!", -4);
    try expectSingle(&machine, "NegativeExponent!", 0.25);
}

test "IEEE and Microsoft Binary Format functions are exact little-endian inverses" {
    const source =
        \\IntegerBytes$ = MKI$(-2)
        \\LongBytes$ = MKL$(&H01020304&)
        \\SingleBytes$ = MKS$(1!)
        \\DoubleBytes$ = MKD$(1#)
        \\MbfSingleBytes$ = MKSMBF$(1!)
        \\MbfNegativeBytes$ = MKSMBF$(-1!)
        \\MbfPiBytes$ = MKSMBF$(3.1415927!)
        \\MbfDoubleBytes$ = MKDMBF$(1#)
        \\MbfDoublePiBytes$ = MKDMBF$(3.141592653589793#)
        \\IntegerValue% = CVI(IntegerBytes$)
        \\LongValue& = CVL(LongBytes$)
        \\SingleValue! = CVS(SingleBytes$)
        \\DoubleValue# = CVD(DoubleBytes$)
        \\MbfSingleValue! = CVSMBF(MbfPiBytes$)
        \\MbfDoubleValue# = CVDMBF(MKDMBF$(3.141592653589793#))
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "numeric-bytes.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 16));

    try expectString(&machine, "IntegerBytes$", &.{ 0xFE, 0xFF });
    try expectString(&machine, "LongBytes$", &.{ 0x04, 0x03, 0x02, 0x01 });
    try expectString(&machine, "SingleBytes$", &.{ 0x00, 0x00, 0x80, 0x3F });
    try expectString(&machine, "DoubleBytes$", &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F });
    try expectString(&machine, "MbfSingleBytes$", &.{ 0x00, 0x00, 0x00, 0x81 });
    try expectString(&machine, "MbfNegativeBytes$", &.{ 0x00, 0x00, 0x80, 0x81 });
    try expectString(&machine, "MbfPiBytes$", &.{ 0xDB, 0x0F, 0x49, 0x82 });
    try expectString(&machine, "MbfDoubleBytes$", &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81 });
    try expectString(&machine, "MbfDoublePiBytes$", &.{ 0xC0, 0x68, 0x21, 0xA2, 0xDA, 0x0F, 0x49, 0x82 });
    try expectInteger(&machine, "IntegerValue%", -2);
    try expectLong(&machine, "LongValue&", 0x01020304);
    try expectSingle(&machine, "SingleValue!", 1);
    try expectDouble(&machine, "DoubleValue#", 1);
    try expectSingle(&machine, "MbfSingleValue!", 3.1415927);
    try expectDouble(&machine, "MbfDoubleValue#", 3.141592653589793);
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
        .exp => @exp(first),
        .log => @log(first),
        .sin => @sin(first),
        .sqr => @sqrt(first),
        .tan => @tan(first),
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
    try expectInteger(&machine, "RoundedValue", 2);
    try expectInteger(&machine, "FloorValue", -3);
    try expectString(&machine, "TextValue$", "AR4BASICCORE  7");
    try expectInteger(&machine, "TextLength", 15);
    try expectInteger(&machine, "FoundAt", 4);
    try expectDouble(&machine, "Angle#", std.math.atan(@as(f64, 1.0)) + 1.0);
    try expectDouble(&machine, "Parsed#", 12.5);
}

test "complete numeric math builtins preserve input precision and QuickBASIC domains" {
    const source =
        \\ExpSingle! = EXP(1!)
        \\ExpDouble# = EXP(1#)
        \\LogSingle! = LOG(EXP(1!))
        \\LogDouble# = LOG(EXP(1#))
        \\RootSingle! = SQR(9!)
        \\RootDouble# = SQR(2#)
        \\TangentSingle! = TAN(.25!)
        \\TangentDouble# = TAN(.25#)
        \\AbsoluteLong& = ABS(-2147483647&)
        \\Arc# = ATN(1#)
        \\Cosine# = COS(1#)
        \\Sine# = SIN(1#)
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "math-model.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var probe: MathProbe = .{};
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{ .context = &probe, .math = probingMath });
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 16));
    try std.testing.expectEqual(@as(u32, 13), probe.calls);
    try expectSingle(&machine, "ExpSingle!", @exp(@as(f32, 1)));
    try expectDouble(&machine, "ExpDouble#", @exp(@as(f64, 1)));
    try expectSingle(&machine, "LogSingle!", 1);
    try expectDouble(&machine, "LogDouble#", 1);
    try expectSingle(&machine, "RootSingle!", 3);
    try expectDouble(&machine, "RootDouble#", @sqrt(@as(f64, 2)));
    try expectSingle(&machine, "TangentSingle!", @tan(@as(f32, 0.25)));
    try expectDouble(&machine, "TangentDouble#", @tan(@as(f64, 0.25)));
    try expectLong(&machine, "AbsoluteLong&", 2_147_483_647);
    try expectDouble(&machine, "Arc#", std.math.atan(@as(f64, 1)));
    try expectDouble(&machine, "Cosine#", @cos(@as(f64, 1)));
    try expectDouble(&machine, "Sine#", @sin(@as(f64, 1)));
}

test "numeric builtin boundaries report QuickBASIC errors 5 and 6" {
    const Case = struct {
        source: []const u8,
        code: core.vm.RuntimeCode,
        number: i32,
    };
    const cases = [_]Case{
        .{ .source = "Value# = 7#\nValue# = LOG(0)\nEND\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "Value# = 7#\nValue# = SQR(-1)\nEND\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "Value# = 7#\nValue# = EXP(100!)\nEND\n", .code = .overflow, .number = 6 },
        .{ .source = "Value# = 7#\nValue# = CINT(32767.5#)\nEND\n", .code = .overflow, .number = 6 },
        .{ .source = "Value# = 7#\nValue# = CLNG(2147483647.5#)\nEND\n", .code = .overflow, .number = 6 },
        .{ .source = "Value# = 7#\nValue# = CVI(\"A\")\nEND\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "Value# = 7#\nValue# = CVS(CHR$(0) + CHR$(0) + CHR$(128) + CHR$(127))\nEND\n", .code = .overflow, .number = 6 },
        .{ .source = "Value# = 7#\nValue# = 1 / 0\nEND\n", .code = .division_by_zero, .number = 11 },
        .{ .source = "Value# = 7#\nValue# = 1 MOD 0\nEND\n", .code = .division_by_zero, .number = 11 },
        .{ .source = "Value# = 7#\nValue# = (-1#) ^ .5#\nEND\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "Value# = 7#\nValue# = 32767 + 1\nEND\n", .code = .overflow, .number = 6 },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "numeric-boundary.bas", case.source);
        defer program.deinit();
        try expectProgramOk(&program);
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(256, 16));
        try std.testing.expectEqual(case.code, machine.runtime_diagnostic.?.code);
        try std.testing.expectEqual(case.number, machine.exit_code);
        try expectDouble(&machine, "Value#", 7);
    }
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

test "injected math faults become deterministic QuickBASIC overflow diagnostics" {
    var program = try core.compiler.compile(std.testing.allocator, "host-error.bas", "DEFINT A-Z\nValue# = COS(0#)\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{ .math = failingMath });
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(32, 8));
    const diagnostic = machine.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
    try std.testing.expectEqual(core.vm.RuntimeCode.overflow, diagnostic.code);
    try std.testing.expectEqual(@as(i32, 6), machine.exit_code);
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
        .{ .source = "DIM Value% AS LONG\nEND\n", .expected = .type_mismatch },
        .{ .source = "DIM Value AS INTEGER\nDIM Value\nEND\n", .expected = .type_mismatch },
        .{ .source = "DEFINT AB\nEND\n", .expected = .unexpected_token },
        .{ .source = "DIM Values(2)\nOPTION BASE 1\nEND\n", .expected = .duplicate_symbol },
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

test "declaration defaults option base arrays records and byte layouts follow QuickBASIC storage rules" {
    const source =
        \\DEFLNG A-C
        \\DEFSNG D-F
        \\DEFDBL G-I
        \\DEFSTR J-L
        \\DEFINT M-Z
        \\Alpha = 11
        \\Delta = 2.5
        \\Golf = 3.25
        \\Juliet = "text"
        \\OPTION BASE 1
        \\Implicit(1) = 7
        \\Implicit(10) = 9
        \\DIM Fixed(2)
        \\Fixed(1) = 41
        \\'$DYNAMIC
        \\DIM Dynamic(1 TO 2) AS LONG
        \\Dynamic(1) = 100
        \\Dynamic(2) = 200
        \\REDIM PRESERVE Dynamic(1 TO 4) AS LONG
        \\DIM Names(1 TO 2) AS STRING * 3
        \\Names(1) = "AB"
        \\REDIM PRESERVE Names(1 TO 3) AS STRING * 3
        \\TYPE Pair
        \\    Code AS INTEGER
        \\    Tag AS STRING * 2
        \\END TYPE
        \\TYPE Envelope
        \\    Number AS LONG
        \\    Payload AS Pair
        \\END TYPE
        \\TYPE RawEight
        \\    Bytes AS STRING * 8
        \\END TYPE
        \\DIM Items(1 TO 1) AS Pair
        \\Items(1).Code = 77
        \\Items(1).Tag = "Q"
        \\REDIM PRESERVE Items(1 TO 2) AS Pair
        \\DIM FirstEnvelope AS Envelope
        \\DIM SecondEnvelope AS Envelope
        \\DIM SecondCopy AS Envelope
        \\DIM Raw AS RawEight
        \\READ FirstEnvelope.Number, FirstEnvelope.Payload.Code, FirstEnvelope.Payload.Tag
        \\SecondEnvelope.Number = 99
        \\LSET Raw = FirstEnvelope
        \\RawBytes$ = Raw.Bytes
        \\RecordLength = LEN(FirstEnvelope)
        \\SWAP FirstEnvelope, SecondEnvelope
        \\Swapped& = FirstEnvelope.Number
        \\SecondCopy = SecondEnvelope
        \\Copied& = SecondCopy.Number
        \\DIM LeftText AS STRING * 4
        \\DIM RightText AS STRING * 4
        \\LSET LeftText = "X"
        \\RSET RightText = "Y"
        \\Lower% = LBOUND(Dynamic)
        \\Upper% = UBOUND(Dynamic, 1)
        \\ERASE Fixed
        \\FixedAfter = Fixed(1)
        \\ERASE Dynamic
        \\END
        \\DATA 16909060&, &H0506, AZ
    ;
    var program = try core.compiler.compile(std.testing.allocator, "declarations-arrays-records.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expectEqual(@as(usize, 3), program.record_types.len);
    try std.testing.expectEqual(@as(u32, 4), program.record_types[0].byte_size);
    try std.testing.expectEqual(@as(u32, 8), program.record_types[1].byte_size);
    try std.testing.expectEqual(@as(u32, 4), program.record_types[1].fields[1].offset);
    try std.testing.expectEqual(@as(u32, 0), program.record_types[1].fields[1].record_type);

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(1024, 64));
    try expectLong(&machine, "Alpha", 11);
    try expectSingle(&machine, "Delta", 2.5);
    try expectDouble(&machine, "Golf", 3.25);
    try expectString(&machine, "Juliet", "text");
    try std.testing.expect(machine.globalArrayElement("Dynamic", &.{1}) == null);
    try std.testing.expectEqual(@as(f64, 7), machine.globalArrayElement("Implicit", &.{1}).?.double);
    try std.testing.expectEqual(@as(f64, 9), machine.globalArrayElement("Implicit", &.{10}).?.double);
    try std.testing.expectEqualStrings("AB ", machine.globalArrayElement("Names", &.{1}).?.string);
    try std.testing.expectEqualStrings("   ", machine.globalArrayElement("Names", &.{3}).?.string);
    try expectArrayRecordInteger(&machine, "Items", &.{1}, "Code", 77);
    try expectArrayRecordInteger(&machine, "Items", &.{2}, "Code", 0);
    try expectInteger(&machine, "RecordLength", 8);
    try expectLong(&machine, "Swapped&", 99);
    try expectLong(&machine, "Copied&", 0x01020304);
    try expectString(&machine, "LeftText", "X   ");
    try expectString(&machine, "RightText", "   Y");
    try expectInteger(&machine, "Lower%", 1);
    try expectInteger(&machine, "Upper%", 4);
    try expectSingle(&machine, "FixedAfter", 0);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1, 6, 5, 'A', 'Z' }, machine.global("RawBytes$").?.string);
}

test "REDIM PRESERVE rejects nonfinal shape changes without changing the array" {
    const source =
        \\DEFINT A-Z
        \\'$DYNAMIC
        \\DIM Grid(1 TO 2, 1 TO 2)
        \\Grid(2, 2) = 42
        \\ON ERROR GOTO PreserveError
        \\REDIM PRESERVE Grid(1 TO 3, 1 TO 2)
        \\After = Grid(2, 2)
        \\END
        \\PreserveError:
        \\Caught = 1
        \\StillThere = Grid(2, 2)
        \\RESUME NEXT
    ;
    var program = try core.compiler.compile(std.testing.allocator, "preserve-atomic.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 32));
    try expectInteger(&machine, "Caught", 1);
    try expectInteger(&machine, "StillThere", 42);
    try expectInteger(&machine, "After", 42);
    try std.testing.expectEqual(@as(i16, 42), machine.globalArrayElement("Grid", &.{ 2, 2 }).?.integer);
    try std.testing.expect(machine.globalArrayElement("Grid", &.{ 3, 2 }) == null);
}

test "REDIM PRESERVE allocation failure leaves bounds and record values untouched" {
    const source =
        \\DEFINT A-Z
        \\TYPE Item
        \\    Code AS INTEGER
        \\    Text AS STRING * 4
        \\END TYPE
        \\'$DYNAMIC
        \\DIM Items(1 TO 2) AS Item
        \\Items(2).Code = 73
        \\Items(2).Text = "KEEP"
        \\SLEEP 1
        \\REDIM PRESERVE Items(1 TO 4) AS Item
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "preserve-oom.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    machine.setGuestTime(0);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 16));

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(no_memory[0..]);
    machine.allocator = fixed.allocator();
    machine.setGuestTime(2 * std.time.ns_per_s);
    const status = machine.runToCompletion(128, 16);
    machine.allocator = std.testing.allocator;
    try std.testing.expectEqual(core.vm.Status.runtime_error, status);
    try std.testing.expectEqual(core.vm.RuntimeCode.out_of_memory, machine.runtime_diagnostic.?.code);
    try std.testing.expectEqual(@as(u32, 11), machine.runtime_diagnostic.?.span.line);
    try expectArrayRecordInteger(&machine, "Items", &.{2}, "Code", 73);
    try std.testing.expectEqual(@as(i32, 1), machine.globalArrayBound("Items", 1, false).?);
    try std.testing.expectEqual(@as(i32, 2), machine.globalArrayBound("Items", 1, true).?);
}

test "automatic static shared and COMMON storage are recursive resettable and VM local" {
    const source =
        \\DEFINT A-Z
        \\COMMON SHARED /State/ CommonCounter AS LONG
        \\DECLARE SUB AutoStep(Index)
        \\DECLARE SUB StaticStep(Index)
        \\DECLARE SUB SelectedStep(Index)
        \\DECLARE SUB SharedStep()
        \\DECLARE SUB CommonStep()
        \\DECLARE FUNCTION SumTo%(N)
        \\DECLARE FUNCTION StaticDepth%(N)
        \\DIM SHARED AutoResults(1 TO 2)
        \\DIM SHARED StaticResults(1 TO 2)
        \\DIM SHARED SelectedResults(1 TO 2)
        \\DIM SHARED SharedCounter
        \\SharedCounter = 40
        \\CommonCounter = 50
        \\CALL AutoStep(1)
        \\CALL AutoStep(2)
        \\CALL StaticStep(1)
        \\CALL StaticStep(2)
        \\CALL SelectedStep(1)
        \\CALL SelectedStep(2)
        \\CALL SharedStep
        \\CALL CommonStep
        \\Recursive = SumTo%(4)
        \\StaticRecursiveFirst = StaticDepth%(3)
        \\StaticRecursiveSecond = StaticDepth%(2)
        \\END
        \\SUB AutoStep(Index)
        \\    Counter = Counter + 1
        \\    AutoResults(Index) = Counter
        \\END SUB
        \\SUB StaticStep(Index) STATIC
        \\    Counter = Counter + 1
        \\    StaticResults(Index) = Counter
        \\END SUB
        \\SUB SelectedStep(Index)
        \\    STATIC Counter
        \\    Counter = Counter + 1
        \\    SelectedResults(Index) = Counter
        \\END SUB
        \\SUB SharedStep
        \\    SHARED SharedCounter
        \\    SharedCounter = SharedCounter + 1
        \\END SUB
        \\SUB CommonStep
        \\    CommonCounter = CommonCounter + 1
        \\END SUB
        \\FUNCTION SumTo%(N)
        \\    LocalValue = N
        \\    IF N > 1 THEN LocalValue = LocalValue + SumTo%(N - 1)
        \\    SumTo% = LocalValue
        \\END FUNCTION
        \\FUNCTION StaticDepth%(N) STATIC
        \\    Depth = Depth + 1
        \\    IF N > 1 THEN Ignored = StaticDepth%(N - 1)
        \\    StaticDepth% = Depth
        \\END FUNCTION
    ;
    var program = try core.compiler.compile(std.testing.allocator, "scope-lifetimes.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    try std.testing.expectEqual(@as(usize, 1), program.common_blocks.len);
    try std.testing.expect(program.common_blocks[0].named);
    try std.testing.expectEqual(@as(u32, 4), program.common_blocks[0].byte_size);

    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(2048, 64));
    try std.testing.expectEqual(core.vm.Status.halted, second.runToCompletion(2048, 64));
    try expectScopeResults(&first);
    try expectScopeResults(&second);

    try first.reset();
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(2048, 64));
    try expectScopeResults(&first);
}

test "CLEAR preserves static array bounds and releases dynamic storage" {
    const source =
        \\DEFINT A-Z
        \\DIM StaticValues(1 TO 2)
        \\StaticValues(1) = 9
        \\'$DYNAMIC
        \\DIM DynamicValues(1 TO 2)
        \\DynamicValues(1) = 8
        \\Text$ = "filled"
        \\CLEAR
        \\StaticLower = LBOUND(StaticValues)
        \\StaticUpper = UBOUND(StaticValues)
        \\StaticValue = StaticValues(1)
        \\TextLength = LEN(Text$)
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "clear-state.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 32));
    try expectInteger(&machine, "StaticLower", 1);
    try expectInteger(&machine, "StaticUpper", 2);
    try expectInteger(&machine, "StaticValue", 0);
    try expectInteger(&machine, "TextLength", 0);
    try std.testing.expect(machine.globalArrayElement("DynamicValues", &.{1}) == null);
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
    const fallback_graphics = handled.graphicsView() orelse return error.MissingGraphicsView;
    try std.testing.expectEqual(@as(u32, 320), fallback_graphics.width);
    try std.testing.expectEqual(@as(u32, 200), fallback_graphics.height);

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

test "QBasic graphics execute on isolated indexed guest screens" {
    var program = try compileFixture(fixture_paths.graphics);
    defer program.deinit();
    try expectProgramOk(&program);

    var first = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer second.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(128, 32));
    try std.testing.expect(second.graphicsView() == null);
    try expectInteger(&first, "Captured", 9);
    try expectInteger(&first, "Placed", 9);
    try expectInteger(&first, "Xored", 0);
    try expectInteger(&first, "Restored", 9);
    try expectInteger(&first, "Painted", 3);
    try expectInteger(&first, "StepColor", 3);
    try expectInteger(&first, "Outside", -1);

    const first_view = first.graphicsView() orelse return error.MissingGraphicsView;
    try std.testing.expectEqual(@as(u32, 640), first_view.width);
    try std.testing.expectEqual(@as(u32, 350), first_view.height);
    try std.testing.expectEqual(@as(u32, 0x00ffaa55), first_view.palette[1]);

    try std.testing.expectEqual(core.vm.Status.halted, second.runToCompletion(128, 32));
    const second_view = second.graphicsView() orelse return error.MissingGraphicsView;
    try std.testing.expect(first_view.pixels.ptr != second_view.pixels.ptr);
    try std.testing.expect(first_view.palette.ptr != second_view.palette.ptr);
    try std.testing.expectEqualSlices(u8, first_view.pixels, second_view.pixels);
}

test "SCREEN pages VIEW WINDOW PMAP and PALETTE USING share one coherent raster" {
    const source =
        \\DEFINT A-Z
        \\DIM Pal&(0 TO 15)
        \\FOR I = 0 TO 15
        \\  Pal&(I) = -1
        \\NEXT I
        \\Pal&(3) = 63
        \\SCREEN 7,,1,0
        \\PSET (5,5),4
        \\Hidden = POINT(5,5)
        \\SCREEN ,,,1
        \\Shown = POINT(5,5)
        \\PCOPY 1,2
        \\SCREEN ,,2,2
        \\Copied = POINT(5,5)
        \\VIEW (10,10)-(110,110),1,2
        \\WINDOW SCREEN (0,0)-(10,10)
        \\PSET (5,5),3
        \\Mapped = POINT(5,5)
        \\MapX! = PMAP(5,0)
        \\MapY! = PMAP(5,1)
        \\PhysX! = POINT(0)
        \\PhysY! = POINT(1)
        \\LogicX! = POINT(2)
        \\LogicY! = POINT(3)
        \\WINDOW
        \\VIEW
        \\SCREEN 9
        \\WIDTH ,43
        \\PALETTE USING Pal&(0)
        \\LOCATE 43,80
        \\PRINT "Z";
        \\LastRow = CSRLIN
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "graphics-pages.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(4096, 64));
    try expectInteger(&machine, "Hidden", 4);
    try expectInteger(&machine, "Shown", 4);
    try expectInteger(&machine, "Copied", 4);
    try expectInteger(&machine, "Mapped", 3);
    try expectSingle(&machine, "MapX!", 60);
    try expectSingle(&machine, "MapY!", 60);
    try expectSingle(&machine, "PhysX!", 60);
    try expectSingle(&machine, "PhysY!", 60);
    try expectSingle(&machine, "LogicX!", 5);
    try expectSingle(&machine, "LogicY!", 5);
    try expectInteger(&machine, "LastRow", 43);
    try std.testing.expectEqual(@as(u8, 'Z'), machine.textScreen().cell(42, 79).?.character);
    const view = machine.graphicsView() orelse return error.MissingGraphicsView;
    try std.testing.expectEqual(@as(u32, 640), view.width);
    try std.testing.expectEqual(@as(u32, 350), view.height);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), view.palette[3]);
}

test "graphics defaults and COLOR PALETTE restrictions match each screen mode" {
    const defaults_source =
        \\DEFINT A-Z
        \\SCREEN 1: PSET (1,1): Cga = POINT(1,1)
        \\SCREEN 2: PSET (1,1): Mono = POINT(1,1)
        \\SCREEN 10: PSET (1,1): Pseudo = POINT(1,1)
        \\SCREEN 11: PSET (1,1): VgaMono = POINT(1,1)
        \\SCREEN 13: PSET (1,1): Mcga = POINT(1,1)
        \\END
    ;
    var defaults_program = try core.compiler.compile(std.testing.allocator, "graphics-defaults.bas", defaults_source);
    defer defaults_program.deinit();
    try expectProgramOk(&defaults_program);
    var defaults = try core.vm.Vm.init(std.testing.allocator, &defaults_program, .{});
    defer defaults.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, defaults.runToCompletion(256, 32));
    try expectInteger(&defaults, "Cga", 3);
    try expectInteger(&defaults, "Mono", 1);
    try expectInteger(&defaults, "Pseudo", 3);
    try expectInteger(&defaults, "VgaMono", 1);
    try expectInteger(&defaults, "Mcga", 7);

    const invalid_sources = [_][]const u8{
        "SCREEN 2\nCOLOR 1\nEND\n",
        "SCREEN 11\nCOLOR 1\nEND\n",
        "SCREEN 12\nCOLOR 1,0\nEND\n",
        "DEFINT A-Z\nDIM P(0 TO 2)\nSCREEN 1\nPALETTE USING P(0)\nEND\n",
        "DEFINT A-Z\nDIM P(0 TO 15)\nSCREEN 12\nPALETTE USING P(0)\nEND\n",
    };
    for (invalid_sources) |source| {
        var program = try core.compiler.compile(std.testing.allocator, "graphics-color-error.bas", source);
        defer program.deinit();
        try expectProgramOk(&program);
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(128, 16));
        const diagnostic = machine.runtime_diagnostic orelse return error.MissingRuntimeDiagnostic;
        try std.testing.expect(diagnostic.code == .illegal_function_call or diagnostic.code == .type_mismatch);
    }
}

test "packed LONG arrays decode as mode 1 and mode 9 images without source special cases" {
    var program = try compileFixture(fixture_paths.packed_images);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 64));

    const ega_solid = (machine.global("EgaSolid") orelse return error.MissingGlobal).integer;
    const ega_erased = (machine.global("EgaErased") orelse return error.MissingGlobal).integer;
    const ega_restored = (machine.global("EgaRestored") orelse return error.MissingGlobal).integer;
    try std.testing.expect(ega_solid > 0);
    try std.testing.expectEqual(@as(i16, 0), ega_erased);
    try std.testing.expectEqual(ega_solid, ega_restored);

    const cga_solid = (machine.global("CgaSolid") orelse return error.MissingGlobal).integer;
    const cga_erased = (machine.global("CgaErased") orelse return error.MissingGlobal).integer;
    const cga_restored = (machine.global("CgaRestored") orelse return error.MissingGlobal).integer;
    try std.testing.expect(cga_solid > 0);
    try std.testing.expectEqual(@as(i16, 0), cga_erased);
    try std.testing.expectEqual(cga_solid, cga_restored);

    const graphics = machine.graphicsView() orelse return error.MissingGraphicsView;
    try std.testing.expectEqual(@as(u32, 320), graphics.width);
    try std.testing.expectEqual(@as(u32, 200), graphics.height);
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
        return 1;
    }
};

const RuntimeAudioSink = struct {
    opens: u32 = 0,
    writes: u32 = 0,
    closes: u32 = 0,
    sample_rate: u32 = 0,
    channels: u16 = 0,
    non_silent: bool = false,

    fn sink(self: *RuntimeAudioSink) core.runtime_adapter.api.AudioSink {
        return .{
            .context = self,
            .open_fn = open,
            .write_fn = write,
            .volume_fn = volume,
            .close_fn = close,
        };
    }

    fn open(context: *anyopaque, config: core.runtime_adapter.api.AudioConfig) i32 {
        const self: *RuntimeAudioSink = @ptrCast(@alignCast(context));
        self.opens += 1;
        self.sample_rate = config.sample_rate;
        self.channels = config.channels;
        return 0;
    }

    fn write(context: *anyopaque, data: []const u8) i32 {
        const self: *RuntimeAudioSink = @ptrCast(@alignCast(context));
        self.writes += 1;
        for (data) |byte| {
            if (byte != 0) {
                self.non_silent = true;
                break;
            }
        }
        return @intCast(data.len);
    }

    fn volume(_: *anyopaque, _: u32) i32 {
        return 0;
    }

    fn close(context: *anyopaque) i32 {
        const self: *RuntimeAudioSink = @ptrCast(@alignCast(context));
        self.closes += 1;
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

test "INPUT prompt variants redo multi-target assignments atomically" {
    const source =
        \\DEFINT A-Z
        \\DIM Fixed AS STRING * 4
        \\INPUT; "Pair"; First, Second$, Fixed
        \\LINE INPUT "Line", Whole$
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "input-prompts.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    try feedInput(&machine, "7\r");
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    try expectInteger(&machine, "First", 0);
    try expectString(&machine, "Second$", "");
    try expectString(&machine, "Fixed", "    ");
    try feedInput(&machine, "7,\"ok\",\"xy\"\r");
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 32));
    try expectInteger(&machine, "First", 7);
    try expectString(&machine, "Second$", "ok");
    try expectString(&machine, "Fixed", "xy  ");
    try feedInput(&machine, "a,b,c\r");
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 32));
    try expectString(&machine, "Whole$", "a,b,c");
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
    const focus = adapter.handleInput(.{ .focus = .{ .focused = false, .tick = 1, .sequence = 1 } });
    try std.testing.expectEqual(core.runtime_adapter.InputDeliveryStatus.control, focus.status);
    const dropped = adapter.handleInput(.{ .text = .{ .codepoint = 'Z', .modifiers = 0, .tick = 2, .sequence = 2 } });
    try std.testing.expectEqual(core.runtime_adapter.InputDeliveryStatus.dropped, dropped.status);
    try std.testing.expectEqual(core.vm.InputDropReason.unfocused, dropped.reason);
}

test "fixed and variable byte strings preserve padding truncation arrays records and aliases" {
    const source =
        \\DEFINT A-Z
        \\TYPE Item
        \\    Code AS STRING * 4
        \\END TYPE
        \\DIM Fixed AS STRING * 5
        \\DIM Names(1 TO 2) AS STRING * 3
        \\DIM Items(1 TO 1) AS Item
        \\Source$ = "ABCDEFG"
        \\Fixed = Source$
        \\Source$ = "Z"
        \\Names(1) = "WXYZ"
        \\Names(2) = "Q"
        \\Items(1).Code = CHR$(0) + CHR$(255) + "R"
        \\Same = (Fixed = "ABCDE")
        \\Joined$ = Fixed + Names(2)
        \\MID$(Fixed, 2, 2) = "xyzz"
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "fixed-strings.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 32));
    try expectString(&machine, "Fixed", "AxyDE");
    try expectString(&machine, "Source$", "Z");
    try expectInteger(&machine, "Same", -1);
    try expectString(&machine, "Joined$", "ABCDEQ  ");
    const first = machine.globalArrayElement("Names", &.{1}) orelse return error.MissingGlobal;
    try std.testing.expectEqualStrings("WXY", first.string);
    const second = machine.globalArrayElement("Names", &.{2}) orelse return error.MissingGlobal;
    try std.testing.expectEqualStrings("Q  ", second.string);
    const record = machine.globalArrayRecordField("Items", &.{1}, "Code") orelse return error.MissingGlobal;
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 'R', ' ' }, record.string);
}

test "string functions cover byte edges based numbers and MID assignment errors atomically" {
    const source =
        \\DEFINT A-Z
        \\Ascii = ASC(CHR$(255))
        \\Lower$ = LCASE$("A" + CHR$(196) + "Z")
        \\FromRight$ = RIGHT$("ABCDE", 3)
        \\Trimmed$ = RTRIM$("A  ")
        \\Repeated$ = STRING$(3, 0)
        \\RepeatedText$ = STRING$(4, "xy")
        \\HexValue$ = HEX$(-1)
        \\OctValue$ = OCT$(-1)
        \\HexParsed# = VAL("&HFFFF trailing")
        \\OctParsed# = VAL("&O177777")
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "string-functions.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 32));
    try expectInteger(&machine, "Ascii", 255);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 196, 'z' }, machine.global("Lower$").?.string);
    try expectString(&machine, "FromRight$", "CDE");
    try expectString(&machine, "Trimmed$", "A");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, machine.global("Repeated$").?.string);
    try expectString(&machine, "RepeatedText$", "xxxx");
    try expectString(&machine, "HexValue$", "FFFF");
    try expectString(&machine, "OctValue$", "177777");
    try expectDouble(&machine, "HexParsed#", -1);
    try expectDouble(&machine, "OctParsed#", -1);

    var invalid_program = try core.compiler.compile(
        std.testing.allocator,
        "mid-error.bas",
        "DIM Fixed AS STRING * 4\nFixed = \"KEEP\"\nMID$(Fixed, 0) = \"X\"\nEND\n",
    );
    defer invalid_program.deinit();
    try expectProgramOk(&invalid_program);
    var invalid = try core.vm.Vm.init(std.testing.allocator, &invalid_program, .{});
    defer invalid.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, invalid.runToCompletion(64, 16));
    try expectString(&invalid, "Fixed", "KEEP");
    try std.testing.expectEqual(@as(i32, 5), invalid.exit_code);
}

test "cursor queries screen reads and extended INPUT dollar preserve exact bytes and sequence" {
    const source =
        \\DEFINT A-Z
        \\CLS
        \\COLOR 14, 1
        \\LOCATE 2, 3, 0
        \\PRINT "A";
        \\CursorRow = CSRLIN
        \\CursorColumn = POS(0)
        \\ScreenByte = SCREEN(2, 3)
        \\ScreenColor = SCREEN(2, 3, 1)
        \\Raw$ = INPUT$(3)
        \\Next$ = INKEY$
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "text-query-input.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(128, 16));
    const extended = machine.acceptKeyCode(0x88, .{ .sequence = 10, .tick = 20 });
    try std.testing.expect(extended.accepted);
    try std.testing.expectEqual(@as(u8, 2), extended.accepted_bytes);
    try std.testing.expect(machine.acceptTextCodepoint('X', .{ .sequence = 11, .tick = 21 }).accepted);
    try std.testing.expect(machine.acceptTextCodepoint('Y', .{ .sequence = 12, .tick = 22 }).accepted);
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 16));
    try expectInteger(&machine, "CursorRow", 2);
    try expectInteger(&machine, "CursorColumn", 4);
    try expectInteger(&machine, "ScreenByte", 'A');
    try expectInteger(&machine, "ScreenColor", 30);
    try std.testing.expectEqualSlices(u8, &.{ 0, 75, 'X' }, machine.global("Raw$").?.string);
    try expectString(&machine, "Next$", "Y");
    const stats = machine.inputStats();
    try std.testing.expectEqual(@as(u64, 4), stats.accepted_bytes);
    try std.testing.expectEqual(@as(u64, 4), stats.consumed_bytes);
    try std.testing.expectEqual(@as(u64, 12), stats.last_consumed_sequence);
    try std.testing.expectEqual(@as(u64, 22), stats.last_consumed_tick);
}

test "PRINT USING and WRITE share reference formatting on the text screen" {
    const source =
        \\CLS
        \\PRINT USING "!"; "LOOK"; "OUT"
        \\PRINT USING "\  \"; "LOOK"; "OUT"
        \\PRINT USING "##.##"; .78
        \\PRINT USING "###.##"; 987.654
        \\PRINT USING "**$##.##"; 2.34
        \\PRINT USING "####,.##"; 1234.5
        \\PRINT USING "+.##^^^^"; 123
        \\PRINT USING "##.##"; 111.22
        \\WRITE 80, 90, "That's all.", -1E-13
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "formatted-output.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
    try expectScreenRow(&machine, 0, "LO");
    try expectScreenRow(&machine, 1, "LOOKOUT");
    try expectScreenRow(&machine, 2, " 0.78");
    try expectScreenRow(&machine, 3, "987.65");
    try expectScreenRow(&machine, 4, "***$2.34");
    try expectScreenRow(&machine, 5, "1,234.50");
    try expectScreenRow(&machine, 6, "+.12E+03");
    try expectScreenRow(&machine, 7, "%111.22");
    try expectScreenRow(&machine, 8, "80,90,\"That's all.\",-1E-13");
}

test "PRINT STR and WRITE round SINGLE and DOUBLE to QuickBASIC significant digits" {
    const source =
        \\CLS
        \\PRINT 1.2345678!
        \\PRINT 1.2345678901234567#
        \\PRINT 1.1E-7
        \\PRINT 1.1D-16
        \\WRITE 1.2345678!, 1.2345678901234567#, 1.1E-7, 1.1D-16
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "quickbasic-number-format.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 32));
    try expectScreenRow(&machine, 0, " 1.234568");
    try expectScreenRow(&machine, 1, " 1.234567890123457");
    try expectScreenRow(&machine, 2, " 1.1E-7");
    try expectScreenRow(&machine, 3, " 1.1D-16");
    try expectScreenRow(&machine, 4, "1.234568,1.234567890123457,1.1E-7,1.1D-16");
}

test "PRINT USING requires at least one formatted value" {
    var program = try core.compiler.compile(std.testing.allocator, "empty-using.bas", "PRINT USING \"##\";\nEND\n");
    defer program.deinit();
    try std.testing.expect(!program.ok());
    try std.testing.expect(containsCompileDiagnostic(program.diagnostics, .wrong_argument_count));
}

test "PRINT USING implements every QuickBASIC numeric mask family" {
    const source =
        \\CLS
        \\PRINT USING "+##.##"; -68.95
        \\PRINT USING "##.##-"; -68.95
        \\PRINT USING "**#.#"; 12.39
        \\PRINT USING "$$###.##"; 456.78
        \\PRINT USING "**$##.##"; 2.34
        \\PRINT USING "##.##^^^^"; 234.56
        \\PRINT USING ".####^^^^-"; -888888
        \\PRINT USING "+.##^^^^^"; 123
        \\PRINT USING "_!##.##_!"; 12.34
        \\PRINT USING ".##"; .999
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "using-masks.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
    try expectScreenRow(&machine, 0, "-68.95");
    try expectScreenRow(&machine, 1, "68.95-");
    try expectScreenRow(&machine, 2, "*12.4");
    try expectScreenRow(&machine, 3, " $456.78");
    try expectScreenRow(&machine, 4, "***$2.34");
    try expectScreenRow(&machine, 5, " 2.35E+02");
    try expectScreenRow(&machine, 6, ".8889E+06-");
    try expectScreenRow(&machine, 7, "+.12E+003");
    try expectScreenRow(&machine, 8, "!12.34!");
    try expectScreenRow(&machine, 9, "%1.00");
}

test "R4BASIC input policy emits one guest byte and filters pointer mapping" {
    const source = "First$ = INKEY$\nSecond$ = INKEY$\nEND\n";
    var program = try core.compiler.compile(std.testing.allocator, "translated-input.bas", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    const viewport = try r4os.subsystem_host.calculateViewport(800, 600, 320, 200);
    var translator = r4os.subsystem_host.InputTranslator.init(.text_only_no_pointer);

    const event = translator.translate(.{
        .kind = @intFromEnum(r4os.abi.GuiEventKind.key_down),
        .key = 'A',
        .tick = 41,
    }, viewport, null) orelse return error.MissingTranslatedInput;
    const delivery = adapter.handleInput(event);
    try std.testing.expectEqual(core.runtime_adapter.InputDeliveryStatus.accepted, delivery.status);
    try std.testing.expectEqual(@as(u64, 1), delivery.sequence);
    try std.testing.expectEqual(@as(u64, 41), delivery.tick);
    try std.testing.expect(translator.takePending() == null);

    try std.testing.expect(translator.translate(.{
        .kind = @intFromEnum(r4os.abi.GuiEventKind.mouse_move),
        .x = viewport.x,
        .y = viewport.y,
        .tick = 42,
    }, viewport, null) == null);
    try std.testing.expectEqual(@as(u64, 2), translator.stats.raw_events);
    try std.testing.expectEqual(@as(u64, 1), translator.stats.logical_events);
    try std.testing.expectEqual(@as(u64, 1), translator.stats.pointer_ignored);
    try std.testing.expectEqual(@as(u64, 0), translator.stats.mouse_mappings);

    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(32, 8));
    try expectString(&machine, "First$", "A");
    try expectString(&machine, "Second$", "");
    const input = machine.inputStats();
    try std.testing.expectEqual(@as(u64, 1), input.accepted_bytes);
    try std.testing.expectEqual(@as(u64, 1), input.consumed_bytes);
    try std.testing.expectEqual(@as(u64, 1), input.last_consumed_sequence);
    try std.testing.expectEqual(@as(u64, 41), input.last_consumed_tick);
    adapter.notePresent(.presented, 50, 60);
    try std.testing.expectEqual(@as(u64, 1), adapter.performance.last_visible_input_sequence);
    try std.testing.expectEqual(@as(u64, 41), adapter.performance.last_visible_input_tick);
    try std.testing.expectEqual(@as(u64, 60), adapter.performance.last_visible_reaction_ns);
}

test "input queue overflow preserves sequence tick fill and distinct drop reasons" {
    var program = try core.compiler.compile(std.testing.allocator, "input-overflow.bas", "First$ = INKEY$\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();

    var sequence: u64 = 1;
    while (sequence <= core.vm.maximum_keyboard_bytes) : (sequence += 1) {
        const accepted = machine.acceptTextCodepoint('Q', .{ .sequence = sequence, .tick = 1000 + sequence });
        try std.testing.expect(accepted.accepted);
    }
    const overflow = machine.acceptTextCodepoint('R', .{ .sequence = sequence, .tick = 1000 + sequence });
    try std.testing.expect(!overflow.accepted);
    try std.testing.expectEqual(core.vm.InputDropReason.queue_full, overflow.reason);
    try std.testing.expectEqual(core.vm.maximum_keyboard_bytes, machine.queuedInputBytes());

    const before = machine.inputStats();
    try std.testing.expectEqual(@as(u64, core.vm.maximum_keyboard_bytes), before.accepted_bytes);
    try std.testing.expectEqual(@as(u64, 1), before.queue_full_drops);
    try std.testing.expectEqual(@as(u64, core.vm.maximum_keyboard_bytes), before.maximum_queue_depth);
    try std.testing.expectEqual(sequence, before.last_dropped_sequence);
    try std.testing.expectEqual(1000 + sequence, before.last_dropped_tick);
    try std.testing.expectEqual(core.vm.InputDropReason.queue_full, before.last_drop_reason);

    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(32, 8));
    try expectString(&machine, "First$", "Q");
    const after = machine.inputStats();
    try std.testing.expectEqual(@as(u64, 1), after.consumed_bytes);
    try std.testing.expectEqual(@as(u64, 1), after.last_consumed_sequence);
    try std.testing.expectEqual(@as(u64, 1001), after.last_consumed_tick);
}

test "input adapter preserves every VM drop category without hot logging" {
    var program = try core.compiler.compile(std.testing.allocator, "input-drops.bas", "END\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);

    try std.testing.expectEqual(
        core.runtime_adapter.InputDeliveryStatus.control,
        adapter.handleInput(.{ .focus = .{ .focused = false, .tick = 1, .sequence = 1 } }).status,
    );
    try std.testing.expectEqual(
        core.vm.InputDropReason.unfocused,
        adapter.handleInput(.{ .text = .{ .codepoint = 'A', .modifiers = 0, .tick = 2, .sequence = 2 } }).reason,
    );
    try std.testing.expectEqual(
        core.runtime_adapter.InputDeliveryStatus.control,
        adapter.handleInput(.{ .focus = .{ .focused = true, .tick = 3, .sequence = 3 } }).status,
    );
    try std.testing.expectEqual(
        core.vm.InputDropReason.invalid_codepoint,
        adapter.handleInput(.{ .text = .{ .codepoint = 0x100, .modifiers = 0, .tick = 4, .sequence = 4 } }).reason,
    );
    try std.testing.expectEqual(
        core.vm.InputDropReason.unsupported_key,
        adapter.handleInput(.{ .key_down = .{ .code = 0x91, .modifiers = 0, .tick = 5, .sequence = 5 } }).reason,
    );
    try std.testing.expectEqual(
        core.vm.InputDropReason.unsupported_event,
        adapter.handleInput(.{ .mouse = .{
            .action = .move,
            .client_x = 0,
            .client_y = 0,
            .guest = null,
            .buttons = 0,
            .modifiers = 0,
            .tick = 6,
            .sequence = 6,
        } }).reason,
    );

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(no_memory[0..]);
    machine.allocator = fixed.allocator();
    const out_of_memory = adapter.handleInput(.{ .text = .{ .codepoint = 'B', .modifiers = 0, .tick = 7, .sequence = 7 } });
    machine.allocator = std.testing.allocator;
    try std.testing.expectEqual(core.vm.InputDropReason.out_of_memory, out_of_memory.reason);

    const input = machine.inputStats();
    try std.testing.expectEqual(@as(u64, 7), input.logical_events);
    try std.testing.expectEqual(@as(u64, 2), input.control_events);
    try std.testing.expectEqual(@as(u64, 5), input.dropped_events);
    try std.testing.expectEqual(@as(u64, 1), input.unfocused_drops);
    try std.testing.expectEqual(@as(u64, 1), input.invalid_codepoint_drops);
    try std.testing.expectEqual(@as(u64, 1), input.unsupported_key_drops);
    try std.testing.expectEqual(@as(u64, 1), input.unsupported_event_drops);
    try std.testing.expectEqual(@as(u64, 1), input.out_of_memory_drops);
    try std.testing.expectEqual(@as(u64, 7), input.last_dropped_sequence);
    try std.testing.expectEqual(@as(u64, 7), input.last_dropped_tick);
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

test "RND and RANDOMIZE reproduce Microsoft's 24-bit state machine per VM" {
    const default_source =
        \\Held! = RND(0)
        \\First! = RND
        \\Second! = RND
        \\Third! = RND
        \\END
    ;
    var default_program = try core.compiler.compile(std.testing.allocator, "rnd-default.bas", default_source);
    defer default_program.deinit();
    try expectProgramOk(&default_program);
    var first = try core.vm.Vm.init(std.testing.allocator, &default_program, .{});
    defer first.deinit();
    var second = try core.vm.Vm.init(std.testing.allocator, &default_program, .{});
    defer second.deinit();
    for ([_]*core.vm.Vm{ &first, &second }) |machine| {
        try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 16));
        try expectSingleBits(machine, "Held!", randomVector(327_680));
        try expectSingleBits(machine, "First!", randomVector(11_837_123));
        try expectSingleBits(machine, "Second!", randomVector(8_949_370));
        try expectSingleBits(machine, "Third!", randomVector(9_722_709));
    }
    try first.reset();
    try std.testing.expectEqual(core.vm.Status.halted, first.runToCompletion(128, 16));
    try expectSingleBits(&first, "First!", randomVector(11_837_123));

    var seeded_program = try core.compiler.compile(
        std.testing.allocator,
        "rnd-randomize.bas",
        "RANDOMIZE 123\nSeeded! = RND\nEND\n",
    );
    defer seeded_program.deinit();
    try expectProgramOk(&seeded_program);
    var seeded = try core.vm.Vm.init(std.testing.allocator, &seeded_program, .{});
    defer seeded.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, seeded.runToCompletion(128, 16));
    try expectSingleBits(&seeded, "Seeded!", randomVector(3_835_075));

    const negative_source =
        \\NegativeOne! = RND(-1)
        \\HeldOne! = RND(0)
        \\NegativeSeven! = RND(-7)
        \\HeldSeven! = RND(0)
        \\END
    ;
    var negative_program = try core.compiler.compile(std.testing.allocator, "rnd-negative.bas", negative_source);
    defer negative_program.deinit();
    try expectProgramOk(&negative_program);
    var negative = try core.vm.Vm.init(std.testing.allocator, &negative_program, .{});
    defer negative.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, negative.runToCompletion(128, 16));
    try expectSingleBits(&negative, "NegativeOne!", randomVector(3_758_214));
    try expectSingleBits(&negative, "HeldOne!", randomVector(3_758_214));
    try expectSingleBits(&negative, "NegativeSeven!", randomVector(1_481_859));
    try expectSingleBits(&negative, "HeldSeven!", randomVector(1_481_859));
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

test "PLAY MML parses stateful commands and rejects invalid ranges atomically" {
    var engine = core.audio.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const result = try engine.play("MB T160 O1 L16 B9 N0 B+ A- P8. > C < C MN C MS D ML E", 0);
    try std.testing.expectEqual(core.audio.PlayMode.background, result.mode);
    try std.testing.expectEqual(@as(u32, 10), result.event_count);
    try std.testing.expectEqual(@as(u32, 8), engine.stats.notes);
    try std.testing.expectEqual(@as(u32, 2), engine.stats.rests);
    const pending_before = engine.pendingFrames();
    try std.testing.expect(pending_before != 0);

    var pcm: [core.audio.frame_bytes * 480]u8 = undefined;
    const rendered = engine.render(&pcm);
    try std.testing.expectEqual(@as(i32, @intCast(pcm.len)), rendered);
    try std.testing.expect(engine.pendingFrames() < pending_before);
    try std.testing.expect(std.mem.indexOfNone(u8, &pcm, &[_]u8{0}) != null);

    const pending_after_render = engine.pendingFrames();
    engine.setGuestTime(std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.skipped_frames);
    try std.testing.expectEqual(pending_after_render, engine.pendingFrames());
    try std.testing.expectEqual(@as(u64, 10), engine.stats.direct_play_events);
    try std.testing.expectEqual(@as(u64, 8), engine.stats.phase_table_lookups);

    const events_before = engine.pendingFrames();
    const statements_before = engine.stats.play_statements;
    for ([_][]const u8{ "T31C", "T256C", "L0C", "O7C", "N85", "O6B+", "MX" }) |invalid| {
        try std.testing.expectError(error.InvalidCommand, engine.play(invalid, 0));
        try std.testing.expectEqual(events_before, engine.pendingFrames());
        try std.testing.expectEqual(statements_before, engine.stats.play_statements);
    }

    var maximum_command = [_]u8{'C'} ** core.audio.maximum_events;
    var maximum_engine = core.audio.Engine.init(std.testing.allocator);
    defer maximum_engine.deinit();
    const maximum = try maximum_engine.play(maximum_command[0..], 0);
    try std.testing.expectEqual(@as(u32, core.audio.maximum_events), maximum.event_count);
    try std.testing.expectEqual(@as(u64, core.audio.maximum_events), maximum_engine.stats.direct_play_events);
    try std.testing.expectEqual(@as(u64, core.audio.maximum_events), maximum_engine.stats.phase_table_lookups);
    try std.testing.expectEqual(@as(u32, 1), maximum_engine.stats.play_capacity_grows);
}

test "MB continues while MF and BEEP wait on resolved transport frames" {
    var program = try compileFixture(fixture_paths.audio);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();

    machine.setGuestTime(0);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(64, 32));
    try expectInteger(&machine, "BackgroundDone", 1);
    try std.testing.expect(machine.global("ForegroundDone") == null or machine.global("ForegroundDone").?.integer == 0);
    var pcm: [core.audio.frame_bytes * 480]u8 = undefined;
    try std.testing.expectEqual(@as(i32, @intCast(pcm.len)), machine.renderAudio(&pcm));
    try std.testing.expect(std.mem.indexOfNone(u8, &pcm, &[_]u8{0}) != null);
    try std.testing.expect(!machine.noteAudioProgress(pcm.len / core.audio.frame_bytes, 0, 0, false));
    machine.setGuestTime(10 * std.time.ns_per_s);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runSlice(64).status);

    var foreground_resolved = false;
    for (0..256) |_| {
        const count = machine.renderAudio(&pcm);
        try std.testing.expect(count >= 0);
        if (count == 0) break;
        const bytes: usize = @intCast(count);
        const silent = std.mem.indexOfNone(u8, pcm[0..bytes], &[_]u8{0}) == null;
        if (machine.noteAudioProgress(
            if (silent) 0 else bytes / core.audio.frame_bytes,
            if (silent) bytes / core.audio.frame_bytes else 0,
            0,
            false,
        )) {
            foreground_resolved = true;
            break;
        }
    }
    try std.testing.expect(foreground_resolved);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.runToCompletion(64, 32));
    try expectInteger(&machine, "ForegroundDone", 1);
    try expectInteger(&machine, "BeepDone", 0);
    const stats = machine.audioStats();
    try std.testing.expectEqual(@as(u32, 2), stats.play_statements);
    try std.testing.expectEqual(@as(u32, 1), stats.beep_statements);

    var beep_resolved = false;
    for (0..64) |_| {
        const count = machine.renderAudio(&pcm);
        try std.testing.expect(count >= 0);
        if (count == 0) break;
        const bytes: usize = @intCast(count);
        if (machine.noteAudioProgress(bytes / core.audio.frame_bytes, 0, 0, false)) {
            beep_resolved = true;
            break;
        }
    }
    try std.testing.expect(beep_resolved);
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 32));
    try expectInteger(&machine, "BeepDone", 1);
    try std.testing.expectEqual(machine.audioStats().scheduled_frames, machine.audioStats().resolved_frames);
    try std.testing.expectEqual(@as(u32, 2), machine.audioStats().foreground_wakes);
}

test "BEEP reaches the buffered subsystem audio sink and closes it once" {
    var program = try core.compiler.compile(std.testing.allocator, "buffered-beep.bas", "DEFINT A-Z\nBEEP\nDone = 1\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = RuntimeHostProbe{};
    var sink = RuntimeAudioSink{};
    var queue: [core.audio.frame_bytes * 960]u8 = undefined;
    var scratch: [core.audio.frame_bytes * 480]u8 = undefined;
    var runtime = try core.runtime_adapter.api.Runtime.init(.{}, 1000, 0, .{
        .config = .{ .sample_rate = core.audio.sample_rate, .channels = core.audio.channels },
        .queue_storage = queue[0..],
        .scratch = scratch[0..],
        .sink = sink.sink(),
    });

    var completed = false;
    for (0..250) |raw_tick| {
        switch (runtime.cycle(@intCast(raw_tick), adapter.driver(), host.driver())) {
            .finished => |finished| {
                try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.completed, finished.state);
                completed = true;
                break;
            },
            .wait => {},
        }
    }
    try std.testing.expect(completed);
    try expectInteger(&machine, "Done", 1);
    try std.testing.expectEqual(@as(u32, 1), sink.opens);
    try std.testing.expect(sink.writes != 0);
    try std.testing.expect(sink.non_silent);
    try std.testing.expectEqual(core.audio.sample_rate, sink.sample_rate);
    try std.testing.expectEqual(core.audio.channels, sink.channels);
    try std.testing.expectEqual(@as(u32, 1), sink.closes);
    try std.testing.expect(runtime.resources_closed);
}

test "background PLAY reaches service acceptance before a fast END closes the stream" {
    var program = try core.compiler.compile(std.testing.allocator, "background-end.bas", "PLAY \"MBT255L64C\"\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = RuntimeHostProbe{};
    var sink = RuntimeAudioSink{};
    var queue: [core.audio.frame_bytes * 960]u8 = undefined;
    var scratch: [core.audio.frame_bytes * 480]u8 = undefined;
    var runtime = try core.runtime_adapter.api.Runtime.init(.{}, 1000, 0, .{
        .config = .{ .sample_rate = core.audio.sample_rate, .channels = core.audio.channels },
        .queue_storage = queue[0..],
        .scratch = scratch[0..],
        .sink = sink.sink(),
    });

    const first = runtime.cycle(0, adapter.driver(), host.driver());
    try std.testing.expect(first == .wait);
    try std.testing.expectEqual(core.vm.Status.halted, machine.status);
    try std.testing.expect(machine.unresolvedAudioFrames() != 0);
    var completed = false;
    for (1..64) |raw_tick| {
        if (runtime.cycle(@intCast(raw_tick), adapter.driver(), host.driver()) == .finished) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(u32, 1), sink.opens);
    try std.testing.expectEqual(@as(u32, 1), sink.writes);
    try std.testing.expectEqual(@as(u32, 1), sink.closes);
    try std.testing.expectEqual(machine.audioStats().scheduled_frames, machine.audioStats().accepted_frames);
    try std.testing.expectEqual(@as(u64, 0), machine.unresolvedAudioFrames());
}

test "eight silent R4BASIC guests consume no audio sessions" {
    var program = try core.compiler.compile(std.testing.allocator, "silent-eight.bas", "DEFINT A-Z\nPLAY \"MFP64\"\nDone = 1\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);

    var machines: [8]core.vm.Vm = undefined;
    var adapters: [8]core.runtime_adapter.Adapter = undefined;
    var hosts: [8]RuntimeHostProbe = undefined;
    var sinks: [8]RuntimeAudioSink = undefined;
    var queues: [8][core.audio.frame_bytes * 960]u8 = undefined;
    var scratches: [8][core.audio.frame_bytes * 480]u8 = undefined;
    var runtimes: [8]core.runtime_adapter.api.Runtime = undefined;
    var initialized: usize = 0;
    defer {
        for (0..initialized) |index| machines[index].deinit();
    }

    for (0..8) |index| {
        machines[index] = try core.vm.Vm.init(std.testing.allocator, &program, .{});
        initialized += 1;
        adapters[index] = core.runtime_adapter.Adapter.init(&machines[index]);
        hosts[index] = .{};
        sinks[index] = .{};
        runtimes[index] = try core.runtime_adapter.api.Runtime.init(.{}, 1000, 0, .{
            .config = .{ .sample_rate = core.audio.sample_rate, .channels = core.audio.channels },
            .queue_storage = queues[index][0..],
            .scratch = scratches[index][0..],
            .sink = sinks[index].sink(),
        });
    }

    var completed = [_]bool{false} ** 8;
    for (0..32) |raw_tick| {
        for (0..8) |index| {
            if (completed[index]) continue;
            if (runtimes[index].cycle(@intCast(raw_tick), adapters[index].driver(), hosts[index].driver()) == .finished) {
                completed[index] = true;
            }
        }
    }
    for (0..8) |index| {
        try std.testing.expect(completed[index]);
        try expectInteger(&machines[index], "Done", 1);
        try std.testing.expectEqual(@as(u32, 0), sinks[index].opens);
        try std.testing.expectEqual(@as(u32, 0), sinks[index].writes);
        try std.testing.expect(runtimes[index].audio.stats.suppressed_bytes != 0);
        try std.testing.expectEqual(@as(u64, 0), machines[index].unresolvedAudioFrames());
    }
}

test "missing subsystem audio degrades without stopping guest time" {
    var program = try core.compiler.compile(std.testing.allocator, "degraded-beep.bas", "DEFINT A-Z\nBEEP\nDone = 1\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = RuntimeHostProbe{};
    var queue: [core.audio.frame_bytes * 960]u8 = undefined;
    var scratch: [core.audio.frame_bytes * 480]u8 = undefined;
    var runtime = try core.runtime_adapter.api.Runtime.init(.{}, 1000, 0, .{
        .config = .{ .sample_rate = core.audio.sample_rate, .channels = core.audio.channels },
        .queue_storage = queue[0..],
        .scratch = scratch[0..],
        .sink = null,
    });

    _ = runtime.cycle(0, adapter.driver(), host.driver());
    try std.testing.expectEqual(core.runtime_adapter.api.AudioState.degraded, runtime.audio.state);
    try std.testing.expectEqual(core.vm.Status.waiting, machine.status);
    var completed = false;
    for (1..250) |raw_tick| {
        if (runtime.cycle(@intCast(raw_tick), adapter.driver(), host.driver()) == .finished) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
    try expectInteger(&machine, "Done", 1);
    try std.testing.expect(runtime.resources_closed);
}

test "invalid PLAY command is a local illegal-function-call runtime error" {
    var program = try core.compiler.compile(std.testing.allocator, "bad-play.bas", "PLAY \"T31C\"\nEND\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(32, 8));
    try std.testing.expectEqual(core.vm.RuntimeCode.illegal_function_call, machine.runtime_diagnostic.?.code);
    try std.testing.expectEqual(@as(u64, 0), machine.pendingAudioFrames());
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
    async_like: bool = false,
    read_ready: bool = false,
    write_ready: bool = false,
    maximum_read_bytes: usize = std.math.maxInt(usize),
    maximum_write_bytes: usize = std.math.maxInt(usize),
    maximum_read_request: usize = 0,
    maximum_write_request: usize = 0,
    fail_next_nonempty_write: bool = false,
    arm_failure_after_partial_write: bool = false,
    failed_writes: u32 = 0,

    fn deinit(self: *MemoryFiles) void {
        self.output.deinit(std.testing.allocator);
        self.appended.deinit(std.testing.allocator);
        self.absolute_output.deinit(std.testing.allocator);
    }

    fn read(context: ?*anyopaque, path: []const u8, offset: u32, out: []u8) core.vm.FileReadResult {
        const self: *MemoryFiles = @ptrCast(@alignCast(context.?));
        self.maximum_read_request = @max(self.maximum_read_request, out.len);
        if (self.async_like and !self.read_ready) {
            self.read_ready = true;
            return .pending;
        }
        self.read_ready = false;
        self.reads += 1;
        if (!std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\input.txt")) return .{ .failure = .not_found };
        if (offset >= self.input.len) return .end;
        const count = @min(out.len, self.maximum_read_bytes, self.input.len - offset);
        @memcpy(out[0..count], self.input[offset..][0..count]);
        return .{ .bytes = @intCast(count) };
    }

    fn write(context: ?*anyopaque, path: []const u8, bytes: []const u8, append: bool) core.vm.FileWriteResult {
        const self: *MemoryFiles = @ptrCast(@alignCast(context.?));
        self.maximum_write_request = @max(self.maximum_write_request, bytes.len);
        if (self.async_like and !self.write_ready) {
            self.write_ready = true;
            return .pending;
        }
        self.write_ready = false;
        self.writes += 1;
        if (bytes.len != 0 and self.fail_next_nonempty_write) {
            self.fail_next_nonempty_write = false;
            self.failed_writes += 1;
            return .{ .failure = .path_error };
        }
        const target = if (std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\output.txt"))
            &self.output
        else if (std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\append.txt"))
            &self.appended
        else if (std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\absolute.txt"))
            &self.absolute_output
        else
            return .{ .failure = .path_error };
        if (!append) target.clearRetainingCapacity();
        const count = @min(bytes.len, self.maximum_write_bytes);
        target.appendSlice(std.testing.allocator, bytes[0..count]) catch return .{ .failure = .too_large };
        if (self.arm_failure_after_partial_write and count < bytes.len) {
            self.arm_failure_after_partial_write = false;
            self.fail_next_nonempty_write = true;
        }
        return .{ .bytes = @intCast(count) };
    }
};

const RandomFiles = struct {
    const count = 4;
    paths: [count][]const u8 = .{
        "C:\\GAMES\\random.dat",
        "C:\\GAMES\\binary.dat",
        "C:\\GAMES\\record.dat",
        "C:\\GAMES\\output.txt",
    },
    data: [count]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty },
    exists: [count]bool = .{false} ** count,
    async_like: bool = true,
    ready: bool = false,
    maximum_transfer: usize = 1,
    lock_calls: u32 = 0,

    fn deinit(self: *@This()) void {
        for (&self.data) |*bytes| bytes.deinit(std.testing.allocator);
    }

    fn index(self: *const @This(), path: []const u8) ?usize {
        for (self.paths, 0..) |candidate, i| if (std.ascii.eqlIgnoreCase(candidate, path)) return i;
        return null;
    }

    fn waitOnce(self: *@This()) bool {
        if (!self.async_like) return false;
        if (!self.ready) {
            self.ready = true;
            return true;
        }
        self.ready = false;
        return false;
    }

    fn info(context: ?*anyopaque, path: []const u8) core.vm.FileInfoResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const i = self.index(path) orelse return .{ .failure = .path_not_found };
        if (!self.exists[i]) return .missing;
        return .{ .info = .{ .size = @intCast(self.data[i].items.len) } };
    }

    fn read(context: ?*anyopaque, path: []const u8, offset: u32, out: []u8) core.vm.FileReadResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const i = self.index(path) orelse return .{ .failure = .path_not_found };
        if (!self.exists[i]) return .{ .failure = .not_found };
        if (self.waitOnce()) return .pending;
        if (offset >= self.data[i].items.len) return .end;
        const amount = @min(out.len, self.maximum_transfer, self.data[i].items.len - offset);
        @memcpy(out[0..amount], self.data[i].items[offset..][0..amount]);
        return .{ .bytes = @intCast(amount) };
    }

    fn writeAt(context: ?*anyopaque, path: []const u8, offset: u32, bytes: []const u8, create: bool) core.vm.FileWriteResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const i = self.index(path) orelse return .{ .failure = .path_not_found };
        if (self.waitOnce()) return .pending;
        if (!self.exists[i]) {
            if (!create) return .{ .failure = .not_found };
            self.exists[i] = true;
        }
        if (bytes.len == 0) return .{ .bytes = 0 };
        const amount = @min(bytes.len, self.maximum_transfer);
        const end = @as(usize, offset) + amount;
        if (self.data[i].items.len < end) {
            self.data[i].appendNTimes(std.testing.allocator, 0, end - self.data[i].items.len) catch
                return .{ .failure = .disk_full };
        }
        @memcpy(self.data[i].items[offset..end], bytes[0..amount]);
        return .{ .bytes = @intCast(amount) };
    }

    fn write(context: ?*anyopaque, path: []const u8, bytes: []const u8, append: bool) core.vm.FileWriteResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const i = self.index(path) orelse return .{ .failure = .path_not_found };
        if (self.waitOnce()) return .pending;
        if (!append) self.data[i].clearRetainingCapacity();
        self.exists[i] = true;
        const amount = @min(bytes.len, self.maximum_transfer);
        self.data[i].appendSlice(std.testing.allocator, bytes[0..amount]) catch return .{ .failure = .disk_full };
        return .{ .bytes = @intCast(amount) };
    }

    fn lock(context: ?*anyopaque, path: []const u8, _: u32, _: u32, _: bool) core.vm.FileLockResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        _ = self.index(path) orelse return .{ .failure = .path_not_found };
        if (self.waitOnce()) return .pending;
        self.lock_calls += 1;
        return .success;
    }
};

const PlatformHost = struct {
    const Entry = struct {
        path: []const u8,
        kind: core.vm.PathKind,
        exists: bool = true,
    };

    entries: [8]Entry = .{
        .{ .path = "C:\\GAMES", .kind = .directory },
        .{ .path = "C:\\GAMES\\DATA", .kind = .directory },
        .{ .path = "C:\\GAMES\\DATA\\OLD.TXT", .kind = .file },
        .{ .path = "C:\\GAMES\\DATA\\NOTE.TXT", .kind = .file },
        .{ .path = "C:\\GAMES\\DATA\\TEMP.TMP", .kind = .file },
        .{ .path = "", .kind = .file, .exists = false },
        .{ .path = "C:\\GAMES\\DATA\\KEEP.TMP", .kind = .directory },
        .{ .path = "", .kind = .file, .exists = false },
    },
    clock: core.vm.WallClock = .{
        .valid = true,
        .year = 2026,
        .month = 8,
        .day = 26,
        .weekday = 3,
        .hour = 14,
        .minute = 15,
        .second = 16,
    },
    environment_updates: u32 = 0,
    mode_fast: bool = false,
    shell_calls: u32 = 0,
    quiesce_calls: u32 = 0,

    fn find(self: *@This(), path: []const u8) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.exists and std.ascii.eqlIgnoreCase(entry.path, path)) return index;
        }
        return null;
    }

    fn info(context: ?*anyopaque, path: []const u8) core.vm.PathInfoResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index = self.find(path) orelse return .missing;
        return .{ .info = self.entries[index].kind };
    }

    fn createDirectory(context: ?*anyopaque, path: []const u8) core.vm.PathOperationResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.find(path) != null) return .{ .failure = .file_exists };
        if (!std.ascii.eqlIgnoreCase(path, "C:\\GAMES\\DATA\\NEW")) return .{ .failure = .path_not_found };
        self.entries[5] = .{ .path = "C:\\GAMES\\DATA\\NEW", .kind = .directory };
        return .success;
    }

    fn deleteDirectory(context: ?*anyopaque, path: []const u8) core.vm.PathOperationResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index = self.find(path) orelse return .missing;
        if (self.entries[index].kind != .directory) return .{ .failure = .path_error };
        self.entries[index].exists = false;
        return .success;
    }

    fn deletePath(context: ?*anyopaque, path: []const u8) core.vm.PathOperationResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index = self.find(path) orelse return .missing;
        if (self.entries[index].kind != .file) return .{ .failure = .path_error };
        self.entries[index].exists = false;
        return .success;
    }

    fn renamePath(context: ?*anyopaque, source: []const u8, target: []const u8) core.vm.PathOperationResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const index = self.find(source) orelse return .missing;
        if (self.find(target) != null) return .{ .failure = .file_exists };
        if (!std.ascii.eqlIgnoreCase(target, "C:\\GAMES\\DATA\\RENAMED.TXT")) return .{ .failure = .path_error };
        self.entries[index].path = "C:\\GAMES\\DATA\\RENAMED.TXT";
        return .success;
    }

    fn directoryRead(context: ?*anyopaque, directory: []const u8, requested: u32, out: []u8) core.vm.DirectoryReadResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        var visible: u32 = 0;
        for (self.entries) |entry| {
            if (!entry.exists or !directChild(directory, entry.path)) continue;
            if (visible != requested) {
                visible += 1;
                continue;
            }
            if (entry.path.len > out.len) return .{ .failure = .too_large };
            @memcpy(out[0..entry.path.len], entry.path);
            return .{ .entry = .{ .kind = entry.kind, .path_length = @intCast(entry.path.len) } };
        }
        return .end;
    }

    fn wall(context: ?*anyopaque) core.vm.WallClockResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return .{ .value = self.clock };
    }

    fn setWall(context: ?*anyopaque, clock: core.vm.WallClock) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.clock = clock;
        return true;
    }

    fn setEnvironment(context: ?*anyopaque, name: []const u8, value: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.environment_updates += 1;
        if (std.ascii.eqlIgnoreCase(name, "MODE")) self.mode_fast = std.mem.eql(u8, value, "FAST");
        return true;
    }

    fn shell(context: ?*anyopaque, command: []const u8) core.vm.ShellResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, command, "ECHO OK")) return .{ .failure = .path_error };
        self.shell_calls += 1;
        return if (self.shell_calls == 1) .pending else .{ .exited = 7 };
    }

    fn quiesce(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.quiesce_calls += 1;
    }

    fn directChild(directory: []const u8, path: []const u8) bool {
        if (path.len <= directory.len or !std.ascii.eqlIgnoreCase(path[0..directory.len], directory)) return false;
        var start = directory.len;
        if (directory[directory.len - 1] != '\\') {
            if (path[start] != '\\') return false;
            start += 1;
        }
        return start < path.len and std.mem.indexOfScalar(u8, path[start..], '\\') == null;
    }
};

test "R4OS path environment wall clock shell and SYSTEM semantics remain VM local" {
    const source =
        \\CHDIR "DATA"
        \\MKDIR "NEW"
        \\NAME "OLD.TXT" AS "RENAMED.TXT"
        \\FILES "*.TXT"
        \\KILL "*.TMP"
        \\ENVIRON "MODE=FAST"
        \\CommandText$ = COMMAND$
        \\BaseEnvironment$ = ENVIRON$(1)
        \\ModeEnvironment$ = ENVIRON$("mode")
        \\DateText$ = DATE$
        \\TimeText$ = TIME$
        \\TimerValue! = TIMER
        \\DATE$ = "02/29/2028"
        \\TIME$ = "23:59:58"
        \\SHELL "ECHO OK"
        \\SYSTEM
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\PLATFORM.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var platform = PlatformHost{};
    const initial_environment = [_]core.vm.EnvironmentInput{.{ .name = "BASE", .value = "ONE" }};
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .platform_context = &platform,
        .path_info = PlatformHost.info,
        .path_delete = PlatformHost.deletePath,
        .path_rename = PlatformHost.renamePath,
        .directory_create = PlatformHost.createDirectory,
        .directory_delete = PlatformHost.deleteDirectory,
        .directory_read = PlatformHost.directoryRead,
        .wall_clock = PlatformHost.wall,
        .wall_clock_set = PlatformHost.setWall,
        .environment_set = PlatformHost.setEnvironment,
        .shell = PlatformHost.shell,
        .platform_quiesce = PlatformHost.quiesce,
        .guest_directory = "C:\\GAMES",
        .command_line = "  /quiet Mixed Case",
        .initial_environment = &initial_environment,
    });
    defer machine.deinit();
    var final_status = core.vm.Status.ready;
    for (0..64) |cycle| {
        machine.setGuestTime(@as(u64, @intCast(cycle)) * std.time.ns_per_ms);
        const result = machine.runSlice(4096);
        final_status = result.status;
        if (result.status == .halted or result.status == .runtime_error) break;
    }
    try std.testing.expectEqual(core.vm.Status.halted, final_status);
    try expectString(&machine, "CommandText$", "  /quiet Mixed Case");
    try expectString(&machine, "BaseEnvironment$", "BASE=ONE");
    try expectString(&machine, "ModeEnvironment$", "FAST");
    try expectString(&machine, "DateText$", "08-26-2026");
    try expectString(&machine, "TimeText$", "14:15:16");
    try std.testing.expect(machine.global("TimerValue!").?.single >= 51_316 and machine.global("TimerValue!").?.single < 51_317);
    try std.testing.expect(platform.find("C:\\GAMES\\DATA\\NEW") != null);
    try std.testing.expect(platform.find("C:\\GAMES\\DATA\\RENAMED.TXT") != null);
    try std.testing.expect(platform.find("C:\\GAMES\\DATA\\TEMP.TMP") == null);
    try std.testing.expect(platform.find("C:\\GAMES\\DATA\\KEEP.TMP") != null);
    try std.testing.expect(platform.mode_fast);
    try std.testing.expectEqual(@as(u16, 2028), platform.clock.year);
    try std.testing.expectEqual(@as(u8, 2), platform.clock.month);
    try std.testing.expectEqual(@as(u8, 29), platform.clock.day);
    try std.testing.expectEqual(@as(u8, 23), platform.clock.hour);
    try std.testing.expectEqual(@as(u8, 59), platform.clock.minute);
    try std.testing.expectEqual(@as(u8, 58), platform.clock.second);
    try std.testing.expectEqual(@as(u32, 2), platform.shell_calls);
    try std.testing.expect(platform.quiesce_calls >= 1);
}

test "platform syntax rejects invalid clocks environment and escaping paths with QuickBASIC errors" {
    const cases = [_]struct {
        source: []const u8,
        code: core.vm.RuntimeCode,
        number: i32,
    }{
        .{ .source = "DATE$ = \"02/30/2028\"\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "TIME$ = \"24:00:00\"\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "ENVIRON \"MISSING\"\n", .code = .illegal_function_call, .number = 5 },
        .{ .source = "CHDIR \"..\\..\\..\"\n", .code = .path_file_access, .number = 75 },
        .{ .source = "MKDIR \"CON\"\n", .code = .bad_file_name, .number = 64 },
        .{ .source = "RMDIR \"C:\\GAMES\\DATA\"\n", .code = .path_file_access, .number = 75 },
        .{ .source = "NAME \"C:\\GAMES\\DATA\\OLD.TXT\" AS \"D:\\OLD.TXT\"\n", .code = .path_file_access, .number = 75 },
    };
    for (cases, 0..) |case, index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "C:\\GAMES\\INVALID{d}.BAS", .{index});
        var program = try core.compiler.compile(std.testing.allocator, name, case.source);
        defer program.deinit();
        try expectProgramOk(&program);
        var platform = PlatformHost{};
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
            .platform_context = &platform,
            .path_info = PlatformHost.info,
            .directory_create = PlatformHost.createDirectory,
            .wall_clock = PlatformHost.wall,
            .wall_clock_set = PlatformHost.setWall,
            .environment_set = PlatformHost.setEnvironment,
            .guest_directory = "C:\\GAMES\\DATA",
        });
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(64, 8));
        const diagnostic = machine.runtime_diagnostic orelse return error.MissingPlatformDiagnostic;
        try std.testing.expectEqual(case.code, diagnostic.code);
        try std.testing.expectEqual(case.number, diagnostic.qbasicErrorNumber());
    }
}

test "two VM environments isolate mutations and reset to their injected state" {
    const source =
        \\Before$ = ENVIRON$("MODE")
        \\BeforeIndex$ = ENVIRON$(1)
        \\ENVIRON "MODE=CHANGED"
        \\After$ = ENVIRON$("MODE")
        \\AfterIndex$ = ENVIRON$(1)
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\ENV.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    const environment_a = [_]core.vm.EnvironmentInput{
        .{ .name = "MODE", .value = "ONE" },
        .{ .name = "KEEP", .value = "A" },
    };
    const environment_b = [_]core.vm.EnvironmentInput{
        .{ .name = "MODE", .value = "TWO" },
        .{ .name = "KEEP", .value = "B" },
    };
    var platform_a = PlatformHost{};
    var platform_b = PlatformHost{};
    var machine_a = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .platform_context = &platform_a,
        .environment_set = PlatformHost.setEnvironment,
        .initial_environment = &environment_a,
    });
    defer machine_a.deinit();
    var machine_b = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .platform_context = &platform_b,
        .environment_set = PlatformHost.setEnvironment,
        .initial_environment = &environment_b,
    });
    defer machine_b.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine_a.runToCompletion(64, 8));
    try std.testing.expectEqual(core.vm.Status.halted, machine_b.runToCompletion(64, 8));
    try expectString(&machine_a, "Before$", "ONE");
    try expectString(&machine_b, "Before$", "TWO");
    try expectString(&machine_a, "BeforeIndex$", "MODE=ONE");
    try expectString(&machine_b, "BeforeIndex$", "MODE=TWO");
    try expectString(&machine_a, "After$", "CHANGED");
    try expectString(&machine_b, "After$", "CHANGED");
    try expectString(&machine_a, "AfterIndex$", "MODE=CHANGED");
    try expectString(&machine_b, "AfterIndex$", "MODE=CHANGED");
    try machine_a.reset();
    try std.testing.expectEqual(core.vm.Status.halted, machine_a.runToCompletion(64, 8));
    try expectString(&machine_a, "Before$", "ONE");
}

test "TIMER follows wall-day midnight while retaining monotone subsecond pacing" {
    const ClockSequence = struct {
        calls: u8 = 0,

        fn wall(context: ?*anyopaque) core.vm.WallClockResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const before_midnight = self.calls == 0;
            self.calls += 1;
            return .{ .value = .{
                .valid = true,
                .year = 2026,
                .month = 12,
                .day = if (before_midnight) 31 else 1,
                .weekday = if (before_midnight) 4 else 5,
                .hour = if (before_midnight) 23 else 0,
                .minute = if (before_midnight) 59 else 0,
                .second = if (before_midnight) 59 else 0,
            } };
        }
    };
    var program = try core.compiler.compile(
        std.testing.allocator,
        "C:\\GAMES\\MIDNIGHT.BAS",
        "Before! = TIMER\nAfter! = TIMER\nEND\n",
    );
    defer program.deinit();
    try expectProgramOk(&program);
    var clock = ClockSequence{};
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .platform_context = &clock,
        .wall_clock = ClockSequence.wall,
    });
    defer machine.deinit();
    machine.setGuestTime(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 8));
    try std.testing.expectApproxEqAbs(@as(f32, 86_399.5), machine.global("Before!").?.single, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), machine.global("After!").?.single, 0.01);
}

test "RUN restarts locally and path RUN requests one same-host transition" {
    const local_source =
        \\A = 1
        \\RUN 100
        \\A = 99
        \\END
        \\100 B = 42
        \\END
    ;
    var local_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\LOCALRUN.BAS", local_source);
    defer local_program.deinit();
    try expectProgramOk(&local_program);
    var local_machine = try core.vm.Vm.init(std.testing.allocator, &local_program, .{});
    defer local_machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, local_machine.runToCompletion(128, 16));
    try expectSingle(&local_machine, "A", 0);
    try expectSingle(&local_machine, "B", 42);

    var path_program = try core.compiler.compile(
        std.testing.allocator,
        "C:\\GAMES\\PATHRUN.BAS",
        "RUN \"NEXT.BAS\"\n",
    );
    defer path_program.deinit();
    try expectProgramOk(&path_program);
    var path_machine = try core.vm.Vm.init(std.testing.allocator, &path_program, .{});
    defer path_machine.deinit();
    try std.testing.expectEqual(core.vm.Status.transition, path_machine.runToCompletion(64, 8));
    var transition = path_machine.takeTransition() orelse return error.MissingRunTransition;
    defer transition.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.vm.TransitionKind.run, transition.kind);
    try std.testing.expectEqualStrings("C:\\GAMES\\NEXT.BAS", transition.path);
}

test "CHAIN transfers COMMON arrays and ALL values with explicit DELETE metadata" {
    const source =
        \\COMMON Shared&, Names$()
        \\DIM Names$(1)
        \\Shared& = 42
        \\Names$(0) = "ALPHA"
        \\Names$(1) = "BETA"
        \\Local& = 7
        \\CHAIN "NEXT.BAS", ALL, DELETE 100-200
    ;
    const target_source =
        \\COMMON Shared&, Names$()
        \\CopiedShared& = Shared&
        \\CopiedFirst$ = Names$(0)
        \\CopiedSecond$ = Names$(1)
        \\CopiedLocal& = Local&
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\CHAIN1.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.transition, machine.runToCompletion(256, 16));
    var transition = machine.takeTransition() orelse return error.MissingChainTransition;
    defer transition.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.vm.TransitionKind.chain, transition.kind);
    try std.testing.expect(transition.preserve_all);
    try std.testing.expect(transition.delete_enabled);
    try std.testing.expectEqual(@as(u16, 100), transition.delete_first);
    try std.testing.expectEqual(@as(u16, 200), transition.delete_last);

    var target_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\NEXT.BAS", target_source);
    defer target_program.deinit();
    try expectProgramOk(&target_program);
    var target_machine = try core.vm.Vm.init(std.testing.allocator, &target_program, .{});
    defer target_machine.deinit();
    try machine.transferCommonTo(&target_machine, transition.preserve_all);
    try std.testing.expectEqual(core.vm.Status.halted, target_machine.runToCompletion(256, 16));
    try expectLong(&target_machine, "CopiedShared&", 42);
    try expectString(&target_machine, "CopiedFirst$", "ALPHA");
    try expectString(&target_machine, "CopiedSecond$", "BETA");
    try expectLong(&target_machine, "CopiedLocal&", 7);
}

test "RANDOM BINARY FIELD GET PUT SEEK metadata and locks preserve partial transfers" {
    const source =
        \\TYPE RowType
        \\  Code AS LONG
        \\  Label AS STRING * 4
        \\END TYPE
        \\DEFINT A-Z
        \\F = FREEFILE
        \\OPEN "random.dat" FOR RANDOM ACCESS READ WRITE AS #F LEN = 8
        \\FIELD #F, 2 AS FL$, 6 AS FR$
        \\LSET FL$ = "AB"
        \\RSET FR$ = "Z"
        \\PUT #F, 1
        \\LSET FL$ = "XX"
        \\LSET FR$ = "YYYYYY"
        \\GET #F, 1
        \\SavedLeft$ = FL$
        \\SavedRight$ = FR$
        \\RandomLoc& = LOC(F)
        \\RandomSeek& = SEEK(F)
        \\RandomLen& = LOF(F)
        \\RandomMode = FILEATTR(F, 1)
        \\RandomSlot = FILEATTR(F, 2)
        \\LOCK #F, 1 TO 1
        \\UNLOCK #F, 1 TO 1
        \\CLOSE #F
        \\Released = LEN(FL$)
        \\B = FREEFILE
        \\OPEN "binary.dat" FOR BINARY ACCESS READ WRITE AS #B
        \\Number& = 305419896&
        \\PUT #B, 1, Number&
        \\SEEK #B, 9
        \\Text$ = "ABCD"
        \\PUT #B, , Text$
        \\BinaryLen& = LOF(B)
        \\SEEK #B, 1
        \\Number& = 0
        \\GET #B, , Number&
        \\SEEK #B, 9
        \\Text$ = SPACE$(4)
        \\GET #B, , Text$
        \\SEEK #B, 9
        \\BinaryInput$ = INPUT$(4, #B)
        \\BinaryAfter& = SEEK(B)
        \\BinaryLoc& = LOC(B)
        \\CLOSE #B
        \\OPEN "B", #4, "binary.dat"
        \\SEEK #4, 9
        \\LegacyInput$ = INPUT$(4, #4)
        \\CLOSE #4
        \\DIM Row AS RowType
        \\OPEN "record.dat" FOR RANDOM AS #3 LEN = 8
        \\Row.Code = 42
        \\Row.Label = "OK"
        \\PUT #3, 2, Row
        \\Row.Code = 0
        \\Row.Label = ""
        \\GET #3, 2, Row
        \\LoadedCode& = Row.Code
        \\LoadedName$ = Row.Label
        \\CLOSE #3
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\RANDOMIO.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var files = RandomFiles{};
    defer files.deinit();
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &files,
        .file_read = RandomFiles.read,
        .file_write_at = RandomFiles.writeAt,
        .file_info = RandomFiles.info,
        .file_lock = RandomFiles.lock,
    });
    defer machine.deinit();
    try std.testing.expect((try runFileIoCooperatively(&machine, 2048)) != 0);
    try expectString(&machine, "SavedLeft$", "AB");
    try expectString(&machine, "SavedRight$", "     Z");
    try expectLong(&machine, "RandomLoc&", 1);
    try expectLong(&machine, "RandomSeek&", 2);
    try expectLong(&machine, "RandomLen&", 8);
    try expectInteger(&machine, "RandomMode", 4);
    try expectInteger(&machine, "RandomSlot", 1);
    try expectInteger(&machine, "Released", 0);
    try expectLong(&machine, "Number&", 0x12345678);
    try expectString(&machine, "Text$", "ABCD");
    try expectString(&machine, "BinaryInput$", "ABCD");
    try expectLong(&machine, "BinaryAfter&", 13);
    try expectLong(&machine, "BinaryLen&", 12);
    try expectLong(&machine, "BinaryLoc&", 12);
    try expectString(&machine, "LegacyInput$", "ABCD");
    try expectLong(&machine, "LoadedCode&", 42);
    try expectString(&machine, "LoadedName$", "OK  ");
    try std.testing.expect(files.lock_calls >= 2);
    try std.testing.expectEqual(@as(usize, 0), machine.openFileCount());
}

test "BINARY whole-array transfers cross the exact 64 KiB boundary resumably" {
    const source =
        \\DIM Blob&(16383)
        \\Blob&(0) = 123456&
        \\Blob&(16383) = 654321&
        \\OPEN "binary.dat" FOR BINARY ACCESS READ WRITE AS #1
        \\PUT #1, 1, Blob&()
        \\BoundaryLen& = LOF(1)
        \\Blob&(0) = 0
        \\Blob&(16383) = 0
        \\GET #1, 1, Blob&()
        \\First& = Blob&(0)
        \\Last& = Blob&(16383)
        \\CLOSE #1
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\BOUNDARY.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var files = RandomFiles{ .maximum_transfer = 257 };
    defer files.deinit();
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &files,
        .file_read = RandomFiles.read,
        .file_write_at = RandomFiles.writeAt,
        .file_info = RandomFiles.info,
        .file_lock = RandomFiles.lock,
    });
    defer machine.deinit();
    const waiting = try runFileIoCooperatively(&machine, 4096);
    try std.testing.expect(waiting != 0);
    try expectLong(&machine, "BoundaryLen&", 64 * 1024);
    try expectLong(&machine, "First&", 123456);
    try expectLong(&machine, "Last&", 654321);
    try std.testing.expectEqual(@as(usize, 64 * 1024), files.data[1].items.len);
}

test "sequential SEEK overwrites exact offsets and APPEND begins after EOF" {
    const source =
        \\OPEN "output.txt" FOR OUTPUT AS #1
        \\PRINT #1, "ABCDE";
        \\SEEK #1, 3
        \\PRINT #1, "xy";
        \\Position& = SEEK(1)
        \\Length& = LOF(1)
        \\CLOSE #1
        \\OPEN "output.txt" FOR APPEND AS #1
        \\AppendStart& = SEEK(1)
        \\PRINT #1, "Z";
        \\FinalLength& = LOF(1)
        \\CLOSE #1
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\POSITION.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var files = RandomFiles{ .maximum_transfer = 2 };
    defer files.deinit();
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &files,
        .file_read = RandomFiles.read,
        .file_write = RandomFiles.write,
        .file_write_at = RandomFiles.writeAt,
        .file_info = RandomFiles.info,
        .file_lock = RandomFiles.lock,
    });
    defer machine.deinit();
    _ = try runFileIoCooperatively(&machine, 1024);
    try expectLong(&machine, "Position&", 5);
    try expectLong(&machine, "Length&", 5);
    try expectLong(&machine, "AppendStart&", 6);
    try expectLong(&machine, "FinalLength&", 6);
    try std.testing.expectEqualStrings("ABxyEZ", files.data[3].items);
}

test "RANDOM record diagnostics remain catchable across RESUME labels" {
    const source =
        \\DEFINT A-Z
        \\ON ERROR GOTO Handler
        \\OPEN "random.dat" FOR RANDOM AS #1 LEN = 8
        \\Stage = 1
        \\FIELD #1, 9 AS F$
        \\AfterOverflow:
        \\FIELD #1, 8 AS F$
        \\Value& = 1
        \\Stage = 2
        \\GET #1, 1, Value&
        \\AfterActive:
        \\RESET
        \\OPEN "random.dat" FOR RANDOM AS #1 LEN = 8
        \\Stage = 3
        \\PUT #1, 1, Value&
        \\AfterLength:
        \\Stage = 4
        \\SEEK #1, 0
        \\AfterRecord:
        \\CLOSE #1
        \\END
        \\Handler:
        \\IF Stage = 1 THEN OverflowError = ERR: RESUME AfterOverflow
        \\IF Stage = 2 THEN ActiveError = ERR: RESUME AfterActive
        \\IF Stage = 3 THEN LengthError = ERR: RESUME AfterLength
        \\IF Stage = 4 THEN RecordError = ERR: RESUME AfterRecord
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\RECORDERR.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var files = RandomFiles{};
    defer files.deinit();
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &files,
        .file_read = RandomFiles.read,
        .file_write_at = RandomFiles.writeAt,
        .file_info = RandomFiles.info,
        .file_lock = RandomFiles.lock,
    });
    defer machine.deinit();
    _ = try runFileIoCooperatively(&machine, 2048);
    try expectInteger(&machine, "OverflowError", 50);
    try expectInteger(&machine, "ActiveError", 56);
    try expectInteger(&machine, "LengthError", 59);
    try expectInteger(&machine, "RecordError", 63);
}

test "storage facade faults retain catchable QuickBASIC file numbers" {
    const FaultFiles = struct {
        failure: core.vm.FileHostError,
        exists: bool,

        fn info(context: ?*anyopaque, _: []const u8) core.vm.FileInfoResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return if (self.exists) .{ .info = .{ .size = 0 } } else .missing;
        }

        fn writeAt(context: ?*anyopaque, _: []const u8, _: u32, _: []const u8, _: bool) core.vm.FileWriteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return .{ .failure = self.failure };
        }

        fn lock(context: ?*anyopaque, _: []const u8, _: u32, _: u32, _: bool) core.vm.FileLockResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return .{ .failure = self.failure };
        }
    };
    const create_source =
        \\DEFINT A-Z
        \\ON ERROR GOTO Handler
        \\OPEN "fault.dat" FOR BINARY AS #1
        \\Missed = 1
        \\END
        \\Handler:
        \\Caught = ERR
        \\RESUME Done
        \\Done:
        \\END
    ;
    const lock_source =
        \\DEFINT A-Z
        \\ON ERROR GOTO Handler
        \\OPEN "fault.dat" FOR RANDOM LOCK WRITE AS #1 LEN = 8
        \\Missed = 1
        \\END
        \\Handler:
        \\Caught = ERR
        \\RESUME Done
        \\Done:
        \\END
    ;
    const cases = [_]struct { failure: core.vm.FileHostError, exists: bool, expected: i16, source: []const u8 }{
        .{ .failure = .file_exists, .exists = false, .expected = 58, .source = create_source },
        .{ .failure = .disk_full, .exists = false, .expected = 61, .source = create_source },
        .{ .failure = .too_many_files, .exists = false, .expected = 67, .source = create_source },
        .{ .failure = .path_not_found, .exists = false, .expected = 76, .source = create_source },
        .{ .failure = .lock_violation, .exists = true, .expected = 70, .source = lock_source },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\HOSTERR.BAS", case.source);
        defer program.deinit();
        try expectProgramOk(&program);
        var files = FaultFiles{ .failure = case.failure, .exists = case.exists };
        var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
            .file_context = &files,
            .file_write_at = FaultFiles.writeAt,
            .file_info = FaultFiles.info,
            .file_lock = FaultFiles.lock,
        });
        defer machine.deinit();
        try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
        try expectInteger(&machine, "Caught", case.expected);
        try expectInteger(&machine, "Missed", 0);
    }
}

test "VM reset and teardown quiesce file bindings before releasing state" {
    const Probe = struct {
        calls: u32 = 0,

        fn quiesce(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
        }
    };

    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\QUIESCE.BAS", "END\n");
    defer program.deinit();
    try expectProgramOk(&program);
    var probe = Probe{};
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &probe,
        .file_quiesce = Probe.quiesce,
    });
    try machine.reset();
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    machine.deinit();
    try std.testing.expectEqual(@as(u32, 2), probe.calls);
}

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
    const counters = machine.performanceStats();
    try std.testing.expectEqual(@as(usize, 0), machine.openFileCount());
    try std.testing.expectEqual(@as(usize, 256), machine.fileIndexByteSize());
    try std.testing.expect(machine.staticByteSize() < 16 * 1024);
    try std.testing.expect(counters.file_table_capacity_grows != 0);
    try std.testing.expect(counters.maximum_open_files != 0);
}

test "PRINT USING WRITE and INPUT dollar use one file format and round-trip through INPUT number" {
    const writer_source =
        \\OPEN "output.txt" FOR OUTPUT AS #1
        \\PRINT #1, USING "##.##"; .78
        \\WRITE #1, "A," + CHR$(34) + "B", -1E-13, 42
        \\CLOSE #1
        \\END
    ;
    var writer_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\WRITER.BAS", writer_source);
    defer writer_program.deinit();
    try expectProgramOk(&writer_program);
    var files = MemoryFiles{};
    defer files.deinit();
    var writer = try core.vm.Vm.init(std.testing.allocator, &writer_program, .{
        .file_context = &files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer writer.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, writer.runToCompletion(256, 32));
    try std.testing.expectEqualStrings(" 0.78\r\n\"A,\"\"B\",-1E-13,42\r\n", files.output.items);

    const reader_source =
        \\DEFINT A-Z
        \\OPEN "input.txt" FOR INPUT AS #1
        \\LINE INPUT #1, Formatted$
        \\INPUT #1, Text$, Tiny!, Whole
        \\CLOSE #1
        \\END
    ;
    var reader_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\READER.BAS", reader_source);
    defer reader_program.deinit();
    try expectProgramOk(&reader_program);
    files.input = files.output.items;
    var reader = try core.vm.Vm.init(std.testing.allocator, &reader_program, .{
        .file_context = &files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer reader.deinit();
    _ = try runFileIoCooperatively(&reader, 64);
    try expectString(&reader, "Formatted$", " 0.78");
    try expectString(&reader, "Text$", "A,\"B");
    try expectSingle(&reader, "Tiny!", -1.0e-13);
    try expectInteger(&reader, "Whole", 42);

    var raw_files = MemoryFiles{ .input = "ABCDE" };
    defer raw_files.deinit();
    const raw_source =
        \\OPEN "input.txt" FOR INPUT AS #1
        \\First$ = INPUT$(3, #1)
        \\Second$ = INPUT$(2, 1)
        \\CLOSE #1
        \\END
    ;
    var raw_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\RAW.BAS", raw_source);
    defer raw_program.deinit();
    try expectProgramOk(&raw_program);
    var raw = try core.vm.Vm.init(std.testing.allocator, &raw_program, .{
        .file_context = &raw_files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer raw.deinit();
    _ = try runFileIoCooperatively(&raw, 64);
    try expectString(&raw, "First$", "ABC");
    try expectString(&raw, "Second$", "DE");
}

test "sequential files stream one byte through four MiB with bounded asynchronous batches" {
    const one_byte_source =
        \\DEFINT A-Z
        \\OPEN "input.txt" FOR INPUT AS #1
        \\LINE INPUT #1, Value$
        \\AtEnd = EOF(1)
        \\CLOSE #1
        \\END
    ;
    var one_byte_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\ONE.BAS", one_byte_source);
    defer one_byte_program.deinit();
    try expectProgramOk(&one_byte_program);
    var one_byte_files = MemoryFiles{ .input = "Z", .async_like = true };
    defer one_byte_files.deinit();
    var one_byte_machine = try core.vm.Vm.init(std.testing.allocator, &one_byte_program, .{
        .file_context = &one_byte_files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer one_byte_machine.deinit();
    try std.testing.expect((try runFileIoCooperatively(&one_byte_machine, 128)) != 0);
    try expectString(&one_byte_machine, "Value$", "Z");
    try expectInteger(&one_byte_machine, "AtEnd", -1);
    try std.testing.expectEqual(@as(u32, 2), one_byte_files.reads);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    var remaining = core.vm.maximum_sequential_file_bytes;
    var expected_lines: i32 = 0;
    while (remaining != 0) {
        const payload = @min(@as(usize, 30_000), remaining - 2);
        try input.appendNTimes(std.testing.allocator, ' ', payload);
        try input.appendSlice(std.testing.allocator, "\r\n");
        remaining -= payload + 2;
        expected_lines += 1;
    }
    try std.testing.expectEqual(core.vm.maximum_sequential_file_bytes, input.items.len);

    const large_source =
        \\DEFINT A-Z
        \\OPEN "input.txt" FOR INPUT AS #1
        \\DO WHILE NOT EOF(1)
        \\LINE INPUT #1, Row$
        \\Lines& = Lines& + 1
        \\Bytes& = Bytes& + LEN(Row$)
        \\LOOP
        \\CLOSE #1
        \\OPEN "output.txt" FOR OUTPUT AS #2
        \\FOR I = 1 TO 128
        \\PRINT #2, SPACE$(32766); CHR$(13); CHR$(10);
        \\NEXT I
        \\Done = 1
        \\END
    ;
    var large_program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\LARGE.BAS", large_source);
    defer large_program.deinit();
    try expectProgramOk(&large_program);
    var large_files = MemoryFiles{
        .input = input.items,
        .async_like = true,
        .maximum_write_bytes = 4096,
    };
    defer large_files.deinit();
    var large_machine = try core.vm.Vm.init(std.testing.allocator, &large_program, .{
        .file_context = &large_files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer large_machine.deinit();
    const waiting_cycles = try runFileIoCooperatively(&large_machine, 20_000);
    try std.testing.expect(waiting_cycles > 1000);
    try expectInteger(&large_machine, "Done", 1);
    try expectLong(&large_machine, "Lines&", expected_lines);
    try expectLong(
        &large_machine,
        "Bytes&",
        @intCast(core.vm.maximum_sequential_file_bytes - @as(usize, @intCast(expected_lines)) * 2),
    );
    try std.testing.expectEqual(core.vm.maximum_sequential_file_bytes, large_files.output.items.len);
    var output_offset: usize = 0;
    for (0..128) |_| {
        for (large_files.output.items[output_offset .. output_offset + 32_766]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
        output_offset += 32_766;
        try std.testing.expectEqualStrings("\r\n", large_files.output.items[output_offset .. output_offset + 2]);
        output_offset += 2;
    }
    try std.testing.expectEqual(large_files.output.items.len, output_offset);
    try std.testing.expectEqual(@as(u32, 65), large_files.reads);
    try std.testing.expectEqual(core.vm.sequential_file_transfer_bytes, large_files.maximum_read_request);
    try std.testing.expect(large_files.maximum_write_request <= core.vm.sequential_file_transfer_bytes);
    const stats = large_machine.performanceStats();
    try std.testing.expectEqual(@as(u64, 64), stats.file_input_refills);
    try std.testing.expectEqual(@as(u64, 1024), stats.file_output_flushes);
    try std.testing.expect(stats.file_input_compaction_bytes != 0);
    try std.testing.expect(stats.maximum_file_input_buffer_bytes <= 2 * core.vm.sequential_file_transfer_bytes);
    try std.testing.expect(stats.maximum_file_output_buffer_bytes <= core.vm.sequential_file_transfer_bytes);
    try std.testing.expect(stats.file_io_waits > 1000);
}

test "failed CLOSE keeps sparse file slots retryable and moved indices valid" {
    const source =
        \\DEFINT A-Z
        \\ON ERROR GOTO Handler
        \\OPEN "output.txt" FOR OUTPUT AS #1
        \\OPEN "append.txt" FOR APPEND AS #255
        \\PRINT #1, "first";
        \\PRINT #255, "second";
        \\CLOSE #1
        \\CLOSE #255
        \\Done = 1
        \\END
        \\Handler:
        \\Failure = 1
        \\RESUME
    ;
    var program = try core.compiler.compile(std.testing.allocator, "C:\\GAMES\\ATOMIC.BAS", source);
    defer program.deinit();
    try expectProgramOk(&program);
    var files = MemoryFiles{
        .maximum_write_bytes = 2,
        .arm_failure_after_partial_write = true,
    };
    defer files.deinit();
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .file_context = &files,
        .file_read = MemoryFiles.read,
        .file_write = MemoryFiles.write,
    });
    defer machine.deinit();

    _ = try runFileIoCooperatively(&machine, 128);
    try expectInteger(&machine, "Done", 1);
    try std.testing.expect(machine.global("Failure").?.integer != 0);
    try std.testing.expectEqual(@as(u32, 1), files.failed_writes);
    try std.testing.expectEqualStrings("first", files.output.items);
    try std.testing.expectEqualStrings("second", files.appended.items);
    try std.testing.expectEqual(@as(usize, 0), machine.openFileCount());
    try std.testing.expectEqual(@as(u64, 2), machine.performanceStats().maximum_open_files);
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

fn runFileIoCooperatively(machine: *core.vm.Vm, maximum_cycles: usize) !u64 {
    var waiting_cycles: u64 = 0;
    for (0..maximum_cycles) |cycle| {
        machine.setGuestTime(@as(u64, @intCast(cycle)) * std.time.ns_per_ms);
        const result = machine.runSlice(4096);
        switch (result.status) {
            .waiting => waiting_cycles += 1,
            .yielded, .ready => {},
            .halted => return waiting_cycles,
            .cancelled => return error.FileIoCancelled,
            .runtime_error => return error.FileIoRuntimeError,
            .transition => return error.UnexpectedProgramTransition,
        }
    }
    return error.FileIoDidNotFinish;
}

fn validateCatalogTarget(
    identifiers: *std.StringHashMap(void),
    target: core.conformance.Target,
) !void {
    try std.testing.expect(target.id.len != 0);
    try std.testing.expect(target.name.len != 0);
    try std.testing.expect(target.semantics.len != 0);
    try std.testing.expect(target.delivery.len != 0);
    try std.testing.expect(!identifiers.contains(target.id));
    try identifiers.put(target.id, {});
}

fn expectTargetImplemented(target: core.conformance.Target) !void {
    try std.testing.expectEqual(core.conformance.Status.implemented, target.lexer);
    try std.testing.expectEqual(core.conformance.Status.implemented, target.syntax);
    try std.testing.expectEqual(core.conformance.Status.implemented, target.binder);
    try std.testing.expectEqual(core.conformance.Status.implemented, target.vm);
    try std.testing.expectEqual(core.conformance.Status.implemented, target.errors);
    try std.testing.expectEqual(core.conformance.Status.implemented, target.coverage);
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

fn appendSource(target: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    var storage: [160]u8 = undefined;
    const text = try std.fmt.bufPrint(storage[0..], format, args);
    try target.appendSlice(std.testing.allocator, text);
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

fn expectSingleBits(machine: *const core.vm.Vm, name: []const u8, expected: f32) !void {
    const actual = machine.global(name) orelse return error.MissingGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.single, actual.valueType());
    try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual.single)));
}

fn randomVector(state: u32) f32 {
    return @as(f32, @floatFromInt(state)) / 16_777_216.0;
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

fn expectScreenRow(machine: *const core.vm.Vm, row: usize, expected: []const u8) !void {
    var bytes: [core.text_screen.columns]u8 = undefined;
    try std.testing.expect(machine.textScreen().copyRow(row, &bytes));
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, &bytes, " "));
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

fn expectScopeResults(machine: *const core.vm.Vm) !void {
    try std.testing.expectEqual(@as(i16, 1), machine.globalArrayElement("AutoResults", &.{1}).?.integer);
    try std.testing.expectEqual(@as(i16, 1), machine.globalArrayElement("AutoResults", &.{2}).?.integer);
    try std.testing.expectEqual(@as(i16, 1), machine.globalArrayElement("StaticResults", &.{1}).?.integer);
    try std.testing.expectEqual(@as(i16, 2), machine.globalArrayElement("StaticResults", &.{2}).?.integer);
    try std.testing.expectEqual(@as(i16, 1), machine.globalArrayElement("SelectedResults", &.{1}).?.integer);
    try std.testing.expectEqual(@as(i16, 2), machine.globalArrayElement("SelectedResults", &.{2}).?.integer);
    try expectInteger(machine, "SharedCounter", 41);
    try expectLong(machine, "CommonCounter", 51);
    try expectInteger(machine, "Recursive", 10);
    try expectInteger(machine, "StaticRecursiveFirst", 3);
    try expectInteger(machine, "StaticRecursiveSecond", 5);
}

fn containsCompileDiagnostic(diagnostics: []const core.bytecode.Diagnostic, expected: core.bytecode.DiagnosticCode) bool {
    for (diagnostics) |diagnostic| if (diagnostic.code == expected) return true;
    return false;
}

fn containsFrontendDiagnostic(diagnostics: []const core.bytecode.Diagnostic, expected: core.frontend.DiagnosticCode) bool {
    for (diagnostics) |diagnostic| if (diagnostic.frontend_code == expected) return true;
    return false;
}

fn hasIntegerConstant(constants: []const core.bytecode.Constant, expected: i16) bool {
    for (constants) |constant| switch (constant) {
        .integer => |value| if (value == expected) return true,
        else => {},
    };
    return false;
}

fn hasLongConstant(constants: []const core.bytecode.Constant, expected: i32) bool {
    for (constants) |constant| switch (constant) {
        .long => |value| if (value == expected) return true,
        else => {},
    };
    return false;
}

fn hasSingleConstant(constants: []const core.bytecode.Constant, expected: f32) bool {
    for (constants) |constant| switch (constant) {
        .single => |value| if (value == expected) return true,
        else => {},
    };
    return false;
}

fn hasDoubleConstant(constants: []const core.bytecode.Constant, expected: f64) bool {
    for (constants) |constant| switch (constant) {
        .double => |value| if (value == expected) return true,
        else => {},
    };
    return false;
}
