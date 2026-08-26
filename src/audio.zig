const std = @import("std");

pub const sample_rate: u32 = 24_000;
pub const channels: u16 = 2;
pub const frame_bytes: usize = channels * @sizeOf(i16);
pub const maximum_events: usize = 4096;
pub const beep_frequency_millihz: u32 = 800_000;
pub const beep_duration_ms: u32 = 200;
pub const amplitude: i16 = 6000;

pub const Error = error{
    OutOfMemory,
    InvalidCommand,
};

pub const PlayMode = enum {
    foreground,
    background,
};

pub const Articulation = enum {
    normal,
    legato,
    staccato,
};

pub const Settings = struct {
    octave: u8 = 4,
    length: u8 = 4,
    tempo: u8 = 120,
    mode: PlayMode = .foreground,
    articulation: Articulation = .normal,
};

pub const Stats = struct {
    play_statements: u32 = 0,
    beep_statements: u32 = 0,
    notes: u32 = 0,
    rests: u32 = 0,
    rendered_frames: u64 = 0,
    skipped_frames: u64 = 0,
    scheduled_frames: u64 = 0,
    accepted_frames: u64 = 0,
    suppressed_frames: u64 = 0,
    discarded_frames: u64 = 0,
    resolved_frames: u64 = 0,
    foreground_waits: u32 = 0,
    foreground_wakes: u32 = 0,
    background_statements: u32 = 0,
    transport_feedbacks: u32 = 0,
    transport_abandons: u32 = 0,
    direct_play_events: u64 = 0,
    play_reserved_events: u64 = 0,
    play_capacity_grows: u32 = 0,
    phase_table_lookups: u64 = 0,
};

pub const PlayResult = struct {
    mode: PlayMode,
    deadline_ns: u64,
    fence_frames: u64,
    event_count: u32,
};

const Event = struct {
    phase_step: u32,
    duration_frames: u32,
    tone_frames: u32,
};

const ParseResult = struct {
    settings: Settings,
    total_frames: u64 = 0,
    notes: u32 = 0,
    rests: u32 = 0,
    event_count: u32 = 0,
    phase_table_lookups: u32 = 0,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    settings: Settings = .{},
    events: std.ArrayList(Event) = .empty,
    event_head: usize = 0,
    event_frame: u32 = 0,
    phase: u32 = 0,
    render_cursor_ns: u64 = 0,
    timeline_end_ns: u64 = 0,
    scheduled_frames: u64 = 0,
    resolved_frames: u64 = 0,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine) void {
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Engine) void {
        self.events.clearRetainingCapacity();
        self.settings = .{};
        self.event_head = 0;
        self.event_frame = 0;
        self.phase = 0;
        self.render_cursor_ns = 0;
        self.timeline_end_ns = 0;
        self.scheduled_frames = 0;
        self.resolved_frames = 0;
        self.stats = .{};
    }

    pub fn setGuestTime(self: *Engine, guest_now_ns: u64) void {
        // Guest time positions a new idle timeline, but never pretends that
        // queued audio was accepted or played. Transport feedback is the only
        // mechanism which resolves scheduled frames.
        if (self.event_head >= self.events.items.len) {
            self.render_cursor_ns = @max(self.render_cursor_ns, guest_now_ns);
            self.timeline_end_ns = @max(self.timeline_end_ns, guest_now_ns);
        }
    }

    pub fn play(self: *Engine, command: []const u8, guest_now_ns: u64) Error!PlayResult {
        self.setGuestTime(guest_now_ns);
        self.compactEvents();
        const event_start = self.events.items.len;
        const queue_was_empty = event_start == 0;
        const capacity_before = self.events.capacity;
        const reserve = @min(command.len, maximum_events - event_start);
        try self.events.ensureUnusedCapacity(self.allocator, reserve);
        if (self.events.capacity != capacity_before) self.stats.play_capacity_grows +%= 1;
        self.stats.play_reserved_events +%= reserve;
        errdefer self.events.items.len = event_start;
        const sequence = try parseSequenceInto(&self.events, self.settings, command);

        const start_ns = @max(guest_now_ns, self.timeline_end_ns);
        if (queue_was_empty and sequence.event_count != 0) self.render_cursor_ns = start_ns;
        self.timeline_end_ns = start_ns +| framesToNanoseconds(sequence.total_frames);
        self.scheduled_frames +|= sequence.total_frames;
        self.settings = sequence.settings;
        self.stats.play_statements +%= 1;
        self.stats.notes +%= sequence.notes;
        self.stats.rests +%= sequence.rests;
        self.stats.scheduled_frames +%= sequence.total_frames;
        self.stats.direct_play_events +%= sequence.event_count;
        self.stats.phase_table_lookups +%= sequence.phase_table_lookups;
        if (sequence.settings.mode == .background) self.stats.background_statements +%= 1;
        return .{
            .mode = sequence.settings.mode,
            .deadline_ns = self.timeline_end_ns,
            .fence_frames = self.scheduled_frames,
            .event_count = sequence.event_count,
        };
    }

    pub fn beep(self: *Engine, guest_now_ns: u64) Error!PlayResult {
        self.setGuestTime(guest_now_ns);
        self.compactEvents();
        if (self.events.items.len >= maximum_events) return error.InvalidCommand;
        const queue_was_empty = self.events.items.len == 0;
        const frames: u32 = @intCast((@as(u64, sample_rate) * beep_duration_ms + 999) / 1000);
        try self.events.append(self.allocator, .{
            .phase_step = phaseStepFromMillihertz(beep_frequency_millihz),
            .duration_frames = frames,
            .tone_frames = frames,
        });
        const start_ns = @max(guest_now_ns, self.timeline_end_ns);
        if (queue_was_empty) self.render_cursor_ns = start_ns;
        self.timeline_end_ns = start_ns +| framesToNanoseconds(frames);
        self.scheduled_frames +|= frames;
        self.stats.beep_statements +%= 1;
        self.stats.notes +%= 1;
        self.stats.scheduled_frames +%= frames;
        return .{
            .mode = .foreground,
            .deadline_ns = self.timeline_end_ns,
            .fence_frames = self.scheduled_frames,
            .event_count = 1,
        };
    }

    pub fn render(self: *Engine, out: []u8) i32 {
        if (out.len < frame_bytes or out.len % frame_bytes != 0) return 0;
        var written_frames: usize = 0;
        const requested_frames = out.len / frame_bytes;
        while (written_frames < requested_frames and self.event_head < self.events.items.len) {
            const event = self.events.items[self.event_head];
            if (self.event_frame >= event.duration_frames) {
                self.event_head += 1;
                self.event_frame = 0;
                self.phase = 0;
                continue;
            }

            var sample: i16 = 0;
            if (event.phase_step != 0 and self.event_frame < event.tone_frames) {
                sample = if ((self.phase & 0x8000_0000) == 0) amplitude else -amplitude;
                self.phase +%= event.phase_step;
            }
            const offset = written_frames * frame_bytes;
            const encoded: u16 = @bitCast(sample);
            std.mem.writeInt(u16, out[offset..][0..2], encoded, .little);
            std.mem.writeInt(u16, out[offset + 2 ..][0..2], encoded, .little);
            self.event_frame += 1;
            written_frames += 1;
        }
        if (self.event_head == self.events.items.len) self.discardEvents();
        self.stats.rendered_frames +%= written_frames;
        self.render_cursor_ns +|= framesToNanoseconds(written_frames);
        return @intCast(written_frames * frame_bytes);
    }

    pub fn pendingFrames(self: *const Engine) u64 {
        if (self.event_head >= self.events.items.len) return 0;
        var result: u64 = self.events.items[self.event_head].duration_frames - self.event_frame;
        for (self.events.items[self.event_head + 1 ..]) |event| result +|= event.duration_frames;
        return result;
    }

    pub fn unresolvedFrames(self: *const Engine) u64 {
        return self.scheduled_frames -| self.resolved_frames;
    }

    pub fn fenceResolved(self: *const Engine, fence_frames: u64) bool {
        return self.resolved_frames >= fence_frames;
    }

    pub fn noteForegroundWait(self: *Engine) void {
        self.stats.foreground_waits +%= 1;
    }

    pub fn noteForegroundWake(self: *Engine) void {
        self.stats.foreground_wakes +%= 1;
    }

    pub fn acceptTransportProgress(
        self: *Engine,
        accepted_frames: u64,
        suppressed_frames: u64,
        discarded_frames: u64,
    ) void {
        if (accepted_frames == 0 and suppressed_frames == 0 and discarded_frames == 0) return;
        self.stats.transport_feedbacks +%= 1;
        self.resolveFrames(&self.stats.accepted_frames, accepted_frames);
        self.resolveFrames(&self.stats.suppressed_frames, suppressed_frames);
        self.resolveFrames(&self.stats.discarded_frames, discarded_frames);
    }

    /// Resolves only frames which have not yet left the guest renderer. PCM
    /// already queued in the host is resolved by the accompanying discarded
    /// transport feedback, so no frame can be counted twice.
    pub fn abandonPending(self: *Engine) void {
        const frames = self.pendingFrames();
        if (frames == 0) return;
        self.stats.transport_abandons +%= 1;
        self.resolveFrames(&self.stats.discarded_frames, frames);
        self.discardEvents();
    }

    fn resolveFrames(self: *Engine, counter: *u64, requested: u64) void {
        const resolved = @min(requested, self.unresolvedFrames());
        counter.* +%= resolved;
        self.resolved_frames +|= resolved;
        self.stats.resolved_frames = self.resolved_frames;
    }

    fn compactEvents(self: *Engine) void {
        if (self.event_head == 0) return;
        if (self.event_head >= self.events.items.len) {
            self.discardEvents();
            return;
        }
        const remaining = self.events.items.len - self.event_head;
        std.mem.copyForwards(Event, self.events.items[0..remaining], self.events.items[self.event_head..]);
        self.events.items.len = remaining;
        self.event_head = 0;
    }

    fn discardEvents(self: *Engine) void {
        self.events.clearRetainingCapacity();
        self.event_head = 0;
        self.event_frame = 0;
        self.phase = 0;
    }
};

fn parseSequenceInto(events: *std.ArrayList(Event), initial: Settings, command: []const u8) Error!ParseResult {
    var result = ParseResult{ .settings = initial };
    var index: usize = 0;
    while (true) {
        skipSpaces(command, &index);
        if (index >= command.len) break;
        const raw = command[index];
        index += 1;
        const symbol = std.ascii.toUpper(raw);
        switch (symbol) {
            'O' => {
                const value = readNumber(command, &index) orelse return error.InvalidCommand;
                if (value > 6) return error.InvalidCommand;
                result.settings.octave = @intCast(value);
            },
            '>' => {
                if (result.settings.octave == 6) return error.InvalidCommand;
                result.settings.octave += 1;
            },
            '<' => {
                if (result.settings.octave == 0) return error.InvalidCommand;
                result.settings.octave -= 1;
            },
            'L' => {
                const value = readNumber(command, &index) orelse return error.InvalidCommand;
                if (value < 1 or value > 64) return error.InvalidCommand;
                result.settings.length = @intCast(value);
            },
            'T' => {
                const value = readNumber(command, &index) orelse return error.InvalidCommand;
                if (value < 32 or value > 255) return error.InvalidCommand;
                result.settings.tempo = @intCast(value);
            },
            'M' => {
                skipSpaces(command, &index);
                if (index >= command.len) return error.InvalidCommand;
                const mode = std.ascii.toUpper(command[index]);
                index += 1;
                switch (mode) {
                    'B' => result.settings.mode = .background,
                    'F' => result.settings.mode = .foreground,
                    'N' => result.settings.articulation = .normal,
                    'L' => result.settings.articulation = .legato,
                    'S' => result.settings.articulation = .staccato,
                    else => return error.InvalidCommand,
                }
            },
            'P' => {
                const length = readLength(command, &index, null) orelse return error.InvalidCommand;
                const dots = readDots(command, &index);
                try appendEvent(events, &result, 0, length, dots, true);
            },
            'N' => {
                const note = readNumber(command, &index) orelse return error.InvalidCommand;
                if (note > 84) return error.InvalidCommand;
                const dots = readDots(command, &index);
                try appendEvent(events, &result, @intCast(note), result.settings.length, dots, note == 0);
            },
            'A', 'B', 'C', 'D', 'E', 'F', 'G' => {
                var note = @as(i16, result.settings.octave) * 12 + noteOffset(symbol);
                skipSpaces(command, &index);
                if (index < command.len) {
                    switch (command[index]) {
                        '#', '+' => {
                            note += 1;
                            index += 1;
                        },
                        '-' => {
                            note -= 1;
                            index += 1;
                        },
                        else => {},
                    }
                }
                if (note < 1 or note > 84) return error.InvalidCommand;
                const length = readLength(command, &index, result.settings.length) orelse return error.InvalidCommand;
                const dots = readDots(command, &index);
                try appendEvent(events, &result, @intCast(note), length, dots, false);
            },
            else => return error.InvalidCommand,
        }
    }
    return result;
}

fn appendEvent(
    events: *std.ArrayList(Event),
    sequence: *ParseResult,
    note: u8,
    length: u8,
    dots: u8,
    rest: bool,
) Error!void {
    if (events.items.len >= maximum_events) return error.InvalidCommand;
    const duration = durationFrames(sequence.settings.tempo, length, dots) orelse return error.InvalidCommand;
    const tone_frames: u32 = if (rest)
        0
    else switch (sequence.settings.articulation) {
        .normal => @max(@as(u32, 1), duration * 7 / 8),
        .legato => duration,
        .staccato => @max(@as(u32, 1), duration * 3 / 4),
    };
    events.appendAssumeCapacity(.{
        .phase_step = if (rest) 0 else phaseStep(note),
        .duration_frames = duration,
        .tone_frames = tone_frames,
    });
    sequence.total_frames +|= duration;
    sequence.event_count +%= 1;
    if (rest) {
        sequence.rests +%= 1;
    } else {
        sequence.notes +%= 1;
        sequence.phase_table_lookups +%= 1;
    }
}

fn noteOffset(symbol: u8) i16 {
    return switch (symbol) {
        'C' => 1,
        'D' => 3,
        'E' => 5,
        'F' => 6,
        'G' => 8,
        'A' => 10,
        'B' => 12,
        else => unreachable,
    };
}

fn readNumber(command: []const u8, index: *usize) ?u16 {
    skipSpaces(command, index);
    const start = index.*;
    var result: u32 = 0;
    while (index.* < command.len and std.ascii.isDigit(command[index.*])) {
        result = result * 10 + command[index.*] - '0';
        if (result > std.math.maxInt(u16)) return null;
        index.* += 1;
    }
    if (index.* == start) return null;
    return @intCast(result);
}

fn readLength(command: []const u8, index: *usize, fallback: ?u8) ?u8 {
    skipSpaces(command, index);
    if (index.* >= command.len or !std.ascii.isDigit(command[index.*])) return fallback;
    const value = readNumber(command, index) orelse return null;
    if (value < 1 or value > 64) return null;
    return @intCast(value);
}

fn readDots(command: []const u8, index: *usize) u8 {
    var dots: u8 = 0;
    while (true) {
        skipSpaces(command, index);
        if (index.* >= command.len or command[index.*] != '.') return dots;
        if (dots == 16) return dots;
        dots += 1;
        index.* += 1;
    }
}

fn skipSpaces(command: []const u8, index: *usize) void {
    while (index.* < command.len and switch (command[index.*]) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    }) index.* += 1;
}

fn durationFrames(tempo: u8, length: u8, dots: u8) ?u32 {
    const base = (@as(f64, @floatFromInt(sample_rate)) * 240.0) /
        (@as(f64, @floatFromInt(tempo)) * @as(f64, @floatFromInt(length)));
    var multiplier: f64 = 1.0;
    var addition: f64 = 0.5;
    for (0..dots) |_| {
        multiplier += addition;
        addition *= 0.5;
    }
    const raw = @ceil(base * multiplier);
    if (!std.math.isFinite(raw) or raw < 1 or raw > std.math.maxInt(u32)) return null;
    return @intFromFloat(raw);
}

const phase_step_table = [85]u32{
    0,         2926232,   3100235,   3284585,   3479896,   3686822,   3906052,   4138318,
    4384395,   4645104,   4921317,   5213953,   5523991,   5852465,   6200470,   6569170,
    6959793,   7373644,   7812103,   8276635,   8768789,   9290209,   9842633,   10427907,
    11047982,  11704930,  12400941,  13138339,  13919586,  14747287,  15624207,  16553270,
    17537579,  18580418,  19685267,  20855814,  22095965,  23409859,  24801882,  26276679,
    27839171,  29494575,  31248413,  33106541,  35075158,  37160835,  39370534,  41711627,
    44191930,  46819719,  49603764,  52553357,  55678342,  58989149,  62496826,  66213081,
    70150316,  74321671,  78741067,  83423255,  88383859,  93639437,  99207528,  105106715,
    111356685, 117978298, 124993653, 132426162, 140300631, 148643341, 157482134, 166846509,
    176767719, 187278874, 198415056, 210213429, 222713370, 235956596, 249987305, 264852324,
    280601263, 297286682, 314964268, 333693018, 353535438,
};

fn phaseStep(note: u8) u32 {
    return phase_step_table[note];
}

fn phaseStepFromMillihertz(frequency_millihz: u32) u32 {
    const numerator = @as(u128, frequency_millihz) * 4_294_967_296;
    return @intCast(numerator / (@as(u128, sample_rate) * 1000));
}

fn framesToNanoseconds(frames: u64) u64 {
    const numerator = @as(u128, frames) * std.time.ns_per_s;
    return @intCast(@min(@as(u128, std.math.maxInt(u64)), (numerator + sample_rate - 1) / sample_rate));
}
