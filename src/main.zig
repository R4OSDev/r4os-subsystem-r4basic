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
const audio_service_timeout_ns: u64 = 25 * std.time.ns_per_ms;
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
    var source_owned = true;
    defer if (source_owned) allocator.free(source);
    timeline.source_end_ns = monotonicNow(sys);
    if (trace.baseline and (!std.ascii.eqlIgnoreCase(launch.guest_path, canonical_baseline_path) or !canonicalBaselineSource(source))) {
        return writeBaselineFailure(&files, trace, "source-identity", 67);
    }

    timeline.compile_begin_ns = monotonicNow(sys);
    var compile_display: graphics_screen.Screen = .{};
    defer compile_display.deinit(allocator);
    compile_display.setMode(allocator, 0) catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "compile-display", error_host_video);
        return error_host_video;
    };
    var compile_text: text_screen.Screen = .{};
    const compile_view = compile_display.view() orelse return error_host_video;
    const compile_surface = host_api.Surface.initIndexed8(
        compile_view.pixels,
        compile_view.palette,
        compile_view.width,
        compile_view.height,
    ) catch return error_host_video;
    var raster_scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window_host = host_api.Host.init(desk, draw, compile_surface, raster_scratch[0..]) catch {
        if (trace.baseline) return writeBaselineFailure(&files, trace, "compile-window", error_host_video);
        return error_host_video;
    };
    window_host.setInputPolicy(.text_only_no_pointer);
    _ = window_host.setMinimumSize(320, 200);
    var compile_progress = CompileProgressView.init(
        sys,
        &window_host,
        &compile_text,
        &compile_display,
        baseName(launch.guest_path),
        &timeline,
    );
    const compile_vm_before = r4os.vm_allocator.stats();
    source_owned = false;
    var program = compiler.compileOwnedObserved(allocator, launch.guest_path, source, compile_progress.observer()) catch |fault| {
        if (fault == error.Cancelled) {
            if (compile_progress.failure != 0) {
                if (trace.baseline) return writeBaselineFailure(&files, trace, "compile-progress", compile_progress.failure);
                return compile_progress.failure;
            }
            return 0;
        }
        if (trace.baseline) return writeBaselineFailure(&files, trace, @errorName(fault), 68);
        return showStatus(allocator, sys, desk, draw, "R4BASIC - Compilerfehler", &.{
            "Der BASIC-Compiler konnte nicht initialisiert werden.",
            @errorName(fault),
        });
    };
    const compile_vm_memory = CompileVmMemory.capture(compile_vm_before, r4os.vm_allocator.stats());
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
    timeline.vm_end_ns = monotonicNow(sys);
    var guest_adapter = runtime_adapter.Adapter.initSystem(&machine, &sys);

    var audio_sink_storage: runtime_api.R4AudioSink = undefined;
    var sink: ?runtime_api.AudioSink = null;
    if (app.audio()) |app_audio| {
        audio_sink_storage = runtime_api.R4AudioSink.initWithTimeout(app_audio, audio_service_timeout_ns);
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
        &storage,
        &timeline,
        trace,
        launch.guest_path,
        source.len,
        program.instructions.len,
        program.compile_stats,
        compile_vm_memory,
        baseName(launch.guest_path),
    );
    runtime_host.runtime = &runtime;
    runtime_host.applyNormalTitle();
    _ = window_host.setMinimumSize(320, 200);
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

const performance_numeric_source =
    \\DEFINT A-Z
    \\A = 0
    \\Work:
    \\A = A + 1
    \\IF A >= 30000 THEN A = 0
    \\GOTO Work
;

const performance_string_assignment_source =
    \\A$ = SPACE$(4096)
    \\Work:
    \\B$ = A$
    \\GOTO Work
;

const performance_string_len_source =
    \\A$ = SPACE$(4096)
    \\Work:
    \\L% = LEN(A$)
    \\GOTO Work
;

const performance_string_ucase_source =
    \\A$ = SPACE$(4096)
    \\Work:
    \\B$ = UCASE$(A$)
    \\GOTO Work
;

const performance_call_source =
    \\DEFINT A-Z
    \\DECLARE SUB Work ()
    \\DIM SHARED A AS LONG
    \\Again:
    \\CALL Work()
    \\GOTO Again
    \\SUB Work ()
    \\    DIM LocalValue AS LONG
    \\    LocalValue = A
    \\    A = A + 1
    \\END SUB
;

const performance_array_source =
    \\DEFINT A-Z
    \\DIM Values(255) AS LONG
    \\I = 0
    \\Work:
    \\Values(I) = Values(I) + 1
    \\I = I + 1
    \\IF I > 255 THEN I = 0
    \\GOTO Work
;

const PerformanceKind = enum {
    numeric,
    string_assignment,
    string_len,
    string_ucase,
    call,
    array,
};

const PerformanceWorkload = struct {
    name: []const u8,
    file_name: []const u8,
    source: []const u8,
    kind: PerformanceKind,
};

const performance_workloads = [_]PerformanceWorkload{
    .{ .name = "numeric", .file_name = "R4BASIC-PERF-NUMERIC.BAS", .source = performance_numeric_source, .kind = .numeric },
    .{ .name = "string-assign", .file_name = "R4BASIC-PERF-STRING-ASSIGN.BAS", .source = performance_string_assignment_source, .kind = .string_assignment },
    .{ .name = "string-len", .file_name = "R4BASIC-PERF-STRING-LEN.BAS", .source = performance_string_len_source, .kind = .string_len },
    .{ .name = "string-ucase", .file_name = "R4BASIC-PERF-STRING-UCASE.BAS", .source = performance_string_ucase_source, .kind = .string_ucase },
    .{ .name = "call", .file_name = "R4BASIC-PERF-CALL.BAS", .source = performance_call_source, .kind = .call },
    .{ .name = "array", .file_name = "R4BASIC-PERF-ARRAY.BAS", .source = performance_array_source, .kind = .array },
};

const PerformanceResult = struct {
    instructions: u64,
    elapsed_ticks: u64,
    ips: u64,
    slices: u64,
    maximum_slice: u32,
    time_limited_steps: u64,
    no_fixed_sleep: bool,
    clock_reads: u64,
    maximum_clock_reads: u32,
    ns_per_instruction: u64,
    stats: vm.PerformanceStats,
    ok: bool,
};

fn runPerformanceSelfTest(app: *r4os.App) i32 {
    const allocator = app.allocator() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    var results: [performance_workloads.len]PerformanceResult = undefined;
    var all_ok = true;
    for (performance_workloads, 0..) |workload, index| {
        sys.print("R4BASIC performance stage: workload=");
        sys.write(workload.name);
        sys.println(" phase=run");
        results[index] = runPerformanceWorkload(allocator, &sys, workload) orelse return performanceFailure(sys, workload.name);
        writePerformanceWorkload(sys, workload, results[index]);
        all_ok = all_ok and results[index].ok;
    }

    sys.print("R4BASIC performance: numericIps=");
    sys.printU64(results[0].ips);
    sys.print(" stringAssignIps=");
    sys.printU64(results[1].ips);
    sys.print(" stringLenIps=");
    sys.printU64(results[2].ips);
    sys.print(" stringUcaseIps=");
    sys.printU64(results[3].ips);
    sys.print(" callIps=");
    sys.printU64(results[4].ips);
    sys.print(" arrayIps=");
    sys.printU64(results[5].ips);
    sys.print(" result=");
    sys.println(if (all_ok) "OK" else "FAILED");
    return if (all_ok) 0 else 1;
}

fn runPerformanceWorkload(allocator: std.mem.Allocator, sys: *const r4os.r4sys.Context, workload: PerformanceWorkload) ?PerformanceResult {
    var program = compiler.compile(allocator, workload.file_name, workload.source) catch return null;
    defer program.deinit();
    if (!program.ok()) return null;
    var machine = vm.Vm.init(allocator, &program, .{}) catch return null;
    defer machine.deinit();
    var adapter = runtime_adapter.Adapter.initSystem(&machine, sys);
    const hz = @max(sys.monotonicHz(), 1);
    const start_tick = sys.ticks();
    const benchmark_ticks = @max((@as(u64, hz) * 200 + 999) / 1000, 1);
    const deadline = start_tick +| benchmark_ticks;
    var slices: u64 = 0;
    var no_fixed_sleep = true;
    while (sys.ticks() < deadline) {
        const result = adapter.driver().step(runtime_api.default_slice_budget, 0);
        if (result.status != .progress) return null;
        if (result.wake_guest_ns != 0) no_fixed_sleep = false;
        slices +%= 1;
    }
    const elapsed = @max(sys.ticks() -| start_tick, 1);
    const instructions = machine.total_instructions;
    const ips: u64 = @intCast((@as(u128, instructions) * hz) / elapsed);
    machine.requestCancel();
    _ = adapter.driver().step(runtime_api.default_slice_budget, 0);
    const stats = machine.performanceStats();
    const ns_per_instruction = if (instructions == 0) @as(u64, 0) else adapter.performance.elapsed_ns / instructions;
    const common_ok = machine.status == .cancelled and no_fixed_sleep and ips != 0 and
        adapter.performance.maximum_instructions <= runtime_api.default_slice_budget and
        adapter.performance.maximum_clock_reads <= 20 and ns_per_instruction != 0 and
        stats.cancel_callback_checks != 0 and stats.cancel_callback_checks < instructions and
        stats.instruction_metadata_reads != 0 and stats.instruction_metadata_reads < instructions and
        stats.text_sync_checks != 0 and stats.text_sync_checks < instructions and
        stats.cell_resolve_calls != 0;
    const workload_ok = switch (workload.kind) {
        .numeric => ips >= 52_000 and stats.group(.value) != 0 and stats.group(.arithmetic) != 0 and stats.group(.control) != 0,
        .string_assignment => stats.string_clones != 0 and stats.string_clone_bytes == stats.string_clones * 4096,
        .string_len => stats.builtin_borrowed_arguments != 0 and stats.string_clones == 0,
        .string_ucase => stats.builtin_borrowed_arguments != 0 and stats.string_clones == 0,
        .call => stats.procedure_calls != 0 and stats.local_pool_grows != 0 and stats.local_pool_reuses != 0 and
            stats.local_pool_grows + stats.local_pool_reuses == stats.procedure_calls and
            stats.local_initializations == stats.procedure_calls,
        .array => stats.group(.value) != 0 and stats.group(.arithmetic) != 0,
    };
    return .{
        .instructions = instructions,
        .elapsed_ticks = elapsed,
        .ips = ips,
        .slices = slices,
        .maximum_slice = adapter.performance.maximum_instructions,
        .time_limited_steps = adapter.performance.time_limited_steps,
        .no_fixed_sleep = no_fixed_sleep,
        .clock_reads = adapter.performance.clock_reads,
        .maximum_clock_reads = adapter.performance.maximum_clock_reads,
        .ns_per_instruction = ns_per_instruction,
        .stats = stats,
        .ok = common_ok and workload_ok,
    };
}

fn writePerformanceWorkload(sys: r4os.r4sys.Context, workload: PerformanceWorkload, result: PerformanceResult) void {
    sys.print("R4BASIC performance-workload: name=");
    sys.write(workload.name);
    sys.print(" instructions=");
    sys.printU64(result.instructions);
    sys.print(" ticks=");
    sys.printU64(result.elapsed_ticks);
    sys.print(" ips=");
    sys.printU64(result.ips);
    sys.print(" slices=");
    sys.printU64(result.slices);
    sys.print(" maxSlice=");
    sys.printU64(result.maximum_slice);
    sys.print(" timeLimited=");
    sys.printU64(result.time_limited_steps);
    sys.print(" noFixedSleep=");
    sys.printU64(if (result.no_fixed_sleep) 1 else 0);
    sys.print(" clockReads=");
    sys.printU64(result.clock_reads);
    sys.print(" maxClockReads=");
    sys.printU64(result.maximum_clock_reads);
    sys.print(" nsPerInstruction=");
    sys.printU64(result.ns_per_instruction);
    sys.print(" stringClones=");
    sys.printU64(result.stats.string_clones);
    sys.print(" stringCloneBytes=");
    sys.printU64(result.stats.string_clone_bytes);
    sys.print(" borrowedBuiltins=");
    sys.printU64(result.stats.builtin_borrowed_arguments);
    sys.print(" ownedBuiltins=");
    sys.printU64(result.stats.builtin_owned_arguments);
    sys.print(" procedureCalls=");
    sys.printU64(result.stats.procedure_calls);
    sys.print(" localPoolGrows=");
    sys.printU64(result.stats.local_pool_grows);
    sys.print(" localPoolReuses=");
    sys.printU64(result.stats.local_pool_reuses);
    sys.print(" localInitializations=");
    sys.printU64(result.stats.local_initializations);
    sys.print(" result=");
    sys.println(if (result.ok) "OK" else "FAILED");
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
    compile_visible_ns: u64 = 0,
    compile_end_ns: u64 = 0,
    compile_progress_updates: u32 = 0,
    vm_begin_ns: u64 = 0,
    vm_end_ns: u64 = 0,
    host_ready_ns: u64 = 0,
    initial_frame_ns: u64 = 0,
    runtime_begin_ns: u64 = 0,
    first_instruction_ns: u64 = 0,
    audio_open_ns: u64 = 0,
    first_frame_ns: u64 = 0,
};

const CompileProgressView = struct {
    sys: r4os.r4sys.Context,
    window: *host_api.Host,
    text: *text_screen.Screen,
    display: *graphics_screen.Screen,
    guest_name: []const u8,
    timeline: *LaunchTimeline,
    last_phase: ?compiler.CompilePhase = null,
    last_percent: u8 = 255,
    failure: i32 = 0,
    title: [title_capacity]u8 = [_]u8{0} ** title_capacity,

    fn init(
        sys: r4os.r4sys.Context,
        window: *host_api.Host,
        text: *text_screen.Screen,
        display: *graphics_screen.Screen,
        guest_name: []const u8,
        timeline: *LaunchTimeline,
    ) CompileProgressView {
        return .{
            .sys = sys,
            .window = window,
            .text = text,
            .display = display,
            .guest_name = guest_name,
            .timeline = timeline,
        };
    }

    fn observer(self: *CompileProgressView) compiler.CompileObserver {
        return .{ .context = self, .update_fn = update };
    }

    fn update(context: *anyopaque, progress: compiler.CompileProgress) bool {
        const self: *CompileProgressView = @ptrCast(@alignCast(context));
        if (!self.poll()) return false;
        const percent = progressPercent(progress);
        if (self.last_phase != progress.phase or self.last_percent != percent) {
            self.render(progress.phase, percent);
            if (self.failure != 0) return false;
            self.last_phase = progress.phase;
            self.last_percent = percent;
        }
        self.sys.taskYield();
        return !self.sys.programShouldClose();
    }

    fn poll(self: *CompileProgressView) bool {
        if (self.sys.programShouldClose()) return false;
        var remaining: usize = 32;
        while (remaining != 0) : (remaining -= 1) {
            const event = self.window.pollInput() orelse break;
            switch (event) {
                .close => return false,
                .resize => self.window.video.invalidateAll(),
                .key_down => |key| if (key.code == 27) return false,
                else => {},
            }
        }
        return true;
    }

    fn render(self: *CompileProgressView, phase: compiler.CompilePhase, percent: u8) void {
        const phase_text = switch (phase) {
            .lexical => "Quelltext und Schluesselwoerter",
            .binding => "Anweisungen und Symbole",
            .resolution => "Sprungziele und Datenmarken",
        };
        const filled: usize = @min(50, (@as(usize, percent) * 50) / 100);
        if (self.last_phase == null) {
            self.text.reset();
            self.text.setColor(15, 1) catch {};
            self.text.locate(null, null, 0, null, null) catch {};
            self.text.write("R4BASIC\r\n\r\n");
            self.text.write("Kompiliere: ");
            self.text.write(self.guest_name);
            self.text.write("\r\n\r\nPhase: ");
            self.text.write(phase_text);
            var percent_storage: [48]u8 = undefined;
            const percent_text = std.fmt.bufPrint(percent_storage[0..], "\r\nFortschritt: {d}%\r\n\r\n[", .{percent}) catch "\r\nFortschritt\r\n\r\n[";
            self.text.write(percent_text);
            for (0..50) |index| self.text.writeByte(if (index < filled) 219 else 176);
            self.text.write("]\r\n\r\nFenster schliessen oder Escape druecken, um abzubrechen.");
        } else {
            var phase_storage: [text_screen.columns]u8 = [_]u8{' '} ** text_screen.columns;
            const phase_line = std.fmt.bufPrint(phase_storage[0..], "Phase: {s}", .{phase_text}) catch phase_storage[0..0];
            @memset(phase_storage[phase_line.len..], ' ');
            self.writeLine(5, phase_storage[0..]);

            var percent_storage: [text_screen.columns]u8 = [_]u8{' '} ** text_screen.columns;
            const percent_line = std.fmt.bufPrint(percent_storage[0..], "Fortschritt: {d}%", .{percent}) catch percent_storage[0..0];
            @memset(percent_storage[percent_line.len..], ' ');
            self.writeLine(6, percent_storage[0..]);

            var bar: [text_screen.columns]u8 = [_]u8{' '} ** text_screen.columns;
            bar[0] = '[';
            for (0..50) |index| bar[index + 1] = if (index < filled) 219 else 176;
            bar[51] = ']';
            self.writeLine(8, bar[0..]);
        }
        const dirty = self.text.takeDirty();
        for (dirty.slice()) |region| self.display.renderText(self.text, region);
        const damage = self.display.takeDamage();
        for (damage.slice()) |region| self.window.video.invalidate(.{
            .x = region.x,
            .y = region.y,
            .w = region.w,
            .h = region.h,
        });
        const title = std.fmt.bufPrintZ(self.title[0..], "R4BASIC - Kompiliert {s} ({d}%)", .{ self.guest_name, percent }) catch "R4BASIC - Kompiliert";
        _ = self.window.setTitle(title.ptr);
        switch (self.window.present()) {
            .failure => |raw| self.failure = raw,
            .presented => {
                if (self.timeline.compile_visible_ns == 0) self.timeline.compile_visible_ns = monotonicNow(self.sys);
                self.timeline.compile_progress_updates +%= 1;
            },
            .hidden, .unchanged => {},
        }
    }

    fn writeLine(self: *CompileProgressView, row: i32, line: []const u8) void {
        self.text.locate(row, 1, null, null, null) catch return;
        self.text.write(line);
    }

    fn progressPercent(progress: compiler.CompileProgress) u8 {
        const range = switch (progress.phase) {
            .lexical => .{ @as(usize, 0), @as(usize, 30) },
            .binding => .{ @as(usize, 30), @as(usize, 65) },
            .resolution => .{ @as(usize, 95), @as(usize, 5) },
        };
        if (progress.total == 0) return @intCast(range[0] + range[1]);
        const completed = @min(progress.completed, progress.total);
        return @intCast(range[0] + (@as(u128, completed) * range[1]) / progress.total);
    }
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

const CompileVmMemory = struct {
    allocations: u64,
    frees: u64,
    active_before: u64,
    active_after: u64,
    peak_active: u64,
    reserved_before: u64,
    reserved_after: u64,
    committed_before: u64,
    committed_after: u64,

    fn capture(before: r4os.vm_allocator.Stats, after: r4os.vm_allocator.Stats) CompileVmMemory {
        return .{
            .allocations = after.allocations -| before.allocations,
            .frees = after.frees -| before.frees,
            .active_before = before.active_bytes,
            .active_after = after.active_bytes,
            .peak_active = after.peak_active_bytes,
            .reserved_before = before.reserved_bytes,
            .reserved_after = after.reserved_bytes,
            .committed_before = before.committed_bytes,
            .committed_after = after.committed_bytes,
        };
    }
};

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
    storage: *const storage_adapter.Adapter,
    timeline: *LaunchTimeline,
    trace: LaunchTrace,
    guest_path: []const u8,
    source_bytes: usize,
    program_instructions: usize,
    compile_stats: @import("bytecode.zig").CompileStats,
    compile_vm_memory: CompileVmMemory,
    runtime: ?*runtime_api.Runtime = null,
    title: [title_capacity]u8 = [_]u8{0} ** title_capacity,
    title_len: usize = 0,
    audio_degraded: bool = false,
    trace_armed: bool = false,
    snapshot_pending: bool = false,
    snapshot_written: bool = false,
    activity_sequence: u64 = 0,

    fn init(
        sys: r4os.r4sys.Context,
        files: *const r4os.Files,
        window: *host_api.Host,
        guest: *runtime_adapter.Adapter,
        storage: *const storage_adapter.Adapter,
        timeline: *LaunchTimeline,
        trace: LaunchTrace,
        guest_path: []const u8,
        source_bytes: usize,
        program_instructions: usize,
        compile_stats: @import("bytecode.zig").CompileStats,
        compile_vm_memory: CompileVmMemory,
        guest_name: []const u8,
    ) RuntimeHost {
        var self = RuntimeHost{
            .sys = sys,
            .files = files,
            .window = window,
            .guest = guest,
            .storage = storage,
            .timeline = timeline,
            .trace = trace,
            .guest_path = guest_path,
            .source_bytes = source_bytes,
            .program_instructions = program_instructions,
            .compile_stats = compile_stats,
            .compile_vm_memory = compile_vm_memory,
        };
        const value = std.fmt.bufPrintZ(self.title[0..], "R4BASIC - {s}", .{guest_name}) catch "R4BASIC";
        self.title_len = value.len;
        return self;
    }

    fn driver(self: *RuntimeHost) runtime_api.HostDriver {
        return .{
            .context = self,
            .poll_fn = poll,
            .present_fn = present,
            .wait_fn = if (self.window.desk.hasFn("desktop_activity_wait")) wait else null,
            .should_close_fn = shouldClose,
        };
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
        if (self.runtime) |runtime| if (runtime.audio.state == .degraded) self.applyDegradedTitle();
        const event = self.window.pollInput() orelse return .idle;
        return switch (event) {
            .close => blk: {
                _ = self.guest.handleInput(event);
                break :blk .{ .command = .close };
            },
            .resize => blk: {
                _ = self.guest.handleInput(event);
                self.window.video.invalidateAll();
                break :blk .present;
            },
            .focus => |focus| blk: {
                _ = self.guest.handleInput(event);
                break :blk if (focus.focused) .present else .handled;
            },
            else => if (self.guest.handleInput(event).wakesGuest()) .handled else .ignored,
        };
    }

    fn shouldClose(context: *anyopaque) bool {
        const self: *RuntimeHost = @ptrCast(@alignCast(context));
        return self.sys.programShouldClose();
    }

    fn wait(context: *anyopaque, timeout_ticks: u64) i32 {
        const self: *RuntimeHost = @ptrCast(@alignCast(context));
        var sequence = self.activity_sequence;
        const raw = self.window.desk.desktopActivityWait(self.activity_sequence, timeout_ticks, &sequence);
        self.activity_sequence = sequence;
        return raw;
    }

    fn present(context: *anyopaque) i32 {
        const self: *RuntimeHost = @ptrCast(@alignCast(context));
        const started_ns = monotonicNow(self.sys);
        _ = self.guest.syncVideo(&self.window.video) catch {
            const ended_ns = monotonicNow(self.sys);
            self.guest.notePresent(.failed, started_ns, ended_ns);
            return error_host_video;
        };
        if (!self.guest.hasHostDisplay()) {
            const ended_ns = monotonicNow(self.sys);
            self.guest.notePresent(.unchanged, started_ns, ended_ns);
            return runtime_api.host_present_unchanged;
        }
        return switch (self.window.present()) {
            .failure => |raw| blk: {
                self.guest.notePresent(.failed, started_ns, monotonicNow(self.sys));
                break :blk raw;
            },
            .hidden => blk: {
                self.guest.notePresent(.hidden, started_ns, monotonicNow(self.sys));
                break :blk runtime_api.host_present_hidden;
            },
            .unchanged => blk: {
                self.guest.notePresent(.unchanged, started_ns, monotonicNow(self.sys));
                break :blk runtime_api.host_present_unchanged;
            },
            .presented => blk: {
                const ended_ns = monotonicNow(self.sys);
                self.guest.notePresent(.presented, started_ns, ended_ns);
                if (self.trace_armed and self.trace.active and self.guest.performance.instructions != 0 and self.timeline.first_frame_ns == 0) {
                    self.timeline.first_frame_ns = ended_ns;
                    self.snapshot_pending = true;
                }
                break :blk runtime_api.host_presented;
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
        var report_storage: [12 * 1024]u8 = undefined;
        var report_len: usize = 0;
        const vm_stats = self.guest.machine.performanceStats();
        const ns_per_instruction = if (self.guest.performance.instructions == 0)
            @as(u64, 0)
        else
            self.guest.performance.elapsed_ns / self.guest.performance.instructions;
        const header = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC {s}: OK id={s} mode={s} guest={s} source_bytes={d} bytecode={d}\r\n", .{
            if (self.trace.baseline) "baseline" else "trace",
            self.trace.id,
            if (self.trace.baseline) "headless" else "gui",
            self.guest_path,
            self.source_bytes,
            self.program_instructions,
        }) catch return false;
        report_len += header.len;
        const timeline = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC timeline: start_ns={d} probe_ns={d} resolve_ns={d} desktop_ns={d} app_ns={d} source_begin_ns={d} source_end_ns={d} compile_begin_ns={d} compile_visible_ns={d} compile_end_ns={d} compile_updates={d} vm_begin_ns={d} vm_end_ns={d} host_ready_ns={d} initial_frame_ns={d} runtime_begin_ns={d} first_instruction_ns={d} audio_open_ns={d} first_frame_ns={d}\r\n", .{
            self.trace.start_ns,
            self.trace.probe_ns,
            self.trace.resolve_ns,
            self.trace.desktop_ns,
            self.timeline.app_main_ns,
            self.timeline.source_begin_ns,
            self.timeline.source_end_ns,
            self.timeline.compile_begin_ns,
            self.timeline.compile_visible_ns,
            self.timeline.compile_end_ns,
            self.timeline.compile_progress_updates,
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
        const compiler_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC compiler: tokens={d} token_capacity={d} keyword_lookups={d} keyword_probes={d} keyword_max_probe={d} name_lookups={d} name_insertions={d} name_probes={d} name_max_probe={d} index_rebuilds={d} constant_lookups={d} constant_reuses={d} constant_probes={d} constant_max_probe={d} label_fixups={d} data_fixups={d} reused_bindings={d} expression_depth={d} progress_updates={d}\r\n", .{
            self.compile_stats.tokens,
            self.compile_stats.token_capacity,
            self.compile_stats.keyword_lookups,
            self.compile_stats.keyword_probes,
            self.compile_stats.keyword_max_probe,
            self.compile_stats.name_lookups,
            self.compile_stats.name_insertions,
            self.compile_stats.name_probes,
            self.compile_stats.name_max_probe,
            self.compile_stats.index_rebuilds,
            self.compile_stats.constant_lookups,
            self.compile_stats.constant_reuses,
            self.compile_stats.constant_probes,
            self.compile_stats.constant_max_probe,
            self.compile_stats.label_fixups,
            self.compile_stats.data_fixups,
            self.compile_stats.reused_statement_bindings,
            self.compile_stats.maximum_expression_depth,
            self.compile_stats.progress_updates,
        }) catch return false;
        report_len += compiler_line.len;
        const compiler_memory_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC compiler-memory: token_bytes={d} initial_list_bytes={d} instruction_hot_bytes={d} instruction_metadata_bytes={d} allocations={d} reallocations={d} copy_bytes={d} peak_bytes={d} program_bytes={d} adopted_source_bytes={d} diagnostics_total={d} diagnostics_stored={d} diagnostics_truncated={d}\r\n", .{
            self.compile_stats.token_bytes,
            self.compile_stats.initial_list_bytes,
            self.compile_stats.instruction_hot_bytes,
            self.compile_stats.instruction_metadata_bytes,
            self.compile_stats.allocator_allocations,
            self.compile_stats.allocator_reallocations,
            self.compile_stats.allocator_copy_bytes,
            self.compile_stats.compiler_peak_bytes,
            self.compile_stats.program_bytes,
            self.compile_stats.adopted_source_bytes,
            self.compile_stats.diagnostics_total,
            self.compile_stats.diagnostics_stored,
            @intFromBool(self.compile_stats.diagnostics_truncated),
        }) catch return false;
        report_len += compiler_memory_line.len;
        const compiler_vm_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC compiler-vm: allocations={d} frees={d} active_before={d} active_after={d} peak_active={d} reserved_before={d} reserved_after={d} committed_before={d} committed_after={d}\r\n", .{
            self.compile_vm_memory.allocations,
            self.compile_vm_memory.frees,
            self.compile_vm_memory.active_before,
            self.compile_vm_memory.active_after,
            self.compile_vm_memory.peak_active,
            self.compile_vm_memory.reserved_before,
            self.compile_vm_memory.reserved_after,
            self.compile_vm_memory.committed_before,
            self.compile_vm_memory.committed_after,
        }) catch return false;
        report_len += compiler_vm_line.len;
        const runtime_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC runtime: cycles={d} close_checks={d} host_polls={d} poll_budget_exhaustions={d} active_cycles={d} waiting_cycles={d} paused_cycles={d} requested_operations={d} executed_operations={d} slices={d} active_continues={d} yields={d} sleeps={d} event_waits={d} event_wakes={d} event_timeouts={d} wait_failures={d} zero_progress_waits={d} present_attempts={d} presents={d} unchanged_presents={d} hidden_presents={d} dropped_presents={d}\r\n", .{
            runtime.stats.cycles,
            runtime.stats.close_checks,
            runtime.stats.host_polls,
            runtime.stats.poll_budget_exhaustions,
            runtime.stats.active_cycles,
            runtime.stats.waiting_cycles,
            runtime.stats.paused_cycles,
            runtime.stats.requested_operations,
            runtime.stats.executed_operations,
            runtime.stats.slices,
            runtime.stats.active_continues,
            runtime.stats.yields,
            runtime.stats.sleeps,
            runtime.stats.event_waits,
            runtime.stats.event_wakes,
            runtime.stats.event_timeouts,
            runtime.stats.event_wait_failures,
            runtime.stats.zero_progress_waits,
            runtime.stats.present_attempts,
            runtime.stats.presents,
            runtime.stats.unchanged_presents,
            runtime.stats.hidden_presents,
            runtime.stats.dropped_presents,
        }) catch return false;
        report_len += runtime_line.len;
        const adapter_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC adapter: steps={d} instructions={d} max_slice={d} budget_limited={d} time_limited={d} frame_ready={d} display_prepares={d} clock_reads={d} max_clock_reads={d} max_clock_chunk={d} active_vm_ns={d} ns_per_instruction={d}\r\n", .{
            self.guest.performance.steps,
            self.guest.performance.instructions,
            self.guest.performance.maximum_instructions,
            self.guest.performance.budget_limited_steps,
            self.guest.performance.time_limited_steps,
            self.guest.performance.frame_ready_steps,
            self.guest.performance.display_prepares,
            self.guest.performance.clock_reads,
            self.guest.performance.maximum_clock_reads,
            self.guest.performance.maximum_clock_chunk,
            self.guest.performance.elapsed_ns,
            ns_per_instruction,
        }) catch return false;
        report_len += adapter_line.len;
        const input_translation = self.window.input.stats;
        const host_stats = self.window.stats;
        const input = vm_stats.input;
        const input_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC input: raw={d} translated={d} filtered={d} pending_created={d} pending_emitted={d} mouse_events={d} mouse_moves={d} mouse_mappings={d} window_info={d} input_window_info={d} viewport_calculations={d} adapter_events={d} accepted={d} controls={d} dropped={d} runtime_input={d} runtime_ignored={d} queue={d} queue_max={d} consumed={d} unfocused={d} invalid_codepoint={d} unsupported_key={d} unsupported_event={d} queue_full={d} oom={d}\r\n", .{
            input_translation.raw_events,
            input_translation.logical_events,
            input_translation.filtered_events,
            input_translation.pending_text_created,
            input_translation.pending_text_emitted,
            input_translation.mouse_events,
            input_translation.mouse_moves,
            input_translation.mouse_mappings,
            host_stats.window_info_calls,
            host_stats.input_window_info_calls,
            host_stats.viewport_calculations,
            self.guest.performance.input_logical_events,
            input.accepted_bytes,
            input.control_events,
            input.dropped_events,
            runtime.stats.input_events,
            runtime.stats.ignored_input_events,
            self.guest.machine.queuedInputBytes(),
            input.maximum_queue_depth,
            input.consumed_bytes,
            input.unfocused_drops,
            input.invalid_codepoint_drops,
            input.unsupported_key_drops,
            input.unsupported_event_drops,
            input.queue_full_drops,
            input.out_of_memory_drops,
        }) catch return false;
        report_len += input_line.len;
        const input_correlation_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC input-correlation: last_raw_sequence={d} last_raw_tick={d} last_filter_sequence={d} last_filter_tick={d} last_filter_reason={s} last_event_sequence={d} last_event_tick={d} last_accepted_sequence={d} last_accepted_tick={d} last_dropped_sequence={d} last_dropped_tick={d} last_drop_reason={s} last_consumed_sequence={d} last_consumed_tick={d} visible_sequence={d} visible_tick={d} visible_reaction_ns={d}\r\n", .{
            input_translation.last_raw_sequence,
            input_translation.last_raw_tick,
            input_translation.last_filtered_sequence,
            input_translation.last_filtered_tick,
            @tagName(input_translation.last_filter_reason),
            input.last_event_sequence,
            input.last_event_tick,
            input.last_accepted_sequence,
            input.last_accepted_tick,
            input.last_dropped_sequence,
            input.last_dropped_tick,
            @tagName(input.last_drop_reason),
            input.last_consumed_sequence,
            input.last_consumed_tick,
            self.guest.performance.last_visible_input_sequence,
            self.guest.performance.last_visible_input_tick,
            self.guest.performance.last_visible_reaction_ns,
        }) catch return false;
        report_len += input_correlation_line.len;
        const frame_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC frame-cycle: cadence_deferred={d} missed_deadlines={d} max_backlog={d} attempts={d} published={d} unchanged={d} hidden={d} dropped={d} failed={d} present_ns={d} max_present_ns={d} max_age_start_ns={d} max_age_end_ns={d}\r\n", .{
            self.guest.performance.cadence_deferred_steps,
            self.guest.performance.missed_frame_deadlines,
            self.guest.performance.maximum_frame_backlog,
            self.guest.performance.present_attempts,
            self.guest.performance.presents,
            self.guest.performance.unchanged_presents,
            self.guest.performance.hidden_presents,
            self.guest.performance.dropped_presents,
            self.guest.performance.failed_presents,
            self.guest.performance.present_elapsed_ns,
            self.guest.performance.maximum_present_ns,
            self.guest.performance.maximum_frame_age_start_ns,
            self.guest.performance.maximum_frame_age_end_ns,
        }) catch return false;
        report_len += frame_line.len;
        const vm_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC vm: cancel_flag_checks={d} cancel_callback_checks={d} group_lookups={d} text_sync_checks={d} text_sync_renders={d} metadata_reads={d} cell_resolves={d} alias_hops={d} same_type_store_moves={d} conversions={d} integer_comparisons={d} floating_comparisons={d} string_comparisons={d} timer_calls={d} timer_waits={d} timer_max_wake_lateness_ns={d}\r\n", .{
            vm_stats.cancel_flag_checks,
            vm_stats.cancel_callback_checks,
            vm_stats.operation_group_lookups,
            vm_stats.text_sync_checks,
            vm_stats.text_sync_renders,
            vm_stats.instruction_metadata_reads,
            vm_stats.cell_resolve_calls,
            vm_stats.cell_alias_hops,
            vm_stats.same_type_store_moves,
            vm_stats.value_conversions,
            vm_stats.integer_comparisons,
            vm_stats.floating_comparisons,
            vm_stats.string_comparisons,
            vm_stats.timer_calls,
            vm_stats.timer_waits,
            vm_stats.maximum_timer_wake_lateness_ns,
        }) catch return false;
        report_len += vm_line.len;
        const raster = vm_stats.raster;
        const raster_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC raster: mode_allocations={d} mode_reuses={d} mode_clear_bytes={d} pixel_probes={d} pixel_changes={d} spans={d} span_pixels={d} damage_commits={d} text_cells={d} text_rows={d} line_segments={d} line_pixels={d} fill_spans={d} paint_spans={d} paint_pixels={d} paint_probes={d} paint_pushes={d} paint_pops={d} paint_duplicate_pops={d} paint_grows={d} paint_queue_max={d} circle_requested={d} circle_segments={d} circle_skipped={d} capture_calls={d} capture_pixels={d} capture_bytes={d} put_calls={d} put_pixels={d} put_bytes={d}\r\n", .{
            raster.mode_allocations,
            raster.mode_reuses,
            raster.mode_clear_bytes,
            raster.pixel_probes,
            raster.pixel_changes,
            raster.span_operations,
            raster.span_pixels,
            raster.damage_commits,
            raster.text_cells,
            raster.text_rows,
            raster.line_segments,
            raster.line_pixels,
            raster.fill_spans,
            raster.paint_spans,
            raster.paint_pixels,
            raster.paint_pixel_probes,
            raster.paint_queue_pushes,
            raster.paint_queue_pops,
            raster.paint_duplicate_pops,
            raster.paint_queue_grows,
            raster.maximum_paint_queue,
            raster.circle_requested_segments,
            raster.circle_segments,
            raster.circle_skipped_segments,
            raster.capture_calls,
            raster.capture_pixels,
            raster.capture_bytes,
            raster.put_calls,
            raster.put_pixels,
            raster.put_bytes,
        }) catch return false;
        report_len += raster_line.len;
        const damage_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC damage: commits={d} regions={d} merges={d} overflow_merges={d} full_commits={d}\r\n", .{
            raster.damage_commits,
            raster.damage_regions,
            raster.damage_merges,
            raster.damage_overflow_merges,
            raster.full_damage_commits,
        }) catch return false;
        report_len += damage_line.len;
        const ownership_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC ownership: compile_borrowed={d} string_clones={d} string_clone_bytes={d} builtin_borrowed={d} builtin_owned={d} procedure_calls={d} local_pool_grows={d} local_pool_reuses={d} local_initializations={d} local_initialization_bytes={d} local_aggregate_initializations={d} format_stack_uses={d} str_result_allocations={d} val_direct={d} val_stack={d} val_scratch={d} val_scratch_grows={d}\r\n", .{
            self.compile_stats.borrowed_builtin_arguments,
            vm_stats.string_clones,
            vm_stats.string_clone_bytes,
            vm_stats.builtin_borrowed_arguments,
            vm_stats.builtin_owned_arguments,
            vm_stats.procedure_calls,
            vm_stats.local_pool_grows,
            vm_stats.local_pool_reuses,
            vm_stats.local_initializations,
            vm_stats.local_initialization_bytes,
            vm_stats.local_aggregate_initializations,
            vm_stats.numeric_format_stack_uses,
            vm_stats.str_result_allocations,
            vm_stats.val_direct_parses,
            vm_stats.val_stack_normalizations,
            vm_stats.val_scratch_normalizations,
            vm_stats.val_scratch_grows,
        }) catch return false;
        report_len += ownership_line.len;
        const storage_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC storage: compact_array_resizes={d} generic_array_resizes={d} compact_array_elements={d} generic_array_initializations={d} array_live_bytes={d} array_live_peak_bytes={d} array_resize_live_peak_bytes={d} array_live_limit_bytes={d} array_resize_live_limit_bytes={d} vm_static_bytes={d} file_index_bytes={d} file_capacity_grows={d} max_open_files={d}\r\n", .{
            vm_stats.compact_array_resizes,
            vm_stats.generic_array_resizes,
            vm_stats.compact_array_elements,
            vm_stats.generic_array_initializations,
            vm_stats.array_live_payload_bytes,
            vm_stats.maximum_array_live_payload_bytes,
            vm_stats.maximum_array_resize_live_bytes,
            vm.array_live_payload_limit_bytes,
            vm.array_resize_live_limit_bytes,
            self.guest.machine.staticByteSize(),
            self.guest.machine.fileIndexByteSize(),
            vm_stats.file_table_capacity_grows,
            vm_stats.maximum_open_files,
        }) catch return false;
        report_len += storage_line.len;
        const file_host_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC file-host: reads={d} read_bytes={d} writes={d} write_bytes={d} failures={d}\r\n", .{
            self.storage.stats.read_calls,
            self.storage.stats.read_bytes,
            self.storage.stats.write_calls,
            self.storage.stats.write_bytes,
            self.storage.stats.failures,
        }) catch return false;
        report_len += file_host_line.len;
        const presenter_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC presenter: published_frames={d} skipped_frames={d} full_frames={d} damage_frames={d} compacted_frames={d} damage_regions={d} indexed8_frames={d} indexed8_blocks={d} indexed8_resource_bytes={d} xrgb_fallback_frames={d} raster_blocks={d} sampled_pixels={d}\r\n", .{
            presenter.published_frames,
            presenter.skipped_frames,
            presenter.full_frames,
            presenter.damage_frames,
            presenter.compacted_frames,
            presenter.damage_regions,
            presenter.indexed8_frames,
            presenter.indexed8_blocks,
            presenter.indexed8_resource_bytes,
            presenter.xrgb_fallback_frames,
            presenter.raster_blocks,
            presenter.sampled_pixels,
        }) catch return false;
        report_len += presenter_line.len;
        const audio_stats = self.guest.machine.audioStats();
        const audio_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC audio: state={s} muted={d} playback=unavailable lazy_opens={d} service_ops={d} service_ops_cycle_max={d} opens={d} writes={d} closes={d} active_cycles={d} silent_cycles={d} paused_cycles={d} muted_cycles={d} active_quanta={d} silent_quanta={d} generated_bytes={d} accepted_bytes={d} suppressed_bytes={d} discarded_bytes={d} paused_bytes={d} muted_bytes={d} busy={d} resyncs={d}\r\n", .{
            @tagName(runtime.audio.state),
            @intFromBool(runtime.audio.muted),
            runtime.audio.stats.lazy_opens,
            runtime.audio.stats.service_operations,
            runtime.audio.stats.maximum_service_operations_per_cycle,
            runtime.audio.stats.open_operations,
            runtime.audio.stats.write_operations,
            runtime.audio.stats.close_operations,
            runtime.audio.stats.active_cycles,
            runtime.audio.stats.silent_cycles,
            runtime.audio.stats.paused_cycles,
            runtime.audio.stats.muted_cycles,
            runtime.audio.stats.active_quanta,
            runtime.audio.stats.silent_quanta,
            runtime.audio.stats.generated_bytes,
            runtime.audio.stats.submitted_bytes,
            runtime.audio.stats.suppressed_bytes,
            runtime.audio.stats.discarded_bytes,
            runtime.audio.stats.paused_bytes,
            runtime.audio.stats.muted_bytes,
            runtime.audio.stats.busy_writes,
            runtime.audio.stats.late_resyncs,
        }) catch return false;
        report_len += audio_line.len;
        const audio_guest_line = std.fmt.bufPrint(report_storage[report_len..], "R4BASIC audio-guest: scheduled_frames={d} accepted_frames={d} suppressed_frames={d} discarded_frames={d} resolved_frames={d} unresolved_frames={d} foreground_waits={d} foreground_wakes={d} background={d} direct_events={d} reserve_grows={d} phase_lookups={d}\r\n", .{
            audio_stats.scheduled_frames,
            audio_stats.accepted_frames,
            audio_stats.suppressed_frames,
            audio_stats.discarded_frames,
            audio_stats.resolved_frames,
            self.guest.machine.unresolvedAudioFrames(),
            audio_stats.foreground_waits,
            audio_stats.foreground_wakes,
            audio_stats.background_statements,
            audio_stats.direct_play_events,
            audio_stats.play_capacity_grows,
            audio_stats.phase_table_lookups,
        }) catch return false;
        report_len += audio_guest_line.len;
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
    var lines: [compiler.maximum_stored_diagnostics][160]u8 = undefined;
    var truncation_line: [160]u8 = undefined;
    var views: [compiler.maximum_stored_diagnostics + 3][]const u8 = undefined;
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
    if (program.diagnostics_truncated) {
        views[count] = std.fmt.bufPrint(truncation_line[0..], "Weitere Diagnosen wurden nicht gespeichert ({d} Fehler insgesamt).", .{
            program.diagnostics_total,
        }) catch "Weitere Diagnosen wurden nicht gespeichert.";
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
    const dirty = text.takeDirty();
    for (dirty.slice()) |region| display.renderText(&text, region);
    const view = display.view() orelse return error_host_video;
    const surface = host_api.Surface.initIndexed8(view.pixels, view.palette, view.width, view.height) catch return error_host_video;
    var scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window = host_api.Host.init(desk, draw, surface, scratch[0..]) catch return error_host_video;
    window.setInputPolicy(.text_only_no_pointer);
    _ = window.setTitle(title);
    _ = window.setMinimumSize(320, 200);
    window.video.invalidateAll();
    var present_pending = true;
    var activity_sequence: u64 = 0;
    while (!sys.programShouldClose()) {
        var event_count: u16 = 0;
        while (event_count < runtime_api.default_max_input_events) : (event_count += 1) {
            const event = window.pollInput() orelse break;
            switch (event) {
                .close => return 0,
                .resize => {
                    window.video.invalidateAll();
                    present_pending = true;
                },
                .key_down => |key| if (key.code == 27) return 0,
                else => {},
            }
        }
        if (present_pending) {
            switch (window.present()) {
                .failure => |raw| return raw,
                .hidden => {},
                else => present_pending = false,
            }
        }
        if (event_count == runtime_api.default_max_input_events) continue;
        if (desk.hasFn("desktop_activity_wait")) {
            var sequence = activity_sequence;
            const raw = desk.desktopActivityWait(activity_sequence, r4os.abi.io_wait_forever, &sequence);
            activity_sequence = sequence;
            if (raw < 0) return raw;
        } else {
            sys.sleepTicks(1);
        }
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
