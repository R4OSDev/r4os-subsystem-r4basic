const r4os = @import("r4os");
const host = r4os.subsystem_host;
const runtime = r4os.subsystem_runtime;
const audio = @import("audio.zig");
const vm = @import("vm.zig");

pub const api = runtime;
pub const reset_error_out_of_memory: i32 = -9801;
pub const display_error_out_of_memory: i32 = -9802;
pub const slice_time_limit_ns: u64 = 8 * @import("std").time.ns_per_ms;
pub const slice_clock_check_instructions: u32 = 256;
pub const slice_clock_target_ns: u64 = @import("std").time.ns_per_ms;
pub const slice_clock_max_instructions: u32 = 16_384;
pub const initial_display_delay_ns: u64 = 33 * @import("std").time.ns_per_ms;
pub const frame_interval_ns: u64 = 33 * @import("std").time.ns_per_ms;

pub const PresentFeedback = enum {
    presented,
    unchanged,
    hidden,
    dropped,
    failed,
};

pub const InputDeliveryStatus = enum {
    accepted,
    control,
    dropped,
};

pub const InputDelivery = struct {
    status: InputDeliveryStatus,
    reason: vm.InputDropReason = .none,
    accepted_bytes: u8 = 0,
    sequence: u64,
    tick: u64,
    queued_bytes: usize,

    pub fn wakesGuest(self: InputDelivery) bool {
        return self.status != .dropped;
    }
};

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
    maximum_clock_chunk: u32 = 0,
    display_prepares: u64 = 0,
    cadence_deferred_steps: u64 = 0,
    missed_frame_deadlines: u64 = 0,
    maximum_frame_backlog: u64 = 0,
    present_attempts: u64 = 0,
    presents: u64 = 0,
    unchanged_presents: u64 = 0,
    hidden_presents: u64 = 0,
    dropped_presents: u64 = 0,
    failed_presents: u64 = 0,
    present_elapsed_ns: u64 = 0,
    maximum_present_ns: u64 = 0,
    maximum_frame_age_start_ns: u64 = 0,
    maximum_frame_age_end_ns: u64 = 0,
    input_logical_events: u64 = 0,
    input_accepted_bytes: u64 = 0,
    input_control_events: u64 = 0,
    input_dropped_events: u64 = 0,
    last_input_sequence: u64 = 0,
    last_input_tick: u64 = 0,
    last_visible_input_sequence: u64 = 0,
    last_visible_input_tick: u64 = 0,
    last_visible_reaction_ns: u64 = 0,
};

pub const Adapter = struct {
    machine: *vm.Vm,
    presented_mode_revision: u64 = 0,
    presented_content_revision: u64 = 0,
    next_video_guest_ns: u64 = 0,
    pending_frame_due_guest_ns: u64 = 0,
    pending_frame_due_host_ns: u64 = 0,
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
        const damage = self.machine.takeGraphicsDamage();
        if (damage.count == 0) return false;
        for (damage.slice()) |region| presenter.invalidate(.{ .x = region.x, .y = region.y, .w = region.w, .h = region.h });
        self.presented_content_revision = view.content_revision;
        return true;
    }

    pub fn driver(self: *Adapter) runtime.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = reset,
            .render_audio_fn = renderAudio,
            .audio_feedback_fn = audioFeedback,
        };
    }

    pub fn handleInput(self: *Adapter, event: host.InputEvent) InputDelivery {
        const host_stamp = event.stamp();
        const stamp = vm.InputStamp{ .sequence = host_stamp.sequence, .tick = host_stamp.tick };
        self.performance.input_logical_events +%= 1;
        self.performance.last_input_sequence = stamp.sequence;
        self.performance.last_input_tick = stamp.tick;
        const delivery: InputDelivery = switch (event) {
            .close => blk: {
                self.machine.requestCancel();
                self.machine.noteInputControl(stamp);
                break :blk self.makeDelivery(.control, .none, stamp);
            },
            .focus => |focus| blk: {
                self.machine.setInputFocused(focus.focused);
                self.machine.noteInputControl(stamp);
                break :blk self.makeDelivery(.control, .none, stamp);
            },
            .key_down => |key| blk: {
                if (self.machine.continueStopped()) {
                    self.machine.noteInputControl(stamp);
                    break :blk self.makeDelivery(.control, .none, stamp);
                }
                break :blk self.deliveryFromVm(self.machine.acceptKeyCode(key.code, stamp), stamp);
            },
            .text => |text_event| blk: {
                if (self.machine.continueStopped()) {
                    self.machine.noteInputControl(stamp);
                    break :blk self.makeDelivery(.control, .none, stamp);
                }
                break :blk self.deliveryFromVm(self.machine.acceptTextCodepoint(text_event.codepoint, stamp), stamp);
            },
            .resize => blk: {
                self.machine.noteInputControl(stamp);
                break :blk self.makeDelivery(.control, .none, stamp);
            },
            .mouse => self.deliveryFromVm(self.machine.noteInputDrop(stamp, .unsupported_event), stamp),
        };
        switch (delivery.status) {
            .accepted => self.performance.input_accepted_bytes +%= delivery.accepted_bytes,
            .control => self.performance.input_control_events +%= 1,
            .dropped => self.performance.input_dropped_events +%= 1,
        }
        return delivery;
    }

    fn deliveryFromVm(self: *Adapter, result: vm.InputResult, stamp: vm.InputStamp) InputDelivery {
        var delivery = self.makeDelivery(if (result.accepted) .accepted else .dropped, result.reason, stamp);
        delivery.accepted_bytes = result.accepted_bytes;
        return delivery;
    }

    fn makeDelivery(self: *Adapter, status: InputDeliveryStatus, reason: vm.InputDropReason, stamp: vm.InputStamp) InputDelivery {
        return .{
            .status = status,
            .reason = reason,
            .sequence = stamp.sequence,
            .tick = stamp.tick,
            .queued_bytes = self.machine.queuedInputBytes(),
        };
    }

    pub fn hasHostDisplay(self: *const Adapter) bool {
        return self.machine.hasHostDisplay();
    }

    pub fn notePresent(self: *Adapter, feedback: PresentFeedback, started_ns: u64, ended_ns: u64) void {
        self.performance.present_attempts +%= 1;
        switch (feedback) {
            .presented => {
                self.performance.presents +%= 1;
                const input = self.machine.inputStats();
                if (input.last_consumed_sequence > self.performance.last_visible_input_sequence) {
                    self.performance.last_visible_input_sequence = input.last_consumed_sequence;
                    self.performance.last_visible_input_tick = input.last_consumed_tick;
                    self.performance.last_visible_reaction_ns = ended_ns;
                }
            },
            .unchanged => self.performance.unchanged_presents +%= 1,
            .hidden => self.performance.hidden_presents +%= 1,
            .dropped => self.performance.dropped_presents +%= 1,
            .failed => self.performance.failed_presents +%= 1,
        }
        const elapsed = ended_ns -| started_ns;
        self.performance.present_elapsed_ns +|= elapsed;
        self.performance.maximum_present_ns = @max(self.performance.maximum_present_ns, elapsed);
        if (self.pending_frame_due_host_ns != 0 and started_ns != 0) {
            self.performance.maximum_frame_age_start_ns = @max(
                self.performance.maximum_frame_age_start_ns,
                started_ns -| self.pending_frame_due_host_ns,
            );
            self.performance.maximum_frame_age_end_ns = @max(
                self.performance.maximum_frame_age_end_ns,
                ended_ns -| self.pending_frame_due_host_ns,
            );
        }
        self.pending_frame_due_guest_ns = 0;
        self.pending_frame_due_host_ns = 0;
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
    var next_chunk: u32 = slice_clock_check_instructions;
    while (executed < allowed) {
        const chunk = @min(next_chunk, allowed - executed);
        self.performance.maximum_clock_chunk = @max(self.performance.maximum_clock_chunk, chunk);
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
            const observed_ns = if (uses_nanoseconds)
                last_ns -| start_ns
            else if (clock) |value|
                nanosecondsForTicks(value.frequency_hz, last_tick -| start_tick)
            else
                0;
            next_chunk = adaptiveClockChunk(executed, observed_ns);
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
    const frame_ready = frameReady(
        self,
        guest_now_ns,
        if (uses_nanoseconds) last_ns else 0,
        result.status == .waiting,
        terminal,
    ) catch return runtime.StepResult.fail(display_error_out_of_memory).withOperations(executed);
    if (frame_ready) self.performance.frame_ready_steps +%= 1;
    return switch (result.status) {
        .ready, .yielded => runtime.StepResult.progress(frame_ready).withOperations(executed),
        .waiting => runtime.StepResult.waitUntil(result.wake_guest_ns, frame_ready).withOperations(executed),
        .halted => if (self.machine.unresolvedAudioFrames() != 0)
            runtime.StepResult.waitUntil(0, frame_ready).withOperations(executed)
        else
            runtime.StepResult.complete(self.machine.exit_code, frame_ready).withOperations(executed),
        .cancelled => runtime.StepResult.complete(self.machine.exit_code, frame_ready).withOperations(executed),
        .runtime_error => runtime.StepResult.fail(self.machine.exit_code).withOperations(executed),
    };
}

fn adaptiveClockChunk(executed: u32, elapsed_ns: u64) u32 {
    if (elapsed_ns == 0) return slice_clock_max_instructions;
    const projected = (@as(u128, executed) * slice_clock_target_ns) / elapsed_ns;
    return @intCast(@min(
        @as(u128, slice_clock_max_instructions),
        @max(@as(u128, 64), projected),
    ));
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

fn frameReady(self: *Adapter, guest_now_ns: u64, host_now_ns: u64, waiting: bool, terminal: bool) vm.InitError!bool {
    if (!self.machine.hasHostDisplay()) {
        var prepared = try self.machine.prepareRequestedHostDisplay();
        if (!prepared and !terminal and (waiting or guest_now_ns >= initial_display_delay_ns)) {
            try self.machine.prepareHostDisplay();
            prepared = true;
        }
        if (!prepared) return false;
        self.performance.display_prepares +%= 1;
    }
    const view = self.machine.graphicsView() orelse return false;
    const changed = self.presented_mode_revision != view.mode_revision or
        self.presented_content_revision != view.content_revision;
    if (!changed) return false;
    if (!terminal and guest_now_ns < self.next_video_guest_ns) {
        self.performance.cadence_deferred_steps +%= 1;
        return false;
    }

    const due_guest_ns = if (self.next_video_guest_ns == 0) guest_now_ns else self.next_video_guest_ns;
    const backlog = (guest_now_ns -| due_guest_ns) / frame_interval_ns;
    self.performance.missed_frame_deadlines +%= backlog;
    self.performance.maximum_frame_backlog = @max(self.performance.maximum_frame_backlog, backlog);
    self.pending_frame_due_guest_ns = due_guest_ns;
    self.pending_frame_due_host_ns = if (host_now_ns == 0)
        0
    else
        host_now_ns -| (guest_now_ns -| due_guest_ns);
    self.next_video_guest_ns = due_guest_ns +| ((backlog + 1) *| frame_interval_ns);
    return true;
}

fn reset(context: *anyopaque) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.machine.reset() catch return reset_error_out_of_memory;
    self.machine.prepareHostDisplay() catch return reset_error_out_of_memory;
    self.performance.display_prepares +%= 1;
    self.presented_mode_revision = 0;
    self.presented_content_revision = 0;
    self.next_video_guest_ns = 0;
    self.pending_frame_due_guest_ns = 0;
    self.pending_frame_due_host_ns = 0;
    return 0;
}

fn renderAudio(context: *anyopaque, out: []u8) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    return self.machine.renderAudio(out);
}

fn audioFeedback(context: *anyopaque, feedback: runtime.AudioFeedback) bool {
    const self: *Adapter = @ptrCast(@alignCast(context));
    const aligned = feedback.accepted_bytes % audio.frame_bytes == 0 and
        feedback.suppressed_bytes % audio.frame_bytes == 0 and
        feedback.discarded_bytes % audio.frame_bytes == 0;
    const abandon = !aligned or feedback.muted or switch (feedback.state) {
        .disabled, .degraded, .closed => true,
        .ready, .active => false,
    };
    return self.machine.noteAudioProgress(
        if (aligned) feedback.accepted_bytes / audio.frame_bytes else 0,
        if (aligned) feedback.suppressed_bytes / audio.frame_bytes else 0,
        if (aligned) feedback.discarded_bytes / audio.frame_bytes else 0,
        abandon,
    );
}
