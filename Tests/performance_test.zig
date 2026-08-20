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

    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    const result = adapter.driver().step(core.vm.default_instruction_budget, 0);

    try std.testing.expectEqual(core.runtime_adapter.api.StepStatus.progress, result.status);
    try std.testing.expectEqual(@as(u64, 0), result.wake_guest_ns);
    try std.testing.expectEqual(core.vm.default_instruction_budget, adapter.performance.last_instructions);
    try std.testing.expect(adapter.performance.last_instructions >= 4 * 26);
    try std.testing.expectEqual(@as(u64, 1), adapter.performance.budget_limited_steps);

    const counters = machine.performanceStats();
    try std.testing.expectEqual(@as(u64, core.vm.default_instruction_budget), counters.instructions);
    try std.testing.expect(counters.group(.value) != 0);
    try std.testing.expect(counters.group(.arithmetic) != 0);
    try std.testing.expect(counters.group(.control) != 0);
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
