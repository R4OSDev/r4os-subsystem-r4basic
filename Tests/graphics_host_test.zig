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
    try std.testing.expectEqual(@as(u64, 2 * 640 * 350), stats.mode_clear_bytes);
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
