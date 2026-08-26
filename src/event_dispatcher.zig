const std = @import("std");

pub const invalid_target: u32 = std.math.maxInt(u32);
pub const slot_count: usize = 41;

pub const Kind = enum(u8) {
    key,
    timer,
    play,
    com,
    pen,
    strig,
    uevent,
};

pub const Action = enum(u8) {
    on,
    off,
    stop,
};

pub const Error = error{InvalidArgument};

const Slot = struct {
    target: u32 = invalid_target,
    mode: Action = .off,
    pending: bool = false,
    handler_active: bool = false,
    pending_sequence: u64 = 0,
    parameter: u32 = 0,
    deadline_ns: u64 = 0,
};

pub const Delivery = struct {
    slot: u8,
    kind: Kind,
    selector: u8,
    target: u32,
};

pub const Stats = struct {
    signals: u64 = 0,
    ignored_off: u64 = 0,
    coalesced: u64 = 0,
    dispatches: u64 = 0,
    handler_returns: u64 = 0,
    timer_deadlines: u64 = 0,
    play_crossings: u64 = 0,
    maximum_pending: u8 = 0,
};

pub const Dispatcher = struct {
    slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
    next_sequence: u64 = 1,
    stats: Stats = .{},

    pub fn reset(self: *Dispatcher) void {
        self.* = .{};
    }

    pub fn bind(
        self: *Dispatcher,
        kind: Kind,
        selector: i32,
        parameter: i32,
        target: u32,
        guest_now_ns: u64,
    ) Error!void {
        const index = try slotIndex(kind, selector);
        var slot = &self.slots[index];
        switch (kind) {
            .timer => {
                if (parameter < 1 or parameter > 86_400) return error.InvalidArgument;
                slot.parameter = @intCast(parameter);
                if (slot.mode != .off) slot.deadline_ns = timerDeadline(guest_now_ns, slot.parameter);
            },
            .play => {
                if (parameter < 1 or parameter > 32) return error.InvalidArgument;
                slot.parameter = @intCast(parameter);
            },
            else => slot.parameter = 0,
        }
        slot.target = target;
        if (target == invalid_target) {
            slot.mode = .off;
            slot.pending = false;
            slot.deadline_ns = 0;
        }
    }

    pub fn control(self: *Dispatcher, kind: Kind, selector: i32, action: Action, guest_now_ns: u64) Error!void {
        const index = try slotIndex(kind, selector);
        var slot = &self.slots[index];
        switch (action) {
            .on => {
                if (slot.mode == .off and kind == .timer and slot.parameter != 0) {
                    slot.deadline_ns = timerDeadline(guest_now_ns, slot.parameter);
                }
                slot.mode = .on;
            },
            .off => {
                slot.mode = .off;
                slot.pending = false;
                if (kind == .timer) slot.deadline_ns = 0;
            },
            .stop => slot.mode = .stop,
        }
    }

    pub fn signal(self: *Dispatcher, kind: Kind, selector: i32) Error!bool {
        const index = try slotIndex(kind, selector);
        return self.signalSlot(index);
    }

    pub fn pollTimer(self: *Dispatcher, guest_now_ns: u64) void {
        const index = timer_slot;
        var slot = &self.slots[index];
        if (slot.mode == .off or slot.target == invalid_target or slot.parameter == 0) return;
        const period_ns = @as(u64, slot.parameter) * std.time.ns_per_s;
        if (slot.deadline_ns == 0) {
            slot.deadline_ns = timerDeadline(guest_now_ns, slot.parameter);
            return;
        }
        if (guest_now_ns < slot.deadline_ns) return;
        self.stats.timer_deadlines +%= 1;
        _ = self.signalSlot(index);
        const elapsed_periods = (guest_now_ns -| slot.deadline_ns) / period_ns + 1;
        slot.deadline_ns +|= elapsed_periods *| period_ns;
    }

    pub fn nextTimerDeadline(self: *const Dispatcher) u64 {
        const slot = self.slots[timer_slot];
        if (slot.mode == .off or slot.target == invalid_target or slot.parameter == 0 or slot.pending) return 0;
        return slot.deadline_ns;
    }

    pub fn notePlayTransition(self: *Dispatcher, before: u32, after: u32) bool {
        const slot = &self.slots[play_slot];
        if (slot.mode == .off or slot.target == invalid_target or slot.parameter == 0) return false;
        if (before >= slot.parameter and after < slot.parameter) {
            self.stats.play_crossings +%= 1;
            return self.signalSlot(play_slot);
        }
        return false;
    }

    pub fn take(self: *Dispatcher) ?Delivery {
        var selected: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (!slot.pending or slot.mode != .on or slot.handler_active or slot.target == invalid_target) continue;
            if (selected) |current| {
                const candidate_descriptor = descriptor(index);
                const current_descriptor = descriptor(current);
                const candidate_priority = priority(candidate_descriptor.kind);
                const current_priority = priority(current_descriptor.kind);
                if (candidate_priority > current_priority or
                    (candidate_priority == current_priority and slot.pending_sequence >= self.slots[current].pending_sequence)) continue;
            }
            selected = index;
        }
        const index = selected orelse return null;
        var slot = &self.slots[index];
        slot.pending = false;
        slot.mode = .stop;
        slot.handler_active = true;
        self.stats.dispatches +%= 1;
        const value = descriptor(index);
        return .{
            .slot = @intCast(index),
            .kind = value.kind,
            .selector = value.selector,
            .target = slot.target,
        };
    }

    pub fn finishHandler(self: *Dispatcher, raw_slot: u8) void {
        const index: usize = raw_slot;
        if (index >= self.slots.len or !self.slots[index].handler_active) return;
        var slot = &self.slots[index];
        slot.handler_active = false;
        if (slot.mode != .off) slot.mode = .on;
        self.stats.handler_returns +%= 1;
    }

    pub fn pendingCount(self: *const Dispatcher) usize {
        var count: usize = 0;
        for (self.slots) |slot| count += @intFromBool(slot.pending);
        return count;
    }

    pub fn mode(self: *const Dispatcher, kind: Kind, selector: i32) Error!Action {
        return self.slots[try slotIndex(kind, selector)].mode;
    }

    pub fn detects(self: *const Dispatcher, kind: Kind, selector: i32) bool {
        const index = slotIndex(kind, selector) catch return false;
        const slot = self.slots[index];
        return slot.mode != .off and slot.target != invalid_target;
    }

    fn signalSlot(self: *Dispatcher, index: usize) bool {
        var slot = &self.slots[index];
        self.stats.signals +%= 1;
        if (slot.mode == .off or slot.target == invalid_target) {
            self.stats.ignored_off +%= 1;
            return false;
        }
        if (slot.pending) {
            self.stats.coalesced +%= 1;
            return false;
        }
        slot.pending = true;
        slot.pending_sequence = self.next_sequence;
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        self.stats.maximum_pending = @max(self.stats.maximum_pending, @as(u8, @intCast(self.pendingCount())));
        return true;
    }
};

const key_slot_count: usize = 31;
const timer_slot: usize = key_slot_count;
const play_slot: usize = timer_slot + 1;
const com_slot: usize = play_slot + 1;
const pen_slot: usize = com_slot + 2;
const strig_slot: usize = pen_slot + 1;
const uevent_slot: usize = strig_slot + 4;

const Descriptor = struct { kind: Kind, selector: u8 };

fn slotIndex(kind: Kind, selector: i32) Error!usize {
    return switch (kind) {
        .key => if ((selector >= 1 and selector <= 25) or selector == 30 or selector == 31)
            @intCast(selector - 1)
        else
            error.InvalidArgument,
        .timer => if (selector == 0) timer_slot else error.InvalidArgument,
        .play => if (selector == 0) play_slot else error.InvalidArgument,
        .com => if (selector == 1 or selector == 2) com_slot + @as(usize, @intCast(selector - 1)) else error.InvalidArgument,
        .pen => if (selector == 0) pen_slot else error.InvalidArgument,
        .strig => switch (selector) {
            0 => strig_slot,
            2 => strig_slot + 1,
            4 => strig_slot + 2,
            6 => strig_slot + 3,
            else => error.InvalidArgument,
        },
        .uevent => if (selector == 0) uevent_slot else error.InvalidArgument,
    };
}

fn descriptor(index: usize) Descriptor {
    if (index < key_slot_count) return .{ .kind = .key, .selector = @intCast(index + 1) };
    if (index == timer_slot) return .{ .kind = .timer, .selector = 0 };
    if (index == play_slot) return .{ .kind = .play, .selector = 0 };
    if (index < pen_slot) return .{ .kind = .com, .selector = @intCast(index - com_slot + 1) };
    if (index == pen_slot) return .{ .kind = .pen, .selector = 0 };
    if (index < uevent_slot) return .{ .kind = .strig, .selector = @intCast((index - strig_slot) * 2) };
    return .{ .kind = .uevent, .selector = 0 };
}

fn priority(kind: Kind) u8 {
    return switch (kind) {
        .uevent => 0,
        .com => 1,
        .key => 2,
        .pen => 3,
        .strig => 4,
        .play => 5,
        .timer => 6,
    };
}

fn timerDeadline(guest_now_ns: u64, seconds: u32) u64 {
    return guest_now_ns +| @as(u64, seconds) * std.time.ns_per_s;
}

test "OFF discards, STOP remembers, and RETURN reenables one coalesced event" {
    var dispatcher = Dispatcher{};
    try dispatcher.bind(.key, 1, 0, 42, 0);
    try dispatcher.control(.key, 1, .stop, 0);
    try std.testing.expect(try dispatcher.signal(.key, 1));
    try std.testing.expect(!try dispatcher.signal(.key, 1));
    try std.testing.expect(dispatcher.take() == null);
    try dispatcher.control(.key, 1, .on, 0);
    const delivery = dispatcher.take().?;
    try std.testing.expectEqual(@as(u32, 42), delivery.target);
    try std.testing.expect(try dispatcher.signal(.key, 1));
    try std.testing.expect(dispatcher.take() == null);
    dispatcher.finishHandler(delivery.slot);
    try std.testing.expect(dispatcher.take() != null);
    try dispatcher.control(.key, 1, .off, 0);
    try std.testing.expect(!try dispatcher.signal(.key, 1));
}

test "source priority is deterministic and timer deadlines coalesce" {
    var dispatcher = Dispatcher{};
    try dispatcher.bind(.timer, 0, 1, 10, 0);
    try dispatcher.bind(.uevent, 0, 0, 20, 0);
    try dispatcher.control(.timer, 0, .on, 0);
    try dispatcher.control(.uevent, 0, .on, 0);
    dispatcher.pollTimer(5 * std.time.ns_per_s);
    try std.testing.expect(try dispatcher.signal(.uevent, 0));
    try std.testing.expectEqual(Kind.uevent, dispatcher.take().?.kind);
    try std.testing.expectEqual(@as(u64, 0), dispatcher.nextTimerDeadline());
}

test "an explicit OFF in a handler survives RETURN" {
    var dispatcher = Dispatcher{};
    try dispatcher.bind(.key, 1, 0, 42, 0);
    try dispatcher.control(.key, 1, .on, 0);
    try std.testing.expect(try dispatcher.signal(.key, 1));
    const delivery = dispatcher.take().?;
    try dispatcher.control(.key, 1, .off, 0);
    dispatcher.finishHandler(delivery.slot);
    try std.testing.expectEqual(Action.off, try dispatcher.mode(.key, 1));
    try std.testing.expect(!try dispatcher.signal(.key, 1));
}

test "all seven sources use one stable cross-source priority" {
    var dispatcher = Dispatcher{};
    const bindings = [_]struct { kind: Kind, selector: i32, parameter: i32 }{
        .{ .kind = .timer, .selector = 0, .parameter = 1 },
        .{ .kind = .play, .selector = 0, .parameter = 2 },
        .{ .kind = .strig, .selector = 0, .parameter = 0 },
        .{ .kind = .pen, .selector = 0, .parameter = 0 },
        .{ .kind = .key, .selector = 1, .parameter = 0 },
        .{ .kind = .com, .selector = 1, .parameter = 0 },
        .{ .kind = .uevent, .selector = 0, .parameter = 0 },
    };
    for (bindings, 0..) |binding, index| {
        try dispatcher.bind(binding.kind, binding.selector, binding.parameter, @intCast(100 + index), 0);
        try dispatcher.control(binding.kind, binding.selector, .on, 0);
        try std.testing.expect(try dispatcher.signal(binding.kind, binding.selector));
    }
    const expected = [_]Kind{ .uevent, .com, .key, .pen, .strig, .play, .timer };
    for (expected) |kind| {
        const delivery = dispatcher.take().?;
        try std.testing.expectEqual(kind, delivery.kind);
        dispatcher.finishHandler(delivery.slot);
    }
    try std.testing.expect(dispatcher.take() == null);
}
