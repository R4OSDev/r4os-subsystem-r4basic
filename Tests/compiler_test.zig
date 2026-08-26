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

    try std.testing.expectEqual(
        core.conformance.part1_count + core.conformance.part2_count +
            core.conformance.metacommand_count + core.conformance.runtime_error_count,
        identifiers.count(),
    );
}

test "unimplemented statements stop at catalog-addressed compile diagnostics" {
    const cases = [_]struct { source: []const u8, id: []const u8 }{
        .{ .source = "ERROR 5\nEND\n", .id = "QB45-P2-050" },
        .{ .source = "SHARED Value\nEND\n", .id = "QB45-P2-153" },
        .{ .source = "STATIC Value\nEND\n", .id = "QB45-P2-161" },
    };
    for (cases) |case| {
        var program = try core.compiler.compile(std.testing.allocator, "not-yet.bas", case.source);
        defer program.deinit();
        try std.testing.expect(!program.ok());
        try std.testing.expect(program.diagnostics.len != 0);
        try std.testing.expectEqual(core.bytecode.DiagnosticCode.unsupported_core_feature, program.diagnostics[0].code);
        try std.testing.expectEqualStrings(case.id, program.diagnostics[0].catalog_id);
    }
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
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(core.bytecode.InstructionMetadata));
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
    try std.testing.expect(dense_program.compile_stats.program_bytes <= 8 * 1024 * 1024);
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
        adapter.handleInput(.{ .key_down = .{ .code = 27, .modifiers = 0, .tick = 5, .sequence = 5 } }).reason,
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
