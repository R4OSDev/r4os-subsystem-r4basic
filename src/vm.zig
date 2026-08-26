const std = @import("std");
const audio = @import("audio.zig");
const bytecode = @import("bytecode.zig");
const frontend = @import("frontend.zig");
const graphics_screen = @import("graphics_screen.zig");
const text_screen = @import("text_screen.zig");
const values = @import("value.zig");

pub const contract_version = "1.8.0";
pub const default_instruction_budget: u32 = 262_144;
pub const timer_poll_interval_ns: u64 = std.time.ns_per_ms;
pub const maximum_value_stack: usize = 16_384;
pub const maximum_call_depth: usize = 256;
pub const maximum_gosub_depth: usize = 1024;
pub const maximum_array_elements: usize = 16 * 1024 * 1024;
pub const array_live_payload_limit_bytes: usize = 128 * 1024 * 1024;
pub const array_resize_live_limit_bytes: usize = 192 * 1024 * 1024;
pub const maximum_keyboard_bytes: usize = 4096;
pub const maximum_input_line_bytes: usize = 255;
pub const maximum_sequential_file_bytes: usize = 4 * 1024 * 1024;
pub const maximum_file_number: usize = 255;
pub const random_mask: u32 = 0x00FF_FFFF;
pub const default_random_seed: u32 = 0x0050_0000;
pub const numeric_format_buffer_bytes: usize = 128;

pub const MathOperation = enum(u8) {
    atn,
    cos,
    sin,
    power,
};

pub const HostMathError = error{MathFault};
pub const ScreenModeError = error{ModeUnavailable};
pub const DeferredStatementError = error{Unsupported};

pub const FileHostError = enum(u8) {
    unavailable,
    not_found,
    permission_denied,
    path_error,
    io_error,
    too_large,
};

pub const FileReadResult = union(enum) {
    bytes: u32,
    end,
    failure: FileHostError,
};

pub const FileWriteResult = union(enum) {
    ok,
    failure: FileHostError,
};

pub const HostServices = struct {
    context: ?*anyopaque = null,
    math: *const fn (?*anyopaque, MathOperation, f64, f64) HostMathError!f64 = defaultMath,
    screen_mode: *const fn (?*anyopaque, i32) ScreenModeError!void = acceptScreenMode,
    deferred_statement: *const fn (?*anyopaque, frontend.Keyword) DeferredStatementError!void = rejectDeferredStatement,
    should_cancel: *const fn (?*anyopaque) bool = neverCancel,
    file_context: ?*anyopaque = null,
    file_read: *const fn (?*anyopaque, []const u8, u32, []u8) FileReadResult = unavailableFileRead,
    file_write: *const fn (?*anyopaque, []const u8, []const u8, bool) FileWriteResult = unavailableFileWrite,
    guest_directory: []const u8 = "",
    initial_random_seed: u32 = default_random_seed,
};

pub const RuntimeCode = enum(u8) {
    overflow,
    division_by_zero,
    type_mismatch,
    illegal_function_call,
    out_of_memory,
    stack_overflow,
    stack_underflow,
    call_depth_exceeded,
    gosub_without_return,
    invalid_instruction,
    host_failure,
    subscript_out_of_range,
    array_already_dimensioned,
    out_of_data,
    resume_without_error,
    restricted_memory,
    bad_file_number,
    file_not_found,
    bad_file_mode,
    file_already_open,
    input_past_end,
    bad_file_name,
    permission_denied,
    path_file_access,
};

pub const RuntimeDiagnostic = struct {
    code: RuntimeCode,
    file_name: []const u8,
    span: frontend.Span,
    instruction: u32,

    pub fn qbasicErrorNumber(self: RuntimeDiagnostic) i32 {
        return switch (self.code) {
            .illegal_function_call, .restricted_memory => 5,
            .overflow => 6,
            .out_of_memory => 7,
            .division_by_zero => 11,
            .type_mismatch => 13,
            .subscript_out_of_range => 9,
            .array_already_dimensioned => 10,
            .out_of_data => 4,
            .resume_without_error => 20,
            .bad_file_number => 52,
            .file_not_found => 53,
            .bad_file_mode => 54,
            .file_already_open => 55,
            .input_past_end => 62,
            .bad_file_name => 64,
            .permission_denied => 70,
            .path_file_access => 75,
            .stack_overflow, .stack_underflow, .call_depth_exceeded, .gosub_without_return, .invalid_instruction, .host_failure => 70,
        };
    }
};

pub const Status = enum(u8) {
    ready,
    yielded,
    waiting,
    halted,
    cancelled,
    runtime_error,
};

pub const SliceResult = struct {
    status: Status,
    instructions: u32,
    wake_guest_ns: u64 = 0,
};

pub const OperationGroup = enum(u8) {
    value,
    arithmetic,
    control,
    graphics,
    text,
    host,
};

pub const operation_group_count: usize = 6;

pub const PerformanceStats = struct {
    instructions: u64 = 0,
    groups: [operation_group_count]u64 = .{0} ** operation_group_count,
    timer_yields: u64 = 0,
    cancel_flag_checks: u64 = 0,
    cancel_callback_checks: u64 = 0,
    operation_group_lookups: u64 = 0,
    text_sync_checks: u64 = 0,
    text_sync_renders: u64 = 0,
    instruction_metadata_reads: u64 = 0,
    cell_resolve_calls: u64 = 0,
    cell_alias_hops: u64 = 0,
    same_type_store_moves: u64 = 0,
    value_conversions: u64 = 0,
    integer_comparisons: u64 = 0,
    floating_comparisons: u64 = 0,
    string_comparisons: u64 = 0,
    timer_calls: u64 = 0,
    timer_waits: u64 = 0,
    maximum_timer_wake_lateness_ns: u64 = 0,
    string_clones: u64 = 0,
    string_clone_bytes: u64 = 0,
    builtin_borrowed_arguments: u64 = 0,
    builtin_owned_arguments: u64 = 0,
    procedure_calls: u64 = 0,
    local_pool_grows: u64 = 0,
    local_pool_reuses: u64 = 0,
    local_initializations: u64 = 0,
    local_initialization_bytes: u64 = 0,
    local_aggregate_initializations: u64 = 0,
    numeric_format_stack_uses: u64 = 0,
    str_result_allocations: u64 = 0,
    val_direct_parses: u64 = 0,
    val_stack_normalizations: u64 = 0,
    val_scratch_normalizations: u64 = 0,
    val_scratch_grows: u64 = 0,
    compact_array_resizes: u64 = 0,
    generic_array_resizes: u64 = 0,
    compact_array_elements: u64 = 0,
    generic_array_initializations: u64 = 0,
    array_live_payload_bytes: u64 = 0,
    maximum_array_live_payload_bytes: u64 = 0,
    maximum_array_resize_live_bytes: u64 = 0,
    file_table_capacity_grows: u64 = 0,
    maximum_open_files: u64 = 0,

    pub fn group(self: *const PerformanceStats, operation_group: OperationGroup) u64 {
        return self.groups[@intFromEnum(operation_group)];
    }
};

pub const InitError = error{
    OutOfMemory,
    InvalidProgram,
};

const ExecutionError = values.Fault || error{
    StackOverflow,
    StackUnderflow,
    CallDepthExceeded,
    GosubWithoutReturn,
    InvalidInstruction,
    HostFailure,
    SubscriptOutOfRange,
    ArrayAlreadyDimensioned,
    OutOfData,
    ResumeWithoutError,
    RestrictedMemory,
    Rethrow,
    WouldBlock,
    BadFileNumber,
    FileNotFound,
    BadFileMode,
    FileAlreadyOpen,
    InputPastEnd,
    BadFileName,
    PermissionDenied,
    PathFileAccess,
};

pub const Dimension = struct {
    lower: i32,
    upper: i32,
    stride: usize,
};

const ArrayValue = struct {
    value_type: bytecode.ValueType,
    record_type: u32,
    expected_dimensions: u8,
    is_dynamic: bool,
    dimensions: []Dimension,
    storage: ArrayStorage,

    fn deinit(self: *ArrayValue, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
        allocator.free(self.dimensions);
        self.* = undefined;
    }
};

const ArrayStorage = union(enum) {
    integer: []i16,
    long: []i32,
    single: []f32,
    double: []f64,
    cells: []Cell,

    fn len(self: *const ArrayStorage) usize {
        return switch (self.*) {
            inline else => |items| items.len,
        };
    }

    fn byteLen(self: *const ArrayStorage) usize {
        return switch (self.*) {
            .integer => |items| items.len * @sizeOf(i16),
            .long => |items| items.len * @sizeOf(i32),
            .single => |items| items.len * @sizeOf(f32),
            .double => |items| items.len * @sizeOf(f64),
            .cells => |items| items.len * @sizeOf(Cell),
        };
    }

    fn deinit(self: *ArrayStorage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .integer => |items| allocator.free(items),
            .long => |items| allocator.free(items),
            .single => |items| allocator.free(items),
            .double => |items| allocator.free(items),
            .cells => |items| {
                for (items) |*element| element.deinit(allocator);
                allocator.free(items);
            },
        }
        self.* = undefined;
    }
};

const RecordValue = struct {
    record_type: u32,
    fields: []Cell,

    fn deinit(self: *RecordValue, allocator: std.mem.Allocator) void {
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

const OwnedValue = union(enum) {
    scalar: values.Value,
    array: ArrayValue,
    record: RecordValue,

    fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scalar => |*scalar| scalar.deinit(allocator),
            .array => |*array| array.deinit(allocator),
            .record => |*record| record.deinit(allocator),
        }
        self.* = undefined;
    }
};

const Cell = union(enum) {
    owned: OwnedValue,
    alias: Reference,

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned => |*owned| owned.deinit(allocator),
            .alias => {},
        }
        self.* = undefined;
    }
};

const Reference = union(enum) {
    cell: *Cell,
    integer: *i16,
    long: *i32,
    single: *f32,
    double: *f64,

    fn value(self: Reference) ExecutionError!values.Value {
        return switch (self) {
            .cell => |cell| switch (cell.*) {
                .owned => |*owned| switch (owned.*) {
                    .scalar => |scalar_value| scalar_value,
                    else => error.TypeMismatch,
                },
                .alias => error.InvalidInstruction,
            },
            .integer => |number| .{ .integer = number.* },
            .long => |number| .{ .long = number.* },
            .single => |number| .{ .single = number.* },
            .double => |number| .{ .double = number.* },
        };
    }

    fn valueType(self: Reference) ExecutionError!bytecode.ValueType {
        return (try self.value()).valueType();
    }

    fn aggregateCell(self: Reference) ExecutionError!*Cell {
        return switch (self) {
            .cell => |cell| switch (cell.*) {
                .owned => cell,
                .alias => error.InvalidInstruction,
            },
            else => error.TypeMismatch,
        };
    }

    fn replace(self: Reference, allocator: std.mem.Allocator, incoming: values.Value) ExecutionError!void {
        switch (self) {
            .cell => |cell| switch (cell.*) {
                .owned => |*owned| switch (owned.*) {
                    .scalar => |*destination| {
                        destination.deinit(allocator);
                        destination.* = incoming;
                    },
                    else => return error.TypeMismatch,
                },
                .alias => return error.InvalidInstruction,
            },
            .integer => |destination| destination.* = switch (incoming) {
                .integer => |number| number,
                else => return error.TypeMismatch,
            },
            .long => |destination| destination.* = switch (incoming) {
                .long => |number| number,
                else => return error.TypeMismatch,
            },
            .single => |destination| destination.* = switch (incoming) {
                .single => |number| number,
                else => return error.TypeMismatch,
            },
            .double => |destination| destination.* = switch (incoming) {
                .double => |number| number,
                else => return error.TypeMismatch,
            },
        }
    }

    fn replaceNumeric(self: Reference, incoming: values.Value) ExecutionError!void {
        switch (self) {
            .cell => |cell| switch (cell.*) {
                .owned => |*owned| switch (owned.*) {
                    .scalar => |*destination| {
                        if (!destination.valueType().isNumeric() or destination.valueType() != incoming.valueType()) return error.TypeMismatch;
                        destination.* = incoming;
                    },
                    else => return error.TypeMismatch,
                },
                .alias => return error.InvalidInstruction,
            },
            .integer => |destination| destination.* = switch (incoming) {
                .integer => |number| number,
                else => return error.TypeMismatch,
            },
            .long => |destination| destination.* = switch (incoming) {
                .long => |number| number,
                else => return error.TypeMismatch,
            },
            .single => |destination| destination.* = switch (incoming) {
                .single => |number| number,
                else => return error.TypeMismatch,
            },
            .double => |destination| destination.* = switch (incoming) {
                .double => |number| number,
                else => return error.TypeMismatch,
            },
        }
    }
};

const FrameLocalSlot = struct {
    cell: Cell = undefined,
    generation: u64 = 0,
    next_initialized: u32 = bytecode.invalid_index,
};

const FrameLocalStorage = struct {
    slots: std.ArrayList(FrameLocalSlot) = .empty,
    generation: u64 = 0,

    fn deinit(self: *FrameLocalStorage, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }
};

const Frame = struct {
    procedure_id: u32,
    return_ip: u32,
    stack_base: usize,
    call_resume_ip: u32,
    call_resume_next: u32,
    error_handler_ip: u32 = bytecode.invalid_index,
    error_handler_active: bool = false,
    local_pool_index: usize,
    local_count: u32,
    local_generation: u64,
    initialized_local_head: u32 = bytecode.invalid_index,
};

const StackItem = union(enum) {
    value: values.Value,
    reference: Reference,

    fn deinit(self: *StackItem, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .value => |*value| value.deinit(allocator),
            .reference => {},
        }
        self.* = undefined;
    }
};

const GosubEntry = struct {
    return_ip: u32,
    frame_depth: usize,
};

const ActiveError = struct {
    diagnostic: RuntimeDiagnostic,
    resume_ip: u32,
    resume_next_ip: u32,
    handler_frame: u32,
};

const ResumeMode = enum {
    retry,
    next,
    label,
};

const SequentialFile = struct {
    mode: bytecode.FileMode,
    path: []u8,
    input: []u8,
    output: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    print_column: usize = 0,

    fn deinit(self: *SequentialFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.input);
        self.output.deinit(allocator);
        self.* = undefined;
    }
};

const FileSlot = struct {
    number: u8,
    file: SequentialFile,
};

const module_frame = bytecode.invalid_index;

pub const Vm = struct {
    allocator: std.mem.Allocator,
    program: *const bytecode.Program,
    host: HostServices,
    globals: []Cell,
    stack: std.ArrayList(StackItem) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    frame_local_storage: std.ArrayList(FrameLocalStorage) = .empty,
    gosub_stack: std.ArrayList(GosubEntry) = .empty,
    instruction_pointer: u32,
    total_instructions: u64 = 0,
    operation_groups: [operation_group_count]u64 = .{0} ** operation_group_count,
    timer_yield_count: u64 = 0,
    cancel_flag_checks: u64 = 0,
    cancel_callback_checks: u64 = 0,
    operation_group_lookups: u64 = 0,
    text_sync_checks: u64 = 0,
    text_sync_renders: u64 = 0,
    instruction_metadata_reads: u64 = 0,
    cell_resolve_calls: u64 = 0,
    cell_alias_hops: u64 = 0,
    same_type_store_moves: u64 = 0,
    value_conversions: u64 = 0,
    integer_comparisons: u64 = 0,
    floating_comparisons: u64 = 0,
    string_comparisons: u64 = 0,
    timer_calls: u64 = 0,
    timer_waits: u64 = 0,
    maximum_timer_wake_lateness_ns: u64 = 0,
    string_clones: u64 = 0,
    string_clone_bytes: u64 = 0,
    builtin_borrowed_arguments: u64 = 0,
    builtin_owned_arguments: u64 = 0,
    procedure_calls: u64 = 0,
    local_pool_grows: u64 = 0,
    local_pool_reuses: u64 = 0,
    local_initializations: u64 = 0,
    local_initialization_bytes: u64 = 0,
    local_aggregate_initializations: u64 = 0,
    numeric_format_stack_uses: u64 = 0,
    str_result_allocations: u64 = 0,
    val_direct_parses: u64 = 0,
    val_stack_normalizations: u64 = 0,
    val_scratch_normalizations: u64 = 0,
    val_scratch_grows: u64 = 0,
    compact_array_resizes: u64 = 0,
    generic_array_resizes: u64 = 0,
    compact_array_elements: u64 = 0,
    generic_array_initializations: u64 = 0,
    array_live_payload_bytes: u64 = 0,
    maximum_array_live_payload_bytes: u64 = 0,
    maximum_array_resize_live_bytes: u64 = 0,
    file_table_capacity_grows: u64 = 0,
    maximum_open_files: u64 = 0,
    status: Status = .ready,
    exit_code: i32 = 0,
    runtime_diagnostic: ?RuntimeDiagnostic = null,
    trapped_diagnostic: ?RuntimeDiagnostic = null,
    active_error: ?ActiveError = null,
    module_error_handler_ip: u32 = bytecode.invalid_index,
    module_error_handler_active: bool = false,
    data_pointer: usize = 0,
    compatibility_segment_zero: bool = false,
    virtual_bios_byte: u8 = 0,
    text: text_screen.Screen = .{},
    graphics: graphics_screen.Screen = .{},
    screen_mode: i32 = 0,
    host_display_requested: bool = false,
    keyboard: std.ArrayList(u8) = .empty,
    keyboard_head: usize = 0,
    keyboard_generation: u64 = 0,
    input_focused: bool = true,
    input_line: std.ArrayList(u8) = .empty,
    numeric_scratch: std.ArrayList(u8) = .empty,
    pending_input_instruction: u32 = bytecode.invalid_index,
    guest_now_ns: u64 = 0,
    wait_wake_ns: u64 = 0,
    cooperative_timer_pacing: bool = false,
    next_timer_poll_ns: u64 = 0,
    pending_sleep_instruction: u32 = bytecode.invalid_index,
    sleep_deadline_ns: u64 = 0,
    sleep_input_generation: u64 = 0,
    audio_engine: audio.Engine,
    pending_audio_instruction: u32 = bytecode.invalid_index,
    audio_deadline_ns: u64 = 0,
    random_state: u32 = default_random_seed,
    random_last: f32 = 0,
    open_files: std.ArrayList(FileSlot) = .empty,
    file_slot_indices: [maximum_file_number + 1]u8 = .{0} ** (maximum_file_number + 1),
    active_print_file: ?u8 = null,
    statement_stack_base: usize = 0,
    current_statement_start: u32 = bytecode.invalid_index,
    current_statement_next: u32 = bytecode.invalid_index,
    cancel_requested: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const bytecode.Program,
        host: HostServices,
    ) InitError!Vm {
        if (!program.ok() or program.instructions.len != program.instruction_metadata.len) return error.InvalidProgram;
        const globals = try allocateGlobals(allocator, program);
        return .{
            .allocator = allocator,
            .program = program,
            .host = host,
            .globals = globals,
            .instruction_pointer = program.module_entry,
            .random_state = normalizeRandomSeed(host.initial_random_seed),
            .audio_engine = audio.Engine.init(allocator),
        };
    }

    pub fn deinit(self: *Vm) void {
        self.discardStackFrom(0);
        self.stack.deinit(self.allocator);
        while (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            self.releaseFrameLocals(&frame);
        }
        self.frames.deinit(self.allocator);
        for (self.frame_local_storage.items) |*storage| storage.deinit(self.allocator);
        self.frame_local_storage.deinit(self.allocator);
        self.gosub_stack.deinit(self.allocator);
        self.keyboard.deinit(self.allocator);
        self.input_line.deinit(self.allocator);
        self.numeric_scratch.deinit(self.allocator);
        self.audio_engine.deinit();
        self.discardFiles();
        self.open_files.deinit(self.allocator);
        self.graphics.deinit(self.allocator);
        deinitGlobals(self.allocator, self.globals);
        self.* = undefined;
    }

    pub fn requestCancel(self: *Vm) void {
        self.cancel_requested = true;
    }

    pub fn enableCooperativeTimerPacing(self: *Vm) void {
        self.cooperative_timer_pacing = true;
    }

    pub fn setGuestTime(self: *Vm, guest_now_ns: u64) void {
        self.guest_now_ns = guest_now_ns;
        self.audio_engine.setGuestTime(guest_now_ns);
    }

    pub fn renderAudio(self: *Vm, out: []u8) i32 {
        return self.audio_engine.render(out);
    }

    pub fn audioStats(self: *const Vm) audio.Stats {
        return self.audio_engine.stats;
    }

    pub fn pendingAudioFrames(self: *const Vm) u64 {
        return self.audio_engine.pendingFrames();
    }

    pub fn setInputFocused(self: *Vm, focused: bool) void {
        self.input_focused = focused;
    }

    pub fn enqueueTextCodepoint(self: *Vm, codepoint: u32) std.mem.Allocator.Error!bool {
        if (!self.input_focused or codepoint < 0x20 or codepoint > 0xFF or codepoint == 0x7F) return false;
        if (self.keyboard.items.len - self.keyboard_head >= maximum_keyboard_bytes) return false;
        try self.keyboard.append(self.allocator, @intCast(codepoint));
        self.keyboard_generation +%= 1;
        return true;
    }

    pub fn enqueueKeyCode(self: *Vm, code: u32) std.mem.Allocator.Error!bool {
        if (!self.input_focused) return false;
        const byte: u8 = switch (code) {
            8 => 8,
            10, 13 => 13,
            else => return false,
        };
        if (self.keyboard.items.len - self.keyboard_head >= maximum_keyboard_bytes) return false;
        try self.keyboard.append(self.allocator, byte);
        self.keyboard_generation +%= 1;
        return true;
    }

    pub fn queuedInputBytes(self: *const Vm) usize {
        return self.keyboard.items.len - self.keyboard_head;
    }

    pub fn textScreen(self: *const Vm) *const text_screen.Screen {
        return &self.text;
    }

    pub fn graphicsView(self: *Vm) ?graphics_screen.View {
        if (self.graphics.view() == null) return null;
        self.syncTextToGraphics();
        return self.graphics.view();
    }

    pub fn prepareHostDisplay(self: *Vm) InitError!void {
        if (self.graphics.view() == null) {
            self.graphics.setMode(self.allocator, 0) catch |fault| switch (fault) {
                error.OutOfMemory => return error.OutOfMemory,
                error.IllegalFunctionCall => return error.InvalidProgram,
            };
        }
        self.syncTextToGraphics();
        self.host_display_requested = false;
    }

    pub fn prepareRequestedHostDisplay(self: *Vm) InitError!bool {
        if (self.graphics.view() != null) return true;
        if (!self.host_display_requested) return false;
        try self.prepareHostDisplay();
        return true;
    }

    pub fn hasHostDisplay(self: *const Vm) bool {
        return self.graphics.pixels != null;
    }

    pub fn takeGraphicsDamage(self: *Vm) ?graphics_screen.Rect {
        self.syncTextToGraphics();
        return self.graphics.takeDamage();
    }

    pub fn graphicsPoint(self: *const Vm, x: i32, y: i32) ?i32 {
        if (self.screen_mode == 0) return null;
        return self.graphics.point(.{ .x = x, .y = y }) catch null;
    }

    pub fn reset(self: *Vm) InitError!void {
        const replacement = try allocateGlobals(self.allocator, self.program);
        errdefer deinitGlobals(self.allocator, replacement);

        self.discardStackFrom(0);
        while (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            self.releaseFrameLocals(&frame);
        }
        self.gosub_stack.clearRetainingCapacity();
        deinitGlobals(self.allocator, self.globals);
        self.globals = replacement;
        self.instruction_pointer = self.program.module_entry;
        self.total_instructions = 0;
        self.operation_groups = .{0} ** operation_group_count;
        self.timer_yield_count = 0;
        self.cancel_flag_checks = 0;
        self.cancel_callback_checks = 0;
        self.operation_group_lookups = 0;
        self.text_sync_checks = 0;
        self.text_sync_renders = 0;
        self.instruction_metadata_reads = 0;
        self.cell_resolve_calls = 0;
        self.cell_alias_hops = 0;
        self.same_type_store_moves = 0;
        self.value_conversions = 0;
        self.integer_comparisons = 0;
        self.floating_comparisons = 0;
        self.string_comparisons = 0;
        self.timer_calls = 0;
        self.timer_waits = 0;
        self.maximum_timer_wake_lateness_ns = 0;
        self.string_clones = 0;
        self.string_clone_bytes = 0;
        self.builtin_borrowed_arguments = 0;
        self.builtin_owned_arguments = 0;
        self.procedure_calls = 0;
        self.local_pool_grows = 0;
        self.local_pool_reuses = 0;
        self.local_initializations = 0;
        self.local_initialization_bytes = 0;
        self.local_aggregate_initializations = 0;
        self.numeric_format_stack_uses = 0;
        self.str_result_allocations = 0;
        self.val_direct_parses = 0;
        self.val_stack_normalizations = 0;
        self.val_scratch_normalizations = 0;
        self.val_scratch_grows = 0;
        self.compact_array_resizes = 0;
        self.generic_array_resizes = 0;
        self.compact_array_elements = 0;
        self.generic_array_initializations = 0;
        self.array_live_payload_bytes = 0;
        self.maximum_array_live_payload_bytes = 0;
        self.maximum_array_resize_live_bytes = 0;
        self.file_table_capacity_grows = 0;
        self.maximum_open_files = 0;
        self.status = .ready;
        self.exit_code = 0;
        self.runtime_diagnostic = null;
        self.trapped_diagnostic = null;
        self.active_error = null;
        self.module_error_handler_ip = bytecode.invalid_index;
        self.module_error_handler_active = false;
        self.data_pointer = 0;
        self.compatibility_segment_zero = false;
        self.virtual_bios_byte = 0;
        self.text.reset();
        self.graphics.reset(self.allocator);
        self.screen_mode = 0;
        self.host_display_requested = false;
        self.keyboard.clearRetainingCapacity();
        self.keyboard_head = 0;
        self.keyboard_generation = 0;
        self.input_focused = true;
        self.input_line.clearRetainingCapacity();
        self.numeric_scratch.clearRetainingCapacity();
        self.pending_input_instruction = bytecode.invalid_index;
        self.guest_now_ns = 0;
        self.wait_wake_ns = 0;
        self.next_timer_poll_ns = 0;
        self.pending_sleep_instruction = bytecode.invalid_index;
        self.sleep_deadline_ns = 0;
        self.sleep_input_generation = 0;
        self.audio_engine.reset();
        self.pending_audio_instruction = bytecode.invalid_index;
        self.audio_deadline_ns = 0;
        self.random_state = normalizeRandomSeed(self.host.initial_random_seed);
        self.random_last = 0;
        self.discardFiles();
        self.active_print_file = null;
        self.statement_stack_base = 0;
        self.current_statement_start = bytecode.invalid_index;
        self.current_statement_next = bytecode.invalid_index;
        self.cancel_requested = false;
    }

    pub fn runSlice(self: *Vm, instruction_budget: u32) SliceResult {
        if (self.status == .halted or self.status == .cancelled or self.status == .runtime_error) {
            return .{ .status = self.status, .instructions = 0 };
        }
        self.cancel_flag_checks +%= 1;
        if (self.cancel_requested) {
            self.status = .cancelled;
            self.exit_code = 130;
            return .{ .status = self.status, .instructions = 0 };
        }
        self.cancel_callback_checks +%= 1;
        if (self.host.should_cancel(self.host.context)) {
            self.status = .cancelled;
            self.exit_code = 130;
            return .{ .status = self.status, .instructions = 0 };
        }
        self.status = .ready;
        self.wait_wake_ns = 0;
        var executed: u32 = 0;
        while (executed < instruction_budget) {
            self.cancel_flag_checks +%= 1;
            if (self.cancel_requested) {
                self.status = .cancelled;
                self.exit_code = 130;
                return .{ .status = self.status, .instructions = executed };
            }
            if (self.instruction_pointer >= self.program.instructions.len) {
                self.recordError(.invalid_instruction, self.instruction_pointer);
                return .{ .status = self.status, .instructions = executed };
            }

            const instruction_index = self.instruction_pointer;
            const instruction = self.program.instructions[instruction_index];
            self.enterInstructionStatement(instruction_index);
            self.instruction_pointer += 1;
            self.execute(instruction_index, instruction) catch |fault| {
                if (fault == error.WouldBlock) {
                    self.instruction_pointer = instruction_index;
                    self.status = .waiting;
                    return .{
                        .status = .waiting,
                        .instructions = executed,
                        .wake_guest_ns = self.wait_wake_ns,
                    };
                }
                const code = if (fault == error.Rethrow and self.active_error != null)
                    self.active_error.?.diagnostic.code
                else
                    runtimeCode(fault);
                if (fault != error.Rethrow and self.trapError(code, instruction_index)) {
                    const group = self.recordOperation(instruction.op);
                    if (group == .text) {
                        self.host_display_requested = true;
                        self.syncTextToGraphics();
                    }
                    executed += 1;
                    self.total_instructions += 1;
                    continue;
                }
                if (fault == error.Rethrow and self.active_error != null) {
                    self.recordDiagnostic(self.active_error.?.diagnostic);
                } else {
                    self.recordError(code, instruction_index);
                }
                return .{ .status = self.status, .instructions = executed };
            };
            const group = self.recordOperation(instruction.op);
            if (group == .text) {
                self.host_display_requested = true;
                self.syncTextToGraphics();
            }
            executed += 1;
            self.total_instructions += 1;
            if (self.status == .halted) return .{ .status = .halted, .instructions = executed };
        }
        self.status = .yielded;
        return .{ .status = .yielded, .instructions = executed };
    }

    pub fn runToCompletion(self: *Vm, slice_budget: u32, maximum_slices: u32) Status {
        var slices: u32 = 0;
        while (slices < maximum_slices) : (slices += 1) {
            const result = self.runSlice(slice_budget);
            if (result.status != .yielded) return result.status;
        }
        return self.status;
    }

    pub fn performanceStats(self: *const Vm) PerformanceStats {
        return .{
            .instructions = self.total_instructions,
            .groups = self.operation_groups,
            .timer_yields = self.timer_yield_count,
            .cancel_flag_checks = self.cancel_flag_checks,
            .cancel_callback_checks = self.cancel_callback_checks,
            .operation_group_lookups = self.operation_group_lookups,
            .text_sync_checks = self.text_sync_checks,
            .text_sync_renders = self.text_sync_renders,
            .instruction_metadata_reads = self.instruction_metadata_reads,
            .cell_resolve_calls = self.cell_resolve_calls,
            .cell_alias_hops = self.cell_alias_hops,
            .same_type_store_moves = self.same_type_store_moves,
            .value_conversions = self.value_conversions,
            .integer_comparisons = self.integer_comparisons,
            .floating_comparisons = self.floating_comparisons,
            .string_comparisons = self.string_comparisons,
            .timer_calls = self.timer_calls,
            .timer_waits = self.timer_waits,
            .maximum_timer_wake_lateness_ns = self.maximum_timer_wake_lateness_ns,
            .string_clones = self.string_clones,
            .string_clone_bytes = self.string_clone_bytes,
            .builtin_borrowed_arguments = self.builtin_borrowed_arguments,
            .builtin_owned_arguments = self.builtin_owned_arguments,
            .procedure_calls = self.procedure_calls,
            .local_pool_grows = self.local_pool_grows,
            .local_pool_reuses = self.local_pool_reuses,
            .local_initializations = self.local_initializations,
            .local_initialization_bytes = self.local_initialization_bytes,
            .local_aggregate_initializations = self.local_aggregate_initializations,
            .numeric_format_stack_uses = self.numeric_format_stack_uses,
            .str_result_allocations = self.str_result_allocations,
            .val_direct_parses = self.val_direct_parses,
            .val_stack_normalizations = self.val_stack_normalizations,
            .val_scratch_normalizations = self.val_scratch_normalizations,
            .val_scratch_grows = self.val_scratch_grows,
            .compact_array_resizes = self.compact_array_resizes,
            .generic_array_resizes = self.generic_array_resizes,
            .compact_array_elements = self.compact_array_elements,
            .generic_array_initializations = self.generic_array_initializations,
            .array_live_payload_bytes = self.array_live_payload_bytes,
            .maximum_array_live_payload_bytes = self.maximum_array_live_payload_bytes,
            .maximum_array_resize_live_bytes = self.maximum_array_resize_live_bytes,
            .file_table_capacity_grows = self.file_table_capacity_grows,
            .maximum_open_files = self.maximum_open_files,
        };
    }

    pub fn global(self: *const Vm, name: []const u8) ?*const values.Value {
        for (self.program.globals, 0..) |variable, index| {
            if (variable.hidden) continue;
            if (std.ascii.eqlIgnoreCase(variable.name.bytes(self.program.source), name)) {
                const cell = resolveCellConst(&self.globals[index]) orelse return null;
                return switch (cell.owned) {
                    .scalar => |*scalar| scalar,
                    else => null,
                };
            }
        }
        return null;
    }

    pub fn globalArrayElement(self: *const Vm, name: []const u8, indices: []const i32) ?values.Value {
        const root = self.globalCell(name) orelse return null;
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return null,
        };
        const element = arrayElementConst(array, indices) orelse return null;
        return element.value() catch null;
    }

    pub fn globalArrayStorageBytes(self: *const Vm, name: []const u8) ?usize {
        const root = self.globalCell(name) orelse return null;
        return switch (root.owned) {
            .array => |*array| array.storage.byteLen(),
            else => null,
        };
    }

    pub fn staticByteSize(_: *const Vm) usize {
        return @sizeOf(Vm);
    }

    pub fn fileIndexByteSize(_: *const Vm) usize {
        return @sizeOf([maximum_file_number + 1]u8);
    }

    pub fn openFileCount(self: *const Vm) usize {
        return self.open_files.items.len;
    }

    pub fn globalArrayRecordField(
        self: *const Vm,
        name: []const u8,
        indices: []const i32,
        field_name: []const u8,
    ) ?*const values.Value {
        const root = self.globalCell(name) orelse return null;
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return null,
        };
        const element = (arrayElementConst(array, indices) orelse return null).aggregateCell() catch return null;
        const record = switch (element.owned) {
            .record => |*value| value,
            else => return null,
        };
        const record_type = self.program.record_types[record.record_type];
        for (record_type.fields, 0..) |field, field_index| {
            if (std.ascii.eqlIgnoreCase(field.name.bytes(self.program.source), field_name)) {
                const field_cell = resolveCellConst(&record.fields[field_index]) orelse return null;
                return switch (field_cell.owned) {
                    .scalar => |*scalar| scalar,
                    else => null,
                };
            }
        }
        return null;
    }

    pub fn virtualNumLockByte(self: *const Vm) u8 {
        return self.virtual_bios_byte;
    }

    fn globalCell(self: *const Vm, name: []const u8) ?*const Cell {
        for (self.program.globals, 0..) |variable, index| {
            if (!variable.hidden and std.ascii.eqlIgnoreCase(variable.name.bytes(self.program.source), name)) {
                return resolveCellConst(&self.globals[index]);
            }
        }
        return null;
    }

    pub fn valueStackDepth(self: *const Vm) usize {
        return self.stack.items.len;
    }

    pub fn callDepth(self: *const Vm) usize {
        return self.frames.items.len;
    }

    pub fn gosubDepth(self: *const Vm) usize {
        return self.gosub_stack.items.len;
    }

    const operation_group_table: [std.meta.fields(bytecode.OpCode).len]OperationGroup = blk: {
        var table: [std.meta.fields(bytecode.OpCode).len]OperationGroup = undefined;
        for (std.meta.tags(bytecode.OpCode)) |op| table[@intFromEnum(op)] = classifyOperation(op);
        break :blk table;
    };

    fn recordOperation(self: *Vm, op: bytecode.OpCode) OperationGroup {
        const group = operation_group_table[@intFromEnum(op)];
        self.operation_group_lookups +%= 1;
        self.operation_groups[@intFromEnum(group)] +%= 1;
        return group;
    }

    fn enterInstructionStatement(self: *Vm, instruction_index: u32) void {
        if (self.current_statement_start != bytecode.invalid_index and
            instruction_index >= self.current_statement_start and
            instruction_index < self.current_statement_next)
        {
            return;
        }
        const metadata = self.readInstructionMetadata(instruction_index);
        self.current_statement_start = if (metadata.statement_start == bytecode.invalid_index)
            instruction_index
        else
            metadata.statement_start;
        self.current_statement_next = if (metadata.statement_next == bytecode.invalid_index)
            instruction_index +| 1
        else
            metadata.statement_next;
        self.statement_stack_base = self.stack.items.len;
        self.active_print_file = null;
    }

    fn readInstructionMetadata(self: *Vm, instruction_index: u32) bytecode.InstructionMetadata {
        self.instruction_metadata_reads +%= 1;
        return self.program.instruction_metadata[instruction_index];
    }

    fn classifyOperation(op: bytecode.OpCode) OperationGroup {
        return switch (op) {
            .push_constant,
            .load_global,
            .load_local,
            .store_global,
            .store_local,
            .initialize_global,
            .initialize_local,
            .push_global_reference,
            .push_local_reference,
            .array_default_lower,
            .select_array_element,
            .select_record_field,
            .load_reference,
            .store_reference,
            .dimension,
            .redimension,
            .read_data,
            .restore_data,
            .convert,
            .pop,
            => .value,
            .negate,
            .logical_not,
            .add,
            .subtract,
            .multiply,
            .divide,
            .integer_divide,
            .modulo,
            .power,
            .compare_equal,
            .compare_not_equal,
            .compare_less,
            .compare_less_equal,
            .compare_greater,
            .compare_greater_equal,
            .logical_and,
            .logical_or,
            .logical_xor,
            => .arithmetic,
            .set_error_handler,
            .resume_error,
            .resume_next,
            .resume_label,
            .call,
            .return_procedure,
            .jump,
            .jump_if_false,
            .jump_if_true,
            .gosub,
            .return_gosub,
            .halt,
            => .control,
            .screen_mode_probe,
            .graphics_palette,
            .graphics_pset,
            .graphics_line,
            .graphics_circle,
            .graphics_paint,
            .graphics_get,
            .graphics_put,
            => .graphics,
            .text_width,
            .text_color,
            .text_cls,
            .text_locate,
            .text_view_print,
            .print_begin_screen,
            .print_value,
            .print_tab,
            .print_comma,
            .print_question,
            .print_newline,
            .print_end,
            .input_console,
            => .text,
            .set_segment,
            .reset_segment,
            .peek,
            .poke,
            .print_begin_file,
            .input_file,
            .randomize,
            .sleep,
            .file_open,
            .file_close,
            .audio_beep,
            .audio_play,
            .deferred_statement,
            .deferred_builtin,
            .call_builtin,
            => .host,
        };
    }

    fn execute(self: *Vm, instruction_index: u32, instruction: bytecode.Instruction) ExecutionError!void {
        switch (instruction.op) {
            .push_constant => try self.pushValue(try values.fromConstant(
                self.allocator,
                self.program.constants[instruction.a],
                self.program.source,
            )),
            .load_global => try self.load(try self.globalCellAt(instruction.a)),
            .load_local => try self.load(try self.localCellAt(instruction.a)),
            .store_global, .initialize_global => try self.store(try self.globalCellAt(instruction.a), bytecode.decodeValueType(instruction.b)),
            .store_local, .initialize_local => try self.store(try self.localCellAt(instruction.a), bytecode.decodeValueType(instruction.b)),
            .push_global_reference => try self.pushResolvedReference(try self.globalCellAt(instruction.a)),
            .push_local_reference => try self.pushResolvedReference(try self.localCellAt(instruction.a)),
            .array_default_lower => try self.arrayDefaultLower(),
            .select_array_element => try self.selectArrayElement(instruction.a),
            .select_record_field => try self.selectRecordField(instruction.a),
            .load_reference => try self.load(try self.popReference()),
            .store_reference => try self.storeReference(bytecode.decodeValueType(instruction.a)),
            .dimension => try self.dimensionArray(instruction.a, false),
            .redimension => try self.dimensionArray(instruction.a, true),
            .read_data => try self.readData(bytecode.decodeValueType(instruction.a)),
            .restore_data => self.data_pointer = instruction.a,
            .set_error_handler => try self.setErrorHandler(instruction.a),
            .resume_error => try self.resumeError(.retry, 0),
            .resume_next => try self.resumeError(.next, 0),
            .resume_label => try self.resumeError(.label, instruction.a),
            .set_segment => try self.setSegment(),
            .reset_segment => self.compatibility_segment_zero = false,
            .peek => try self.peek(),
            .poke => try self.poke(),
            .screen_mode_probe => try self.screenModeProbe(),
            .graphics_palette => try self.graphicsPalette(),
            .graphics_pset => try self.graphicsPset(instruction.a),
            .graphics_line => try self.graphicsLine(instruction.a),
            .graphics_circle => try self.graphicsCircle(instruction.a, instruction.b),
            .graphics_paint => try self.graphicsPaint(instruction.a, instruction.b),
            .graphics_get => try self.graphicsGet(instruction.a),
            .graphics_put => try self.graphicsPut(instruction.a, instruction.b),
            .text_width => try self.textWidth(instruction.a),
            .text_color => try self.textColor(instruction.a, instruction.b),
            .text_cls => try self.textCls(instruction.a),
            .text_locate => try self.textLocate(instruction.a, instruction.b),
            .text_view_print => try self.textViewPrint(instruction.a),
            .print_begin_screen => self.active_print_file = null,
            .print_begin_file => try self.printBeginFile(),
            .print_value => try self.printValue(),
            .print_tab => try self.printTab(),
            .print_comma => try self.printComma(),
            .print_question => try self.printBytes("? "),
            .print_newline => try self.printNewline(),
            .print_end => self.active_print_file = null,
            .input_console => try self.consoleInput(instruction_index, instruction.a, instruction.b),
            .input_file => try self.fileInput(instruction.a, instruction.b != 0),
            .randomize => try self.randomize(instruction_index, instruction.a),
            .sleep => try self.sleep(instruction_index, instruction.a),
            .file_open => try self.openFile(@enumFromInt(@as(u8, @intCast(instruction.a)))),
            .file_close => try self.closeFiles(instruction.a),
            .audio_beep => try self.audioBeep(instruction_index),
            .audio_play => try self.audioPlay(instruction_index),
            .deferred_statement => self.host.deferred_statement(
                self.host.context,
                @enumFromInt(@as(u8, @intCast(instruction.a))),
            ) catch return error.HostFailure,
            .deferred_builtin => try self.deferredBuiltin(instruction.b),
            .convert => try self.convertTop(bytecode.decodeValueType(instruction.a)),
            .negate => try self.unaryNegate(bytecode.decodeValueType(instruction.a)),
            .logical_not => try self.unaryLogicalNot(),
            .add => try self.binary(.add, bytecode.decodeValueType(instruction.a)),
            .subtract => try self.binary(.subtract, bytecode.decodeValueType(instruction.a)),
            .multiply => try self.binary(.multiply, bytecode.decodeValueType(instruction.a)),
            .divide => try self.binary(.divide, bytecode.decodeValueType(instruction.a)),
            .integer_divide => try self.binary(.integer_divide, bytecode.decodeValueType(instruction.a)),
            .modulo => try self.binary(.modulo, bytecode.decodeValueType(instruction.a)),
            .logical_and => try self.binary(.logical_and, .long),
            .logical_or => try self.binary(.logical_or, .long),
            .logical_xor => try self.binary(.logical_xor, .long),
            .power => try self.power(bytecode.decodeValueType(instruction.a)),
            .compare_equal => try self.comparison(.equal, bytecode.decodeValueType(instruction.a)),
            .compare_not_equal => try self.comparison(.not_equal, bytecode.decodeValueType(instruction.a)),
            .compare_less => try self.comparison(.less, bytecode.decodeValueType(instruction.a)),
            .compare_less_equal => try self.comparison(.less_equal, bytecode.decodeValueType(instruction.a)),
            .compare_greater => try self.comparison(.greater, bytecode.decodeValueType(instruction.a)),
            .compare_greater_equal => try self.comparison(.greater_equal, bytecode.decodeValueType(instruction.a)),
            .call_builtin => try self.callBuiltin(@enumFromInt(@as(u8, @intCast(instruction.a))), instruction.b),
            .call => try self.callProcedure(instruction.a, instruction.b),
            .return_procedure => try self.returnProcedure(),
            .jump => self.instruction_pointer = instruction.a,
            .jump_if_false => {
                if (!try self.popCondition()) self.instruction_pointer = instruction.a;
            },
            .jump_if_true => {
                if (try self.popCondition()) self.instruction_pointer = instruction.a;
            },
            .gosub => try self.gosub(instruction.a),
            .return_gosub => try self.returnGosub(instruction.a),
            .pop => {
                var item = self.stack.pop() orelse return error.StackUnderflow;
                item.deinit(self.allocator);
            },
            .halt => {
                try self.closeAllFiles();
                self.status = .halted;
                self.exit_code = 0;
            },
        }
    }

    fn load(self: *Vm, reference: Reference) ExecutionError!void {
        const value = try reference.value();
        try self.pushValue(try self.cloneValueTracked(&value));
    }

    fn store(self: *Vm, reference: Reference, target: bytecode.ValueType) ExecutionError!void {
        return self.storeValue(reference, target, try self.popValue());
    }

    fn storeReference(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        var incoming = try self.popValue();
        var incoming_owned = true;
        defer if (incoming_owned) incoming.deinit(self.allocator);
        const reference = try self.popReference();
        incoming_owned = false;
        try self.storeValue(reference, target, incoming);
    }

    fn storeValue(self: *Vm, reference: Reference, target: bytecode.ValueType, raw_incoming: values.Value) ExecutionError!void {
        var incoming = raw_incoming;
        var incoming_owned = true;
        defer if (incoming_owned) incoming.deinit(self.allocator);
        if (try reference.valueType() != target) return error.InvalidInstruction;
        if (incoming.valueType() == target) {
            self.same_type_store_moves +%= 1;
            try reference.replace(self.allocator, incoming);
            incoming_owned = false;
            return;
        }
        self.value_conversions +%= 1;
        var converted = try values.convert(self.allocator, incoming, target);
        var converted_owned = true;
        defer if (converted_owned) converted.deinit(self.allocator);
        try reference.replace(self.allocator, converted);
        converted_owned = false;
    }

    fn arrayDefaultLower(self: *Vm) ExecutionError!void {
        var upper = try self.popValue();
        self.pushValue(.{ .integer = 0 }) catch |fault| {
            upper.deinit(self.allocator);
            return fault;
        };
        try self.pushValue(upper);
    }

    fn selectArrayElement(self: *Vm, dimension_count: u32) ExecutionError!void {
        if (dimension_count == 0 or dimension_count > bytecode.unknown_dimensions) return error.InvalidInstruction;
        var indices: [60]i32 = undefined;
        if (dimension_count > indices.len) return error.InvalidInstruction;
        var remaining: usize = @intCast(dimension_count);
        while (remaining != 0) {
            var index_value = try self.popValue();
            defer index_value.deinit(self.allocator);
            remaining -= 1;
            indices[remaining] = try values.asLong(index_value);
        }
        const root = try (try self.popReference()).aggregateCell();
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return error.TypeMismatch,
        };
        const element = arrayElement(array, indices[0..dimension_count]) orelse return error.SubscriptOutOfRange;
        try self.pushResolvedReference(element);
    }

    fn selectRecordField(self: *Vm, field_index: u32) ExecutionError!void {
        const root = try (try self.popReference()).aggregateCell();
        const record = switch (root.owned) {
            .record => |*value| value,
            else => return error.TypeMismatch,
        };
        if (field_index >= record.fields.len) return error.InvalidInstruction;
        try self.pushReference(&record.fields[field_index]);
    }

    fn dimensionArray(self: *Vm, dimension_count: u32, redimension: bool) ExecutionError!void {
        if (dimension_count == 0 or dimension_count > 60) return error.InvalidInstruction;
        const root = try (try self.popReference()).aggregateCell();
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return error.TypeMismatch,
        };
        if (array.expected_dimensions != bytecode.unknown_dimensions and array.expected_dimensions != dimension_count) {
            return error.SubscriptOutOfRange;
        }
        if (redimension and !array.is_dynamic) return error.IllegalFunctionCall;
        if (!redimension and array.dimensions.len != 0) return error.ArrayAlreadyDimensioned;

        var lowers: [60]i32 = undefined;
        var uppers: [60]i32 = undefined;
        var remaining: usize = @intCast(dimension_count);
        while (remaining != 0) {
            var upper_value = try self.popValue();
            defer upper_value.deinit(self.allocator);
            var lower_value = try self.popValue();
            defer lower_value.deinit(self.allocator);
            remaining -= 1;
            const lower = try values.asLong(lower_value);
            const upper = try values.asLong(upper_value);
            if (lower < std.math.minInt(i16) or lower > std.math.maxInt(i16) or
                upper < std.math.minInt(i16) or upper > std.math.maxInt(i16) or lower > upper)
            {
                return error.SubscriptOutOfRange;
            }
            lowers[remaining] = lower;
            uppers[remaining] = upper;
        }
        try self.resizeArray(array, lowers[0..dimension_count], uppers[0..dimension_count]);
    }

    fn resizeArray(self: *Vm, array: *ArrayValue, lowers: []const i32, uppers: []const i32) ExecutionError!void {
        const dimensions = try self.allocator.alloc(Dimension, lowers.len);
        errdefer self.allocator.free(dimensions);
        var total: usize = 1;
        var reverse = lowers.len;
        while (reverse != 0) {
            reverse -= 1;
            const length: usize = @intCast(uppers[reverse] - lowers[reverse] + 1);
            if (length != 0 and total > maximum_array_elements / length) return error.OutOfMemory;
            dimensions[reverse] = .{ .lower = lowers[reverse], .upper = uppers[reverse], .stride = total };
            total *= length;
        }
        if (total > maximum_array_elements) return error.OutOfMemory;
        const old_payload_bytes = try arrayLogicalPayloadBytes(self.program, array.value_type, array.record_type, array.storage.len());
        const new_payload_bytes = try arrayLogicalPayloadBytes(self.program, array.value_type, array.record_type, total);
        const old_dimension_bytes = std.math.mul(usize, array.dimensions.len, @sizeOf(Dimension)) catch return error.OutOfMemory;
        const new_dimension_bytes = std.math.mul(usize, dimensions.len, @sizeOf(Dimension)) catch return error.OutOfMemory;
        const current_live_bytes = std.math.cast(usize, self.array_live_payload_bytes) orelse return error.OutOfMemory;
        const live_without_old_bytes = std.math.sub(usize, current_live_bytes, old_payload_bytes) catch return error.InvalidInstruction;
        const final_live_bytes = std.math.add(usize, live_without_old_bytes, new_payload_bytes) catch return error.OutOfMemory;
        var resize_live_bytes = std.math.add(usize, current_live_bytes, new_payload_bytes) catch return error.OutOfMemory;
        resize_live_bytes = std.math.add(usize, resize_live_bytes, old_dimension_bytes) catch return error.OutOfMemory;
        resize_live_bytes = std.math.add(usize, resize_live_bytes, new_dimension_bytes) catch return error.OutOfMemory;
        if (final_live_bytes > array_live_payload_limit_bytes or resize_live_bytes > array_resize_live_limit_bytes) {
            return error.OutOfMemory;
        }

        if (array.record_type == bytecode.invalid_index and array.value_type.isNumeric()) {
            try resizeCompactArrayStorage(self.allocator, &array.storage, total, array.value_type);
            self.compact_array_resizes +%= 1;
            self.compact_array_elements +|= @intCast(total);
        } else {
            const elements = try self.allocator.alloc(Cell, total);
            var initialized: usize = 0;
            errdefer {
                for (elements[0..initialized]) |*element| element.deinit(self.allocator);
                self.allocator.free(elements);
            }
            for (elements) |*element| {
                element.* = try allocateElement(self.allocator, self.program, array.value_type, array.record_type);
                initialized += 1;
            }
            array.storage.deinit(self.allocator);
            array.storage = .{ .cells = elements };
            self.generic_array_resizes +%= 1;
            self.generic_array_initializations +|= @intCast(total);
        }

        self.array_live_payload_bytes = @intCast(final_live_bytes);
        self.maximum_array_live_payload_bytes = @max(self.maximum_array_live_payload_bytes, self.array_live_payload_bytes);
        self.maximum_array_resize_live_bytes = @max(self.maximum_array_resize_live_bytes, @as(u64, @intCast(resize_live_bytes)));

        self.allocator.free(array.dimensions);
        array.dimensions = dimensions;
    }

    fn readData(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        const destination = try self.popReference();
        if (self.data_pointer >= self.program.data_items.len) return error.OutOfData;
        const converted = try dataValue(self.allocator, self.program.data_items[self.data_pointer], self.program.source, target);
        try self.storeValue(destination, target, converted);
        self.data_pointer += 1;
    }

    fn setErrorHandler(self: *Vm, target: u32) ExecutionError!void {
        if (target != bytecode.invalid_index and target >= self.program.instructions.len) return error.InvalidInstruction;
        const frame_id: u32 = if (self.frames.items.len == 0) module_frame else @intCast(self.frames.items.len - 1);
        if (target == bytecode.invalid_index and self.active_error != null and self.active_error.?.handler_frame == frame_id) {
            return error.Rethrow;
        }
        if (frame_id == module_frame) {
            self.module_error_handler_ip = target;
            self.module_error_handler_active = false;
        } else {
            self.frames.items[frame_id].error_handler_ip = target;
            self.frames.items[frame_id].error_handler_active = false;
        }
    }

    fn resumeError(self: *Vm, mode: ResumeMode, label: u32) ExecutionError!void {
        const active = self.active_error orelse return error.ResumeWithoutError;
        if (active.handler_frame == module_frame) {
            self.module_error_handler_active = false;
        } else {
            if (active.handler_frame >= self.frames.items.len) return error.InvalidInstruction;
            self.frames.items[active.handler_frame].error_handler_active = false;
        }
        self.instruction_pointer = switch (mode) {
            .retry => active.resume_ip,
            .next => active.resume_next_ip,
            .label => label,
        };
        if (self.instruction_pointer >= self.program.instructions.len) return error.InvalidInstruction;
        self.active_error = null;
        self.current_statement_start = bytecode.invalid_index;
        self.current_statement_next = bytecode.invalid_index;
        self.statement_stack_base = self.stack.items.len;
    }

    fn trapError(self: *Vm, code: RuntimeCode, instruction_index: u32) bool {
        if (!isCatchable(code)) return false;
        var handler_frame: u32 = module_frame;
        var handler_ip: u32 = bytecode.invalid_index;
        var search = self.frames.items.len;
        while (search != 0) {
            search -= 1;
            const frame = self.frames.items[search];
            if (frame.error_handler_ip != bytecode.invalid_index and !frame.error_handler_active) {
                handler_frame = @intCast(search);
                handler_ip = frame.error_handler_ip;
                break;
            }
        }
        if (handler_ip == bytecode.invalid_index and
            self.module_error_handler_ip != bytecode.invalid_index and !self.module_error_handler_active)
        {
            handler_frame = module_frame;
            handler_ip = self.module_error_handler_ip;
        }
        if (handler_ip == bytecode.invalid_index) return false;

        var resume_ip = if (self.current_statement_start == bytecode.invalid_index) instruction_index else self.current_statement_start;
        var resume_next_ip = if (self.current_statement_next == bytecode.invalid_index) self.instruction_pointer else self.current_statement_next;
        const keep_frames: usize = if (handler_frame == module_frame) 0 else @as(usize, handler_frame) + 1;
        if (self.frames.items.len > keep_frames) {
            const child = self.frames.items[keep_frames];
            resume_ip = child.call_resume_ip;
            resume_next_ip = child.call_resume_next;
        }

        self.discardStackFrom(@min(self.statement_stack_base, self.stack.items.len));
        while (self.frames.items.len > keep_frames) {
            var frame = self.frames.pop().?;
            self.discardStackFrom(@min(frame.stack_base, self.stack.items.len));
            self.releaseFrameLocals(&frame);
        }
        while (self.gosub_stack.items.len != 0 and self.gosub_stack.items[self.gosub_stack.items.len - 1].frame_depth > keep_frames) {
            _ = self.gosub_stack.pop();
        }

        const diagnostic = self.makeDiagnostic(code, instruction_index);
        self.trapped_diagnostic = diagnostic;
        self.active_error = .{
            .diagnostic = diagnostic,
            .resume_ip = resume_ip,
            .resume_next_ip = resume_next_ip,
            .handler_frame = handler_frame,
        };
        if (handler_frame == module_frame) {
            self.module_error_handler_active = true;
        } else {
            self.frames.items[handler_frame].error_handler_active = true;
        }
        self.instruction_pointer = handler_ip;
        self.current_statement_start = bytecode.invalid_index;
        self.current_statement_next = bytecode.invalid_index;
        self.statement_stack_base = self.stack.items.len;
        return true;
    }

    fn setSegment(self: *Vm) ExecutionError!void {
        var segment = try self.popValue();
        defer segment.deinit(self.allocator);
        if (try values.asLong(segment) != 0) return error.RestrictedMemory;
        self.compatibility_segment_zero = true;
    }

    fn peek(self: *Vm) ExecutionError!void {
        var address = try self.popValue();
        defer address.deinit(self.allocator);
        if (!self.compatibility_segment_zero or try values.asLong(address) != 1047) return error.RestrictedMemory;
        try self.pushValue(.{ .integer = self.virtual_bios_byte });
    }

    fn poke(self: *Vm) ExecutionError!void {
        var byte_value = try self.popValue();
        defer byte_value.deinit(self.allocator);
        var address = try self.popValue();
        defer address.deinit(self.allocator);
        const byte = try values.asLong(byte_value);
        if (!self.compatibility_segment_zero or try values.asLong(address) != 1047 or byte < 0 or byte > 255) {
            return error.RestrictedMemory;
        }
        self.virtual_bios_byte = @intCast(byte);
    }

    fn screenModeProbe(self: *Vm) ExecutionError!void {
        var mode_value = try self.popValue();
        defer mode_value.deinit(self.allocator);
        const mode = try values.asLong(mode_value);
        if (mode != 0 and mode != 1 and mode != 9) return error.IllegalFunctionCall;
        self.host.screen_mode(self.host.context, mode) catch return error.IllegalFunctionCall;
        self.graphics.setMode(self.allocator, mode) catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            error.IllegalFunctionCall => error.IllegalFunctionCall,
        };
        self.text.configure(if (mode == 1) 40 else 80) catch return error.IllegalFunctionCall;
        self.screen_mode = mode;
        self.host_display_requested = false;
    }

    fn graphicsPalette(self: *Vm) ExecutionError!void {
        const display_color = try self.popLong();
        const attribute = try self.popLong();
        self.graphics.setPalette(attribute, display_color) catch return error.IllegalFunctionCall;
    }

    fn graphicsPset(self: *Vm, flags: u32) ExecutionError!void {
        if ((flags & ~(bytecode.graphics_point_relative | bytecode.graphics_color_present)) != 0) return error.InvalidInstruction;
        const color = if ((flags & bytecode.graphics_color_present) != 0) try self.popLong() else self.text.foreground;
        const raw = try self.popGraphicsPoint();
        const target = self.graphics.resolvePoint(raw.x, raw.y, (flags & bytecode.graphics_point_relative) != 0);
        self.graphics.pset(target, color) catch return error.IllegalFunctionCall;
    }

    fn graphicsLine(self: *Vm, flags: u32) ExecutionError!void {
        const allowed = bytecode.graphics_point_relative | bytecode.graphics_second_point_relative |
            bytecode.graphics_color_present | (@as(u32, 3) << bytecode.graphics_box_shift);
        if ((flags & ~allowed) != 0) return error.InvalidInstruction;
        const encoded_box = (flags >> bytecode.graphics_box_shift) & 3;
        if (encoded_box > @intFromEnum(bytecode.GraphicsBoxMode.filled_box)) return error.InvalidInstruction;
        const color = if ((flags & bytecode.graphics_color_present) != 0) try self.popLong() else self.text.foreground;
        const raw_second = try self.popGraphicsPoint();
        const raw_first = try self.popGraphicsPoint();
        const first = self.graphics.resolvePoint(raw_first.x, raw_first.y, (flags & bytecode.graphics_point_relative) != 0);
        const second = if ((flags & bytecode.graphics_second_point_relative) != 0)
            graphics_screen.Point{ .x = saturatingCoordinateAdd(first.x, raw_second.x), .y = saturatingCoordinateAdd(first.y, raw_second.y) }
        else
            raw_second;
        self.graphics.line(first, second, color, @enumFromInt(@as(u8, @intCast(encoded_box)))) catch return error.IllegalFunctionCall;
    }

    fn graphicsCircle(self: *Vm, flags: u32, optional: u32) ExecutionError!void {
        if ((flags & ~bytecode.graphics_point_relative) != 0) return error.InvalidInstruction;
        const mask = optional & 0x0f;
        const count = optional >> bytecode.graphics_optional_count_shift;
        if (@popCount(mask) != count or count > 4) return error.InvalidInstruction;
        var aspect: ?f64 = null;
        var end: ?f64 = null;
        var start: ?f64 = null;
        var color: i32 = self.text.foreground;
        if ((mask & 8) != 0) aspect = try self.popDouble();
        if ((mask & 4) != 0) end = try self.popDouble();
        if ((mask & 2) != 0) start = try self.popDouble();
        if ((mask & 1) != 0) color = try self.popLong();
        const radius = try self.popDouble();
        const raw_center = try self.popGraphicsPoint();
        const center = self.graphics.resolvePoint(raw_center.x, raw_center.y, (flags & bytecode.graphics_point_relative) != 0);
        self.graphics.circle(center, radius, color, start, end, aspect) catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            error.IllegalFunctionCall => error.IllegalFunctionCall,
        };
    }

    fn graphicsPaint(self: *Vm, flags: u32, optional: u32) ExecutionError!void {
        if ((flags & ~bytecode.graphics_point_relative) != 0) return error.InvalidInstruction;
        const mask = optional & 0x03;
        const count = optional >> bytecode.graphics_optional_count_shift;
        if (@popCount(mask) != count or count > 2) return error.InvalidInstruction;
        var border: ?i32 = null;
        var fill: i32 = self.text.foreground;
        if ((mask & 2) != 0) border = try self.popLong();
        if ((mask & 1) != 0) fill = try self.popLong();
        const raw = try self.popGraphicsPoint();
        const target = self.graphics.resolvePoint(raw.x, raw.y, (flags & bytecode.graphics_point_relative) != 0);
        self.graphics.paint(self.allocator, target, fill, border orelse fill) catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            error.IllegalFunctionCall => error.IllegalFunctionCall,
        };
    }

    fn graphicsGet(self: *Vm, flags: u32) ExecutionError!void {
        if ((flags & ~(bytecode.graphics_point_relative | bytecode.graphics_second_point_relative)) != 0) return error.InvalidInstruction;
        const array = try self.popArrayReference();
        const raw_second = try self.popGraphicsPoint();
        const raw_first = try self.popGraphicsPoint();
        const first = self.graphics.resolvePoint(raw_first.x, raw_first.y, (flags & bytecode.graphics_point_relative) != 0);
        const second = if ((flags & bytecode.graphics_second_point_relative) != 0)
            graphics_screen.Point{ .x = saturatingCoordinateAdd(first.x, raw_second.x), .y = saturatingCoordinateAdd(first.y, raw_second.y) }
        else
            raw_second;
        const bytes = self.graphics.capture(self.allocator, first, second) catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            error.IllegalFunctionCall => error.IllegalFunctionCall,
        };
        defer self.allocator.free(bytes);
        try writeArrayRawPrefix(array, bytes);
    }

    fn graphicsPut(self: *Vm, flags: u32, encoded_action: u32) ExecutionError!void {
        if ((flags & ~bytecode.graphics_point_relative) != 0 or encoded_action > @intFromEnum(bytecode.GraphicsPutAction.xor)) {
            return error.InvalidInstruction;
        }
        const array = try self.popArrayReference();
        const raw = try self.popGraphicsPoint();
        const target = self.graphics.resolvePoint(raw.x, raw.y, (flags & bytecode.graphics_point_relative) != 0);
        const bytes = try readArrayRaw(self.allocator, array);
        defer self.allocator.free(bytes);
        self.graphics.put(target, bytes, @enumFromInt(@as(u8, @intCast(encoded_action)))) catch return error.IllegalFunctionCall;
    }

    fn popGraphicsPoint(self: *Vm) ExecutionError!graphics_screen.Point {
        const y = try self.popLong();
        const x = try self.popLong();
        return .{ .x = x, .y = y };
    }

    fn popArrayReference(self: *Vm) ExecutionError!*ArrayValue {
        const root = try (try self.popReference()).aggregateCell();
        return switch (root.owned) {
            .array => |*array| if (array.record_type == bytecode.invalid_index and array.value_type.isNumeric()) array else error.TypeMismatch,
            else => error.TypeMismatch,
        };
    }

    fn syncTextToGraphics(self: *Vm) void {
        self.text_sync_checks +%= 1;
        if (self.graphics.view() == null) return;
        if (self.text.takeDirty()) |dirty| {
            self.text_sync_renders +%= 1;
            self.graphics.renderText(&self.text, dirty);
        }
    }

    fn textWidth(self: *Vm, argument_count: u32) ExecutionError!void {
        if (argument_count < 1 or argument_count > 2) return error.InvalidInstruction;
        const requested_rows = if (argument_count == 2) try self.popLong() else null;
        const requested_columns = try self.popLong();
        self.text.setWidth(requested_columns, requested_rows) catch return error.IllegalFunctionCall;
    }

    fn textColor(self: *Vm, mask: u32, argument_count: u32) ExecutionError!void {
        var arguments = [_]?i32{null} ** 2;
        try self.popOptionalLongs(mask, argument_count, &arguments);
        self.text.setColor(arguments[0], arguments[1]) catch return error.IllegalFunctionCall;
    }

    fn textCls(self: *Vm, argument_count: u32) ExecutionError!void {
        if (argument_count > 1) return error.InvalidInstruction;
        const mode = if (argument_count == 1) try self.popLong() else null;
        if (self.screen_mode == 0) {
            self.text.clear(mode) catch return error.IllegalFunctionCall;
            return;
        }
        const graphics_mode = mode orelse 0;
        if (graphics_mode < 0 or graphics_mode > 2) return error.IllegalFunctionCall;
        if (graphics_mode == 0 or graphics_mode == 1) {
            self.graphics.clear(@as(i32, self.text.background & self.graphics.maximumAttribute())) catch return error.IllegalFunctionCall;
        }
        if (graphics_mode == 0 or graphics_mode == 2) {
            self.text.clear(if (graphics_mode == 2) 2 else 0) catch return error.IllegalFunctionCall;
        }
    }

    fn textLocate(self: *Vm, mask: u32, argument_count: u32) ExecutionError!void {
        var arguments = [_]?i32{null} ** 5;
        try self.popOptionalLongs(mask, argument_count, &arguments);
        self.text.locate(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4]) catch
            return error.IllegalFunctionCall;
    }

    fn textViewPrint(self: *Vm, argument_count: u32) ExecutionError!void {
        if (argument_count != 0 and argument_count != 2) return error.InvalidInstruction;
        const bottom = if (argument_count == 2) try self.popLong() else null;
        const top = if (argument_count == 2) try self.popLong() else null;
        self.text.setView(top, bottom) catch return error.IllegalFunctionCall;
    }

    fn popOptionalLongs(self: *Vm, mask: u32, argument_count: u32, out: []?i32) ExecutionError!void {
        if (out.len > 31) return error.InvalidInstruction;
        const valid_mask: u32 = (@as(u32, 1) << @intCast(out.len)) - 1;
        if ((mask & ~valid_mask) != 0 or @popCount(mask) != argument_count) return error.InvalidInstruction;
        var position = out.len;
        while (position != 0) {
            position -= 1;
            if ((mask & (@as(u32, 1) << @intCast(position))) != 0) out[position] = try self.popLong();
        }
    }

    fn popLong(self: *Vm) ExecutionError!i32 {
        var value = try self.popValue();
        defer value.deinit(self.allocator);
        return values.asLong(value);
    }

    fn popDouble(self: *Vm) ExecutionError!f64 {
        var value = try self.popValue();
        defer value.deinit(self.allocator);
        return values.asDouble(value);
    }

    fn printBeginFile(self: *Vm) ExecutionError!void {
        const file_number = try self.popFileNumber();
        const file = try self.fileAt(file_number);
        if (file.mode == .input) return error.BadFileMode;
        self.active_print_file = @intCast(file_number);
    }

    fn printValue(self: *Vm) ExecutionError!void {
        var value = try self.popValue();
        defer value.deinit(self.allocator);
        switch (value) {
            .string => |bytes| try self.printBytes(bytes),
            .integer => |number| try self.printNumber(number, number >= 0),
            .long => |number| try self.printNumber(number, number >= 0),
            .single => |number| try self.printNumber(number, number >= 0),
            .double => |number| try self.printNumber(number, number >= 0),
        }
    }

    fn printNumber(self: *Vm, number: anytype, positive: bool) ExecutionError!void {
        var storage: [numeric_format_buffer_bytes]u8 = undefined;
        const formatted = try self.formatNumber(&storage, number);
        if (positive) try self.printBytes(" ");
        try self.printBytes(formatted);
        try self.printBytes(" ");
    }

    fn formatNumber(self: *Vm, storage: *[numeric_format_buffer_bytes]u8, number: anytype) ExecutionError![]const u8 {
        self.numeric_format_stack_uses +%= 1;
        return std.fmt.bufPrint(storage, "{d}", .{number}) catch return error.Overflow;
    }

    fn printBytes(self: *Vm, bytes: []const u8) ExecutionError!void {
        if (self.active_print_file) |raw_number| {
            const file = try self.fileAt(raw_number);
            if (file.mode == .input) return error.BadFileMode;
            if (bytes.len > maximum_sequential_file_bytes -| file.output.items.len) return error.OutOfMemory;
            try file.output.appendSlice(self.allocator, bytes);
            for (bytes) |byte| switch (byte) {
                '\r', '\n' => file.print_column = 0,
                else => file.print_column +|= 1,
            };
            return;
        }
        self.text.write(bytes);
    }

    fn printTab(self: *Vm) ExecutionError!void {
        const requested = try self.popLong();
        if (requested < 1 or requested > 255) return error.IllegalFunctionCall;
        if (self.active_print_file) |raw_number| {
            const file = try self.fileAt(raw_number);
            const target: usize = @intCast(requested - 1);
            if (target < file.print_column) try self.printNewline();
            try self.printSpaces(target -| file.print_column);
            return;
        }
        self.text.printTab(requested) catch return error.IllegalFunctionCall;
    }

    fn printComma(self: *Vm) ExecutionError!void {
        if (self.active_print_file) |raw_number| {
            const file = try self.fileAt(raw_number);
            const next = (file.print_column / text_screen.print_zone_columns + 1) * text_screen.print_zone_columns;
            try self.printSpaces(next - file.print_column);
            return;
        }
        self.text.printComma();
    }

    fn printSpaces(self: *Vm, count: usize) ExecutionError!void {
        const spaces = [_]u8{' '} ** text_screen.columns;
        var remaining = count;
        while (remaining != 0) {
            const amount = @min(remaining, spaces.len);
            try self.printBytes(spaces[0..amount]);
            remaining -= amount;
        }
    }

    fn printNewline(self: *Vm) ExecutionError!void {
        if (self.active_print_file != null) {
            try self.printBytes("\r\n");
        } else {
            self.text.newLine();
        }
    }

    fn consoleInput(self: *Vm, instruction_index: u32, target_count: u32, flags: u32) ExecutionError!void {
        if (target_count == 0 or target_count > self.stack.items.len or (flags & ~@as(u32, 3)) != 0) {
            return error.InvalidInstruction;
        }
        const line_input = (flags & 1) != 0;
        const keep_same_line = (flags & 2) != 0;
        const target_base = self.stack.items.len - target_count;
        try self.validateInputTargets(target_base, target_count);

        if (!try self.acquireInputLine(instruction_index)) return error.WouldBlock;
        if (!keep_same_line) self.text.newLine();

        const parsed = self.decodeConsoleInput(target_base, target_count, line_input) catch |fault| switch (fault) {
            error.TypeMismatch, error.Overflow, error.IllegalFunctionCall => {
                self.text.write("Redo from start\r\n? ");
                self.input_line.clearRetainingCapacity();
                self.wait_wake_ns = if (self.queuedInputBytes() == 0) 0 else self.guest_now_ns;
                return error.WouldBlock;
            },
            else => return fault,
        };
        self.assignInputValues(target_base, parsed);
        self.allocator.free(parsed);
        self.discardStackFrom(target_base);
        self.pending_input_instruction = bytecode.invalid_index;
        self.input_line.clearRetainingCapacity();
    }

    fn acquireInputLine(self: *Vm, instruction_index: u32) ExecutionError!bool {
        if (self.pending_input_instruction != instruction_index) {
            self.pending_input_instruction = instruction_index;
            self.input_line.clearRetainingCapacity();
        }
        while (self.popKeyboardByte()) |byte| {
            switch (byte) {
                13, 10 => return true,
                8 => {
                    if (self.input_line.items.len != 0) {
                        _ = self.input_line.pop();
                        self.text.erasePrevious();
                    }
                },
                0x20...0xFF => if (self.input_line.items.len < maximum_input_line_bytes) {
                    try self.input_line.append(self.allocator, byte);
                    self.text.writeByte(byte);
                },
                else => {},
            }
        }
        self.wait_wake_ns = 0;
        return false;
    }

    fn popKeyboardByte(self: *Vm) ?u8 {
        if (self.keyboard_head >= self.keyboard.items.len) {
            self.keyboard.clearRetainingCapacity();
            self.keyboard_head = 0;
            return null;
        }
        const result = self.keyboard.items[self.keyboard_head];
        self.keyboard_head += 1;
        if (self.keyboard_head >= 1024 and self.keyboard_head * 2 >= self.keyboard.items.len) {
            const remaining = self.keyboard.items.len - self.keyboard_head;
            std.mem.copyForwards(u8, self.keyboard.items[0..remaining], self.keyboard.items[self.keyboard_head..]);
            self.keyboard.items.len = remaining;
            self.keyboard_head = 0;
        }
        return result;
    }

    fn decodeConsoleInput(
        self: *Vm,
        target_base: usize,
        target_count: u32,
        line_input: bool,
    ) ExecutionError![]values.Value {
        const parsed = try self.allocator.alloc(values.Value, target_count);
        var initialized: usize = 0;
        errdefer {
            for (parsed[0..initialized]) |*value| value.deinit(self.allocator);
            self.allocator.free(parsed);
        }

        if (line_input) {
            if (target_count != 1 or try self.inputTargetType(target_base) != .string) return error.TypeMismatch;
            parsed[0] = .{ .string = try self.allocator.dupe(u8, self.input_line.items) };
            return parsed;
        }

        var cursor: usize = 0;
        var target: usize = 0;
        while (target < target_count) : (target += 1) {
            const field = nextInputField(self.input_line.items, &cursor) orelse return error.TypeMismatch;
            parsed[target] = try self.decodeInputField(field, try self.inputTargetType(target_base + target));
            initialized += 1;
        }
        skipInputSeparators(self.input_line.items, &cursor);
        if (cursor != self.input_line.items.len) return error.TypeMismatch;
        return parsed;
    }

    fn validateInputTargets(self: *Vm, base: usize, count: u32) ExecutionError!void {
        if (base + count > self.stack.items.len) return error.StackUnderflow;
        var index: usize = 0;
        while (index < count) : (index += 1) _ = try self.inputTargetCell(base + index);
    }

    fn inputTargetCell(self: *Vm, stack_index: usize) ExecutionError!Reference {
        if (stack_index >= self.stack.items.len) return error.StackUnderflow;
        const reference = switch (self.stack.items[stack_index]) {
            .reference => |value| value,
            .value => return error.InvalidInstruction,
        };
        _ = try reference.value();
        return reference;
    }

    fn inputTargetType(self: *Vm, stack_index: usize) ExecutionError!bytecode.ValueType {
        return (try self.inputTargetCell(stack_index)).valueType();
    }

    fn assignInputValues(self: *Vm, target_base: usize, parsed: []values.Value) void {
        for (parsed, 0..) |value, index| {
            const reference = self.inputTargetCell(target_base + index) catch unreachable;
            reference.replace(self.allocator, value) catch unreachable;
        }
    }

    fn decodeInputField(self: *Vm, field: InputField, target: bytecode.ValueType) ExecutionError!values.Value {
        if (target == .string) return .{ .string = try self.allocator.dupe(u8, field.bytes) };
        const trimmed = std.mem.trim(u8, field.bytes, " \t");
        if (trimmed.len == 0) return error.TypeMismatch;
        const number = std.fmt.parseFloat(f64, trimmed) catch return error.TypeMismatch;
        if (!std.math.isFinite(number)) return error.Overflow;
        const source: values.Value = .{ .double = number };
        return values.convert(self.allocator, source, target);
    }

    fn fileInput(self: *Vm, target_count: u32, line_input: bool) ExecutionError!void {
        if (target_count == 0 or self.stack.items.len < target_count + 1) return error.StackUnderflow;
        const statement_base = self.stack.items.len - target_count - 1;
        const file_number = try self.fileNumberAt(statement_base);
        const file = try self.fileAt(file_number);
        if (file.mode != .input) return error.BadFileMode;
        try self.validateInputTargets(statement_base + 1, target_count);

        const parsed = try self.allocator.alloc(values.Value, target_count);
        var initialized: usize = 0;
        errdefer {
            for (parsed[0..initialized]) |*value| value.deinit(self.allocator);
            self.allocator.free(parsed);
        }
        var cursor = file.offset;
        if (line_input) {
            if (target_count != 1 or try self.inputTargetType(statement_base + 1) != .string) return error.TypeMismatch;
            if (cursor >= file.input.len) return error.InputPastEnd;
            const start = cursor;
            while (cursor < file.input.len and file.input[cursor] != '\r' and file.input[cursor] != '\n') cursor += 1;
            parsed[0] = .{ .string = try self.allocator.dupe(u8, file.input[start..cursor]) };
            initialized = 1;
            consumeLineEnding(file.input, &cursor);
        } else {
            var target: usize = 0;
            while (target < target_count) : (target += 1) {
                const field = nextSequentialField(file.input, &cursor) orelse return error.InputPastEnd;
                parsed[target] = try self.decodeInputField(field, try self.inputTargetType(statement_base + 1 + target));
                initialized += 1;
            }
        }
        self.assignInputValues(statement_base + 1, parsed);
        self.allocator.free(parsed);
        file.offset = cursor;
        self.discardStackFrom(statement_base);
    }

    fn randomize(self: *Vm, instruction_index: u32, argument_count: u32) ExecutionError!void {
        if (argument_count > 1) return error.InvalidInstruction;
        if (argument_count == 1) {
            var seed_value = try self.popValue();
            defer seed_value.deinit(self.allocator);
            self.seedRandom(try values.asDouble(seed_value));
            return;
        }

        const fresh = self.pending_input_instruction != instruction_index;
        if (fresh) self.text.write("Random Number Seed (-32768 to 32767)? ");
        if (!try self.acquireInputLine(instruction_index)) return error.WouldBlock;
        self.text.newLine();
        const trimmed = std.mem.trim(u8, self.input_line.items, " \t");
        const seed = std.fmt.parseFloat(f64, trimmed) catch {
            self.text.write("Redo from start\r\n? ");
            self.input_line.clearRetainingCapacity();
            self.wait_wake_ns = if (self.queuedInputBytes() == 0) 0 else self.guest_now_ns;
            return error.WouldBlock;
        };
        if (!std.math.isFinite(seed) or seed < -32768 or seed > 32767) {
            self.text.write("Redo from start\r\n? ");
            self.input_line.clearRetainingCapacity();
            self.wait_wake_ns = if (self.queuedInputBytes() == 0) 0 else self.guest_now_ns;
            return error.WouldBlock;
        }
        self.seedRandom(seed);
        self.pending_input_instruction = bytecode.invalid_index;
        self.input_line.clearRetainingCapacity();
    }

    fn seedRandom(self: *Vm, seed: f64) void {
        const single: f32 = @floatCast(seed);
        const bits: u32 = @bitCast(single);
        self.random_state = normalizeRandomSeed(bits ^ (bits >> 8) ^ 0x00A5_5A5A);
        self.random_last = 0;
    }

    fn nextRandom(self: *Vm) f32 {
        self.random_state = (self.random_state *% 0x00FD_43FD +% 0x00C3_9EC3) & random_mask;
        self.random_last = @as(f32, @floatFromInt(self.random_state)) / 16_777_216.0;
        return self.random_last;
    }

    fn sleep(self: *Vm, instruction_index: u32, argument_count: u32) ExecutionError!void {
        if (argument_count > 1) return error.InvalidInstruction;
        if (self.pending_sleep_instruction != instruction_index) {
            var seconds: f64 = 0;
            if (argument_count == 1) {
                var duration = try self.popValue();
                defer duration.deinit(self.allocator);
                seconds = try values.asDouble(duration);
                if (!std.math.isFinite(seconds) or seconds < 0) return error.IllegalFunctionCall;
            }
            self.pending_sleep_instruction = instruction_index;
            self.sleep_input_generation = self.keyboard_generation;
            self.sleep_deadline_ns = if (seconds == 0)
                std.math.maxInt(u64)
            else blk: {
                const duration_ns = seconds * @as(f64, @floatFromInt(std.time.ns_per_s));
                if (duration_ns >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) break :blk std.math.maxInt(u64);
                break :blk self.guest_now_ns +| @as(u64, @intFromFloat(@ceil(duration_ns)));
            };
        }
        if (self.keyboard_generation != self.sleep_input_generation or self.guest_now_ns >= self.sleep_deadline_ns) {
            self.pending_sleep_instruction = bytecode.invalid_index;
            self.sleep_deadline_ns = 0;
            return;
        }
        self.wait_wake_ns = if (self.sleep_deadline_ns == std.math.maxInt(u64)) 0 else self.sleep_deadline_ns;
        return error.WouldBlock;
    }

    fn audioBeep(self: *Vm, instruction_index: u32) ExecutionError!void {
        if (self.pending_audio_instruction != instruction_index) {
            const result = self.audio_engine.beep(self.guest_now_ns) catch |fault| switch (fault) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCommand => return error.IllegalFunctionCall,
            };
            self.pending_audio_instruction = instruction_index;
            self.audio_deadline_ns = result.deadline_ns;
        }
        try self.waitForForegroundAudio();
    }

    fn audioPlay(self: *Vm, instruction_index: u32) ExecutionError!void {
        if (self.pending_audio_instruction != instruction_index) {
            var command = try self.popValue();
            defer command.deinit(self.allocator);
            if (command != .string) return error.TypeMismatch;
            const result = self.audio_engine.play(command.string, self.guest_now_ns) catch |fault| switch (fault) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCommand => return error.IllegalFunctionCall,
            };
            if (result.mode == .background or result.deadline_ns <= self.guest_now_ns) return;
            self.pending_audio_instruction = instruction_index;
            self.audio_deadline_ns = result.deadline_ns;
        }
        try self.waitForForegroundAudio();
    }

    fn waitForForegroundAudio(self: *Vm) ExecutionError!void {
        if (self.guest_now_ns >= self.audio_deadline_ns) {
            self.pending_audio_instruction = bytecode.invalid_index;
            self.audio_deadline_ns = 0;
            return;
        }
        self.wait_wake_ns = self.audio_deadline_ns;
        return error.WouldBlock;
    }

    fn openFile(self: *Vm, mode: bytecode.FileMode) ExecutionError!void {
        const file_number = try self.popFileNumber();
        var path_value = try self.popValue();
        defer path_value.deinit(self.allocator);
        const raw_path = switch (path_value) {
            .string => |value| value,
            else => return error.TypeMismatch,
        };
        if (self.fileSlotIndex(file_number) != null) return error.FileAlreadyOpen;
        const resolved_path = try self.resolveGuestPath(raw_path);
        errdefer self.allocator.free(resolved_path);

        const previous_capacity = self.open_files.capacity;
        try self.open_files.ensureUnusedCapacity(self.allocator, 1);
        if (self.open_files.capacity != previous_capacity) self.file_table_capacity_grows +%= 1;

        var input = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(input);
        switch (mode) {
            .input => {
                self.allocator.free(input);
                input = try self.readWholeFile(resolved_path);
            },
            .output, .append => {
                const result = self.host.file_write(self.fileHostContext(), resolved_path, "", mode == .append);
                switch (result) {
                    .ok => {},
                    .failure => |failure| return fileHostFault(failure),
                }
            },
        }
        self.open_files.appendAssumeCapacity(.{
            .number = @intCast(file_number),
            .file = .{
                .mode = mode,
                .path = resolved_path,
                .input = input,
            },
        });
        self.file_slot_indices[file_number] = @intCast(self.open_files.items.len);
        self.maximum_open_files = @max(self.maximum_open_files, @as(u64, @intCast(self.open_files.items.len)));
    }

    fn readWholeFile(self: *Vm, path: []const u8) ExecutionError![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        var scratch: [4096]u8 = undefined;
        var offset: u32 = 0;
        while (true) {
            switch (self.host.file_read(self.fileHostContext(), path, offset, &scratch)) {
                .bytes => |raw_count| {
                    const count: usize = @intCast(raw_count);
                    if (count == 0 or count > scratch.len) return error.PathFileAccess;
                    if (count > maximum_sequential_file_bytes -| result.items.len) return error.OutOfMemory;
                    try result.appendSlice(self.allocator, scratch[0..count]);
                    offset = std.math.add(u32, offset, raw_count) catch return error.PathFileAccess;
                },
                .end => return result.toOwnedSlice(self.allocator),
                .failure => |failure| return fileHostFault(failure),
            }
        }
    }

    fn closeFiles(self: *Vm, argument_count: u32) ExecutionError!void {
        if (argument_count == 0) return self.closeAllFiles();
        if (argument_count > self.stack.items.len) return error.StackUnderflow;
        var remaining = argument_count;
        while (remaining != 0) : (remaining -= 1) {
            const file_number = try self.popFileNumber();
            try self.closeFile(file_number);
        }
    }

    fn closeAllFiles(self: *Vm) ExecutionError!void {
        while (self.open_files.items.len != 0) {
            try self.closeFile(self.open_files.items[self.open_files.items.len - 1].number);
        }
    }

    fn closeFile(self: *Vm, file_number: usize) ExecutionError!void {
        const slot_index = self.fileSlotIndex(file_number) orelse return error.BadFileNumber;
        const file = &self.open_files.items[slot_index].file;
        if (file.mode != .input) {
            const result = self.host.file_write(self.fileHostContext(), file.path, file.output.items, file.mode == .append);
            switch (result) {
                .ok => {},
                .failure => |failure| return fileHostFault(failure),
            }
        }
        var removed = self.open_files.swapRemove(slot_index);
        removed.file.deinit(self.allocator);
        self.file_slot_indices[file_number] = 0;
        if (slot_index < self.open_files.items.len) {
            const moved_number = self.open_files.items[slot_index].number;
            self.file_slot_indices[moved_number] = @intCast(slot_index + 1);
        }
        if (self.active_print_file != null and self.active_print_file.? == @as(u8, @intCast(file_number))) self.active_print_file = null;
    }

    fn discardFiles(self: *Vm) void {
        for (self.open_files.items) |*slot| slot.file.deinit(self.allocator);
        self.open_files.clearRetainingCapacity();
        self.file_slot_indices = .{0} ** (maximum_file_number + 1);
    }

    fn fileAt(self: *Vm, file_number: usize) ExecutionError!*SequentialFile {
        if (file_number == 0 or file_number > maximum_file_number) return error.BadFileNumber;
        const slot_index = self.fileSlotIndex(file_number) orelse return error.BadFileNumber;
        if (slot_index >= self.open_files.items.len or self.open_files.items[slot_index].number != file_number) return error.InvalidInstruction;
        return &self.open_files.items[slot_index].file;
    }

    fn fileSlotIndex(self: *const Vm, file_number: usize) ?usize {
        if (file_number == 0 or file_number > maximum_file_number) return null;
        const encoded = self.file_slot_indices[file_number];
        return if (encoded == 0) null else @as(usize, encoded - 1);
    }

    fn fileHostContext(self: *Vm) ?*anyopaque {
        return self.host.file_context orelse self.host.context;
    }

    fn popFileNumber(self: *Vm) ExecutionError!usize {
        var value = try self.popValue();
        defer value.deinit(self.allocator);
        const number = try values.asLong(value);
        if (number < 1 or number > maximum_file_number) return error.BadFileNumber;
        return @intCast(number);
    }

    fn fileNumberAt(self: *Vm, stack_index: usize) ExecutionError!usize {
        if (stack_index >= self.stack.items.len) return error.StackUnderflow;
        const item = switch (self.stack.items[stack_index]) {
            .value => |value| value,
            .reference => return error.InvalidInstruction,
        };
        const number = try values.asLong(item);
        if (number < 1 or number > maximum_file_number) return error.BadFileNumber;
        return @intCast(number);
    }

    fn resolveGuestPath(self: *Vm, raw_path: []const u8) ExecutionError![]u8 {
        if (raw_path.len == 0 or containsInvalidPathByte(raw_path) or isReservedDevicePath(raw_path)) return error.BadFileName;
        if (isAbsoluteGuestPath(raw_path)) return self.allocator.dupe(u8, raw_path);
        if (std.mem.indexOfScalar(u8, raw_path, ':') != null) return error.BadFileName;

        var base = self.host.guest_directory;
        if (base.len == 0) {
            const file_name = self.program.file_name;
            if (!isAbsoluteGuestPath(file_name)) return error.BadFileName;
            base = file_name[0 .. lastPathSeparator(file_name) orelse return error.BadFileName];
        }
        if (!isAbsoluteGuestPath(base)) return error.BadFileName;
        const needs_separator = base.len != 0 and base[base.len - 1] != '\\' and base[base.len - 1] != '/';
        return std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ base, if (needs_separator) "\\" else "", raw_path });
    }

    fn deferredBuiltin(self: *Vm, argument_count: u32) ExecutionError!void {
        if (argument_count > self.stack.items.len) return error.StackUnderflow;
        var remaining = argument_count;
        while (remaining != 0) : (remaining -= 1) {
            var argument = try self.popValue();
            argument.deinit(self.allocator);
        }
        return error.HostFailure;
    }

    fn convertTop(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        var input = try self.popValue();
        defer input.deinit(self.allocator);
        self.value_conversions +%= 1;
        try self.pushValue(try values.convert(self.allocator, input, target));
    }

    fn unaryNegate(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        var input = try self.popValue();
        defer input.deinit(self.allocator);
        try self.pushValue(try values.negate(input, target));
    }

    fn unaryLogicalNot(self: *Vm) ExecutionError!void {
        var input = try self.popValue();
        defer input.deinit(self.allocator);
        try self.pushValue(try values.logicalNot(input));
    }

    fn binary(self: *Vm, operation: values.BinaryOperation, target: bytecode.ValueType) ExecutionError!void {
        var right = try self.popValue();
        defer right.deinit(self.allocator);
        var left = try self.popValue();
        defer left.deinit(self.allocator);
        try self.pushValue(try values.binary(self.allocator, operation, left, right, target));
    }

    fn comparison(self: *Vm, operation: values.Comparison, bound_type: bytecode.ValueType) ExecutionError!void {
        var right = try self.popValue();
        defer right.deinit(self.allocator);
        var left = try self.popValue();
        defer left.deinit(self.allocator);
        switch (bound_type) {
            .integer, .long => self.integer_comparisons +%= 1,
            .single, .double => self.floating_comparisons +%= 1,
            .string => self.string_comparisons +%= 1,
        }
        try self.pushValue(try values.compare(left, right, operation, bound_type));
    }

    fn power(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        var exponent = try self.popValue();
        defer exponent.deinit(self.allocator);
        var base = try self.popValue();
        defer base.deinit(self.allocator);
        const first = try values.asDouble(base);
        const second = try values.asDouble(exponent);
        if (first == 0 and second < 0) return error.DivisionByZero;
        if (first < 0 and @floor(second) != second) return error.IllegalFunctionCall;
        const result = self.host.math(self.host.context, .power, first, second) catch return error.HostFailure;
        if (!std.math.isFinite(result)) return error.Overflow;
        if (target == .double) return self.pushValue(.{ .double = result });
        const single: f32 = @floatCast(result);
        if (!std.math.isFinite(single)) return error.Overflow;
        const raw: values.Value = .{ .single = single };
        try self.pushValue(raw);
    }

    fn popCondition(self: *Vm) ExecutionError!bool {
        var condition = try self.popValue();
        defer condition.deinit(self.allocator);
        return values.isTrue(condition);
    }

    fn callProcedure(
        self: *Vm,
        procedure_id: u32,
        argument_count: u32,
    ) ExecutionError!void {
        if (procedure_id >= self.program.procedures.len) return error.InvalidInstruction;
        if (self.frames.items.len >= maximum_call_depth) return error.CallDepthExceeded;
        const procedure = self.program.procedures[procedure_id];
        if (argument_count != procedure.parameters.len or argument_count > self.stack.items.len) return error.InvalidInstruction;
        const stack_base = self.stack.items.len - argument_count;

        var frame = try self.acquireFrameLocalStorage(procedure_id, stack_base);
        errdefer self.releaseFrameLocals(&frame);

        for (procedure.parameters, 0..) |parameter, index| {
            const item = self.stack.items[stack_base + index];
            const local = switch (parameter.passing_mode) {
                .by_ref => switch (item) {
                    .reference => |cell| Cell{ .alias = cell },
                    .value => try self.cloneArgumentCell(item, parameter.value_type),
                },
                .by_value => try self.cloneArgumentCell(item, parameter.value_type),
            };
            self.installPendingFrameLocal(&frame, parameter.local_index, local);
        }

        try self.frames.append(self.allocator, frame);
        self.procedure_calls +%= 1;
        self.discardStackFrom(stack_base);
        self.instruction_pointer = procedure.entry_ip;
    }

    fn returnProcedure(self: *Vm) ExecutionError!void {
        if (self.frames.items.len == 0) return error.InvalidInstruction;
        const frame_depth = self.frames.items.len;
        const procedure = self.program.procedures[self.frames.items[frame_depth - 1].procedure_id];
        var return_value: ?values.Value = null;
        if (procedure.returnsValue()) {
            const cell = try self.frameLocalCell(frame_depth - 1, procedure.return_local);
            const value = try (try self.resolveCellTracked(cell)).value();
            return_value = try self.cloneValueTracked(&value);
        }

        var frame = self.frames.pop().?;
        self.discardStackFrom(frame.stack_base);
        self.instruction_pointer = frame.return_ip;
        self.releaseFrameLocals(&frame);
        while (self.gosub_stack.items.len != 0 and self.gosub_stack.items[self.gosub_stack.items.len - 1].frame_depth >= frame_depth) {
            _ = self.gosub_stack.pop();
        }
        if (return_value) |value| try self.pushValue(value);
    }

    fn acquireFrameLocalStorage(self: *Vm, procedure_id: u32, stack_base: usize) ExecutionError!Frame {
        const pool_index = self.frames.items.len;
        if (pool_index == self.frame_local_storage.items.len) {
            try self.frame_local_storage.append(self.allocator, .{});
        }
        if (pool_index >= self.frame_local_storage.items.len) return error.InvalidInstruction;

        const local_count = self.program.procedures[procedure_id].locals.len;
        var storage = &self.frame_local_storage.items[pool_index];
        if (storage.slots.capacity < local_count) {
            try storage.slots.ensureTotalCapacityPrecise(self.allocator, local_count);
            self.local_pool_grows +%= 1;
        } else {
            self.local_pool_reuses +%= 1;
        }
        if (storage.slots.items.len < local_count) {
            const previous = storage.slots.items.len;
            storage.slots.items.len = local_count;
            for (storage.slots.items[previous..]) |*slot| slot.* = .{};
        }
        storage.generation +%= 1;
        if (storage.generation == 0) {
            for (storage.slots.items) |*slot| slot.generation = 0;
            storage.generation = 1;
        }
        return .{
            .procedure_id = procedure_id,
            .return_ip = self.instruction_pointer,
            .stack_base = stack_base,
            .call_resume_ip = self.current_statement_start,
            .call_resume_next = self.current_statement_next,
            .local_pool_index = pool_index,
            .local_count = @intCast(local_count),
            .local_generation = storage.generation,
        };
    }

    fn cloneArgumentCell(self: *Vm, item: StackItem, target: bytecode.ValueType) ExecutionError!Cell {
        var argument = try self.cloneStackItem(item);
        if (argument.valueType() == target) return .{ .owned = .{ .scalar = argument } };
        defer argument.deinit(self.allocator);
        return .{ .owned = .{ .scalar = try values.convert(self.allocator, argument, target) } };
    }

    fn installPendingFrameLocal(self: *Vm, frame: *Frame, local_index: u32, cell: Cell) void {
        std.debug.assert(local_index < frame.local_count);
        var storage = &self.frame_local_storage.items[frame.local_pool_index];
        var slot = &storage.slots.items[local_index];
        std.debug.assert(slot.generation != frame.local_generation);
        slot.cell = cell;
        slot.generation = frame.local_generation;
        slot.next_initialized = frame.initialized_local_head;
        frame.initialized_local_head = local_index;
        self.recordLocalInitialization(frame.procedure_id, local_index);
    }

    fn frameLocalCell(self: *Vm, frame_index: usize, local_index: u32) ExecutionError!*Cell {
        if (frame_index >= self.frames.items.len) return error.InvalidInstruction;
        const frame = self.frames.items[frame_index];
        if (local_index >= frame.local_count) return error.InvalidInstruction;
        var slot = &self.frame_local_storage.items[frame.local_pool_index].slots.items[local_index];
        if (slot.generation != frame.local_generation) {
            const variable = self.program.procedures[frame.procedure_id].locals[local_index];
            const cell = try allocateVariable(self.allocator, self.program, variable);
            self.installActiveFrameLocal(frame_index, local_index, cell);
            slot = &self.frame_local_storage.items[frame.local_pool_index].slots.items[local_index];
        }
        return &slot.cell;
    }

    fn installActiveFrameLocal(self: *Vm, frame_index: usize, local_index: u32, cell: Cell) void {
        const pool_index = self.frames.items[frame_index].local_pool_index;
        const generation = self.frames.items[frame_index].local_generation;
        var slot = &self.frame_local_storage.items[pool_index].slots.items[local_index];
        std.debug.assert(slot.generation != generation);
        slot.cell = cell;
        slot.generation = generation;
        slot.next_initialized = self.frames.items[frame_index].initialized_local_head;
        self.frames.items[frame_index].initialized_local_head = local_index;
        self.recordLocalInitialization(self.frames.items[frame_index].procedure_id, local_index);
    }

    fn recordLocalInitialization(self: *Vm, procedure_id: u32, local_index: u32) void {
        self.local_initializations +%= 1;
        self.local_initialization_bytes +|= @as(u64, @sizeOf(Cell));
        const variable = self.program.procedures[procedure_id].locals[local_index];
        if (variable.isArray() or variable.record_type != bytecode.invalid_index) {
            self.local_aggregate_initializations +%= 1;
        }
    }

    fn releaseFrameLocals(self: *Vm, frame: *Frame) void {
        var storage = &self.frame_local_storage.items[frame.local_pool_index];
        var current = frame.initialized_local_head;
        while (current != bytecode.invalid_index) {
            var slot = &storage.slots.items[current];
            std.debug.assert(slot.generation == frame.local_generation);
            const next = slot.next_initialized;
            self.deinitCellTracked(&slot.cell);
            slot.generation = 0;
            slot.next_initialized = bytecode.invalid_index;
            current = next;
        }
        frame.* = undefined;
    }

    fn deinitCellTracked(self: *Vm, cell: *Cell) void {
        const payload_bytes = switch (cell.*) {
            .owned => |*owned| switch (owned.*) {
                .array => |*array| arrayLogicalPayloadBytes(self.program, array.value_type, array.record_type, array.storage.len()) catch 0,
                else => 0,
            },
            .alias => 0,
        };
        std.debug.assert(payload_bytes <= self.array_live_payload_bytes);
        self.array_live_payload_bytes -|= @intCast(payload_bytes);
        cell.deinit(self.allocator);
    }

    fn gosub(self: *Vm, target: u32) ExecutionError!void {
        if (self.gosub_stack.items.len >= maximum_gosub_depth) return error.StackOverflow;
        try self.gosub_stack.append(self.allocator, .{
            .return_ip = self.instruction_pointer,
            .frame_depth = self.frames.items.len,
        });
        self.instruction_pointer = target;
    }

    fn returnGosub(self: *Vm, target: u32) ExecutionError!void {
        const entry = self.gosub_stack.pop() orelse return error.GosubWithoutReturn;
        if (entry.frame_depth != self.frames.items.len) return error.GosubWithoutReturn;
        self.instruction_pointer = if (target == bytecode.invalid_index) entry.return_ip else target;
    }

    fn callBuiltin(self: *Vm, builtin: bytecode.Builtin, argument_count: u32) ExecutionError!void {
        if (argument_count > 3 or argument_count > self.stack.items.len) return error.InvalidInstruction;
        var argument_items: [3]StackItem = undefined;
        var arguments: [3]values.Value = undefined;
        var first_initialized: usize = argument_count;
        defer for (argument_items[first_initialized..argument_count]) |*argument| argument.deinit(self.allocator);
        while (first_initialized != 0) {
            first_initialized -= 1;
            const item = self.stack.pop().?;
            argument_items[first_initialized] = item;
            arguments[first_initialized] = switch (item) {
                .value => |value| blk: {
                    self.builtin_owned_arguments +%= 1;
                    break :blk value;
                },
                .reference => |cell| blk: {
                    self.builtin_borrowed_arguments +%= 1;
                    break :blk try cell.value();
                },
            };
        }

        const result = try self.evaluateBuiltin(builtin, arguments[0..argument_count]);
        try self.pushValue(result);
    }

    fn evaluateBuiltin(self: *Vm, builtin: bytecode.Builtin, arguments: []const values.Value) ExecutionError!values.Value {
        return switch (builtin) {
            .abs => absolute(arguments[0]),
            .atn => self.hostMath(.atn, arguments[0], .{ .single = 0 }),
            .cos => self.hostMath(.cos, arguments[0], .{ .single = 0 }),
            .sin => self.hostMath(.sin, arguments[0], .{ .single = 0 }),
            .chr_string => self.character(arguments[0]),
            .cint => values.convert(self.allocator, arguments[0], .integer),
            .instr => self.instr(arguments),
            .int => integerFloor(arguments[0]),
            .left_string => self.leftString(arguments[0], arguments[1]),
            .len => .{ .integer = @intCast(arguments[0].string.len) },
            .ltrim_string => self.leftTrim(arguments[0]),
            .mid_string => self.midString(arguments),
            .peek => error.HostFailure,
            .space_string => self.spaceString(arguments[0]),
            .str_string => self.numberString(arguments[0]),
            .ucase_string => self.upperString(arguments[0]),
            .val => self.val(arguments[0]),
            .eof => self.endOfFile(arguments[0]),
            .inkey_string => self.inkeyString(),
            .rnd => self.randomNumber(arguments),
            .timer => self.timerValue(),
            .point => blk: {
                const x = try values.asLong(arguments[0]);
                const y = try values.asLong(arguments[1]);
                break :blk .{ .integer = @intCast(try self.graphics.point(.{ .x = x, .y = y })) };
            },
        };
    }

    fn endOfFile(self: *Vm, file_number_value: values.Value) ExecutionError!values.Value {
        const raw_number = try values.asLong(file_number_value);
        if (raw_number < 1 or raw_number > maximum_file_number) return error.BadFileNumber;
        const file = try self.fileAt(@intCast(raw_number));
        if (file.mode != .input) return error.BadFileMode;
        return .{ .integer = if (file.offset >= file.input.len) -1 else 0 };
    }

    fn inkeyString(self: *Vm) ExecutionError!values.Value {
        const byte = self.popKeyboardByte() orelse return .{ .string = try self.allocator.alloc(u8, 0) };
        const result = try self.allocator.alloc(u8, 1);
        result[0] = byte;
        return .{ .string = result };
    }

    fn randomNumber(self: *Vm, arguments: []const values.Value) ExecutionError!values.Value {
        if (arguments.len > 1) return error.InvalidInstruction;
        if (arguments.len == 0) return .{ .single = self.nextRandom() };
        const argument = try values.asDouble(arguments[0]);
        if (!std.math.isFinite(argument)) return error.IllegalFunctionCall;
        if (argument < 0) {
            self.seedRandom(argument);
            return .{ .single = self.nextRandom() };
        }
        if (argument == 0) return .{ .single = self.random_last };
        return .{ .single = self.nextRandom() };
    }

    fn timerSeconds(self: *const Vm) f32 {
        const day_ns: u64 = 86_400 * std.time.ns_per_s;
        const within_day = self.guest_now_ns % day_ns;
        return @as(f32, @floatFromInt(within_day)) / @as(f32, @floatFromInt(std.time.ns_per_s));
    }

    fn timerValue(self: *Vm) ExecutionError!values.Value {
        self.timer_calls +%= 1;
        if (self.cooperative_timer_pacing and self.guest_now_ns < self.next_timer_poll_ns) {
            self.wait_wake_ns = self.next_timer_poll_ns;
            self.timer_yield_count +%= 1;
            self.timer_waits +%= 1;
            return error.WouldBlock;
        }
        if (self.cooperative_timer_pacing) {
            if (self.next_timer_poll_ns != 0) {
                self.maximum_timer_wake_lateness_ns = @max(
                    self.maximum_timer_wake_lateness_ns,
                    self.guest_now_ns -| self.next_timer_poll_ns,
                );
            }
            self.next_timer_poll_ns = self.guest_now_ns +| timer_poll_interval_ns;
        }
        return .{ .single = self.timerSeconds() };
    }

    fn hostMath(self: *Vm, operation: MathOperation, input: values.Value, unused: values.Value) ExecutionError!values.Value {
        _ = unused;
        const number = try values.asDouble(input);
        const result = self.host.math(self.host.context, operation, number, 0) catch return error.HostFailure;
        if (!std.math.isFinite(result)) return error.Overflow;
        if (input.valueType() == .double) return .{ .double = result };
        const single: f32 = @floatCast(result);
        if (!std.math.isFinite(single)) return error.Overflow;
        return .{ .single = single };
    }

    fn character(self: *Vm, input: values.Value) ExecutionError!values.Value {
        const number = try values.asLong(input);
        if (number < 0 or number > 255) return error.IllegalFunctionCall;
        const result = try self.allocator.alloc(u8, 1);
        result[0] = @intCast(number);
        return .{ .string = result };
    }

    fn instr(self: *Vm, arguments: []const values.Value) ExecutionError!values.Value {
        _ = self;
        const offset: usize = if (arguments.len == 3) 1 else 0;
        const start: i32 = if (offset == 1) try values.asLong(arguments[0]) else 1;
        if (start < 1) return error.IllegalFunctionCall;
        const haystack = arguments[offset].string;
        const needle = arguments[offset + 1].string;
        const start_index: usize = @intCast(start - 1);
        if (start_index > haystack.len) return .{ .integer = 0 };
        const found = std.mem.indexOfPos(u8, haystack, start_index, needle) orelse return .{ .integer = 0 };
        if (found + 1 > std.math.maxInt(i16)) return error.Overflow;
        return .{ .integer = @intCast(found + 1) };
    }

    fn leftString(self: *Vm, string_value: values.Value, count_value: values.Value) ExecutionError!values.Value {
        const count = try values.asLong(count_value);
        if (count < 0) return error.IllegalFunctionCall;
        const length = @min(string_value.string.len, @as(usize, @intCast(count)));
        return .{ .string = try self.allocator.dupe(u8, string_value.string[0..length]) };
    }

    fn leftTrim(self: *Vm, input: values.Value) ExecutionError!values.Value {
        var start: usize = 0;
        while (start < input.string.len and input.string[start] == ' ') start += 1;
        return .{ .string = try self.allocator.dupe(u8, input.string[start..]) };
    }

    fn midString(self: *Vm, arguments: []const values.Value) ExecutionError!values.Value {
        const start = try values.asLong(arguments[1]);
        if (start < 1) return error.IllegalFunctionCall;
        const start_index: usize = @intCast(start - 1);
        if (start_index >= arguments[0].string.len) return .{ .string = try self.allocator.dupe(u8, "") };
        var end = arguments[0].string.len;
        if (arguments.len == 3) {
            const count = try values.asLong(arguments[2]);
            if (count < 0) return error.IllegalFunctionCall;
            end = @min(end, start_index + @as(usize, @intCast(count)));
        }
        return .{ .string = try self.allocator.dupe(u8, arguments[0].string[start_index..end]) };
    }

    fn spaceString(self: *Vm, input: values.Value) ExecutionError!values.Value {
        const count = try values.asLong(input);
        if (count < 0 or count > values.maximum_string_bytes) return error.IllegalFunctionCall;
        const result = try self.allocator.alloc(u8, @intCast(count));
        @memset(result, ' ');
        return .{ .string = result };
    }

    fn numberString(self: *Vm, input: values.Value) ExecutionError!values.Value {
        var storage: [numeric_format_buffer_bytes]u8 = undefined;
        const body = switch (input) {
            .integer => |number| try self.formatNumber(&storage, number),
            .long => |number| try self.formatNumber(&storage, number),
            .single => |number| try self.formatNumber(&storage, number),
            .double => |number| try self.formatNumber(&storage, number),
            .string => return error.TypeMismatch,
        };
        const positive = body.len == 0 or body[0] != '-';
        const result = try self.allocator.alloc(u8, body.len + @intFromBool(positive));
        self.str_result_allocations +%= 1;
        if (positive) result[0] = ' ';
        @memcpy(result[@intFromBool(positive)..], body);
        return .{ .string = result };
    }

    fn upperString(self: *Vm, input: values.Value) ExecutionError!values.Value {
        const result = try self.allocator.dupe(u8, input.string);
        for (result) |*byte| byte.* = std.ascii.toUpper(byte.*);
        return .{ .string = result };
    }

    fn val(self: *Vm, input: values.Value) ExecutionError!values.Value {
        const trimmed = std.mem.trimStart(u8, input.string, " \t");
        if (trimmed.len == 0) return .{ .double = 0 };
        var length: usize = 0;
        if (trimmed[length] == '+' or trimmed[length] == '-') length += 1;
        var exponent_seen = false;
        while (length < trimmed.len) : (length += 1) {
            const byte = trimmed[length];
            if (std.ascii.isDigit(byte) or byte == '.') continue;
            if (!exponent_seen and (byte == 'E' or byte == 'e' or byte == 'D' or byte == 'd')) {
                exponent_seen = true;
                if (length + 1 < trimmed.len and (trimmed[length + 1] == '+' or trimmed[length + 1] == '-')) length += 1;
                continue;
            }
            break;
        }
        if (length == 0) return .{ .double = 0 };
        const number_text = trimmed[0..length];
        var needs_normalization = false;
        for (number_text) |byte| {
            if (byte == 'D' or byte == 'd') {
                needs_normalization = true;
                break;
            }
        }
        if (!needs_normalization) {
            self.val_direct_parses +%= 1;
            const number = std.fmt.parseFloat(f64, number_text) catch return .{ .double = 0 };
            if (!std.math.isFinite(number)) return error.Overflow;
            return .{ .double = number };
        }

        var stack_storage: [numeric_format_buffer_bytes]u8 = undefined;
        const normalized: []u8 = if (number_text.len <= stack_storage.len) blk: {
            self.val_stack_normalizations +%= 1;
            break :blk stack_storage[0..number_text.len];
        } else blk: {
            const previous_capacity = self.numeric_scratch.capacity;
            try self.numeric_scratch.ensureTotalCapacityPrecise(self.allocator, number_text.len);
            if (self.numeric_scratch.capacity != previous_capacity) self.val_scratch_grows +%= 1;
            self.numeric_scratch.items.len = number_text.len;
            self.val_scratch_normalizations +%= 1;
            break :blk self.numeric_scratch.items;
        };
        @memcpy(normalized, number_text);
        for (normalized) |*byte| {
            if (byte.* == 'D' or byte.* == 'd') byte.* = 'E';
        }
        const number = std.fmt.parseFloat(f64, normalized) catch return .{ .double = 0 };
        if (!std.math.isFinite(number)) return error.Overflow;
        return .{ .double = number };
    }

    fn pushValue(self: *Vm, value: values.Value) ExecutionError!void {
        if (self.stack.items.len >= maximum_value_stack) {
            var owned = value;
            owned.deinit(self.allocator);
            return error.StackOverflow;
        }
        try self.stack.append(self.allocator, .{ .value = value });
    }

    fn pushReference(self: *Vm, cell: *Cell) ExecutionError!void {
        return self.pushResolvedReference(try self.resolveCellTracked(cell));
    }

    fn pushResolvedReference(self: *Vm, reference: Reference) ExecutionError!void {
        if (self.stack.items.len >= maximum_value_stack) return error.StackOverflow;
        try self.stack.append(self.allocator, .{ .reference = reference });
    }

    fn popReference(self: *Vm) ExecutionError!Reference {
        const item = self.stack.pop() orelse return error.StackUnderflow;
        return switch (item) {
            .reference => |reference| reference,
            .value => |value| blk: {
                var owned = value;
                owned.deinit(self.allocator);
                break :blk error.TypeMismatch;
            },
        };
    }

    fn popValue(self: *Vm) ExecutionError!values.Value {
        const item = self.stack.pop() orelse return error.StackUnderflow;
        return switch (item) {
            .value => |value| value,
            .reference => |reference| blk: {
                const value = try reference.value();
                break :blk self.cloneValueTracked(&value);
            },
        };
    }

    fn cloneStackItem(self: *Vm, item: StackItem) ExecutionError!values.Value {
        return switch (item) {
            .value => |value| self.cloneValueTracked(&value),
            .reference => |reference| blk: {
                const value = try reference.value();
                break :blk self.cloneValueTracked(&value);
            },
        };
    }

    fn cloneValueTracked(self: *Vm, value: *const values.Value) ExecutionError!values.Value {
        switch (value.*) {
            .string => |bytes| {
                self.string_clones +%= 1;
                self.string_clone_bytes +|= @intCast(bytes.len);
            },
            else => {},
        }
        return value.clone(self.allocator);
    }

    fn discardStackFrom(self: *Vm, first: usize) void {
        while (self.stack.items.len > first) {
            var item = self.stack.pop().?;
            item.deinit(self.allocator);
        }
    }

    fn localCellAt(self: *Vm, index: u32) ExecutionError!Reference {
        if (self.frames.items.len == 0) return error.InvalidInstruction;
        return self.resolveCellTracked(try self.frameLocalCell(self.frames.items.len - 1, index));
    }

    fn globalCellAt(self: *Vm, index: u32) ExecutionError!Reference {
        if (index >= self.globals.len) return error.InvalidInstruction;
        return self.resolveCellTracked(&self.globals[index]);
    }

    fn resolveCellTracked(self: *Vm, original: *Cell) ExecutionError!Reference {
        self.cell_resolve_calls +%= 1;
        var cell = original;
        var depth: usize = 0;
        while (depth <= maximum_call_depth) : (depth += 1) {
            switch (cell.*) {
                .owned => return .{ .cell = cell },
                .alias => |target| switch (target) {
                    .cell => |next| {
                        self.cell_alias_hops +%= 1;
                        cell = next;
                    },
                    else => {
                        self.cell_alias_hops +%= 1;
                        return target;
                    },
                },
            }
        }
        return error.InvalidInstruction;
    }

    fn recordError(self: *Vm, code: RuntimeCode, instruction: u32) void {
        self.recordDiagnostic(self.makeDiagnostic(code, instruction));
    }

    fn recordDiagnostic(self: *Vm, diagnostic: RuntimeDiagnostic) void {
        self.runtime_diagnostic = diagnostic;
        self.status = .runtime_error;
        self.exit_code = self.runtime_diagnostic.?.qbasicErrorNumber();
    }

    fn makeDiagnostic(self: *Vm, code: RuntimeCode, instruction: u32) RuntimeDiagnostic {
        const span: frontend.Span = if (instruction < self.program.instructions.len)
            self.readInstructionMetadata(instruction).span
        else
            .{ .start = 0, .end = 0, .line = 1, .column = 1 };
        return .{ .code = code, .file_name = self.program.file_name, .span = span, .instruction = instruction };
    }
};

const InputField = struct {
    bytes: []const u8,
};

fn nextInputField(bytes: []const u8, cursor: *usize) ?InputField {
    while (cursor.* < bytes.len and (bytes[cursor.*] == ' ' or bytes[cursor.*] == '\t')) cursor.* += 1;
    if (cursor.* >= bytes.len) return null;
    if (bytes[cursor.*] == ',') {
        cursor.* += 1;
        return .{ .bytes = "" };
    }
    if (bytes[cursor.*] == '"') {
        cursor.* += 1;
        const start = cursor.*;
        while (cursor.* < bytes.len and bytes[cursor.*] != '"') cursor.* += 1;
        if (cursor.* >= bytes.len) return null;
        const result = bytes[start..cursor.*];
        cursor.* += 1;
        while (cursor.* < bytes.len and (bytes[cursor.*] == ' ' or bytes[cursor.*] == '\t')) cursor.* += 1;
        if (cursor.* < bytes.len) {
            if (bytes[cursor.*] != ',') return null;
            cursor.* += 1;
        }
        return .{ .bytes = result };
    }
    const start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != ',') cursor.* += 1;
    const result = std.mem.trim(u8, bytes[start..cursor.*], " \t");
    if (cursor.* < bytes.len) cursor.* += 1;
    return .{ .bytes = result };
}

fn skipInputSeparators(bytes: []const u8, cursor: *usize) void {
    while (cursor.* < bytes.len and (bytes[cursor.*] == ' ' or bytes[cursor.*] == '\t')) cursor.* += 1;
}

fn nextSequentialField(bytes: []const u8, cursor: *usize) ?InputField {
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        if (byte != ' ' and byte != '\t' and byte != ',' and byte != '\r' and byte != '\n') break;
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return null;
    if (bytes[cursor.*] == '"') {
        cursor.* += 1;
        const start = cursor.*;
        while (cursor.* < bytes.len and bytes[cursor.*] != '"') cursor.* += 1;
        if (cursor.* >= bytes.len) return null;
        const result = bytes[start..cursor.*];
        cursor.* += 1;
        while (cursor.* < bytes.len and bytes[cursor.*] != ',' and bytes[cursor.*] != '\r' and bytes[cursor.*] != '\n') cursor.* += 1;
        if (cursor.* < bytes.len) {
            if (bytes[cursor.*] == '\r' or bytes[cursor.*] == '\n') {
                consumeLineEnding(bytes, cursor);
            } else {
                cursor.* += 1;
            }
        }
        return .{ .bytes = result };
    }
    const start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != ',' and bytes[cursor.*] != '\r' and bytes[cursor.*] != '\n') cursor.* += 1;
    const result = std.mem.trim(u8, bytes[start..cursor.*], " \t");
    if (cursor.* < bytes.len) {
        if (bytes[cursor.*] == '\r' or bytes[cursor.*] == '\n') {
            consumeLineEnding(bytes, cursor);
        } else {
            cursor.* += 1;
        }
    }
    return .{ .bytes = result };
}

fn consumeLineEnding(bytes: []const u8, cursor: *usize) void {
    if (cursor.* >= bytes.len) return;
    const first = bytes[cursor.*];
    if (first != '\r' and first != '\n') return;
    cursor.* += 1;
    if (cursor.* < bytes.len and ((first == '\r' and bytes[cursor.*] == '\n') or (first == '\n' and bytes[cursor.*] == '\r'))) {
        cursor.* += 1;
    }
}

fn normalizeRandomSeed(seed: u32) u32 {
    const normalized = seed & random_mask;
    return if (normalized == 0) 1 else normalized;
}

fn fileHostFault(failure: FileHostError) ExecutionError {
    return switch (failure) {
        .unavailable => error.HostFailure,
        .not_found => error.FileNotFound,
        .permission_denied => error.PermissionDenied,
        .path_error => error.PathFileAccess,
        .io_error => error.PathFileAccess,
        .too_large => error.OutOfMemory,
    };
}

fn containsInvalidPathByte(path: []const u8) bool {
    for (path) |byte| if (byte < 0x20 or byte == 0x7F or byte == '"' or byte == '<' or byte == '>' or byte == '|' or byte == '?' or byte == '*') return true;
    return false;
}

fn isAbsoluteGuestPath(path: []const u8) bool {
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index != 0) {
        index -= 1;
        if (path[index] == '\\' or path[index] == '/') return index;
    }
    return null;
}

fn isReservedDevicePath(path: []const u8) bool {
    const separator = lastPathSeparator(path);
    const component_start = if (separator) |index| index + 1 else 0;
    const component = path[component_start..];
    var end: usize = 0;
    while (end < component.len and component[end] != '.' and component[end] != ':') : (end += 1) {}
    const name = std.mem.trim(u8, component[0..end], " ");
    if (std.ascii.eqlIgnoreCase(name, "CON") or std.ascii.eqlIgnoreCase(name, "PRN") or
        std.ascii.eqlIgnoreCase(name, "AUX") or std.ascii.eqlIgnoreCase(name, "NUL") or
        std.ascii.eqlIgnoreCase(name, "CLOCK$") or std.ascii.eqlIgnoreCase(name, "SCRN") or
        std.ascii.eqlIgnoreCase(name, "KYBD") or std.ascii.eqlIgnoreCase(name, "CONS")) return true;
    if (name.len == 4 and name[3] >= '1' and name[3] <= '9') {
        if (std.ascii.eqlIgnoreCase(name[0..3], "COM") or std.ascii.eqlIgnoreCase(name[0..3], "LPT")) return true;
    }
    return false;
}

fn absolute(input: values.Value) ExecutionError!values.Value {
    return switch (input) {
        .integer => |number| if (number == std.math.minInt(i16)) error.Overflow else .{ .integer = @intCast(@abs(number)) },
        .long => |number| if (number == std.math.minInt(i32)) error.Overflow else .{ .long = @intCast(@abs(number)) },
        .single => |number| .{ .single = @abs(number) },
        .double => |number| .{ .double = @abs(number) },
        .string => error.TypeMismatch,
    };
}

fn integerFloor(input: values.Value) ExecutionError!values.Value {
    return switch (input) {
        .integer => |number| .{ .integer = number },
        .long => |number| .{ .long = number },
        .single => |number| .{ .single = @floor(number) },
        .double => |number| .{ .double = @floor(number) },
        .string => error.TypeMismatch,
    };
}

fn saturatingCoordinateAdd(first: i32, second: i32) i32 {
    const result = @as(i64, first) + second;
    return @intCast(std.math.clamp(result, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn arrayElementWidth(value_type: bytecode.ValueType) ExecutionError!usize {
    return switch (value_type) {
        .integer => 2,
        .long, .single => 4,
        .double => 8,
        .string => error.TypeMismatch,
    };
}

fn readArrayRaw(allocator: std.mem.Allocator, array: *const ArrayValue) ExecutionError![]u8 {
    if (array.record_type != bytecode.invalid_index or !array.value_type.isNumeric()) return error.TypeMismatch;
    const width = try arrayElementWidth(array.value_type);
    const byte_count = std.math.mul(usize, array.storage.len(), width) catch return error.OutOfMemory;
    const result = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(result);
    var index: usize = 0;
    while (index < array.storage.len()) : (index += 1) {
        const element = arrayReferenceAtConst(array, index) orelse return error.InvalidInstruction;
        try encodeArrayElement(element, array.value_type, result[index * width ..][0..width]);
    }
    return result;
}

fn writeArrayRawPrefix(array: *ArrayValue, bytes: []const u8) ExecutionError!void {
    if (array.record_type != bytecode.invalid_index or !array.value_type.isNumeric()) return error.TypeMismatch;
    const width = try arrayElementWidth(array.value_type);
    const byte_count = std.math.mul(usize, array.storage.len(), width) catch return error.OutOfMemory;
    if (bytes.len > byte_count) return error.IllegalFunctionCall;
    var raw: [8]u8 = [_]u8{0} ** 8;
    var index: usize = 0;
    while (index < array.storage.len()) : (index += 1) {
        const offset = index * width;
        if (offset >= bytes.len) break;
        const element = arrayReferenceAt(array, index) orelse return error.InvalidInstruction;
        try encodeArrayElement(element, array.value_type, raw[0..width]);
        const amount = @min(width, bytes.len - offset);
        @memcpy(raw[0..amount], bytes[offset .. offset + amount]);
        try decodeArrayElement(element, array.value_type, raw[0..width]);
    }
}

fn encodeArrayElement(reference: Reference, value_type: bytecode.ValueType, out: []u8) ExecutionError!void {
    const scalar = try reference.value();
    if (scalar.valueType() != value_type or out.len != try arrayElementWidth(value_type)) return error.TypeMismatch;
    switch (scalar) {
        .integer => |number| std.mem.writeInt(u16, out[0..2], @bitCast(number), .little),
        .long => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number), .little),
        .single => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number), .little),
        .double => |number| std.mem.writeInt(u64, out[0..8], @bitCast(number), .little),
        .string => return error.TypeMismatch,
    }
}

fn decodeArrayElement(reference: Reference, value_type: bytecode.ValueType, bytes: []const u8) ExecutionError!void {
    if (try reference.valueType() != value_type or bytes.len != try arrayElementWidth(value_type)) return error.TypeMismatch;
    const scalar: values.Value = switch (value_type) {
        .integer => .{ .integer = @bitCast(std.mem.readInt(u16, bytes[0..2], .little)) },
        .long => .{ .long = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)) },
        .single => .{ .single = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)) },
        .double => .{ .double = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)) },
        .string => return error.TypeMismatch,
    };
    try reference.replaceNumeric(scalar);
}

fn runtimeCode(fault: ExecutionError) RuntimeCode {
    return switch (fault) {
        error.Overflow => .overflow,
        error.DivisionByZero => .division_by_zero,
        error.TypeMismatch => .type_mismatch,
        error.IllegalFunctionCall => .illegal_function_call,
        error.OutOfMemory => .out_of_memory,
        error.StackOverflow => .stack_overflow,
        error.StackUnderflow => .stack_underflow,
        error.CallDepthExceeded => .call_depth_exceeded,
        error.GosubWithoutReturn => .gosub_without_return,
        error.InvalidInstruction => .invalid_instruction,
        error.HostFailure => .host_failure,
        error.SubscriptOutOfRange => .subscript_out_of_range,
        error.ArrayAlreadyDimensioned => .array_already_dimensioned,
        error.OutOfData => .out_of_data,
        error.ResumeWithoutError => .resume_without_error,
        error.RestrictedMemory => .restricted_memory,
        error.BadFileNumber => .bad_file_number,
        error.FileNotFound => .file_not_found,
        error.BadFileMode => .bad_file_mode,
        error.FileAlreadyOpen => .file_already_open,
        error.InputPastEnd => .input_past_end,
        error.BadFileName => .bad_file_name,
        error.PermissionDenied => .permission_denied,
        error.PathFileAccess => .path_file_access,
        error.Rethrow => .invalid_instruction,
        error.WouldBlock => .invalid_instruction,
    };
}

fn isCatchable(code: RuntimeCode) bool {
    return switch (code) {
        .overflow, .division_by_zero, .type_mismatch, .illegal_function_call, .out_of_memory, .subscript_out_of_range, .array_already_dimensioned, .out_of_data, .restricted_memory, .bad_file_number, .file_not_found, .bad_file_mode, .file_already_open, .input_past_end, .bad_file_name, .permission_denied, .path_file_access => true,
        .stack_overflow, .stack_underflow, .call_depth_exceeded, .gosub_without_return, .invalid_instruction, .host_failure, .resume_without_error => false,
    };
}

fn defaultMath(_: ?*anyopaque, operation: MathOperation, first: f64, second: f64) HostMathError!f64 {
    const result = switch (operation) {
        .atn => std.math.atan(first),
        .cos => @cos(first),
        .sin => @sin(first),
        .power => std.math.pow(f64, first, second),
    };
    if (!std.math.isFinite(result)) return error.MathFault;
    return result;
}

fn acceptScreenMode(_: ?*anyopaque, _: i32) ScreenModeError!void {}

fn rejectDeferredStatement(_: ?*anyopaque, _: frontend.Keyword) DeferredStatementError!void {
    return error.Unsupported;
}

fn neverCancel(_: ?*anyopaque) bool {
    return false;
}

fn unavailableFileRead(_: ?*anyopaque, _: []const u8, _: u32, _: []u8) FileReadResult {
    return .{ .failure = .unavailable };
}

fn unavailableFileWrite(_: ?*anyopaque, _: []const u8, _: []const u8, _: bool) FileWriteResult {
    return .{ .failure = .unavailable };
}

fn allocateGlobals(allocator: std.mem.Allocator, program: *const bytecode.Program) InitError![]Cell {
    const globals = try allocator.alloc(Cell, program.globals.len);
    var initialized: usize = 0;
    errdefer {
        for (globals[0..initialized]) |*cell| cell.deinit(allocator);
        allocator.free(globals);
    }
    for (program.globals, 0..) |variable, index| {
        globals[index] = allocateVariable(allocator, program, variable) catch return error.OutOfMemory;
        initialized += 1;
    }
    return globals;
}

fn deinitGlobals(allocator: std.mem.Allocator, globals: []Cell) void {
    for (globals) |*cell| cell.deinit(allocator);
    allocator.free(globals);
}

fn allocateVariable(
    allocator: std.mem.Allocator,
    program: *const bytecode.Program,
    variable: bytecode.Variable,
) ExecutionError!Cell {
    if (variable.isArray()) {
        const dimensions = try allocator.alloc(Dimension, 0);
        errdefer allocator.free(dimensions);
        const storage = try allocateEmptyArrayStorage(allocator, variable.value_type, variable.record_type);
        return .{ .owned = .{ .array = .{
            .value_type = variable.value_type,
            .record_type = variable.record_type,
            .expected_dimensions = variable.dimensions,
            .is_dynamic = variable.is_dynamic,
            .dimensions = dimensions,
            .storage = storage,
        } } };
    }
    return allocateElement(allocator, program, variable.value_type, variable.record_type);
}

fn allocateEmptyArrayStorage(
    allocator: std.mem.Allocator,
    value_type: bytecode.ValueType,
    record_type: u32,
) std.mem.Allocator.Error!ArrayStorage {
    if (record_type != bytecode.invalid_index) return .{ .cells = try allocator.alloc(Cell, 0) };
    return switch (value_type) {
        .integer => .{ .integer = try allocator.alloc(i16, 0) },
        .long => .{ .long = try allocator.alloc(i32, 0) },
        .single => .{ .single = try allocator.alloc(f32, 0) },
        .double => .{ .double = try allocator.alloc(f64, 0) },
        .string => .{ .cells = try allocator.alloc(Cell, 0) },
    };
}

fn arrayLogicalPayloadBytes(
    program: *const bytecode.Program,
    value_type: bytecode.ValueType,
    record_type: u32,
    element_count: usize,
) ExecutionError!usize {
    const bytes_per_element: usize = if (record_type == bytecode.invalid_index)
        switch (value_type) {
            .integer => @sizeOf(i16),
            .long => @sizeOf(i32),
            .single => @sizeOf(f32),
            .double => @sizeOf(f64),
            .string => @sizeOf(Cell),
        }
    else record: {
        if (record_type >= program.record_types.len) return error.InvalidInstruction;
        const field_bytes = std.math.mul(usize, program.record_types[record_type].fields.len, @sizeOf(Cell)) catch return error.OutOfMemory;
        break :record std.math.add(usize, @sizeOf(Cell), field_bytes) catch return error.OutOfMemory;
    };
    return std.math.mul(usize, element_count, bytes_per_element) catch return error.OutOfMemory;
}

fn resizeCompactArrayStorage(
    allocator: std.mem.Allocator,
    storage: *ArrayStorage,
    new_len: usize,
    value_type: bytecode.ValueType,
) ExecutionError!void {
    switch (storage.*) {
        .integer => |items| {
            if (value_type != .integer) return error.InvalidInstruction;
            const replacement = try allocator.realloc(items, new_len);
            @memset(replacement, 0);
            storage.* = .{ .integer = replacement };
        },
        .long => |items| {
            if (value_type != .long) return error.InvalidInstruction;
            const replacement = try allocator.realloc(items, new_len);
            @memset(replacement, 0);
            storage.* = .{ .long = replacement };
        },
        .single => |items| {
            if (value_type != .single) return error.InvalidInstruction;
            const replacement = try allocator.realloc(items, new_len);
            @memset(replacement, 0);
            storage.* = .{ .single = replacement };
        },
        .double => |items| {
            if (value_type != .double) return error.InvalidInstruction;
            const replacement = try allocator.realloc(items, new_len);
            @memset(replacement, 0);
            storage.* = .{ .double = replacement };
        },
        .cells => return error.InvalidInstruction,
    }
}

fn allocateElement(
    allocator: std.mem.Allocator,
    program: *const bytecode.Program,
    value_type: bytecode.ValueType,
    record_type: u32,
) ExecutionError!Cell {
    if (record_type == bytecode.invalid_index) {
        return .{ .owned = .{ .scalar = try values.defaultValue(allocator, value_type) } };
    }
    if (record_type >= program.record_types.len) return error.InvalidInstruction;
    const definition = program.record_types[record_type];
    const fields = try allocator.alloc(Cell, definition.fields.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (definition.fields, 0..) |field, index| {
        fields[index] = .{ .owned = .{ .scalar = try values.defaultValue(allocator, field.value_type) } };
        initialized += 1;
    }
    return .{ .owned = .{ .record = .{ .record_type = record_type, .fields = fields } } };
}

fn resolveCell(original: *Cell) ?*Cell {
    var cell = original;
    var depth: usize = 0;
    while (depth <= maximum_call_depth) : (depth += 1) {
        switch (cell.*) {
            .owned => return cell,
            .alias => |target| switch (target) {
                .cell => |next| cell = next,
                else => return null,
            },
        }
    }
    return null;
}

fn resolveCellConst(original: *const Cell) ?*const Cell {
    var cell = original;
    var depth: usize = 0;
    while (depth <= maximum_call_depth) : (depth += 1) {
        switch (cell.*) {
            .owned => return cell,
            .alias => |target| switch (target) {
                .cell => |next| cell = next,
                else => return null,
            },
        }
    }
    return null;
}

fn scalarAt(cell: *const Cell) ExecutionError!*const values.Value {
    const resolved = resolveCellConst(cell) orelse return error.InvalidInstruction;
    return switch (resolved.owned) {
        .scalar => |*scalar| scalar,
        else => error.TypeMismatch,
    };
}

fn scalarAtMutable(cell: *Cell) ExecutionError!*values.Value {
    const resolved = resolveCell(cell) orelse return error.InvalidInstruction;
    return switch (resolved.owned) {
        .scalar => |*scalar| scalar,
        else => error.TypeMismatch,
    };
}

fn arrayElement(array: *ArrayValue, indices: []const i32) ?Reference {
    if (indices.len != array.dimensions.len) return null;
    var offset: usize = 0;
    for (array.dimensions, indices) |dimension, index| {
        if (index < dimension.lower or index > dimension.upper) return null;
        offset += @as(usize, @intCast(index - dimension.lower)) * dimension.stride;
    }
    return arrayReferenceAt(array, offset);
}

fn arrayElementConst(array: *const ArrayValue, indices: []const i32) ?Reference {
    if (indices.len != array.dimensions.len) return null;
    var offset: usize = 0;
    for (array.dimensions, indices) |dimension, index| {
        if (index < dimension.lower or index > dimension.upper) return null;
        offset += @as(usize, @intCast(index - dimension.lower)) * dimension.stride;
    }
    return arrayReferenceAtConst(array, offset);
}

fn arrayReferenceAt(array: *ArrayValue, offset: usize) ?Reference {
    return switch (array.storage) {
        .integer => |items| if (offset < items.len) .{ .integer = &items[offset] } else null,
        .long => |items| if (offset < items.len) .{ .long = &items[offset] } else null,
        .single => |items| if (offset < items.len) .{ .single = &items[offset] } else null,
        .double => |items| if (offset < items.len) .{ .double = &items[offset] } else null,
        .cells => |items| if (offset < items.len) .{ .cell = &items[offset] } else null,
    };
}

fn arrayReferenceAtConst(array: *const ArrayValue, offset: usize) ?Reference {
    return switch (array.storage) {
        .integer => |items| if (offset < items.len) .{ .integer = &items[offset] } else null,
        .long => |items| if (offset < items.len) .{ .long = &items[offset] } else null,
        .single => |items| if (offset < items.len) .{ .single = &items[offset] } else null,
        .double => |items| if (offset < items.len) .{ .double = &items[offset] } else null,
        .cells => |items| if (offset < items.len) .{ .cell = &items[offset] } else null,
    };
}

fn dataValue(
    allocator: std.mem.Allocator,
    item: bytecode.DataItem,
    source: []const u8,
    target: bytecode.ValueType,
) ExecutionError!values.Value {
    if (item.constant == .string) {
        if (target != .string) return error.TypeMismatch;
        const token = item.constant.string.bytes(source);
        const bytes = if (item.string_is_quoted and token.len >= 2) token[1 .. token.len - 1] else token;
        return .{ .string = try allocator.dupe(u8, bytes) };
    }
    var raw = try values.fromConstant(allocator, item.constant, source);
    defer raw.deinit(allocator);
    if (target != .string) return values.convert(allocator, raw, target);
    const text = switch (raw) {
        .integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .long => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .single => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .double => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .string => unreachable,
    };
    return .{ .string = text };
}
