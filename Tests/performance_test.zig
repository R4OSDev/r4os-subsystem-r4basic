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
    try std.testing.expectEqual(@as(u32, 17), clock.reads);
    try std.testing.expectEqual(clock.reads, adapter.performance.last_clock_reads);
    try std.testing.expect(adapter.performance.maximum_clock_reads <= 17);

    const counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, core.vm.default_instruction_budget), counters.instructions);
    try std.testing.expect(counters.group(.value) != 0);
    try std.testing.expect(counters.group(.arithmetic) != 0);
    try std.testing.expect(counters.group(.control) != 0);
    try std.testing.expectEqual(@as(u64, 16), counters.cancel_callback_checks);
    try std.testing.expectEqual(counters.cancel_callback_checks, cancel_probe.calls);
    try std.testing.expectEqual(@as(u64, core.vm.default_instruction_budget) + counters.cancel_callback_checks, counters.cancel_flag_checks);
    try std.testing.expectEqual(counters.instructions, counters.operation_group_lookups);
    try std.testing.expect(counters.instruction_metadata_reads < counters.instructions);
    try std.testing.expectEqual(@as(u64, 1), counters.text_sync_checks);
    try std.testing.expectEqual(@as(u64, 1), counters.text_sync_renders);
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
    try std.testing.expect(adapter.performance.last_clock_reads <= 17);

    const before = machine.total_instructions;
    _ = adapter.driver().step(core.vm.default_instruction_budget, 1 * std.time.ns_per_ms);
    try std.testing.expect(machine.total_instructions > before);
}

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
