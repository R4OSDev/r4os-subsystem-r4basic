const r4os = @import("r4os");
const host = r4os.subsystem_host;
const runtime = r4os.subsystem_runtime;
const vm = @import("vm.zig");

pub const api = runtime;
pub const reset_error_out_of_memory: i32 = -9801;
pub const slice_time_limit_ns: u64 = 8 * @import("std").time.ns_per_ms;
pub const slice_clock_check_instructions: u32 = 256;

pub const SliceClock = struct {
    context: *anyopaque,
    ticks_fn: *const fn (*anyopaque) u64,
    nanoseconds_fn: ?*const fn (*anyopaque) ?u64 = null,
    frequency_hz: u32,

    pub fn ticks(self: SliceClock) u64 {
        return self.ticks_fn(self.context);
    }

    pub fn nanoseconds(self: SliceClock) ?u64 {
        return if (self.nanoseconds_fn) |read| read(self.context) else null;
    }
};

pub const PerformanceStats = struct {
    steps: u64 = 0,
    instructions: u64 = 0,
    last_instructions: u32 = 0,
    maximum_instructions: u32 = 0,
    budget_limited_steps: u64 = 0,
    time_limited_steps: u64 = 0,
    waiting_steps: u64 = 0,
    frame_ready_steps: u64 = 0,
    first_instruction_ns: u64 = 0,
    last_elapsed_ticks: u64 = 0,
    maximum_elapsed_ticks: u64 = 0,
    elapsed_ns: u64 = 0,
    last_elapsed_ns: u64 = 0,
    maximum_elapsed_ns: u64 = 0,
    clock_reads: u64 = 0,
    last_clock_reads: u32 = 0,
    maximum_clock_reads: u32 = 0,
};

pub const Adapter = struct {
    machine: *vm.Vm,
    presented_mode_revision: u64 = 0,
    presented_content_revision: u64 = 0,
    next_video_guest_ns: u64 = 0,
    slice_clock: ?SliceClock = null,
    performance: PerformanceStats = .{},

    pub fn init(machine: *vm.Vm) Adapter {
        machine.enableCooperativeTimerPacing();
        return .{ .machine = machine };
    }

    pub fn initTimed(machine: *vm.Vm, slice_clock: SliceClock) Adapter {
        var result = init(machine);
        if (slice_clock.frequency_hz != 0) result.slice_clock = slice_clock;
        return result;
    }

    pub fn initSystem(machine: *vm.Vm, system: *const r4os.r4sys.Context) Adapter {
        return initTimed(machine, .{
            .context = @ptrCast(@constCast(system)),
            .ticks_fn = systemTicks,
            .nanoseconds_fn = systemNanoseconds,
            .frequency_hz = system.monotonicHz(),
        });
    }

    pub fn syncVideo(self: *Adapter, presenter: *host.Presenter) host.Error!bool {
        const view = self.machine.graphicsView() orelse {
            self.presented_mode_revision = 0;
            return false;
        };
        if (self.presented_mode_revision != view.mode_revision) {
            const surface = try host.Surface.initIndexed8(view.pixels, view.palette, view.width, view.height);
            try presenter.setSurface(surface);
            self.presented_mode_revision = view.mode_revision;
            self.presented_content_revision = view.content_revision;
            _ = self.machine.takeGraphicsDamage();
            return true;
        }
        const damage = self.machine.takeGraphicsDamage() orelse return false;
        presenter.invalidate(.{ .x = damage.x, .y = damage.y, .w = damage.w, .h = damage.h });
        self.presented_content_revision = view.content_revision;
        return true;
    }

    pub fn driver(self: *Adapter) runtime.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = reset,
            .render_audio_fn = renderAudio,
        };
    }

    pub fn handleInput(self: *Adapter, event: host.InputEvent) bool {
        return switch (event) {
            .close => blk: {
                self.machine.requestCancel();
                break :blk true;
            },
            .focus => |focus| blk: {
                self.machine.setInputFocused(focus.focused);
                break :blk true;
            },
            .key_down => |key| self.machine.enqueueKeyCode(key.code) catch false,
            .text => |text_event| self.machine.enqueueTextCodepoint(text_event.codepoint) catch false,
            .resize, .mouse => false,
        };
    }
};

fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime.StepResult {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.machine.setGuestTime(guest_now_ns);
    const allowed = @min(budget, vm.default_instruction_budget);
    const clock = self.slice_clock;
    var clock_reads: u32 = 0;
    const start_ns_optional = if (clock) |value| blk: {
        if (value.nanoseconds_fn == null) break :blk null;
        clock_reads += 1;
        break :blk value.nanoseconds();
    } else null;
    const uses_nanoseconds = start_ns_optional != null;
    const start_ns = start_ns_optional orelse 0;
    const start_tick = if (clock) |value| if (uses_nanoseconds) 0 else blk: {
        clock_reads += 1;
        break :blk value.ticks();
    } else 0;
    const tick_limit = if (clock) |value| ticksForNanoseconds(value.frequency_hz, slice_time_limit_ns) else 0;
    var last_ns = start_ns;
    var last_tick = start_tick;
    var result: vm.SliceResult = .{ .status = .yielded, .instructions = 0 };
    var executed: u32 = 0;
    var time_limited = false;
    while (executed < allowed) {
        const chunk = @min(slice_clock_check_instructions, allowed - executed);
        const current = self.machine.runSlice(chunk);
        executed += current.instructions;
        result = .{ .status = current.status, .instructions = executed, .wake_guest_ns = current.wake_guest_ns };
        if (clock) |value| {
            clock_reads += 1;
            if (uses_nanoseconds) {
                last_ns = value.nanoseconds() orelse {
                    time_limited = true;
                    break;
                };
            } else {
                last_tick = value.ticks();
            }
        }
        if (current.status != .yielded or current.instructions == 0) break;
        if (clock != null) {
            const limit_reached = if (uses_nanoseconds)
                last_ns -| start_ns >= slice_time_limit_ns
            else
                last_tick -| start_tick >= tick_limit;
            if (limit_reached) {
                time_limited = true;
                break;
            }
        }
    }
    const direct_elapsed_ns = if (uses_nanoseconds) last_ns -| start_ns else 0;
    const elapsed_ticks = if (clock) |value| if (uses_nanoseconds)
        ticksForElapsedNanoseconds(value.frequency_hz, direct_elapsed_ns)
    else
        last_tick -| start_tick else 0;
    const elapsed_ns = if (clock) |value| if (uses_nanoseconds)
        direct_elapsed_ns
    else
        nanosecondsForTicks(value.frequency_hz, elapsed_ticks) else 0;
    self.performance.steps +%= 1;
    self.performance.instructions +%= executed;
    self.performance.last_instructions = executed;
    self.performance.maximum_instructions = @max(self.performance.maximum_instructions, executed);
    self.performance.last_elapsed_ticks = elapsed_ticks;
    self.performance.maximum_elapsed_ticks = @max(self.performance.maximum_elapsed_ticks, elapsed_ticks);
    self.performance.elapsed_ns +|= elapsed_ns;
    self.performance.last_elapsed_ns = elapsed_ns;
    self.performance.maximum_elapsed_ns = @max(self.performance.maximum_elapsed_ns, elapsed_ns);
    self.performance.clock_reads +%= clock_reads;
    self.performance.last_clock_reads = clock_reads;
    self.performance.maximum_clock_reads = @max(self.performance.maximum_clock_reads, clock_reads);
    if (executed != 0 and self.performance.first_instruction_ns == 0) {
        self.performance.first_instruction_ns = start_ns;
    }
    if (time_limited) self.performance.time_limited_steps +%= 1 else if (result.status == .yielded and executed == allowed) self.performance.budget_limited_steps +%= 1;
    if (result.status == .waiting) self.performance.waiting_steps +%= 1;
    const terminal = result.status == .halted or result.status == .cancelled or result.status == .runtime_error;
    const frame_ready = frameReady(self, guest_now_ns, terminal);
    if (frame_ready) self.performance.frame_ready_steps +%= 1;
    return switch (result.status) {
        .ready, .yielded => runtime.StepResult.progress(frame_ready).withOperations(executed),
        .waiting => runtime.StepResult.waitUntil(
            if (result.wake_guest_ns == 0) guest_now_ns +| vm.input_poll_interval_ns else result.wake_guest_ns,
            frame_ready,
        ).withOperations(executed),
        .halted, .cancelled => runtime.StepResult.complete(self.machine.exit_code, frame_ready).withOperations(executed),
        .runtime_error => runtime.StepResult.fail(self.machine.exit_code).withOperations(executed),
    };
}

fn ticksForNanoseconds(frequency_hz: u32, nanoseconds: u64) u64 {
    const product = @as(u128, frequency_hz) * nanoseconds;
    const ticks = (product + @import("std").time.ns_per_s - 1) / @import("std").time.ns_per_s;
    return @max(@as(u64, 1), @as(u64, @intCast(ticks)));
}

fn ticksForElapsedNanoseconds(frequency_hz: u32, nanoseconds: u64) u64 {
    return @intCast((@as(u128, frequency_hz) * nanoseconds) / @import("std").time.ns_per_s);
}

fn nanosecondsForTicks(frequency_hz: u32, ticks: u64) u64 {
    const value = (@as(u128, ticks) * @import("std").time.ns_per_s) / frequency_hz;
    return if (value > @import("std").math.maxInt(u64)) @import("std").math.maxInt(u64) else @intCast(value);
}

fn systemTicks(context: *anyopaque) u64 {
    const system: *const r4os.r4sys.Context = @ptrCast(@alignCast(context));
    return system.ticks();
}

fn systemNanoseconds(context: *anyopaque) ?u64 {
    const system: *const r4os.r4sys.Context = @ptrCast(@alignCast(context));
    return system.monotonicNanoseconds();
}

fn frameReady(self: *Adapter, guest_now_ns: u64, terminal: bool) bool {
    const view = self.machine.graphicsView() orelse return false;
    const changed = self.presented_mode_revision != view.mode_revision or
        self.presented_content_revision != view.content_revision;
    if (!changed or (!terminal and guest_now_ns < self.next_video_guest_ns)) return false;
    self.next_video_guest_ns = guest_now_ns +| 33 * @import("std").time.ns_per_ms;
    return true;
}

fn reset(context: *anyopaque) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.machine.reset() catch return reset_error_out_of_memory;
    self.machine.prepareHostDisplay() catch return reset_error_out_of_memory;
    self.presented_mode_revision = 0;
    self.presented_content_revision = 0;
    self.next_video_guest_ns = 0;
    return 0;
}

fn renderAudio(context: *anyopaque, out: []u8) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    return self.machine.renderAudio(out);
}
