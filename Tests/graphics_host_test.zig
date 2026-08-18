const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const host = r4os.subsystem_host;

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

    fn beginDamage(context: *anyopaque) i32 {
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

    fn commit(context: *anyopaque) i32 {
        state(context).commits += 1;
        return 0;
    }

    fn cancel(_: *anyopaque) i32 {
        return 0;
    }
};

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
