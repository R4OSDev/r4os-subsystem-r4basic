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
const error_trace_write: i32 = -9821;
const title_capacity: usize = 192;
const audio_quantum_frames: u32 = runtime_api.default_quantum_frames * 2;
const audio_target_quanta: u16 = 4;
const audio_queue_frames: usize = @as(usize, audio_quantum_frames) * audio_target_quanta;
const canonical_baseline_path = "C:\\TEMP\\GORILLA.BAS";
const baseline_report_path = "C:\\TEMP\\R4BASIC.BASELINE";
const gui_report_path = "C:\\TEMP\\R4BASIC.LAST";
const canonical_baseline_size: usize = 29_434;
const canonical_baseline_sha256 = [_]u8{
    0x99, 0x26, 0xFC, 0x1F, 0x50, 0xC4, 0xB4, 0x89,
    0xEC, 0x4C, 0x1B, 0x0D, 0xA5, 0xBD, 0x2C, 0x49,
    0x7E, 0xBF, 0x42, 0x82, 0xB3, 0x25, 0x9C, 0x28,
    0xA8, 0x35, 0xA7, 0x43, 0xE2, 0x46, 0x99, 0xF7,
};

pub fn r4_app_main(app: *r4os.App) i32 {
    if (containsIgnoreCase(app.args(), "/PERFTEST")) return runPerformanceSelfTest(app);
    if (app.profile != .desktop) return 64;
    const allocator = app.allocator() orelse return r4os.abi.err_no_group;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    var timeline = LaunchTimeline{ .app_main_ns = monotonicNow(sys) };
    const desk = app.desktop() orelse return r4os.abi.err_no_group;
    const draw = app.drawing() orelse return r4os.abi.err_no_group;

    const launch = launch_api.parse(app.args()) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Startfehler", &.{
            "R4BASIC konnte den Subsystemstart nicht lesen.",
            @errorName(fault),
            "Eine BAS-Datei muss ueber Explorer oder Open With gestartet werden.",
        });
    };
    const trace = LaunchTrace.parse(launch);
    var guest_path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "guest-path", 65);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Startfehler", &.{
            "Der uebergebene Gastpfad ist ungueltig.",
            launch.guest_path,
        });
    };
    timeline.source_begin_ns = monotonicNow(sys);
    const source = loadSource(allocator, &files, guest_path.asZ()) catch |fault| {
        if (trace.baseline) return writeBaselineFailure(&files, trace, @errorName(fault), 66);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Ladefehler", &.{
            "Die BASIC-Datei konnte nicht geladen werden.",
            launch.guest_path,
            @errorName(fault),
        });
    };
    defer allocator.free(source);
    timeline.source_end_ns = monotonicNow(sys);
    if (trace.baseline and (!std.ascii.eqlIgnoreCase(launch.guest_path, canonical_baseline_path) or !canonicalBaselineSource(source))) {
        return writeBaselineFailure(&files, trace, "source-identity", 67);
    }

    timeline.compile_begin_ns = monotonicNow(sys);
    var program = compiler.compile(allocator, launch.guest_path, source) catch |fault| {
        if (trace.baseline) return writeBaselineFailure(&files, trace, @errorName(fault), 68);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Compilerfehler", &.{
            "Der BASIC-Compiler konnte nicht initialisiert werden.",
            @errorName(fault),
        });
    };
    defer program.deinit();
    timeline.compile_end_ns = monotonicNow(sys);
    if (!program.ok()) {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "compiler-diagnostic", 69);
        return showCompilerDiagnostics(allocator, sys, desk, draw, &program);
    }

    timeline.vm_begin_ns = monotonicNow(sys);
    var services = vm.HostServices{};
    var storage = storage_adapter.Adapter.init(files);
    storage.install(&services);
    var machine = vm.Vm.init(allocator, &program, services) catch |fault| {
        if (trace.baseline) return writeBaselineFailure(&files, trace, @errorName(fault), 70);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Laufzeitfehler", &.{
            "Die BASIC-Laufzeit konnte nicht angelegt werden.",
            @errorName(fault),
        });
    };
    defer machine.deinit();
    machine.prepareHostDisplay() catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "display-init", 71);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Anzeigefehler", &.{
            "Der virtuelle BASIC-Bildschirm konnte nicht angelegt werden.",
        });
    };
    timeline.vm_end_ns = monotonicNow(sys);

    const view = machine.graphicsView() orelse {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "display-view", error_host_video);
        return error_host_video;
    };
    const surface = host_api.Surface.initIndexed8(view.pixels, view.palette, view.width, view.height) catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "display-surface", error_host_video);
        return error_host_video;
    };
    var raster_scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window_host = host_api.Host.init(desk, draw, surface, raster_scratch[0..]) catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "window-host", error_host_video);
        return error_host_video;
    };
    var guest_adapter = runtime_adapter.Adapter.initSystem(&machine, &sys);

    var audio_sink_storage: runtime_api.R4AudioSink = undefined;
    var sink: ?runtime_api.AudioSink = null;
    if (app.audio()) |app_audio| {
        audio_sink_storage = runtime_api.R4AudioSink.init(app_audio);
        sink = audio_sink_storage.sink();
    }
    var audio_queue: [audio.frame_bytes * audio_queue_frames]u8 = undefined;
    var audio_scratch: [audio.frame_bytes * @as(usize, audio_quantum_frames)]u8 = undefined;
    var runtime = runtime_api.Runtime.init(.{
        .slice_budget = runtime_api.default_slice_budget,
        .max_input_events = runtime_api.default_max_input_events,
        .max_wait_ticks = runtime_api.default_max_wait_ticks,
    }, sys.monotonicHz(), sys.ticks(), .{
        .config = .{
            .sample_rate = audio.sample_rate,
            .channels = audio.channels,
            .quantum_frames = audio_quantum_frames,
            .target_quanta = audio_target_quanta,
            .max_catchup_quanta = audio_target_quanta,
        },
        .queue_storage = audio_queue[0..],
        .scratch = audio_scratch[0..],
        .sink = sink,
    }) catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "runtime-init", 72);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Laufzeitfehler", &.{
            "Die kooperative Subsystemlaufzeit konnte nicht initialisiert werden.",
        });
    };
    defer runtime.shutdown();
    timeline.host_ready_ns = monotonicNow(sys);

    var runtime_host = RuntimeHost.init(
        sys,
        &files,
        &window_host,
        &guest_adapter,
        &timeline,
        trace,
        launch.guest_path,
        source.len,
        program.instructions.len,
        baseName(launch.guest_path),
    );
    runtime_host.runtime = &runtime;
    runtime_host.applyNormalTitle();
    _ = window_host.setMinimumSize(320, 200);
    const initial_present = RuntimeHost.present(&runtime_host);
    if (initial_present < 0) {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "initial-present", initial_present);
        return initial_present;
    }
    timeline.initial_frame_ns = monotonicNow(sys);
    runtime_host.trace_armed = true;
    timeline.runtime_begin_ns = monotonicNow(sys);

    const exit = runtime.run(&sys, guest_adapter.driver(), runtime_host.driver());
    if (trace.baseline) return if (runtime.state == .closed and runtime_host.snapshot_written) 0 else if (exit == 0) error_trace_write else exit;
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

const performance_source =
    \\DEFINT A-Z
    \\A = 0
    \\Work:
    \\A = A + 1
    \\IF A >= 30000 THEN A = 0
    \\GOTO Work
;

fn runPerformanceSelfTest(app: *r4os.App) i32 {
    const allocator = app.allocator() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    sys.println("R4BASIC performance stage: compile");
    var program = compiler.compile(allocator, "R4BASIC-PERFTEST.BAS", performance_source) catch return performanceFailure(sys, "compile");
    defer program.deinit();
    if (!program.ok()) return performanceFailure(sys, "diagnostic");
    sys.println("R4BASIC performance stage: vm-init");
    var machine = vm.Vm.init(allocator, &program, .{}) catch return performanceFailure(sys, "vm-init");
    defer machine.deinit();
    var adapter = runtime_adapter.Adapter.initSystem(&machine, &sys);
    const hz = @max(sys.monotonicHz(), 1);
    const start_tick = sys.ticks();
    const benchmark_ticks = @max((@as(u64, hz) * 50 + 999) / 1000, 1);
    const deadline = start_tick +| benchmark_ticks;
    var slices: u64 = 0;
    var no_fixed_sleep = true;
    sys.println("R4BASIC performance stage: run");
    while (sys.ticks() < deadline) {
        const result = adapter.driver().step(runtime_api.default_slice_budget, 0);
        if (result.status != .progress) return performanceFailure(sys, "unexpected-step");
        if (result.wake_guest_ns != 0) no_fixed_sleep = false;
        slices +%= 1;
        sys.taskYield();
    }
    const elapsed = @max(sys.ticks() -| start_tick, 1);
    const instructions = machine.total_instructions;
    const ips: u64 = @intCast((@as(u128, instructions) * hz) / elapsed);
    machine.requestCancel();
    _ = adapter.driver().step(runtime_api.default_slice_budget, 0);
    const stats = machine.performanceStats();
    const ok = machine.status == .cancelled and no_fixed_sleep and ips >= 52_000 and
        adapter.performance.maximum_instructions <= runtime_api.default_slice_budget and
        stats.group(.value) != 0 and stats.group(.arithmetic) != 0 and stats.group(.control) != 0;

    sys.print("R4BASIC performance: instructions=");
    sys.printU64(instructions);
    sys.print(" ticks=");
    sys.printU64(elapsed);
    sys.print(" ips=");
    sys.printU64(ips);
    sys.print(" slices=");
    sys.printU64(slices);
    sys.print(" maxSlice=");
    sys.printU64(adapter.performance.maximum_instructions);
    sys.print(" timeLimited=");
    sys.printU64(adapter.performance.time_limited_steps);
    sys.print(" noFixedSleep=");
    sys.printU64(if (no_fixed_sleep) 1 else 0);
    sys.print(" result=");
    sys.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn performanceFailure(sys: r4os.r4sys.Context, stage: []const u8) i32 {
    sys.print("R4BASIC performance: stage=");
    sys.write(stage);
    sys.println(" result=FAILED");
    return 1;
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or value.len < needle.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= value.len) : (offset += 1) {
        if (std.ascii.eqlIgnoreCase(value[offset .. offset + needle.len], needle)) return true;
    }
    return false;
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

const LaunchTrace = struct {
    active: bool = false,
    baseline: bool = false,
    id: []const u8 = "",
    start_ns: u64 = 0,
    probe_ns: u64 = 0,
    resolve_ns: u64 = 0,
    desktop_ns: u64 = 0,

    fn parse(request: launch_api.Request) LaunchTrace {
        const id = (request.option(launch_api.trace_key) catch null) orelse return .{};
        if (id.len != 16) return .{};
        const start_ns = std.fmt.parseInt(u64, id, 16) catch return .{};
        var result = LaunchTrace{ .active = true, .id = id, .start_ns = start_ns };
        if ((request.option(launch_api.trace_mode_key) catch null)) |mode| {
            result.baseline = std.ascii.eqlIgnoreCase(mode, launch_api.trace_mode_headless);
        }
        if ((request.option(launch_api.trace_phases_key) catch null)) |phases| {
            var fields = std.mem.splitScalar(u8, phases, ',');
            const probe_elapsed = std.fmt.parseInt(u64, fields.next() orelse return result, 10) catch return result;
            const resolve_elapsed = std.fmt.parseInt(u64, fields.next() orelse return result, 10) catch return result;
            const desktop_elapsed = std.fmt.parseInt(u64, fields.next() orelse return result, 10) catch return result;
            if (fields.next() != null) return result;
            result.probe_ns = start_ns +| probe_elapsed;
            result.resolve_ns = start_ns +| resolve_elapsed;
            if (desktop_elapsed != 0) result.desktop_ns = start_ns +| desktop_elapsed;
        }
        return result;
    }
};

const LaunchTimeline = struct {
    app_main_ns: u64 = 0,
    source_begin_ns: u64 = 0,
    source_end_ns: u64 = 0,
    compile_begin_ns: u64 = 0,
    compile_end_ns: u64 = 0,
    vm_begin_ns: u64 = 0,
    vm_end_ns: u64 = 0,
    host_ready_ns: u64 = 0,
    initial_frame_ns: u64 = 0,
    runtime_begin_ns: u64 = 0,
    first_instruction_ns: u64 = 0,
    audio_open_ns: u64 = 0,
    first_frame_ns: u64 = 0,
};

fn monotonicNow(sys: r4os.r4sys.Context) u64 {
    return sys.monotonicNanoseconds() orelse 0;
}

fn canonicalBaselineSource(source: []const u8) bool {
    if (source.len != canonical_baseline_size) return false;
    var digest: [canonical_baseline_sha256.len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.mem.eql(u8, canonical_baseline_sha256[0..], digest[0..]);
}

fn writeBaselineFailure(files: *const r4os.Files, trace: LaunchTrace, reason: []const u8, code: i32) i32 {
    var report_storage: [256]u8 = undefined;
    const report = std.fmt.bufPrint(report_storage[0..], "R4BASIC baseline: FAILED id={s} reason={s} code={d}\r\n", .{
        trace.id,
        reason,
        code,
    }) catch return if (code == 0) error_trace_write else code;
    var path = r4os.AbsoluteFilePath.parse(baseline_report_path) catch return if (code == 0) error_trace_write else code;
    _ = files.write(path.asZ(), report);
    return if (code == 0) error_trace_write else code;
}

const RuntimeHost = struct {
    sys: r4os.r4sys.Context,
    files: *const r4os.Files,
    window: *host_api.Host,
    guest: *runtime_adapter.Adapter,
    timeline: *LaunchTimeline,
    trace: LaunchTrace,
    guest_path: []const u8,
    source_bytes: usize,
    program_instructions: usize,
    runtime: ?*runtime_api.Runtime = null,
    title: [title_capacity]u8 = [_]u8{0} ** title_capacity,
    title_len: usize = 0,
    audio_degraded: bool = false,
    trace_armed: bool = false,
    snapshot_pending: bool = false,
    snapshot_written: bool = false,

    fn init(
        sys: r4os.r4sys.Context,
        files: *const r4os.Files,
        window: *host_api.Host,
        guest: *runtime_adapter.Adapter,
        timeline: *LaunchTimeline,
        trace: LaunchTrace,
        guest_path: []const u8,
        source_bytes: usize,
        program_instructions: usize,
        guest_name: []const u8,
    ) RuntimeHost {
        var self = RuntimeHost{
            .sys = sys,
            .files = files,
            .window = window,
            .guest = guest,
            .timeline = timeline,
            .trace = trace,
            .guest_path = guest_path,
            .source_bytes = source_bytes,
            .program_instructions = program_instructions,
        };
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
        self.observeRuntime();
        if (self.snapshot_pending) {
            self.snapshot_pending = false;
            self.snapshot_written = self.writeSnapshot();
            if (!self.snapshot_written and self.trace.baseline) return .{ .failure = error_trace_write };
            if (self.trace.baseline) return .{ .command = .close };
        }
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
            .hidden, .unchanged => 0,
            .presented => blk: {
                if (self.trace_armed and self.trace.active and self.guest.performance.instructions != 0 and self.timeline.first_frame_ns == 0) {
                    self.timeline.first_frame_ns = monotonicNow(self.sys);
                    self.snapshot_pending = true;
                }
                break :blk 1;
            },
        };
    }

    fn observeRuntime(self: *RuntimeHost) void {
        if (self.timeline.first_instruction_ns == 0) self.timeline.first_instruction_ns = self.guest.performance.first_instruction_ns;
        if (self.timeline.audio_open_ns == 0) {
            if (self.runtime) |runtime| if (runtime.audio.stats.lazy_opens != 0) {
                self.timeline.audio_open_ns = monotonicNow(self.sys);
            };
        }
    }

    fn writeSnapshot(self: *RuntimeHost) bool {
        self.observeRuntime();
        const runtime = self.runtime orelse return false;
        const presenter = self.window.video.stats;
        var report_storage: [2048]u8 = undefined;
        var report_len: usize = 0;
        const header = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC {s}: OK id={s} mode={s} guest={s} source_bytes={d} bytecode={d}\r\n", .{
            if (self.trace.baseline) "baseline" else "trace",
            self.trace.id,
            if (self.trace.baseline) "headless" else "gui",
            self.guest_path,
            self.source_bytes,
            self.program_instructions,
        }) catch return false;
        report_len += header.len;
        const timeline = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC timeline: start_ns={d} probe_ns={d} resolve_ns={d} desktop_ns={d} app_ns={d} source_begin_ns={d} source_end_ns={d} compile_begin_ns={d} compile_end_ns={d} vm_begin_ns={d} vm_end_ns={d} host_ready_ns={d} initial_frame_ns={d} runtime_begin_ns={d} first_instruction_ns={d} audio_open_ns={d} first_frame_ns={d}\r\n", .{
            self.trace.start_ns,
            self.trace.probe_ns,
            self.trace.resolve_ns,
            self.trace.desktop_ns,
            self.timeline.app_main_ns,
            self.timeline.source_begin_ns,
            self.timeline.source_end_ns,
            self.timeline.compile_begin_ns,
            self.timeline.compile_end_ns,
            self.timeline.vm_begin_ns,
            self.timeline.vm_end_ns,
            self.timeline.host_ready_ns,
            self.timeline.initial_frame_ns,
            self.timeline.runtime_begin_ns,
            self.timeline.first_instruction_ns,
            self.timeline.audio_open_ns,
            self.timeline.first_frame_ns,
        }) catch return false;
        report_len += timeline.len;
        const runtime_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC runtime: requested_operations={d} executed_operations={d} slices={d} yields={d} sleeps={d} present_attempts={d} presents={d} skipped_presents={d}\r\n", .{
            runtime.stats.requested_operations,
            runtime.stats.executed_operations,
            runtime.stats.slices,
            runtime.stats.yields,
            runtime.stats.sleeps,
            runtime.stats.present_attempts,
            runtime.stats.presents,
            runtime.stats.skipped_presents,
        }) catch return false;
        report_len += runtime_line.len;
        const adapter_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC adapter: steps={d} instructions={d} max_slice={d} budget_limited={d} time_limited={d} frame_ready={d}\r\n", .{
            self.guest.performance.steps,
            self.guest.performance.instructions,
            self.guest.performance.maximum_instructions,
            self.guest.performance.budget_limited_steps,
            self.guest.performance.time_limited_steps,
            self.guest.performance.frame_ready_steps,
        }) catch return false;
        report_len += adapter_line.len;
        const presenter_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC presenter: published_frames={d} skipped_frames={d} full_frames={d} damage_frames={d} raster_blocks={d} sampled_pixels={d}\r\n", .{
            presenter.published_frames,
            presenter.skipped_frames,
            presenter.full_frames,
            presenter.damage_frames,
            presenter.raster_blocks,
            presenter.sampled_pixels,
        }) catch return false;
        report_len += presenter_line.len;
        const audio_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC audio: state={s} lazy_opens={d} generated_bytes={d} submitted_bytes={d} suppressed_bytes={d}\r\n", .{
            @tagName(runtime.audio.state),
            runtime.audio.stats.lazy_opens,
            runtime.audio.stats.generated_bytes,
            runtime.audio.stats.submitted_bytes,
            runtime.audio.stats.suppressed_bytes,
        }) catch return false;
        report_len += audio_line.len;
        const report = report_storage[0..report_len];
        const target_path = if (self.trace.baseline) baseline_report_path else gui_report_path;
        var path = r4os.AbsoluteFilePath.parse(target_path) catch return false;
        return switch (self.files.write(path.asZ(), report)) {
            .bytes => |count| count == report.len,
            .end, .failure => false,
        };
    }
};

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
