const std = @import("std");
const core = @import("core");
const frontend = core.frontend;

const canonical_path = "../../../Artifacts/Distribution/Injection/Temp/gorilla.bas";
const canonical_size: usize = 29_434;
const canonical_sha256 = [_]u8{
    0x99, 0x26, 0xFC, 0x1F, 0x50, 0xC4, 0xB4, 0x89,
    0xEC, 0x4C, 0x1B, 0x0D, 0xA5, 0xBD, 0x2C, 0x49,
    0x7E, 0xBF, 0x42, 0x82, 0xB3, 0x25, 0x9C, 0x28,
    0xA8, 0x35, 0xA7, 0x43, 0xE2, 0x46, 0x99, 0xF7,
};

test "canonical local GORILLA.BAS lexes parses and binds unchanged" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, canonical_path, allocator, .limited(frontend.maximum_source_bytes));
    defer allocator.free(source);
    try std.testing.expectEqual(canonical_size, source.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualSlices(u8, canonical_sha256[0..], digest[0..]);

    var program = try core.compiler.compile(allocator, canonical_path, source);
    defer program.deinit();
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
    try std.testing.expect(program.instructions.len != 0);
    try std.testing.expect(program.record_types.len != 0);
    try std.testing.expect(program.data_items.len != 0);
}

test "canonical local GORILLA.BAS completes a deterministic round with victory" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, canonical_path, allocator, .limited(frontend.maximum_source_bytes));
    defer allocator.free(source);

    var program = try core.compiler.compile(allocator, canonical_path, source);
    defer program.deinit();
    try std.testing.expect(program.ok());

    var machine = try core.vm.Vm.init(allocator, &program, .{
        .initial_random_seed = 0x0042_4242,
    });
    defer machine.deinit();

    const Stage = enum {
        intro,
        intro_key,
        player_one,
        player_two,
        game_invalid,
        game_valid,
        gravity_invalid,
        gravity_valid,
        choice,
        choice_key,
        angle,
        angle_key,
        velocity,
        velocity_key,
        round_animation,
        second_angle_key,
        second_velocity,
        second_velocity_key,
        victory,
    };
    var stage: Stage = .intro;
    var delay_slices: u8 = 0;
    var guest_ns: u64 = 0;
    var audio_scratch: [core.audio.frame_bytes * 480]u8 = undefined;
    var accepted_audio_frames: u64 = 0;
    var completed_round = false;

    run_loop: for (0..80_000) |_| {
        machine.setGuestTime(guest_ns);
        const slice = machine.runSlice(256);
        guest_ns +|= 10 * std.time.ns_per_ms;
        accepted_audio_frames +|= try acceptAudioTransport(&machine, &audio_scratch);

        if (slice.status == .runtime_error) {
            std.debug.print("unexpected GORILLA VM error in {s}: {s}:{d}:{d} {s}\n", .{
                @tagName(stage),
                machine.runtime_diagnostic.?.file_name,
                machine.runtime_diagnostic.?.span.line,
                machine.runtime_diagnostic.?.span.column,
                @tagName(machine.runtime_diagnostic.?.code),
            });
            return error.UnexpectedGorillaRuntimeError;
        }

        switch (stage) {
            .intro => if (screenContains(&machine, "Press any key to continue")) {
                stage = .intro_key;
                delay_slices = 3;
            },
            .intro_key => if (delay_slices != 0) {
                delay_slices -= 1;
            } else {
                try feedInput(&machine, "X");
                stage = .player_one;
            },
            .player_one => if (slice.status == .waiting and screenContains(&machine, "Name of Player 1")) {
                try feedInput(&machine, "Alix\x08ce\r");
                stage = .player_two;
            },
            .player_two => if (slice.status == .waiting and screenContains(&machine, "Name of Player 2")) {
                try feedInput(&machine, "Bob\r");
                stage = .game_invalid;
            },
            .game_invalid => if (slice.status == .waiting and screenContains(&machine, "Play to how many")) {
                try feedInput(&machine, "xx\r");
                stage = .game_valid;
            },
            .game_valid => if (slice.status == .waiting and screenContains(&machine, "Play to how many")) {
                try feedInput(&machine, "3\r");
                stage = .gravity_invalid;
            },
            .gravity_invalid => if (slice.status == .waiting and screenContains(&machine, "Gravity in Meters")) {
                try feedInput(&machine, "bad\r");
                stage = .gravity_valid;
            },
            .gravity_valid => if (slice.status == .waiting and screenContains(&machine, "Gravity in Meters")) {
                try feedInput(&machine, "9.8\r");
                stage = .choice;
            },
            .choice => if (screenContains(&machine, "Your Choice?")) {
                stage = .choice_key;
                delay_slices = 2;
            },
            .choice_key => if (delay_slices != 0) {
                delay_slices -= 1;
            } else {
                try feedInput(&machine, "P");
                stage = .angle;
            },
            .angle => if (screenContains(&machine, "Angle:")) {
                stage = .angle_key;
                delay_slices = 2;
            },
            .angle_key => if (delay_slices != 0) {
                delay_slices -= 1;
            } else {
                try feedInput(&machine, "4X6\x085\r");
                stage = .velocity;
            },
            .velocity => if (screenContains(&machine, "Velocity:")) {
                stage = .velocity_key;
                delay_slices = 2;
            },
            .velocity_key => if (delay_slices != 0) {
                delay_slices -= 1;
            } else {
                try feedInput(&machine, "9Q0\r");
                stage = .round_animation;
            },
            .round_animation => if (screenContains(&machine, "Angle:") and !screenContains(&machine, "Velocity:")) {
                stage = .second_angle_key;
                delay_slices = 2;
            },
            .second_angle_key => if (delay_slices != 0) {
                delay_slices -= 1;
            } else {
                try feedInput(&machine, "57\r");
                stage = .second_velocity;
            },
            .second_velocity => if (screenContains(&machine, "Velocity:")) {
                stage = .second_velocity_key;
                delay_slices = 2;
            },
            .second_velocity_key => if (delay_slices != 0) {
                delay_slices -= 1;
            } else {
                // The reference Microsoft RND sequence places the players at
                // (74,168) and (533,91) with wind 5 for this fixed guest-time
                // run. 57 degrees at velocity 74 is a real high-arc hit;
                // the former velocity-1 self-hit depended on the old RNG.
                try feedInput(&machine, "74\r");
                stage = .victory;
            },
            .victory => if (screenContains(&machine, "Angle:") and scoreWasUpdated(&machine) and machine.audioStats().play_statements >= 12) {
                completed_round = true;
                break :run_loop;
            },
        }
    }

    for (0..4096) |_| {
        const frames = try acceptAudioTransport(&machine, &audio_scratch);
        accepted_audio_frames +|= frames;
        if (frames == 0) break;
    }

    if (!completed_round) {
        std.debug.print("GORILLA guard end: stage={s} status={s} instructions={d} audio_calls={d}\n", .{ @tagName(stage), @tagName(machine.status), machine.total_instructions, machine.audioStats().play_statements + machine.audioStats().beep_statements });
        var debug_row: [core.text_screen.columns]u8 = undefined;
        for (0..core.text_screen.rows) |row| {
            if (machine.textScreen().copyRow(row, &debug_row)) std.debug.print("{d:0>2}: {s}\n", .{ row + 1, std.mem.trimEnd(u8, &debug_row, " ") });
        }
    }
    try std.testing.expect(completed_round);
    try expectString(&machine, "Name1$", "Alice");
    try expectString(&machine, "Name2$", "Bob");
    try expectInteger(&machine, "NumGames", 3);
    try expectDouble(&machine, "gravity#", 9.8);
    const graphics = machine.graphicsView() orelse return error.MissingGorillaGraphics;
    try std.testing.expectEqual(@as(u32, 640), graphics.width);
    try std.testing.expectEqual(@as(u32, 350), graphics.height);
    // This golden uses both production audio fences and Microsoft's exact
    // 24-bit RND sequence. The score, palette, command counts and named state
    // below make the raster identity a semantic round result, not a timing
    // snapshot or a program-specific random path.
    try std.testing.expectEqual(@as(u64, 0xd58388942d891f55), std.hash.Wyhash.hash(0, graphics.pixels));
    try std.testing.expectEqual(@as(u32, 0x000000aa), graphics.palette[0]);
    try std.testing.expectEqual(@as(u32, 0x00ffaa55), graphics.palette[1]);
    try std.testing.expectEqual(@as(u32, 0x00ff0055), graphics.palette[2]);
    try std.testing.expectEqual(@as(u32, 0x00ffff00), graphics.palette[3]);
    try std.testing.expectEqual(@as(u32, 0x00ffffff), graphics.palette[9]);
    try std.testing.expect(scoreWasUpdated(&machine));
    try std.testing.expectEqual(@as(u32, 12), machine.audioStats().play_statements);
    try std.testing.expectEqual(@as(u32, 2), machine.audioStats().beep_statements);
    try std.testing.expect(accepted_audio_frames != 0);
    try std.testing.expectEqual(machine.audioStats().scheduled_frames, machine.audioStats().resolved_frames);
}

fn acceptAudioTransport(machine: *core.vm.Vm, scratch: []u8) !u64 {
    const count = machine.renderAudio(scratch);
    try std.testing.expect(count >= 0);
    if (count == 0) return 0;
    const bytes: usize = @intCast(count);
    try std.testing.expectEqual(@as(usize, 0), bytes % core.audio.frame_bytes);
    const frames = bytes / core.audio.frame_bytes;
    _ = machine.noteAudioProgress(frames, 0, 0, false);
    return frames;
}

fn screenContains(machine: *const core.vm.Vm, needle: []const u8) bool {
    var row_bytes: [core.text_screen.columns]u8 = undefined;
    for (0..core.text_screen.rows) |row| {
        if (!machine.textScreen().copyRow(row, &row_bytes)) return false;
        if (std.mem.indexOf(u8, &row_bytes, needle) != null) return true;
    }
    return false;
}

fn scoreWasUpdated(machine: *const core.vm.Vm) bool {
    return screenContains(machine, "1>Score<0") or screenContains(machine, "0>Score<1");
}

fn feedInput(machine: *core.vm.Vm, bytes: []const u8) !void {
    for (bytes) |byte| {
        const accepted = switch (byte) {
            8, 10, 13 => try machine.enqueueKeyCode(byte),
            else => try machine.enqueueTextCodepoint(byte),
        };
        try std.testing.expect(accepted);
    }
}

fn expectInteger(machine: *const core.vm.Vm, name: []const u8, expected: i16) !void {
    const actual = machine.global(name) orelse return error.MissingGorillaGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.integer, actual.valueType());
    try std.testing.expectEqual(expected, actual.integer);
}

fn expectDouble(machine: *const core.vm.Vm, name: []const u8, expected: f64) !void {
    const actual = machine.global(name) orelse return error.MissingGorillaGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.double, actual.valueType());
    try std.testing.expectApproxEqAbs(expected, actual.double, 0.0000001);
}

fn expectString(machine: *const core.vm.Vm, name: []const u8, expected: []const u8) !void {
    const actual = machine.global(name) orelse return error.MissingGorillaGlobal;
    try std.testing.expectEqual(core.bytecode.ValueType.string, actual.valueType());
    try std.testing.expectEqualStrings(expected, actual.string);
}
