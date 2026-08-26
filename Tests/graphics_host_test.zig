const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const host = r4os.subsystem_host;

fn imageHash(bytes: []const u8) u64 {
    var result: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        result ^= byte;
        result *%= 0x100000001b3;
    }
    return result;
}

const FakeBackend = struct {
    full_begins: u32 = 0,
    damage_begins: u32 = 0,
    rasters: u32 = 0,
    commits: u32 = 0,
    invalid_raster: bool = false,

    fn backend(self: *FakeBackend) host.Backend {
        return .{
            .context = self,
            .begin_full_fn = beginFull,
            .begin_damage_fn = beginDamage,
            .clear_fn = clear,
            .raster_fn = raster,
            .indexed8_fn = indexed8,
            .commit_full_fn = commit,
            .commit_damage_fn = commit,
            .cancel_fn = cancel,
        };
    }

    fn state(context: *anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(context));
    }

    fn beginFull(context: *anyopaque) i32 {
        state(context).full_begins += 1;
        return 0;
    }

    fn beginDamage(context: *anyopaque, _: []const r4os.abi.DisplayDamageRect) i32 {
        state(context).damage_begins += 1;
        return 0;
    }

    fn clear(_: *anyopaque, _: u32) i32 {
        return 0;
    }

    fn raster(context: *anyopaque, _: i32, _: i32, width: u32, height: u32, _: u32, pixels: []const u32) i32 {
        const self = state(context);
        self.rasters += 1;
        if (width == 0 or height == 0 or width > host.tile_max_width or height > host.tile_max_height or
            pixels.len != @as(usize, width) * height)
        {
            self.invalid_raster = true;
        }
        return 0;
    }

    fn indexed8(_: *anyopaque, _: host.IndexedBatch) i32 {
        return -1;
    }

    fn commit(context: *anyopaque) i32 {
        state(context).commits += 1;
        return 0;
    }

    fn cancel(_: *anyopaque) i32 {
        return 0;
    }
};

test "R4BASIC exposes the initial SCREEN 0 text raster to the window host" {
    var program = try core.compiler.compile(std.testing.allocator, "text-window.bas", "PRINT \"R4BASIC\"\nEND\n");
    defer program.deinit();
    try std.testing.expect(program.ok());
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try machine.prepareHostDisplay();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(32, 8));

    const view = machine.graphicsView() orelse return error.MissingTextRaster;
    try std.testing.expectEqual(@as(u32, 640), view.width);
    try std.testing.expectEqual(@as(u32, 400), view.height);
    try std.testing.expect(std.mem.indexOfNone(u8, view.pixels, &[_]u8{0}) != null);

    var adapter = core.runtime_adapter.Adapter.init(&machine);
    var placeholder_pixels = [_]u8{0};
    var placeholder_palette = [_]u32{0} ** host.palette_entries;
    var scratch: [host.tile_max_pixels]u32 = undefined;
    var presenter = try host.Presenter.init(
        try host.Surface.initIndexed8(placeholder_pixels[0..], placeholder_palette[0..], 1, 1),
        scratch[0..],
    );
    var backend: FakeBackend = .{};
    try std.testing.expect(try adapter.syncVideo(&presenter));
    const result = presenter.presentTo(backend.backend(), 640, 400);
    switch (result) {
        .presented => |info| {
            try std.testing.expectEqual(host.PresentMode.full, info.mode);
            try std.testing.expectEqual(@as(u32, 20), info.raster_blocks);
        },
        else => return error.UnexpectedPresentResult,
    }
    try std.testing.expect(!backend.invalid_raster);
}

test "R4BASIC publishes full damage and unchanged frames through the subsystem host" {
    const source =
        \\DEFINT A-Z
        \\SCREEN 9
        \\FOR I = 0 TO 29
        \\  PSET (I, I), I MOD 15 + 1
        \\NEXT I
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "animation.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    var adapter = core.runtime_adapter.Adapter.init(&machine);

    var placeholder_pixels = [_]u8{0};
    var placeholder_palette = [_]u32{0} ** host.palette_entries;
    var scratch: [host.tile_max_pixels]u32 = undefined;
    var presenter = try host.Presenter.init(
        try host.Surface.initIndexed8(placeholder_pixels[0..], placeholder_palette[0..], 1, 1),
        scratch[0..],
    );
    var backend: FakeBackend = .{};

    const started = std.Io.Clock.awake.now(std.testing.io);
    var full_frames: u32 = 0;
    var damage_frames: u32 = 0;
    var steps: usize = 0;
    while (machine.status != .halted and steps < 4096) : (steps += 1) {
        _ = machine.runSlice(1);
        if (!try adapter.syncVideo(&presenter)) continue;
        const result = presenter.presentTo(backend.backend(), 640, 350);
        switch (result) {
            .presented => |info| switch (info.mode) {
                .full => {
                    full_frames += 1;
                    try std.testing.expectEqual(@as(u32, 15), info.raster_blocks);
                },
                .damage => {
                    damage_frames += 1;
                    try std.testing.expectEqual(@as(u32, 1), info.raster_blocks);
                },
            },
            else => return error.UnexpectedPresentResult,
        }
    }
    const elapsed_ns = started.untilNow(std.testing.io, .awake).nanoseconds;
    try std.testing.expectEqual(core.vm.Status.halted, machine.status);
    try std.testing.expectEqual(@as(u32, 1), full_frames);
    try std.testing.expectEqual(@as(u32, 30), damage_frames);
    try std.testing.expect(!backend.invalid_raster);
    try std.testing.expect(elapsed_ns < 30 * std.time.ns_per_s / 20);

    try std.testing.expect(!try adapter.syncVideo(&presenter));
    try std.testing.expect(presenter.presentTo(backend.backend(), 640, 350) == .unchanged);

    const resized = presenter.presentTo(backend.backend(), 1280, 720);
    switch (resized) {
        .presented => |info| {
            try std.testing.expectEqual(host.PresentMode.full, info.mode);
            try std.testing.expectEqual(@as(i32, 0), info.viewport.x);
            try std.testing.expectEqual(@as(i32, 10), info.viewport.y);
            try std.testing.expectEqual(@as(u32, 1280), info.viewport.w);
            try std.testing.expectEqual(@as(u32, 700), info.viewport.h);
            try std.testing.expectEqual(@as(u32, 2), info.viewport.integer_scale);
        },
        else => return error.UnexpectedPresentResult,
    }

    const previous_mode_revision = (machine.graphicsView() orelse return error.MissingGraphicsView).mode_revision;
    try std.testing.expectEqual(@as(i32, 0), adapter.driver().reset());
    var reset_steps: usize = 0;
    while (machine.graphicsView() == null and reset_steps < 64) : (reset_steps += 1) {
        _ = machine.runSlice(1);
    }
    const reset_view = machine.graphicsView() orelse return error.MissingResetGraphicsView;
    try std.testing.expect(reset_view.mode_revision != previous_mode_revision);
    try std.testing.expect(try adapter.syncVideo(&presenter));
}

test "text raster has a pixel-exact reference image" {
    var text: core.text_screen.Screen = .{};
    try text.setColor(14, 1);
    try text.locate(2, 3, null, null, null);
    text.write("R4Basic 0.69.61");
    try text.setColor(10, 4);
    try text.locate(9, 17, null, null, null);
    text.write("Raster reference");

    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 0);
    _ = screen.takeDamage();
    const before = screen.performanceStats();
    const text_damage = text.takeDirty();
    if (text_damage.count == 0) return error.MissingTextDamage;
    for (text_damage.slice()) |region| screen.renderText(&text, region);
    const after = screen.performanceStats();
    const view = screen.view() orelse return error.MissingTextRaster;
    try std.testing.expectEqual(@as(u64, 0xa533e9d9dcbd63f1), imageHash(view.pixels));
    try std.testing.expectEqual(@as(u64, 2_000), after.text_cells - before.text_cells);
    try std.testing.expectEqual(@as(u64, 400), after.text_rows - before.text_rows);
    try std.testing.expectEqual(@as(u64, 400), after.span_operations - before.span_operations);
    try std.testing.expectEqual(@as(u64, 256_000), after.span_pixels - before.span_pixels);
    try std.testing.expectEqual(@as(u64, 256_000), after.pixel_probes - before.pixel_probes);
    try std.testing.expect(after.pixel_changes > before.pixel_changes);
    try std.testing.expectEqual(@as(u64, 1), after.damage_commits - before.damage_commits);

    _ = screen.takeDamage();
    screen.renderText(&text, .{ .x = 0, .y = 0, .w = 80, .h = 25 });
    const unchanged = screen.performanceStats();
    try std.testing.expectEqual(after.damage_commits, unchanged.damage_commits);
    try std.testing.expectEqual(@as(usize, 0), screen.takeDamage().count);
}

test "graphics primitives and packed images have pixel-exact references" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    _ = screen.takeDamage();

    try screen.pset(.{ .x = 3, .y = 4 }, 12);
    try screen.line(.{ .x = -20, .y = 8 }, .{ .x = 130, .y = 93 }, 2, .line);
    try screen.line(.{ .x = 25, .y = 30 }, .{ .x = 105, .y = 82 }, 4, .box);
    try screen.line(.{ .x = 115, .y = 24 }, .{ .x = 172, .y = 68 }, 5, .filled_box);
    try screen.line(.{ .x = 205, .y = 35 }, .{ .x = 282, .y = 104 }, 15, .box);
    try screen.paint(std.testing.allocator, .{ .x = 220, .y = 50 }, 3, 15);
    try screen.circle(.{ .x = 170, .y = 150 }, 43, 11, null, null, null);
    try screen.circle(.{ .x = 285, .y = 165 }, 67, 13, -0.35, -4.95, 0.72);

    const packed_image = try screen.capture(std.testing.allocator, .{ .x = 8, .y = 6 }, .{ .x = 327, .y = 205 });
    defer std.testing.allocator.free(packed_image);
    try screen.put(.{ .x = 315, .y = 125 }, packed_image, .pset);
    try screen.put(.{ .x = 315, .y = 125 }, packed_image, .xor);
    try screen.put(.{ .x = 315, .y = 125 }, packed_image, .xor);

    const view = screen.view() orelse return error.MissingGraphicsRaster;
    try std.testing.expectEqual(@as(u64, 0x2c649185395d9fe1), imageHash(view.pixels));
    try std.testing.expectEqual(@as(u64, 0xf09378bb86921a3e), imageHash(packed_image));
}

test "all graphics modes share exact GET PUT layouts actions and far-edge bounds" {
    const modes = [_]i32{ 1, 2, 7, 8, 9, 10, 11, 12, 13 };
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    for (modes) |mode| {
        try screen.setMode(std.testing.allocator, mode);
        _ = screen.takeDamage();
        const spec = core.graphics_screen.modeSpec(mode) orelse return error.MissingModeSpec;
        const maximum: u8 = @intCast(spec.attributes - 1);
        const source: u8 = @min(maximum, 3);
        for (0..8) |x| try screen.pset(.{ .x = @intCast(x), .y = 0 }, if ((x & 1) == 0) source else 0);
        for (0..8) |x| try screen.pset(.{ .x = @intCast(x), .y = 1 }, if ((x & 1) == 0) 0 else source);

        const image = try screen.capture(std.testing.allocator, .{ .x = 0, .y = 0 }, .{ .x = 7, .y = 1 });
        defer std.testing.allocator.free(image);
        const width_bits: usize = 8 * spec.bits_per_pixel_per_plane;
        const expected_bytes = 4 + ((width_bits + 7) / 8) * spec.planes * 2;
        try std.testing.expectEqual(expected_bytes, image.len);
        try std.testing.expectEqual(@as(u16, @intCast(width_bits)), std.mem.readInt(u16, image[0..2], .little));
        try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, image[2..4], .little));

        const far = core.graphics_screen.Point{ .x = @intCast(spec.width - 8), .y = @intCast(spec.height - 2) };
        try screen.put(far, image, .pset);
        try std.testing.expectEqual(@as(i32, source), try screen.point(far));
        try std.testing.expectError(
            error.IllegalFunctionCall,
            screen.put(.{ .x = @intCast(spec.width - 7), .y = far.y }, image, .pset),
        );

        const origins = [_]core.graphics_screen.Point{
            .{ .x = 20, .y = 10 },
            .{ .x = 40, .y = 10 },
            .{ .x = 60, .y = 10 },
            .{ .x = 80, .y = 10 },
            .{ .x = 100, .y = 10 },
        };
        for (origins) |origin| try screen.pset(origin, maximum);
        try screen.put(origins[0], image, .pset);
        try screen.put(origins[1], image, .preset);
        try screen.put(origins[2], image, .and_);
        try screen.put(origins[3], image, .or_);
        try screen.put(origins[4], image, .xor);
        try std.testing.expectEqual(@as(i32, source), try screen.point(origins[0]));
        try std.testing.expectEqual(@as(i32, source ^ maximum), try screen.point(origins[1]));
        try std.testing.expectEqual(@as(i32, source & maximum), try screen.point(origins[2]));
        try std.testing.expectEqual(@as(i32, source | maximum), try screen.point(origins[3]));
        try std.testing.expectEqual(@as(i32, source ^ maximum), try screen.point(origins[4]));
    }
}

test "every graphics mode has one pixel-exact primitive and pattern golden" {
    const modes = [_]i32{ 1, 2, 7, 8, 9, 10, 11, 12, 13 };
    const goldens = [_]u64{
        0xae6e1bd6b09c9de4,
        0x6da12e0e4f7d9f44,
        0x107d0438e2371836,
        0x61522562ab2faca2,
        0x9d6cfc7e5d8b5e36,
        0xe2a68cc24cbd313c,
        0x78a8171e55c2a16b,
        0xdac99bc67a91cb25,
        0x1955f1b3af57a92e,
    };
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    for (modes, goldens) |mode, golden| {
        try screen.setMode(std.testing.allocator, mode);
        _ = screen.takeDamage();
        const spec = core.graphics_screen.modeSpec(mode) orelse return error.MissingModeSpec;
        const color: i32 = @min(spec.attributes - 1, 5);

        try screen.pset(.{ .x = 2, .y = 2 }, color);
        try screen.pset(.{ .x = 2, .y = 2 }, 0);
        try screen.pset(.{ .x = -1, .y = -1 }, color);
        try screen.lineStyled(.{ .x = -20, .y = 4 }, .{ .x = 45, .y = 19 }, color, .line, 0xA55A);
        const step_end = screen.resolveRelativeTo(.{ .x = 8, .y = 24 }, 24, 18);
        try screen.lineStyled(.{ .x = 8, .y = 24 }, step_end, color, .box, 0xF0F0);
        try screen.line(.{ .x = 38, .y = 25 }, .{ .x = 58, .y = 41 }, color, .filled_box);
        try screen.circle(.{ .x = 72, .y = 58 }, 21, color, -0.25, -4.75, 1.4);
        try screen.circle(.{ .x = 0, .y = 0 }, 17, color, null, null, null);

        try screen.line(.{ .x = 90, .y = 35 }, .{ .x = 116, .y = 57 }, color, .box);
        var tile: [8]u8 = undefined;
        const plane_count: usize = spec.planes;
        const tile_length = plane_count * 2;
        for (0..2) |row| for (0..plane_count) |plane| {
            tile[row * plane_count + plane] = if (((row + plane) & 1) == 0) 0xAA else 0x55;
        };
        try screen.paintTile(std.testing.allocator, .{ .x = 100, .y = 45 }, tile[0..tile_length], color, null);

        const view = screen.view() orelse return error.MissingGraphicsRaster;
        try std.testing.expectEqual(golden, imageHash(view.pixels));
        const stats = screen.performanceStats();
        try std.testing.expect(stats.maximum_paint_queue <= 3);
        try std.testing.expect(screen.takeDamage().count <= 8);
    }
}

test "packed video ranges and tiled PAINT round trip without host memory" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 13);
    _ = screen.takeDamage();
    try screen.writePackedRange(0, &[_]u8{ 7, 8, 9 });
    try std.testing.expectEqual(@as(i32, 7), try screen.point(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(i32, 9), try screen.point(.{ .x = 2, .y = 0 }));
    var packed_bytes: [3]u8 = undefined;
    try screen.readPackedRange(0, packed_bytes[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 7, 8, 9 }, packed_bytes[0..]);

    try screen.setMode(std.testing.allocator, 1);
    _ = screen.takeDamage();
    try screen.paintTile(std.testing.allocator, .{ .x = 0, .y = 0 }, &[_]u8{0b00011011}, null, null);
    try std.testing.expectEqual(@as(i32, 0), try screen.point(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(i32, 1), try screen.point(.{ .x = 1, .y = 0 }));
    try std.testing.expectEqual(@as(i32, 2), try screen.point(.{ .x = 2, .y = 0 }));
    try std.testing.expectEqual(@as(i32, 3), try screen.point(.{ .x = 3, .y = 0 }));
    try std.testing.expectError(
        error.IllegalFunctionCall,
        screen.paintTile(std.testing.allocator, .{ .x = 0, .y = 0 }, &[_]u8{ 1, 2, 3 }, null, &[_]u8{ 1, 2, 3 }),
    );
    try std.testing.expectError(
        error.IllegalFunctionCall,
        screen.paintTile(std.testing.allocator, .{ .x = 0, .y = 0 }, &[_]u8{ 1, 2 }, null, &[_]u8{3}),
    );
    const stats = screen.performanceStats();
    try std.testing.expect(stats.maximum_paint_queue <= 2);
    try std.testing.expectEqual(@as(u64, 200), stats.paint_spans);
}

test "filled regions and PAINT use one damage commit and bounded spans" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    _ = screen.takeDamage();
    const box_before = screen.performanceStats();
    try screen.line(.{ .x = 10, .y = 20 }, .{ .x = 67, .y = 64 }, 6, .filled_box);
    const box_after = screen.performanceStats();
    try std.testing.expectEqual(@as(u64, 45), box_after.fill_spans - box_before.fill_spans);
    try std.testing.expectEqual(@as(u64, 45), box_after.span_operations - box_before.span_operations);
    try std.testing.expectEqual(@as(u64, 58 * 45), box_after.span_pixels - box_before.span_pixels);
    try std.testing.expectEqual(@as(u64, 1), box_after.damage_commits - box_before.damage_commits);

    try screen.setMode(std.testing.allocator, 1);
    _ = screen.takeDamage();
    const paint_before = screen.performanceStats();
    try screen.paint(std.testing.allocator, .{ .x = 0, .y = 0 }, 1, 1);
    const paint_after = screen.performanceStats();
    try std.testing.expectEqual(@as(u64, 200), paint_after.paint_spans - paint_before.paint_spans);
    try std.testing.expectEqual(@as(u64, 64_000), paint_after.paint_pixels - paint_before.paint_pixels);
    try std.testing.expectEqual(@as(u64, 200), paint_after.paint_queue_pushes - paint_before.paint_queue_pushes);
    try std.testing.expectEqual(@as(u64, 200), paint_after.paint_queue_pops - paint_before.paint_queue_pops);
    try std.testing.expectEqual(@as(u64, 0), paint_after.paint_duplicate_pops - paint_before.paint_duplicate_pops);
    try std.testing.expect(paint_after.maximum_paint_queue <= 2);
    try std.testing.expectEqual(@as(u64, 1), paint_after.damage_commits - paint_before.damage_commits);
}

test "solid PAINT without a border crosses every color until its paint color" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 1);
    try screen.line(.{ .x = 1, .y = 1 }, .{ .x = 8, .y = 8 }, 1, .box);
    try screen.pset(.{ .x = 3, .y = 3 }, 2);
    try screen.pset(.{ .x = 4, .y = 3 }, 3);

    try screen.paintSolid(std.testing.allocator, .{ .x = 2, .y = 2 }, 1, null);

    try std.testing.expectEqual(@as(i32, 1), try screen.point(.{ .x = 3, .y = 3 }));
    try std.testing.expectEqual(@as(i32, 1), try screen.point(.{ .x = 4, .y = 3 }));
    try std.testing.expectEqual(@as(i32, 0), try screen.point(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(i32, 0), try screen.point(.{ .x = 9, .y = 9 }));
}

test "sparse graphics changes remain separate damage regions" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    _ = screen.takeDamage();
    try screen.pset(.{ .x = 2, .y = 3 }, 1);
    try screen.pset(.{ .x = 600, .y = 320 }, 2);
    const damage = screen.takeDamage();
    try std.testing.expectEqual(@as(usize, 2), damage.count);
    try std.testing.expect(!rectsOverlap(damage.regions[0], damage.regions[1]));
}

fn rectsOverlap(a: core.graphics_screen.Rect, b: core.graphics_screen.Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

test "invisible huge circles skip their complete trigonometric segment set" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    _ = screen.takeDamage();
    const before = screen.performanceStats();
    try screen.circle(.{ .x = 320, .y = 175 }, 1_000_000, 7, null, null, null);
    const after = screen.performanceStats();
    try std.testing.expectEqual(@as(u64, 16_384), after.circle_requested_segments - before.circle_requested_segments);
    try std.testing.expectEqual(@as(u64, 16_384), after.circle_skipped_segments - before.circle_skipped_segments);
    try std.testing.expectEqual(before.circle_segments, after.circle_segments);
    try std.testing.expectEqual(before.pixel_changes, after.pixel_changes);
    try std.testing.expectEqual(before.damage_commits, after.damage_commits);
    try std.testing.expectEqual(@as(usize, 0), screen.takeDamage().count);
}

test "same-mode SCREEN reuses and clears its pixel allocation" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    const original_pointer = screen.pixels.?.ptr;
    try screen.pset(.{ .x = 12, .y = 13 }, 8);
    try screen.setMode(std.testing.allocator, 9);
    try std.testing.expectEqual(original_pointer, screen.pixels.?.ptr);
    try std.testing.expectEqual(@as(i32, 0), try screen.point(.{ .x = 12, .y = 13 }));
    const stats = screen.performanceStats();
    try std.testing.expectEqual(@as(u64, 1), stats.mode_allocations);
    try std.testing.expectEqual(@as(u64, 1), stats.mode_reuses);
    try std.testing.expectEqual(@as(u64, 2 * 640 * 350 * 2), stats.mode_clear_bytes);
}

test "all canonical SCREEN modes expose exact geometry attributes palettes and page counts" {
    const expectations = [_]struct {
        mode: i32,
        width: u32,
        height: u32,
        text_columns: usize,
        text_rows: usize,
        pages: u8,
        attributes: u16,
        packed_bytes: usize,
    }{
        .{ .mode = 0, .width = 640, .height = 400, .text_columns = 80, .text_rows = 25, .pages = 8, .attributes = 16, .packed_bytes = 0 },
        .{ .mode = 1, .width = 320, .height = 200, .text_columns = 40, .text_rows = 25, .pages = 1, .attributes = 4, .packed_bytes = 16 * 1024 },
        .{ .mode = 2, .width = 640, .height = 200, .text_columns = 80, .text_rows = 25, .pages = 1, .attributes = 2, .packed_bytes = 16 * 1024 },
        .{ .mode = 7, .width = 320, .height = 200, .text_columns = 40, .text_rows = 25, .pages = 8, .attributes = 16, .packed_bytes = 32 * 1024 },
        .{ .mode = 8, .width = 640, .height = 200, .text_columns = 80, .text_rows = 25, .pages = 4, .attributes = 16, .packed_bytes = 64 * 1024 },
        .{ .mode = 9, .width = 640, .height = 350, .text_columns = 80, .text_rows = 25, .pages = 2, .attributes = 16, .packed_bytes = 128 * 1024 },
        .{ .mode = 10, .width = 640, .height = 350, .text_columns = 80, .text_rows = 25, .pages = 4, .attributes = 4, .packed_bytes = 64 * 1024 },
        .{ .mode = 11, .width = 640, .height = 480, .text_columns = 80, .text_rows = 30, .pages = 1, .attributes = 2, .packed_bytes = 64 * 1024 },
        .{ .mode = 12, .width = 640, .height = 480, .text_columns = 80, .text_rows = 30, .pages = 1, .attributes = 16, .packed_bytes = 256 * 1024 },
        .{ .mode = 13, .width = 320, .height = 200, .text_columns = 40, .text_rows = 25, .pages = 1, .attributes = 256, .packed_bytes = 64 * 1024 },
    };
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    for (expectations) |expected| {
        const spec = core.graphics_screen.modeSpec(expected.mode) orelse return error.MissingModeSpec;
        try std.testing.expectEqual(expected.width, spec.width);
        try std.testing.expectEqual(expected.height, spec.height);
        try std.testing.expectEqual(expected.text_columns, spec.text_columns);
        try std.testing.expectEqual(expected.text_rows, spec.text_rows);
        try std.testing.expectEqual(expected.pages, spec.pages);
        try std.testing.expectEqual(expected.attributes, spec.attributes);
        try std.testing.expectEqual(expected.packed_bytes, spec.packed_page_bytes);
        try screen.setMode(std.testing.allocator, expected.mode);
        const view = screen.view() orelse return error.MissingGraphicsView;
        try std.testing.expectEqual(expected.width, view.width);
        try std.testing.expectEqual(expected.height, view.height);
        try std.testing.expectEqual(@as(usize, expected.width * expected.height), view.pixels.len);
        try std.testing.expectEqual(@as(u8, @intCast(expected.attributes - 1)), screen.maximumAttribute());
    }
    try std.testing.expect(core.graphics_screen.modeSpec(3) == null);
    try std.testing.expectError(error.IllegalFunctionCall, screen.setMode(std.testing.allocator, 3));
}

test "hidden page writes copies and palette changes publish only truthful frames" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setModePages(std.testing.allocator, 7, 0, 0);
    _ = screen.takeDamage();
    try screen.pset(.{ .x = 5, .y = 6 }, 2);
    _ = screen.takeDamage();
    const page_zero_revision = screen.content_revision;

    try screen.selectPages(1, 0);
    try screen.pset(.{ .x = 5, .y = 6 }, 4);
    try std.testing.expectEqual(page_zero_revision, screen.content_revision);
    try std.testing.expectEqual(@as(usize, 0), screen.takeDamage().count);
    try std.testing.expectEqual(@as(u8, 2), screen.view().?.pixels[6 * 320 + 5]);

    try screen.selectPages(1, 1);
    const shown = screen.takeDamage();
    try std.testing.expectEqual(@as(usize, 1), shown.count);
    try std.testing.expectEqual(@as(u8, 4), screen.view().?.pixels[6 * 320 + 5]);
    const visible_revision = screen.content_revision;
    try std.testing.expect(try screen.copyPage(1, 2));
    try std.testing.expectEqual(visible_revision, screen.content_revision);
    try std.testing.expectEqual(@as(usize, 0), screen.takeDamage().count);
    try std.testing.expect(!(try screen.copyPage(1, 2)));

    try screen.selectPages(2, 2);
    _ = screen.takeDamage();
    try std.testing.expectEqual(@as(u8, 4), screen.view().?.pixels[6 * 320 + 5]);
    const pixel_before = screen.view().?.pixels[6 * 320 + 5];
    const palette_before = screen.view().?.palette[4];
    try screen.setPalette(4, 15);
    try std.testing.expectEqual(pixel_before, screen.view().?.pixels[6 * 320 + 5]);
    try std.testing.expect(palette_before != screen.view().?.palette[4]);
    try std.testing.expectEqual(@as(usize, 1), screen.takeDamage().count);

    const stats = screen.performanceStats();
    try std.testing.expectEqual(@as(u64, 2), stats.page_switches);
    try std.testing.expectEqual(@as(u64, 2), stats.page_copies);
    try std.testing.expect(stats.hidden_page_commits >= 2);
}

test "VIEW WINDOW and PMAP use one reversible clipped transform" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    _ = screen.takeDamage();
    try screen.setView(.{ .x = 100, .y = 50 }, .{ .x = 300, .y = 250 }, false, 1, 2);
    try std.testing.expectEqual(@as(i32, 1), try screen.point(.{ .x = 100, .y = 50 }));
    try std.testing.expectEqual(@as(i32, 1), try screen.point(.{ .x = 101, .y = 51 }));
    const pixels = screen.view().?.pixels;
    try std.testing.expectEqual(@as(u8, 2), pixels[49 * 640 + 99]);
    try std.testing.expectEqual(@as(u8, 2), pixels[251 * 640 + 301]);

    try screen.setWindow(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, false);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.mapCoordinate(5, 0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.mapCoordinate(5, 1), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), try screen.mapCoordinate(100, 2), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), try screen.mapCoordinate(100, 3), 0.000001);
    const middle = screen.resolvePoint(5, 5, false);
    try std.testing.expectEqual(core.graphics_screen.Point{ .x = 200, .y = 150 }, middle);
    try screen.pset(middle, 3);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.currentCoordinate(0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.currentCoordinate(1), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), try screen.currentCoordinate(2), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), try screen.currentCoordinate(3), 0.000001);

    _ = screen.takeDamage();
    try screen.line(.{ .x = -100, .y = 150 }, .{ .x = 500, .y = 150 }, 4, .line);
    const clipped = screen.takeDamage();
    try std.testing.expectEqual(@as(usize, 1), clipped.count);
    try std.testing.expectEqual(@as(u32, 100), clipped.regions[0].x);
    try std.testing.expectEqual(@as(u32, 201), clipped.regions[0].w);
    try std.testing.expectEqual(@as(i32, -1), try screen.point(.{ .x = 99, .y = 150 }));

    try screen.setWindow(.{ .x = 10, .y = 10 }, .{ .x = 0, .y = 0 }, true);
    try std.testing.expectApproxEqAbs(@as(f64, 200), try screen.mapCoordinate(0, 0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 200), try screen.mapCoordinate(0, 1), 0.000001);
    try screen.setWindow(null, null, false);
    try std.testing.expectEqual(core.graphics_screen.Point{ .x = 100, .y = 50 }, screen.resolvePoint(0, 0, false));

    try screen.setView(.{ .x = 100, .y = 50 }, .{ .x = 300, .y = 250 }, true, null, null);
    try screen.pset(.{ .x = 200, .y = 150 }, 3);
    try std.testing.expectApproxEqAbs(@as(f64, 200), try screen.currentCoordinate(0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 150), try screen.currentCoordinate(1), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.mapCoordinate(200, 0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.mapCoordinate(150, 1), 0.000001);
    try screen.setView(null, null, false, null, null);
    try std.testing.expectEqual(core.graphics_screen.Point{ .x = 0, .y = 0 }, screen.resolvePoint(0, 0, false));
}

test "CLS graphics viewport and full-screen paths keep their exact bounds" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    try std.testing.expectApproxEqAbs(@as(f64, 320), try screen.currentCoordinate(0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 175), try screen.currentCoordinate(1), 0.000001);
    try screen.pset(.{ .x = 10, .y = 10 }, 3);
    try screen.setView(.{ .x = 100, .y = 50 }, .{ .x = 300, .y = 250 }, false, null, null);
    try screen.pset(.{ .x = 150, .y = 100 }, 4);
    try screen.clear(0);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.currentCoordinate(0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.currentCoordinate(1), 0.000001);
    var pixels = screen.view().?.pixels;
    try std.testing.expectEqual(@as(u8, 3), pixels[10 * 640 + 10]);
    try std.testing.expectEqual(@as(u8, 0), pixels[100 * 640 + 150]);

    try screen.clearAll(0);
    try std.testing.expectApproxEqAbs(@as(f64, 220), try screen.currentCoordinate(0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 125), try screen.currentCoordinate(1), 0.000001);
    pixels = screen.view().?.pixels;
    try std.testing.expectEqual(@as(u8, 0), pixels[10 * 640 + 10]);
}

test "PAINT preserves the most recent graphics point" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    try screen.line(.{ .x = 130, .y = 90 }, .{ .x = 170, .y = 130 }, 2, .box);
    try screen.pset(.{ .x = 140, .y = 100 }, 4);
    try screen.paintSolid(std.testing.allocator, .{ .x = 150, .y = 110 }, 5, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 140), try screen.currentCoordinate(0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), try screen.currentCoordinate(1), 0.000001);
}

test "CGA COLOR selects a standard palette and replaces prior PALETTE overrides" {
    var screen: core.graphics_screen.Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 1);
    const palette_one = screen.view().?.palette[0..4].*;
    try screen.setCgaColor(4, 2);
    const palette_zero = screen.view().?.palette[0..4].*;
    try std.testing.expect(palette_zero[0] != palette_one[0]);
    try std.testing.expect(palette_zero[1] != palette_one[1]);
    try std.testing.expect(palette_zero[2] != palette_one[2]);
    try std.testing.expect(palette_zero[3] != palette_one[3]);

    try screen.setPalette(1, 15);
    const override = screen.view().?.palette[1];
    try screen.setCgaColor(null, null);
    try std.testing.expect(override != screen.view().?.palette[1]);
    try std.testing.expectEqual(palette_zero[1], screen.view().?.palette[1]);
    try std.testing.expectError(error.IllegalFunctionCall, screen.setCgaColor(null, 256));
}

test "VM GET and PUT expose only the packed image prefix of a large numeric array" {
    const source =
        \\DEFINT A-Z
        \\DIM Sprite&(0 TO 30000)
        \\Sprite&(30000) = 123456789
        \\SCREEN 9
        \\LINE (0, 0)-(7, 7), 9, BF
        \\GET (0, 0)-(7, 7), Sprite&
        \\PUT (20, 20), Sprite&, PSET
        \\END
    ;
    var program = try core.compiler.compile(std.testing.allocator, "packed-prefix.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());
    var machine = try core.vm.Vm.init(std.testing.allocator, &program, .{});
    defer machine.deinit();
    try std.testing.expectEqual(core.vm.Status.halted, machine.runToCompletion(4096, 32));

    try std.testing.expectEqual(@as(i32, 123456789), machine.globalArrayElement("Sprite&", &.{30000}).?.long);
    const raster = machine.performanceStats().raster;
    try std.testing.expectEqual(@as(u64, 1), raster.capture_calls);
    try std.testing.expectEqual(@as(u64, 64), raster.capture_pixels);
    try std.testing.expectEqual(@as(u64, 36), raster.capture_bytes);
    try std.testing.expectEqual(@as(u64, 1), raster.put_calls);
    try std.testing.expectEqual(@as(u64, 64), raster.put_pixels);
    try std.testing.expectEqual(@as(u64, 36), raster.put_bytes);
}
