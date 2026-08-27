const std = @import("std");
const core = @import("core");

const cpu_source =
    \\DEFINT A-Z
    \\A = 0
    \\Again:
    \\A = A + 1
    \\IF A < 30000 THEN GOTO Again
    \\END
;

test "runnable BASIC consumes the bounded runtime budget without a fixed sleep" {
    var program = try core.compiler.compile(std.testing.allocator, "cpu-benchmark.bas", cpu_source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var cancel_probe = CancelProbe{};
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{
        .context = &cancel_probe,
        .should_cancel = CancelProbe.check,
    });
    defer machine.deinit();
    var clock = SteadyClock{};
    var adapter = core.runtime_adapter.Adapter.initTimed(&machine, .{
        .context = &clock,
        .ticks_fn = SteadyClock.read,
        .frequency_hz = 1000,
    });
    const result = adapter.driver().step(core.vm.default_instruction_budget, 0);

    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.progress, result.status);
    try std.testing.expectEqual(@as(u64, 0), result.wake_guest_ns);
    try std.testing.expectEqual(core.vm.default_instruction_budget, adapter.performance.last_instructions);
    try std.testing.expect(adapter.performance.last_instructions >= 4 * 26);
    try std.testing.expectEqual(@as(u64, 1), adapter.performance.budget_limited_steps);
    try std.testing.expectEqual(@as(u32, 18), clock.reads);
    try std.testing.expectEqual(clock.reads, adapter.performance.last_clock_reads);
    try std.testing.expect(adapter.performance.maximum_clock_reads <= 20);
    try std.testing.expectEqual(core.runtime_adapter.slice_clock_max_instructions, adapter.performance.maximum_clock_chunk);

    const counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, core.vm.default_instruction_budget), counters.instructions);
    try std.testing.expect(counters.group(.value) != 0);
    try std.testing.expect(counters.group(.arithmetic) != 0);
    try std.testing.expect(counters.group(.control) != 0);
    try std.testing.expectEqual(@as(u64, 17), counters.cancel_callback_checks);
    try std.testing.expectEqual(counters.cancel_callback_checks, cancel_probe.calls);
    try std.testing.expectEqual(@as(u64, core.vm.default_instruction_budget) + counters.cancel_callback_checks, counters.cancel_flag_checks);
    try std.testing.expectEqual(counters.instructions, counters.operation_group_lookups);
    try std.testing.expect(counters.instruction_metadata_reads < counters.instructions);
    try std.testing.expectEqual(@as(u64, 0), counters.text_sync_checks);
    try std.testing.expectEqual(@as(u64, 0), counters.text_sync_renders);
    try std.testing.expect(!machine.hasHostDisplay());
}

test "timed BASIC slices stop at a clock boundary and remain resumable" {
    var program = try core.compiler.compile(std.testing.allocator, "timed-benchmark.bas", cpu_source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var clock = FakeClock{};
    var adapter = core.runtime_adapter.Adapter.initTimed(&machine, .{
        .context = &clock,
        .ticks_fn = FakeClock.read,
        .frequency_hz = 1000,
    });
    const first = adapter.driver().step(core.vm.default_instruction_budget, 0);

    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.progress, first.status);
    try std.testing.expectEqual(@as(u64, 1), adapter.performance.time_limited_steps);
    try std.testing.expect(adapter.performance.last_instructions >= core.runtime_adapter.slice_clock_check_instructions);
    try std.testing.expect(adapter.performance.last_instructions < core.vm.default_instruction_budget);
    try std.testing.expect(adapter.performance.last_elapsed_ticks >= 8);
    try std.testing.expectEqual(clock.reads, adapter.performance.last_clock_reads);
    try std.testing.expect(adapter.performance.last_clock_reads <= 20);

    const before = machine.total_instructions;
    _ = adapter.driver().step(core.vm.default_instruction_budget, 1 * std.time.ns_per_ms);
    try std.testing.expect(machine.total_instructions > before);
}

test "first guest output prepares the display only after BASIC has executed" {
    var program = try core.compiler.compile(std.testing.allocator, "lazy-display.bas", "PRINT \"READY\"\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expect(!machine.hasHostDisplay());

    var adapter = core.runtime_adapter.Adapter.init(&machine);
    const result = adapter.driver().step(core.vm.default_instruction_budget, 0);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.completed, result.status);
    try std.testing.expect(result.operations != 0);
    try std.testing.expect(result.frame_ready);
    try std.testing.expect(machine.hasHostDisplay());
    try std.testing.expectEqual(@as(u64, 1), adapter.performance.display_prepares);
}

test "console input schedules a deferred echo frame without another host event" {
    var program = try core.compiler.compile(std.testing.allocator, "event-input.bas", "INPUT A%\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);

    const waiting = adapter.driver().step(core.vm.default_instruction_budget, 0);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.waiting, waiting.status);
    try std.testing.expectEqual(@as(u64, 0), waiting.wake_guest_ns);
    try std.testing.expect(waiting.frame_ready);

    const initial_view = machine.graphicsView().?;
    adapter.presented_mode_revision = initial_view.mode_revision;
    adapter.presented_content_revision = initial_view.content_revision;

    try std.testing.expect(try machine.enqueueTextCodepoint('7'));
    const deferred = adapter.driver().step(core.vm.default_instruction_budget, std.time.ns_per_ms);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.waiting, deferred.status);
    try std.testing.expect(!deferred.frame_ready);
    try std.testing.expectEqual(core.runtime_adapter.frame_interval_ns, deferred.wake_guest_ns);

    const visible = adapter.driver().step(core.vm.default_instruction_budget, deferred.wake_guest_ns);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.waiting, visible.status);
    try std.testing.expect(visible.frame_ready);
    try std.testing.expectEqual(@as(u64, 1), adapter.performance.cadence_deferred_steps);

    try std.testing.expect(try machine.enqueueKeyCode(13));
    const completed = adapter.driver().step(core.vm.default_instruction_budget, deferred.wake_guest_ns);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.completed, completed.status);
}

test "consumed host input publishes its echo in the same guest slice" {
    var program = try core.compiler.compile(std.testing.allocator, "visible-input.bas", "INPUT A%\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);

    const waiting = adapter.driver().step(core.vm.default_instruction_budget, 0);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.waiting, waiting.status);
    try std.testing.expect(waiting.frame_ready);

    const initial_view = machine.graphicsView().?;
    adapter.presented_mode_revision = initial_view.mode_revision;
    adapter.presented_content_revision = initial_view.content_revision;

    const delivery = adapter.handleInput(.{ .text = .{
        .codepoint = '7',
        .modifiers = 0,
        .tick = 41,
        .sequence = 9,
    } });
    try std.testing.expectEqual(core.runtime_adapter.InputDeliveryStatus.accepted, delivery.status);

    const visible = adapter.driver().step(core.vm.default_instruction_budget, std.time.ns_per_ms);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.waiting, visible.status);
    try std.testing.expect(visible.frame_ready);
    try std.testing.expectEqual(@as(u64, 0), visible.wake_guest_ns);
    try std.testing.expectEqual(@as(u64, 0), adapter.performance.cadence_deferred_steps);
    try std.testing.expectEqual(
        std.time.ns_per_ms + core.runtime_adapter.frame_interval_ns,
        adapter.next_video_guest_ns,
    );

    adapter.notePresent(.presented, 50, 60);
    try std.testing.expectEqual(@as(u64, 9), adapter.performance.last_visible_input_sequence);
    try std.testing.expectEqual(@as(u64, 41), adapter.performance.last_visible_input_tick);
}

test "paused runtime retains ordered input and reports ignored drops before resume" {
    var program = try core.compiler.compile(std.testing.allocator, "paused-input.bas", "First$ = INKEY$\nSecond$ = INKEY$\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var host = PausedInputHost{ .adapter = &adapter };
    var runtime = try core.runtime_adapter.api.Runtime.init(.{}, 1000, 0, null);

    _ = runtime.cycle(0, adapter.driver(), host.driver());
    try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.paused, runtime.state);
    try std.testing.expectEqual(@as(u64, 0), machine.total_instructions);

    _ = runtime.cycle(1, adapter.driver(), host.driver());
    try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.paused, runtime.state);
    try std.testing.expectEqual(@as(usize, 2), machine.queuedInputBytes());
    try std.testing.expectEqual(@as(u64, 0), machine.inputStats().consumed_bytes);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.ignored_input_events);

    _ = runtime.cycle(2, adapter.driver(), host.driver());
    try std.testing.expectEqual(core.runtime_adapter.api.LifecycleState.completed, runtime.state);
    try std.testing.expectEqualStrings("A", machine.global("First$").?.string);
    try std.testing.expectEqualStrings("B", machine.global("Second$").?.string);
    try std.testing.expectEqual(@as(u64, 2), machine.inputStats().last_consumed_sequence);
    try std.testing.expectEqual(@as(u64, 102), machine.inputStats().last_consumed_tick);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.resumes);
}

const PausedInputHost = struct {
    adapter: *core.runtime_adapter.Adapter,
    stage: u8 = 0,
    input_index: u8 = 0,
    idle_after_stage: bool = false,

    fn driver(self: *PausedInputHost) core.runtime_adapter.api.HostDriver {
        return .{
            .context = self,
            .poll_fn = poll,
            .present_fn = present,
        };
    }

    fn poll(context: *anyopaque) core.runtime_adapter.api.HostPollResult {
        const self: *PausedInputHost = @ptrCast(@alignCast(context));
        if (self.idle_after_stage) {
            self.idle_after_stage = false;
            return .idle;
        }
        return switch (self.stage) {
            0 => blk: {
                self.stage = 1;
                self.idle_after_stage = true;
                break :blk .{ .command = .pause };
            },
            1 => blk: {
                const sequence: u64 = @as(u64, self.input_index) + 1;
                const tick = 100 + sequence;
                const delivered = switch (self.input_index) {
                    0 => self.adapter.handleInput(.{ .text = .{ .codepoint = 'A', .modifiers = 0, .tick = tick, .sequence = sequence } }),
                    1 => self.adapter.handleInput(.{ .text = .{ .codepoint = 'B', .modifiers = 0, .tick = tick, .sequence = sequence } }),
                    else => self.adapter.handleInput(.{ .text = .{ .codepoint = 0x100, .modifiers = 0, .tick = tick, .sequence = sequence } }),
                };
                self.input_index += 1;
                if (self.input_index == 3) {
                    self.stage = 2;
                    self.idle_after_stage = true;
                }
                break :blk if (delivered.wakesGuest()) .handled else .ignored;
            },
            2 => blk: {
                self.stage = 3;
                self.idle_after_stage = true;
                break :blk .{ .command = .resume_running };
            },
            else => .idle,
        };
    }

    fn present(_: *anyopaque) i32 {
        return core.runtime_adapter.api.host_present_unchanged;
    }
};

const FakeClock = struct {
    tick: u64 = 0,
    reads: u32 = 0,

    fn read(raw: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(raw));
        self.reads += 1;
        if ((self.reads & 1) == 0) self.tick += 4;
        return self.tick;
    }
};

const SteadyClock = struct {
    reads: u32 = 0,

    fn read(raw: *anyopaque) u64 {
        const self: *SteadyClock = @ptrCast(@alignCast(raw));
        self.reads += 1;
        return 0;
    }
};

const CancelProbe = struct {
    calls: u64 = 0,

    fn check(raw: ?*anyopaque) bool {
        const self: *CancelProbe = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return false;
    }
};

test "bound types and resolved cells remove only measured redundant VM work" {
    const source =
        \\DEFINT A-Z
        \\A = 1
        \\B = A
        \\C = A < B
        \\L& = 100000
        \\M& = L& > A
        \\F! = 1.5
        \\G! = F! > A
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "bound-hotpath.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var direct_cell_operations: u64 = 0;
    for (program.instructions) |instruction| switch (instruction.op) {
        .load_global,
        .load_local,
        .store_global,
        .store_local,
        .initialize_global,
        .initialize_local,
        .push_global_reference,
        .push_local_reference,
        => direct_cell_operations += 1,
        else => {},
    };

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(256, 8));
    const counters = machine.performanceStats();

    try std.testing.expectEqual(direct_cell_operations, counters.cell_resolve_calls);
    try std.testing.expectEqual(@as(u64, 0), counters.cell_alias_hops);
    try std.testing.expectEqual(@as(u64, 5), counters.same_type_store_moves);
    try std.testing.expectEqual(@as(u64, 2), counters.value_conversions);
    try std.testing.expectEqual(@as(u64, 2), counters.integer_comparisons);
    try std.testing.expectEqual(@as(u64, 1), counters.floating_comparisons);
    try std.testing.expectEqual(@as(u64, 0), counters.string_comparisons);
    try std.testing.expectEqual(@as(i16, 0), machine.global("C").?.integer);
    try std.testing.expectEqual(@as(i32, -1), machine.global("M&").?.long);
    try std.testing.expectEqual(@as(f32, -1), machine.global("G!").?.single);
}

test "simple string assignment clones only the distinct destination value" {
    const source =
        \\A$ = "ABCD"
        \\B$ = A$
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "string-assignment.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 8));
    const counters = machine.performanceStats();

    try std.testing.expectEqualStrings("ABCD", machine.global("B$").?.string);
    try std.testing.expectEqual(@as(u64, 1), counters.string_clones);
    try std.testing.expectEqual(@as(u64, 4), counters.string_clone_bytes);
    try std.testing.expectEqual(@as(u64, 2), counters.same_type_store_moves);
}

test "read only builtins borrow scalar arguments without cloning strings" {
    const source =
        \\A$ = "12.5"
        \\L% = LEN(A$)
        \\U$ = UCASE$(A$)
        \\V# = VAL(A$)
        \\N# = 2.5
        \\I# = INT(N#)
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "borrowed-builtins.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());
    try std.testing.expectEqual(@as(u64, 3), program.compile_stats.borrowed_builtin_arguments);

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 8));
    const counters = machine.performanceStats();

    try std.testing.expectEqual(@as(i16, 4), machine.global("L%").?.integer);
    try std.testing.expectEqualStrings("12.5", machine.global("U$").?.string);
    try std.testing.expectEqual(@as(f64, 12.5), machine.global("V#").?.double);
    try std.testing.expectEqual(@as(f64, 2), machine.global("I#").?.double);
    try std.testing.expectEqual(@as(u64, 3), counters.builtin_borrowed_arguments);
    try std.testing.expectEqual(@as(u64, 1), counters.builtin_owned_arguments);
    try std.testing.expectEqual(@as(u64, 0), counters.string_clones);
    try std.testing.expectEqual(@as(u64, 1), counters.val_direct_parses);
}

test "borrowed builtins keep interactive procedure locals alive through nested calls" {
    const source =
        \\DECLARE FUNCTION ReadNumber# ()
        \\Answer# = ReadNumber#()
        \\END
        \\FUNCTION ReadNumber# ()
        \\    Result$ = ""
        \\    Done = 0
        \\    DO WHILE NOT Done
        \\        Kbd$ = INKEY$
        \\        SELECT CASE Kbd$
        \\            CASE "0" TO "9"
        \\                Result$ = Result$ + Kbd$
        \\            CASE CHR$(13)
        \\                Done = -1
        \\            CASE CHR$(8)
        \\                IF LEN(Result$) > 0 THEN Result$ = LEFT$(Result$, LEN(Result$) - 1)
        \\        END SELECT
        \\    LOOP
        \\    ReadNumber# = VAL(Result$)
        \\END FUNCTION
    ;
    var program = try core.compiler.compile(std.testing.allocator, "interactive-borrow.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    for ("4X6\x085\r") |byte| {
        const accepted = switch (byte) {
            8, 10, 13 => try machine.enqueueKeyCode(byte),
            else => try machine.enqueueTextCodepoint(byte),
        };
        try std.testing.expect(accepted);
    }
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(1024, 64));
    try std.testing.expectEqual(@as(f64, 45), machine.global("Answer#").?.double);
}

test "procedure frames reuse their pool and initialize only reached locals" {
    const source =
        \\DEFINT A-Z
        \\DECLARE SUB Touch ()
        \\DIM SHARED CallCount AS INTEGER
        \\CALL Touch()
        \\CALL Touch()
        \\END
        \\SUB Touch ()
        \\    IF 0 THEN NeverTouched& = 1
        \\    Used& = CallCount
        \\    CallCount = CallCount + 1
        \\END SUB
    ;
    var program = try core.compiler.compile(std.testing.allocator, "frame-pool.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());
    try std.testing.expectEqual(@as(usize, 1), program.procedures.len);
    try std.testing.expectEqual(@as(usize, 2), program.procedures[0].locals.len);

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 8));
    const counters = machine.performanceStats();

    try std.testing.expectEqual(@as(i16, 2), machine.global("CallCount").?.integer);
    try std.testing.expectEqual(@as(u64, 2), counters.procedure_calls);
    try std.testing.expectEqual(@as(u64, 1), counters.local_pool_grows);
    try std.testing.expectEqual(@as(u64, 1), counters.local_pool_reuses);
    try std.testing.expectEqual(@as(u64, 2), counters.local_initializations);
    try std.testing.expectEqual(@as(u64, 0), counters.local_aggregate_initializations);
}

test "numeric arrays use typed payloads and preserve element ByRef semantics" {
    const source =
        \\DEFINT A-Z
        \\DECLARE SUB AddLong (Value AS LONG)
        \\'$DYNAMIC
        \\DIM Integers%(1023)
        \\DIM Longs&(1023)
        \\DIM Singles!(1023)
        \\DIM Doubles#(1023)
        \\Integers%(0) = 7
        \\Longs&(7) = 74
        \\CALL AddLong(Longs&(7))
        \\REDIM Integers%(2047)
        \\ResetValue% = Integers%(0)
        \\END
        \\SUB AddLong (Value AS LONG)
        \\    Value = Value + 4
        \\END SUB
    ;
    var program = try core.compiler.compile(std.testing.allocator, "compact-arrays.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(512, 32));
    const counters = machine.performanceStats();

    try std.testing.expectEqual(@as(usize, 4096), machine.globalArrayStorageBytes("Integers%").?);
    try std.testing.expectEqual(@as(usize, 4096), machine.globalArrayStorageBytes("Longs&").?);
    try std.testing.expectEqual(@as(usize, 4096), machine.globalArrayStorageBytes("Singles!").?);
    try std.testing.expectEqual(@as(usize, 8192), machine.globalArrayStorageBytes("Doubles#").?);
    try std.testing.expectEqual(@as(i32, 78), machine.globalArrayElement("Longs&", &.{7}).?.long);
    try std.testing.expectEqual(@as(i16, 0), machine.global("ResetValue%").?.integer);
    try std.testing.expectEqual(@as(u64, 5), counters.compact_array_resizes);
    try std.testing.expectEqual(@as(u64, 6144), counters.compact_array_elements);
    try std.testing.expectEqual(@as(u64, 20 * 1024), counters.array_live_payload_bytes);
    try std.testing.expectEqual(@as(u64, 20 * 1024), counters.maximum_array_live_payload_bytes);
    try std.testing.expect(counters.maximum_array_resize_live_bytes >= 22 * 1024);
    try std.testing.expectEqual(@as(u64, 0), counters.generic_array_initializations);
}

test "failed compact REDIM leaves the previous array intact" {
    const LimitedAllocator = struct {
        backing: std.mem.Allocator,
        maximum_request_bytes: usize,

        const vtable = std.mem.Allocator.VTable{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocate(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (len > self.maximum_request_bytes) return null;
            return self.backing.rawAlloc(len, alignment, return_address);
        }

        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (new_len > self.maximum_request_bytes) return false;
            return self.backing.rawResize(memory, alignment, new_len, return_address);
        }

        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (new_len > self.maximum_request_bytes) return null;
            return self.backing.rawRemap(memory, alignment, new_len, return_address);
        }

        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.backing.rawFree(memory, alignment, return_address);
        }
    };

    const source =
        \\DEFINT A-Z
        \\'$DYNAMIC
        \\DIM Values&(3)
        \\Values&(0) = 77
        \\REDIM Values&(32767)
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "atomic-redim.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var limited = LimitedAllocator{ .backing = std.testing.allocator, .maximum_request_bytes = 64 * 1024 };
    var machine = try core.vm.Vm.init(limited.allocator(), &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(128, 16));
    try std.testing.expectEqual(core.vm.RuntimeCode.out_of_memory, machine.runtime_diagnostic.?.code);
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(i32)), machine.globalArrayStorageBytes("Values&").?);
    try std.testing.expectEqual(@as(i32, 77), machine.globalArrayElement("Values&", &.{0}).?.long);
}

test "generic array payload cap rejects oversized DIM before allocation" {
    const source =
        \\DEFINT A-Z
        \\TYPE Wide
        \\    F01 AS DOUBLE
        \\    F02 AS DOUBLE
        \\    F03 AS DOUBLE
        \\    F04 AS DOUBLE
        \\    F05 AS DOUBLE
        \\    F06 AS DOUBLE
        \\    F07 AS DOUBLE
        \\    F08 AS DOUBLE
        \\    F09 AS DOUBLE
        \\    F10 AS DOUBLE
        \\    F11 AS DOUBLE
        \\    F12 AS DOUBLE
        \\    F13 AS DOUBLE
        \\    F14 AS DOUBLE
        \\    F15 AS DOUBLE
        \\    F16 AS DOUBLE
        \\END TYPE
        \\DIM Huge(0 TO 32767, 0 TO 7) AS Wide
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "bounded-generic-array.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.runtime_error, machine.runToCompletion(128, 16));
    try std.testing.expectEqual(core.vm.RuntimeCode.out_of_memory, machine.runtime_diagnostic.?.code);
    const counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, 0), counters.array_live_payload_bytes);
    try std.testing.expectEqual(@as(u64, 0), counters.maximum_array_live_payload_bytes);
    try std.testing.expectEqual(@as(usize, 0), machine.globalArrayStorageBytes("Huge").?);
}

test "procedure array payload leaves the live budget on frame release" {
    const source =
        \\DEFINT A-Z
        \\DECLARE SUB Work ()
        \\CALL Work
        \\CALL Work
        \\END
        \\SUB Work ()
        \\    DIM Scratch&(1023)
        \\    Scratch&(0) = 1
        \\END SUB
    ;
    var program = try core.compiler.compile(std.testing.allocator, "local-array-budget.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 32));
    const counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, 2), counters.compact_array_resizes);
    try std.testing.expectEqual(@as(u64, 2048), counters.compact_array_elements);
    try std.testing.expectEqual(@as(u64, 0), counters.array_live_payload_bytes);
    try std.testing.expectEqual(@as(u64, 4096), counters.maximum_array_live_payload_bytes);
}

test "number formatting and ordinary VAL avoid transient heap buffers" {
    const source =
        \\A$ = "12.5"
        \\V# = VAL(A$)
        \\D# = VAL("1D2")
        \\S$ = STR$(123)
        \\PRINT 42;
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "numeric-transients.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(128, 8));
    const counters = machine.performanceStats();

    try std.testing.expectEqual(@as(f64, 12.5), machine.global("V#").?.double);
    try std.testing.expectEqual(@as(f64, 100), machine.global("D#").?.double);
    try std.testing.expectEqualStrings(" 123", machine.global("S$").?.string);
    try std.testing.expectEqual(@as(u64, 2), counters.numeric_format_stack_uses);
    try std.testing.expectEqual(@as(u64, 1), counters.str_result_allocations);
    try std.testing.expectEqual(@as(u64, 1), counters.val_direct_parses);
    try std.testing.expectEqual(@as(u64, 1), counters.val_stack_normalizations);
    try std.testing.expectEqual(@as(u64, 0), counters.val_scratch_normalizations);
    try std.testing.expectEqual(@as(u64, 0), counters.val_scratch_grows);
}

test "long D exponents reuse one retained VAL normalization buffer" {
    const long_d_number =
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "1D1";
    comptime std.debug.assert(long_d_number.len > core.vm.numeric_format_buffer_bytes);
    const source =
        "A$ = \"" ++ long_d_number ++ "\"\n" ++
        "B# = VAL(A$)\n" ++
        "C# = VAL(A$)\n" ++
        "END\n";
    var program = try core.compiler.compile(std.testing.allocator, "val-scratch.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(64, 8));
    const counters = machine.performanceStats();

    try std.testing.expectEqual(@as(f64, 10), machine.global("B#").?.double);
    try std.testing.expectEqual(@as(f64, 10), machine.global("C#").?.double);
    try std.testing.expectEqual(@as(u64, 2), counters.builtin_borrowed_arguments);
    try std.testing.expectEqual(@as(u64, 2), counters.val_scratch_normalizations);
    try std.testing.expectEqual(@as(u64, 1), counters.val_scratch_grows);
}

test "cooperative TIMER retries at its guest deadline without an idle yield loop" {
    var program = try core.compiler.compile(std.testing.allocator, "timer-deadline.bas", "A! = TIMER\nB! = TIMER\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);

    const waiting = adapter.driver().step(core.vm.default_instruction_budget, 0);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.waiting, waiting.status);
    try std.testing.expectEqual(core.vm.timer_poll_interval_ns, waiting.wake_guest_ns);
    var counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, 2), counters.timer_calls);
    try std.testing.expectEqual(@as(u64, 1), counters.timer_waits);

    const completed = adapter.driver().step(core.vm.default_instruction_budget, core.vm.timer_poll_interval_ns);
    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.completed, completed.status);
    counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, 3), counters.timer_calls);
    try std.testing.expectEqual(@as(u64, 1), counters.timer_waits);
    try std.testing.expectEqual(@as(u64, 0), counters.maximum_timer_wake_lateness_ns);
}
