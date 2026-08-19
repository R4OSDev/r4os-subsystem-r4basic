const std = @import("std");
const r4os = @import("r4os");
const audio = @import("audio.zig");
const compiler = @import("compiler.zig");
const frontend = @import("frontend.zig");
const graphics_screen = @import("graphics_screen.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const storage_adapter = @import("storage_adapter.zig");
const text_screen = @import("text_screen.zig");
const vm = @import("vm.zig");

const host_api = r4os.subsystem_host;
const runtime_api = r4os.subsystem_runtime;
const launch_api = r4os.subsystem_launch;
const error_host_video: i32 = -9820;
const title_capacity: usize = 192;
const audio_quantum_frames: usize = runtime_api.default_quantum_frames;
const audio_queue_frames: usize = audio_quantum_frames * runtime_api.default_target_quanta;

pub fn r4_app_main(app: *r4os.App) i32 {
    if (app.profile != .desktop) return 64;
    const allocator = app.allocator() orelse return r4os.abi.err_no_group;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    const desk = app.desktop() orelse return r4os.abi.err_no_group;
    const draw = app.drawing() orelse return r4os.abi.err_no_group;

    const launch = launch_api.parse(app.args()) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Startfehler", &.{
            "R4BASIC konnte den Subsystemstart nicht lesen.",
            @errorName(fault),
            "Eine BAS-Datei muss ueber Explorer oder Open With gestartet werden.",
        });
    };
    var guest_path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Startfehler", &.{
            "Der uebergebene Gastpfad ist ungueltig.",
            launch.guest_path,
        });
    };
    const source = loadSource(allocator, &files, guest_path.asZ()) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Ladefehler", &.{
            "Die BASIC-Datei konnte nicht geladen werden.",
            launch.guest_path,
            @errorName(fault),
        });
    };
    defer allocator.free(source);

    var program = compiler.compile(allocator, launch.guest_path, source) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Compilerfehler", &.{
            "Der BASIC-Compiler konnte nicht initialisiert werden.",
            @errorName(fault),
        });
    };
    defer program.deinit();
    if (!program.ok()) return showCompilerDiagnostics(allocator, sys, desk, draw, &program);

    var services = vm.HostServices{};
    var storage = storage_adapter.Adapter.init(files);
    storage.install(&services);
    var machine = vm.Vm.init(allocator, &program, services) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Laufzeitfehler", &.{
            "Die BASIC-Laufzeit konnte nicht angelegt werden.",
            @errorName(fault),
        });
    };
    defer machine.deinit();
    machine.prepareHostDisplay() catch {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Anzeigefehler", &.{
            "Der virtuelle BASIC-Bildschirm konnte nicht angelegt werden.",
        });
    };

    const view = machine.graphicsView() orelse return error_host_video;
    const surface = host_api.Surface.initIndexed8(view.pixels, view.palette, view.width, view.height) catch return error_host_video;
    var raster_scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window_host = host_api.Host.init(desk, draw, surface, raster_scratch[0..]) catch return error_host_video;
    var guest_adapter = runtime_adapter.Adapter.init(&machine);

    var audio_sink_storage: runtime_api.R4AudioSink = undefined;
    var sink: ?runtime_api.AudioSink = null;
    if (app.audio()) |app_audio| {
        audio_sink_storage = runtime_api.R4AudioSink.init(app_audio);
        sink = audio_sink_storage.sink();
    }
    var audio_queue: [audio.frame_bytes * audio_queue_frames]u8 = undefined;
    var audio_scratch: [audio.frame_bytes * audio_quantum_frames]u8 = undefined;
    var runtime = runtime_api.Runtime.init(.{
        .slice_budget = runtime_api.default_slice_budget,
        .max_input_events = runtime_api.default_max_input_events,
        .max_wait_ticks = runtime_api.default_max_wait_ticks,
    }, sys.monotonicHz(), sys.ticks(), .{
        .config = .{ .sample_rate = audio.sample_rate, .channels = audio.channels },
        .queue_storage = audio_queue[0..],
        .scratch = audio_scratch[0..],
        .sink = sink,
    }) catch {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Laufzeitfehler", &.{
            "Die kooperative Subsystemlaufzeit konnte nicht initialisiert werden.",
        });
    };
    defer runtime.shutdown();

    var runtime_host = RuntimeHost.init(sys, &window_host, &guest_adapter, baseName(launch.guest_path));
    runtime_host.runtime = &runtime;
    runtime_host.applyNormalTitle();
    _ = window_host.setMinimumSize(320, 200);
    _ = RuntimeHost.present(&runtime_host);

    const exit = runRuntime(&runtime, sys, guest_adapter.driver(), runtime_host.driver());
    if (runtime.state == .closed) return 0;
    if (machine.status == .runtime_error) {
        return showRuntimeDiagnostic(allocator, sys, desk, draw, &machine, runtime_host.audio_degraded);
    }
    if (runtime.state == .failed) {
        var failure_text: [64]u8 = undefined;
        const formatted_failure = std.fmt.bufPrint(failure_text[0..], "Hostfehler: {d}", .{exit}) catch "Hostfehlercode nicht darstellbar";
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Hostfehler", &.{
            "Die Subsystemlaufzeit hat diese Gastinstanz kontrolliert beendet.",
            formatted_failure,
            if (runtime_host.audio_degraded) "Audio war bereits degradiert; andere Gastinstanzen bleiben unabhaengig." else "Andere Gastinstanzen bleiben unabhaengig.",
        });
    }
    const completion = if (machine.status == .cancelled)
        "Das BASIC-Programm wurde beendet."
    else
        "Das BASIC-Programm ist beendet.";
    var exit_text: [64]u8 = undefined;
    const formatted_exit = std.fmt.bufPrint(exit_text[0..], "Exitcode: {d}", .{exit}) catch "Exitcode nicht darstellbar";
    return showStatus(allocator, sys, desk, draw, "R4BASIC - Programmende", &.{
        completion,
        formatted_exit,
        if (runtime_host.audio_degraded) "Audio war nicht verfuegbar; Grafik und Gastzeit liefen weiter." else "Audio wurde regulaer geschlossen.",
    });
}

const LoadError = error{
    OutOfMemory,
    Missing,
    Directory,
    TooLarge,
    ReadFailure,
    ShortRead,
};

fn loadSource(allocator: std.mem.Allocator, files: *const r4os.Files, path: r4os.app_storage.PathZ) LoadError![]u8 {
    const info = switch (files.info(path)) {
        .value => |value| value,
        .missing => return error.Missing,
        .failure => return error.ReadFailure,
    };
    if (info.is_dir != 0) return error.Directory;
    if (info.size > frontend.maximum_source_bytes or info.size > std.math.maxInt(usize)) return error.TooLarge;
    const source = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(source);
    var offset: usize = 0;
    while (offset < source.len) {
        const read_offset: u32 = std.math.cast(u32, offset) orelse return error.TooLarge;
        switch (files.readAt(path, read_offset, source[offset..])) {
            .bytes => |count| {
                if (count == 0 or count > source.len - offset) return error.ReadFailure;
                offset += count;
            },
            .end => return error.ShortRead,
            .failure => return error.ReadFailure,
        }
    }
    return source;
}

const RuntimeHost = struct {
    sys: r4os.r4sys.Context,
    window: *host_api.Host,
    guest: *runtime_adapter.Adapter,
    runtime: ?*runtime_api.Runtime = null,
    title: [title_capacity]u8 = [_]u8{0} ** title_capacity,
    title_len: usize = 0,
    audio_degraded: bool = false,

    fn init(sys: r4os.r4sys.Context, window: *host_api.Host, guest: *runtime_adapter.Adapter, guest_name: []const u8) RuntimeHost {
        var self = RuntimeHost{ .sys = sys, .window = window, .guest = guest };
        const value = std.fmt.bufPrintZ(self.title[0..], "R4BASIC - {s}", .{guest_name}) catch "R4BASIC";
        self.title_len = value.len;
        return self;
    }

    fn driver(self: *RuntimeHost) runtime_api.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn applyNormalTitle(self: *RuntimeHost) void {
        self.title[self.title_len] = 0;
        _ = self.window.setTitle(@ptrCast(&self.title));
    }

    fn applyDegradedTitle(self: *RuntimeHost) void {
        if (self.audio_degraded) return;
        self.audio_degraded = true;
        const base_len = self.title_len;
        const suffix = " [Audio nicht verfuegbar]";
        const count = @min(suffix.len, self.title.len - base_len - 1);
        @memcpy(self.title[base_len .. base_len + count], suffix[0..count]);
        self.title[base_len + count] = 0;
        _ = self.window.setTitle(@ptrCast(&self.title));
    }

    fn poll(context: *anyopaque) runtime_api.HostPollResult {
        const self: *RuntimeHost = @ptrCast(@alignCast(context));
        if (self.sys.programShouldClose()) return .{ .command = .close };
        if (self.runtime) |runtime| if (runtime.audio.state == .degraded) self.applyDegradedTitle();
        const event = self.window.pollInput() orelse return .idle;
        return switch (event) {
            .close => .{ .command = .close },
            .resize => blk: {
                self.window.video.invalidateAll();
                break :blk .present;
            },
            else => if (self.guest.handleInput(event)) .handled else .handled,
        };
    }

    fn present(context: *anyopaque) i32 {
        const self: *RuntimeHost = @ptrCast(@alignCast(context));
        _ = self.guest.syncVideo(&self.window.video) catch return error_host_video;
        return switch (self.window.present()) {
            .failure => |raw| raw,
            else => 0,
        };
    }
};

fn runRuntime(runtime: *runtime_api.Runtime, sys: r4os.r4sys.Context, guest: runtime_api.GuestDriver, host: runtime_api.HostDriver) i32 {
    runtime.start(sys.ticks());
    while (true) {
        switch (runtime.cycle(sys.ticks(), guest, host)) {
            .finished => |finished| return finished.exit_code,
            .wait => |ticks| if (ticks == 0) sys.taskYield() else sys.sleepTicks(ticks),
        }
    }
}

fn showCompilerDiagnostics(
    allocator: std.mem.Allocator,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    program: *const @import("bytecode.zig").Program,
) i32 {
    var lines: [20][160]u8 = undefined;
    var views: [22][]const u8 = undefined;
    views[0] = "Die BASIC-Datei enthaelt Syntax- oder Bindefehler:";
    views[1] = program.file_name;
    var count: usize = 2;
    for (program.diagnostics[0..@min(program.diagnostics.len, lines.len)]) |diagnostic| {
        views[count] = std.fmt.bufPrint(lines[count - 2][0..], "{d}:{d}: {s}", .{
            diagnostic.span.line,
            diagnostic.span.column,
            diagnostic.message(),
        }) catch "Diagnose konnte nicht formatiert werden";
        count += 1;
    }
    return showStatus(allocator, sys, desk, draw, "R4BASIC - Syntaxfehler", views[0..count]);
}

fn showRuntimeDiagnostic(
    allocator: std.mem.Allocator,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    machine: *const vm.Vm,
    audio_degraded: bool,
) i32 {
    const diagnostic = machine.runtime_diagnostic orelse return showStatus(allocator, sys, desk, draw, "R4BASIC - Laufzeitfehler", &.{
        "Das BASIC-Programm wurde durch einen unbekannten Laufzeitfehler beendet.",
    });
    var location: [160]u8 = undefined;
    const location_text = std.fmt.bufPrint(location[0..], "{s}:{d}:{d}", .{
        diagnostic.file_name,
        diagnostic.span.line,
        diagnostic.span.column,
    }) catch "Quellposition nicht darstellbar";
    return showStatus(allocator, sys, desk, draw, "R4BASIC - Laufzeitfehler", &.{
        "Das BASIC-Programm wurde kontrolliert beendet.",
        location_text,
        @tagName(diagnostic.code),
        if (audio_degraded) "Audio war bereits degradiert; die Gastlaufzeit blieb davon unabhaengig." else "Nur diese Gastinstanz wurde beendet.",
    });
}

fn showStatus(
    allocator: std.mem.Allocator,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    title: [*:0]const u8,
    lines: []const []const u8,
) i32 {
    var text: text_screen.Screen = .{};
    text.setColor(15, 1) catch {};
    text.write("R4BASIC\r\n\r\n");
    for (lines) |line| {
        text.write(line);
        text.write("\r\n");
    }
    text.write("\r\nFenster schliessen oder Escape druecken.");

    var display: graphics_screen.Screen = .{};
    defer display.deinit(allocator);
    display.setMode(allocator, 0) catch return error_host_video;
    if (text.takeDirty()) |dirty| display.renderText(&text, dirty);
    const view = display.view() orelse return error_host_video;
    const surface = host_api.Surface.initIndexed8(view.pixels, view.palette, view.width, view.height) catch return error_host_video;
    var scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window = host_api.Host.init(desk, draw, surface, scratch[0..]) catch return error_host_video;
    _ = window.setTitle(title);
    _ = window.setMinimumSize(320, 200);
    window.video.invalidateAll();
    var present_pending = true;
    while (!sys.programShouldClose()) {
        if (window.pollInput()) |event| switch (event) {
            .close => return 0,
            .resize => {
                window.video.invalidateAll();
                present_pending = true;
            },
            .key_down => |key| if (key.code == 27) return 0,
            else => {},
        };
        if (present_pending) {
            switch (window.present()) {
                .failure => |raw| return raw,
                .hidden => {},
                else => present_pending = false,
            }
        }
        sys.sleepTicks(1);
    }
    return 0;
}

fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '\\' or byte == '/') start = index + 1;
    }
    return if (start < path.len) path[start..] else path;
}
