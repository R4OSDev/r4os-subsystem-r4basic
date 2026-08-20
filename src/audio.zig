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
};

pub const PlayResult = struct {
    mode: PlayMode,
    deadline_ns: u64,
    event_count: u32,
};

const Event = struct {
    phase_step: u32,
    duration_frames: u32,
    tone_frames: u32,
};

const Sequence = struct {
    events: std.ArrayList(Event) = .empty,
    settings: Settings,
    total_frames: u64 = 0,
    notes: u32 = 0,
    rests: u32 = 0,

    fn deinit(self: *Sequence, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
        self.* = undefined;
    }
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
        self.stats = .{};
    }

    pub fn setGuestTime(self: *Engine, guest_now_ns: u64) void {
        if (self.timeline_end_ns != 0 and guest_now_ns >= self.timeline_end_ns) {
            self.stats.skipped_frames +%= self.pendingFrames();
            self.discardEvents();
            self.render_cursor_ns = guest_now_ns;
            self.timeline_end_ns = guest_now_ns;
            return;
        }
        if (self.event_head < self.events.items.len and guest_now_ns > self.render_cursor_ns) {
            const skipped = self.skipFrames(nanosecondsToFramesCeil(guest_now_ns - self.render_cursor_ns));
            self.stats.skipped_frames +%= skipped;
            self.render_cursor_ns +|= framesToNanoseconds(skipped);
        }
    }

    pub fn play(self: *Engine, command: []const u8, guest_now_ns: u64) Error!PlayResult {
        self.setGuestTime(guest_now_ns);
        var sequence = try parseSequence(self.allocator, self.settings, command);
        defer sequence.deinit(self.allocator);

        self.compactEvents();
        if (sequence.events.items.len > maximum_events - self.events.items.len) return error.InvalidCommand;
        const queue_was_empty = self.events.items.len == 0;
        try self.events.ensureUnusedCapacity(self.allocator, sequence.events.items.len);
        for (sequence.events.items) |event| self.events.appendAssumeCapacity(event);

        const start_ns = @max(guest_now_ns, self.timeline_end_ns);
        if (queue_was_empty) self.render_cursor_ns = start_ns;
        self.timeline_end_ns = start_ns +| framesToNanoseconds(sequence.total_frames);
        self.settings = sequence.settings;
        self.stats.play_statements +%= 1;
        self.stats.notes +%= sequence.notes;
        self.stats.rests +%= sequence.rests;
        return .{
            .mode = sequence.settings.mode,
            .deadline_ns = self.timeline_end_ns,
            .event_count = @intCast(sequence.events.items.len),
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
        self.stats.beep_statements +%= 1;
        self.stats.notes +%= 1;
        return .{ .mode = .foreground, .deadline_ns = self.timeline_end_ns, .event_count = 1 };
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

    fn skipFrames(self: *Engine, requested: u64) u64 {
        var remaining = requested;
        var skipped: u64 = 0;
        while (remaining != 0 and self.event_head < self.events.items.len) {
            const event = self.events.items[self.event_head];
            if (self.event_frame >= event.duration_frames) {
                self.event_head += 1;
                self.event_frame = 0;
                self.phase = 0;
                continue;
            }
            const available = event.duration_frames - self.event_frame;
            const take: u32 = @intCast(@min(remaining, available));
            if (event.phase_step != 0 and self.event_frame < event.tone_frames) {
                const tone_take = @min(take, event.tone_frames - self.event_frame);
                self.phase +%= event.phase_step *% tone_take;
            }
            self.event_frame += take;
            remaining -= take;
            skipped += take;
        }
        if (self.event_head == self.events.items.len or
            (self.event_head + 1 == self.events.items.len and self.event_frame >= self.events.items[self.event_head].duration_frames))
        {
            self.discardEvents();
        }
        return skipped;
    }

    fn discardEvents(self: *Engine) void {
        self.events.clearRetainingCapacity();
        self.event_head = 0;
        self.event_frame = 0;
        self.phase = 0;
    }
};

fn parseSequence(allocator: std.mem.Allocator, initial: Settings, command: []const u8) Error!Sequence {
    var result = Sequence{ .settings = initial };
    errdefer result.deinit(allocator);
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
                try appendEvent(allocator, &result, 0, length, dots, true);
            },
            'N' => {
                const note = readNumber(command, &index) orelse return error.InvalidCommand;
                if (note > 84) return error.InvalidCommand;
                const dots = readDots(command, &index);
                try appendEvent(allocator, &result, @intCast(note), result.settings.length, dots, note == 0);
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
                try appendEvent(allocator, &result, @intCast(note), length, dots, false);
            },
            else => return error.InvalidCommand,
        }
    }
    return result;
}

fn appendEvent(
    allocator: std.mem.Allocator,
    sequence: *Sequence,
    note: u8,
    length: u8,
    dots: u8,
    rest: bool,
) Error!void {
    if (sequence.events.items.len >= maximum_events) return error.InvalidCommand;
    const duration = durationFrames(sequence.settings.tempo, length, dots) orelse return error.InvalidCommand;
    const tone_frames: u32 = if (rest)
        0
    else switch (sequence.settings.articulation) {
        .normal => @max(@as(u32, 1), duration * 7 / 8),
        .legato => duration,
        .staccato => @max(@as(u32, 1), duration * 3 / 4),
    };
    try sequence.events.append(allocator, .{
        .phase_step = if (rest) 0 else phaseStep(note),
        .duration_frames = duration,
        .tone_frames = tone_frames,
    });
    sequence.total_frames +|= duration;
    if (rest) {
        sequence.rests +%= 1;
    } else {
        sequence.notes +%= 1;
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

fn phaseStep(note: u8) u32 {
    const semitones = (@as(f64, @floatFromInt(note)) - 58.0) / 12.0;
    const frequency = 440.0 * std.math.pow(f64, 2.0, semitones);
    const raw = frequency * 4_294_967_296.0 / @as(f64, @floatFromInt(sample_rate));
    return @intFromFloat(@round(raw));
}

fn phaseStepFromMillihertz(frequency_millihz: u32) u32 {
    const numerator = @as(u128, frequency_millihz) * 4_294_967_296;
    return @intCast(numerator / (@as(u128, sample_rate) * 1000));
}

fn framesToNanoseconds(frames: u64) u64 {
    const numerator = @as(u128, frames) * std.time.ns_per_s;
    return @intCast(@min(@as(u128, std.math.maxInt(u64)), (numerator + sample_rate - 1) / sample_rate));
}

fn nanosecondsToFramesCeil(nanoseconds: u64) u64 {
    const numerator = @as(u128, nanoseconds) * sample_rate;
    return @intCast(@min(@as(u128, std.math.maxInt(u64)), (numerator + std.time.ns_per_s - 1) / std.time.ns_per_s));
}
