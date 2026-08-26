const std = @import("std");
const audio = @import("audio.zig");
const bytecode = @import("bytecode.zig");
const frontend = @import("frontend.zig");
const graphics_screen = @import("graphics_screen.zig");
const text_screen = @import("text_screen.zig");
const values = @import("value.zig");

pub const contract_version = "2.5.0";
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
pub const sequential_file_transfer_bytes: usize = 64 * 1024;
pub const file_poll_interval_ns: u64 = std.time.ns_per_ms;
pub const maximum_file_number: usize = 255;
pub const random_mask: u32 = 0x00FF_FFFF;
pub const default_random_seed: u32 = 0x0005_0000;
pub const numeric_format_buffer_bytes: usize = 128;
pub const maximum_trace_entries: usize = 256;
pub const maximum_guest_path_bytes: usize = 1023;
pub const maximum_environment_name_bytes: usize = 32;
pub const maximum_environment_value_bytes: usize = 512;
pub const maximum_environment_block_bytes: usize = 2048;
pub const maximum_environment_entries: usize = 64;

pub const MathOperation = enum(u8) {
    atn,
    cos,
    exp,
    log,
    sin,
    sqr,
    tan,
    power,
};

pub const HostMathError = error{MathFault};
pub const ScreenModeError = error{ModeUnavailable};
pub const FileHostError = enum(u8) {
    unavailable,
    not_found,
    path_not_found,
    file_exists,
    disk_full,
    too_many_files,
    lock_violation,
    permission_denied,
    path_error,
    io_error,
    too_large,
};

pub const FileReadResult = union(enum) {
    bytes: u32,
    end,
    pending,
    failure: FileHostError,
};

pub const FileWriteResult = union(enum) {
    bytes: u32,
    pending,
    failure: FileHostError,
};

pub const FileInfo = struct {
    size: u32,
};

pub const FileInfoResult = union(enum) {
    info: FileInfo,
    missing,
    pending,
    failure: FileHostError,
};

pub const FileLockResult = union(enum) {
    success,
    pending,
    failure: FileHostError,
};

pub const PathKind = enum(u8) { file, directory };

pub const PathInfoResult = union(enum) {
    info: PathKind,
    missing,
    failure: FileHostError,
};

pub const PathOperationResult = union(enum) {
    success,
    missing,
    failure: FileHostError,
};

pub const DirectoryEntry = struct {
    kind: PathKind,
    path_length: u16,
};

pub const DirectoryReadResult = union(enum) {
    entry: DirectoryEntry,
    end,
    failure: FileHostError,
};

pub const WallClock = struct {
    valid: bool = false,
    year: u16 = 1980,
    month: u8 = 1,
    day: u8 = 1,
    weekday: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,

    pub fn secondsSinceMidnight(self: WallClock) u32 {
        return @as(u32, self.hour) * 3600 + @as(u32, self.minute) * 60 + self.second;
    }
};

pub const WallClockResult = union(enum) {
    value: WallClock,
    failure,
};

pub const EnvironmentInput = struct {
    name: []const u8,
    value: []const u8,
};

pub const ShellResult = union(enum) {
    pending,
    exited: i32,
    failure: FileHostError,
};

pub const HostServices = struct {
    context: ?*anyopaque = null,
    math: *const fn (?*anyopaque, MathOperation, f64, f64) HostMathError!f64 = defaultMath,
    screen_mode: *const fn (?*anyopaque, i32) ScreenModeError!void = acceptScreenMode,
    should_cancel: *const fn (?*anyopaque) bool = neverCancel,
    file_context: ?*anyopaque = null,
    file_read: *const fn (?*anyopaque, []const u8, u32, []u8) FileReadResult = unavailableFileRead,
    file_write: *const fn (?*anyopaque, []const u8, []const u8, bool) FileWriteResult = unavailableFileWrite,
    file_write_at: *const fn (?*anyopaque, []const u8, u32, []const u8, bool) FileWriteResult = unavailableFileWriteAt,
    file_info: *const fn (?*anyopaque, []const u8) FileInfoResult = unavailableFileInfo,
    file_lock: *const fn (?*anyopaque, []const u8, u32, u32, bool) FileLockResult = unavailableFileLock,
    file_quiesce: *const fn (?*anyopaque) void = ignoreFileQuiesce,
    platform_context: ?*anyopaque = null,
    path_info: *const fn (?*anyopaque, []const u8) PathInfoResult = unavailablePathInfo,
    path_delete: *const fn (?*anyopaque, []const u8) PathOperationResult = unavailablePathOperation,
    path_rename: *const fn (?*anyopaque, []const u8, []const u8) PathOperationResult = unavailablePathRename,
    directory_create: *const fn (?*anyopaque, []const u8) PathOperationResult = unavailablePathOperation,
    directory_delete: *const fn (?*anyopaque, []const u8) PathOperationResult = unavailablePathOperation,
    directory_read: *const fn (?*anyopaque, []const u8, u32, []u8) DirectoryReadResult = unavailableDirectoryRead,
    wall_clock: *const fn (?*anyopaque) WallClockResult = unavailableWallClock,
    wall_clock_set: *const fn (?*anyopaque, WallClock) bool = rejectWallClock,
    environment_set: *const fn (?*anyopaque, []const u8, []const u8) bool = rejectEnvironment,
    shell: *const fn (?*anyopaque, []const u8) ShellResult = unavailableShell,
    platform_quiesce: *const fn (?*anyopaque) void = ignoreFileQuiesce,
    guest_directory: []const u8 = "",
    command_line: []const u8 = "",
    initial_environment: []const EnvironmentInput = &.{},
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
    raised_error,
    no_resume,
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
    field_overflow,
    field_active,
    file_exists,
    bad_record_length,
    disk_full,
    bad_record_number,
    too_many_files,
    permission_denied,
    path_not_found,
    path_file_access,
};

pub const RuntimeDiagnostic = struct {
    code: RuntimeCode,
    file_name: []const u8,
    span: frontend.Span,
    instruction: u32,
    error_number: u8 = 0,

    pub fn qbasicErrorNumber(self: RuntimeDiagnostic) i32 {
        if (self.error_number != 0) return self.error_number;
        return switch (self.code) {
            .illegal_function_call, .restricted_memory => 5,
            .overflow => 6,
            .out_of_memory => 7,
            .division_by_zero => 11,
            .type_mismatch => 13,
            .subscript_out_of_range => 9,
            .array_already_dimensioned => 10,
            .out_of_data => 4,
            .gosub_without_return => 3,
            .no_resume => 19,
            .resume_without_error => 20,
            .bad_file_number => 52,
            .file_not_found => 53,
            .bad_file_mode => 54,
            .file_already_open => 55,
            .input_past_end => 62,
            .bad_file_name => 64,
            .field_overflow => 50,
            .field_active => 56,
            .file_exists => 58,
            .bad_record_length => 59,
            .disk_full => 61,
            .bad_record_number => 63,
            .too_many_files => 67,
            .permission_denied => 70,
            .path_not_found => 76,
            .path_file_access => 75,
            .raised_error => 5,
            .stack_overflow, .stack_underflow, .call_depth_exceeded, .invalid_instruction, .host_failure => 70,
        };
    }
};

pub const TraceEntry = struct {
    instruction: u32 = bytecode.invalid_index,
    basic_line: u16 = 0,
};

pub const Status = enum(u8) {
    ready,
    yielded,
    waiting,
    halted,
    cancelled,
    runtime_error,
    transition,
};

pub const TransitionKind = enum(u8) { run, chain };

pub const ProgramTransition = struct {
    kind: TransitionKind,
    path: []u8,
    preserve_all: bool = false,
    delete_enabled: bool = false,
    delete_first: u16 = 0,
    delete_last: u16 = 0,

    pub fn deinit(self: *ProgramTransition, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
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

pub const InputStamp = struct {
    sequence: u64 = 0,
    tick: u64 = 0,
};

pub const InputDropReason = enum {
    none,
    unfocused,
    invalid_codepoint,
    unsupported_key,
    unsupported_event,
    queue_full,
    out_of_memory,
};

pub const InputResult = struct {
    accepted: bool,
    accepted_bytes: u8 = 0,
    reason: InputDropReason = .none,
};

pub const InputStats = struct {
    logical_events: u64 = 0,
    accepted_bytes: u64 = 0,
    control_events: u64 = 0,
    dropped_events: u64 = 0,
    unfocused_drops: u64 = 0,
    invalid_codepoint_drops: u64 = 0,
    unsupported_key_drops: u64 = 0,
    unsupported_event_drops: u64 = 0,
    queue_full_drops: u64 = 0,
    out_of_memory_drops: u64 = 0,
    consumed_bytes: u64 = 0,
    maximum_queue_depth: u64 = 0,
    last_event_sequence: u64 = 0,
    last_event_tick: u64 = 0,
    last_accepted_sequence: u64 = 0,
    last_accepted_tick: u64 = 0,
    last_dropped_sequence: u64 = 0,
    last_dropped_tick: u64 = 0,
    last_drop_reason: InputDropReason = .none,
    last_consumed_sequence: u64 = 0,
    last_consumed_tick: u64 = 0,
};

const QueuedInput = struct {
    value: u8,
    sequence: u64,
    tick: u64,
};

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
    file_input_refills: u64 = 0,
    file_output_flushes: u64 = 0,
    file_io_waits: u64 = 0,
    file_input_compaction_bytes: u64 = 0,
    file_output_compaction_bytes: u64 = 0,
    maximum_file_input_buffer_bytes: u64 = 0,
    maximum_file_output_buffer_bytes: u64 = 0,
    raster: graphics_screen.PerformanceStats = .{},
    input: InputStats = .{},

    pub fn group(self: *const PerformanceStats, operation_group: OperationGroup) u64 {
        return self.groups[@intFromEnum(operation_group)];
    }
};

pub const InitError = error{
    OutOfMemory,
    InvalidProgram,
};

pub const ProgramTransferError = error{
    OutOfMemory,
    IncompatibleCommon,
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
    RaisedError,
    NoResume,
    RestrictedMemory,
    Rethrow,
    WouldBlock,
    BadFileNumber,
    FileNotFound,
    BadFileMode,
    FileAlreadyOpen,
    InputPastEnd,
    BadFileName,
    FieldOverflow,
    FieldActive,
    FileExists,
    BadRecordLength,
    DiskFull,
    BadRecordNumber,
    TooManyFiles,
    PermissionDenied,
    PathNotFound,
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
    fixed_string_length: u16,
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

const FixedString = struct {
    value: values.Value,
    length: u16,

    fn deinit(self: *FixedString, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

const FieldString = struct {
    value: values.Value,
    file_generation: u64,
};

const OwnedValue = union(enum) {
    scalar: values.Value,
    fixed_string: FixedString,
    field_string: FieldString,
    array: ArrayValue,
    record: RecordValue,

    fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scalar => |*scalar| scalar.deinit(allocator),
            .fixed_string => |*string| string.deinit(allocator),
            .field_string => {},
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
                    .fixed_string => |string| string.value,
                    .field_string => |string| string.value,
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

    fn fixedStringLength(self: Reference) ExecutionError!?u16 {
        return switch (self) {
            .cell => |cell| switch (cell.*) {
                .owned => |*owned| switch (owned.*) {
                    .fixed_string => |string| string.length,
                    .field_string => |string| switch (string.value) {
                        .string => |bytes| @intCast(bytes.len),
                        else => error.InvalidInstruction,
                    },
                    .scalar => null,
                    else => error.TypeMismatch,
                },
                .alias => error.InvalidInstruction,
            },
            else => null,
        };
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
                    .fixed_string => |*destination| {
                        const source = switch (incoming) {
                            .string => |bytes| bytes,
                            else => return error.TypeMismatch,
                        };
                        if (source.len == destination.length) {
                            destination.value.deinit(allocator);
                            destination.value = incoming;
                            return;
                        }
                        const replacement = try allocator.alloc(u8, destination.length);
                        @memset(replacement, ' ');
                        @memcpy(replacement[0..@min(replacement.len, source.len)], source[0..@min(replacement.len, source.len)]);
                        destination.value.deinit(allocator);
                        destination.value = .{ .string = replacement };
                        var consumed = incoming;
                        consumed.deinit(allocator);
                    },
                    .field_string => {
                        const source = switch (incoming) {
                            .string => |bytes| bytes,
                            else => return error.TypeMismatch,
                        };
                        const replacement = try allocator.dupe(u8, source);
                        var consumed = incoming;
                        consumed.deinit(allocator);
                        owned.* = .{ .scalar = .{ .string = replacement } };
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

const FileRange = struct {
    first: u32,
    last: u32,
};

const SequentialFile = struct {
    mode: bytecode.FileMode,
    access: bytecode.FileAccess = .default,
    open_lock: bytecode.FileLock = .default,
    path: []u8,
    record_length: u16 = 128,
    size: u32 = 0,
    next_position: u32 = 1,
    generation: u64 = 0,
    storage_ready: bool = false,
    create_pending: bool = false,
    open_lock_ready: bool = false,
    record_buffer: []u8 = &.{},
    locks: std.ArrayList(FileRange) = .empty,
    input: std.ArrayList(u8) = .empty,
    input_head: usize = 0,
    input_offset: usize = 0,
    input_eof: bool = false,
    output: std.ArrayList(u8) = .empty,
    output_head: usize = 0,
    output_total_bytes: usize = 0,
    print_column: usize = 0,

    fn deinit(self: *SequentialFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.input.deinit(allocator);
        self.output.deinit(allocator);
        if (self.record_buffer.len != 0) allocator.free(self.record_buffer);
        self.locks.deinit(allocator);
        self.* = undefined;
    }
};

const FileSlot = struct {
    number: u8,
    file: SequentialFile,
};

const PendingFileTransfer = struct {
    instruction: u32,
    file_number: u8,
    write: bool,
    offset: u32,
    buffer: []u8,
    transferred: usize = 0,
    stack_base: usize,
    flags: u32,
    position: u32,

    fn deinit(self: *PendingFileTransfer, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = undefined;
    }
};

const EnvironmentValue = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *EnvironmentValue, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const PendingDirectory = struct {
    instruction: u32,
    kill: bool,
    directory: []u8,
    pattern: []u8,
    index: u32 = 0,
    matches: u32 = 0,
    header_written: bool = false,

    fn deinit(self: *PendingDirectory, allocator: std.mem.Allocator) void {
        allocator.free(self.directory);
        allocator.free(self.pattern);
        self.* = undefined;
    }
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
    file_input_refills: u64 = 0,
    file_output_flushes: u64 = 0,
    file_io_waits: u64 = 0,
    file_input_compaction_bytes: u64 = 0,
    file_output_compaction_bytes: u64 = 0,
    maximum_file_input_buffer_bytes: u64 = 0,
    maximum_file_output_buffer_bytes: u64 = 0,
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
    keyboard: std.ArrayList(QueuedInput) = .empty,
    keyboard_head: usize = 0,
    keyboard_generation: u64 = 0,
    input_focused: bool = true,
    input_stats: InputStats = .{},
    input_line: std.ArrayList(u8) = .empty,
    numeric_scratch: std.ArrayList(u8) = .empty,
    format_scratch: std.ArrayList(u8) = .empty,
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
    audio_fence_frames: u64 = 0,
    random_state: u32 = default_random_seed,
    random_last: f32 = 0,
    open_files: std.ArrayList(FileSlot) = .empty,
    file_slot_indices: [maximum_file_number + 1]u8 = .{0} ** (maximum_file_number + 1),
    pending_open_file: ?SequentialFile = null,
    pending_open_number: u8 = 0,
    next_file_generation: u64 = 1,
    pending_file_transfer: ?PendingFileTransfer = null,
    initial_guest_directory: []u8 = &.{},
    drive_directories: [26]?[]u8 = .{null} ** 26,
    current_drive: u8 = 2,
    command_line: []u8 = &.{},
    initial_environment: std.ArrayList(EnvironmentValue) = .empty,
    environment: std.ArrayList(EnvironmentValue) = .empty,
    pending_directory: ?PendingDirectory = null,
    transition: ?ProgramTransition = null,
    active_print_file: ?u8 = null,
    print_using_cursor: usize = 0,
    write_item_count: usize = 0,
    statement_stack_base: usize = 0,
    current_statement_start: u32 = bytecode.invalid_index,
    current_statement_next: u32 = bytecode.invalid_index,
    raised_error_number: u8 = 0,
    stopped: bool = false,
    trace_enabled: bool = false,
    trace_entries: [maximum_trace_entries]TraceEntry = [_]TraceEntry{.{}} ** maximum_trace_entries,
    trace_head: usize = 0,
    trace_count: usize = 0,
    trace_dropped: u64 = 0,
    cancel_requested: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const bytecode.Program,
        host: HostServices,
    ) InitError!Vm {
        if (!program.ok() or program.instructions.len != program.instruction_metadata.len) return error.InvalidProgram;
        const globals = try allocateGlobals(allocator, program);
        const random_state = normalizeRandomSeed(host.initial_random_seed);
        var machine = Vm{
            .allocator = allocator,
            .program = program,
            .host = host,
            .globals = globals,
            .instruction_pointer = program.module_entry,
            .random_state = random_state,
            .random_last = randomValue(random_state),
            .audio_engine = audio.Engine.init(allocator),
        };
        errdefer machine.deinit();
        try machine.initializePlatformState();
        return machine;
    }

    pub fn deinit(self: *Vm) void {
        self.host.file_quiesce(self.fileHostContext());
        self.host.platform_quiesce(self.platformHostContext());
        self.discardPendingFileTransfer();
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
        self.format_scratch.deinit(self.allocator);
        self.audio_engine.deinit();
        self.discardFiles();
        self.open_files.deinit(self.allocator);
        self.discardPendingDirectory();
        if (self.transition) |*transition| transition.deinit(self.allocator);
        self.deinitPlatformState();
        self.graphics.deinit(self.allocator);
        deinitGlobals(self.allocator, self.globals);
        self.* = undefined;
    }

    pub fn requestCancel(self: *Vm) void {
        self.cancel_requested = true;
    }

    pub fn takeTransition(self: *Vm) ?ProgramTransition {
        const transition = self.transition orelse return null;
        self.transition = null;
        return transition;
    }

    pub fn isStopped(self: *const Vm) bool {
        return self.stopped;
    }

    pub fn continueStopped(self: *Vm) bool {
        if (!self.stopped) return false;
        self.stopped = false;
        if (self.status == .waiting) self.status = .ready;
        return true;
    }

    pub fn traceCount(self: *const Vm) usize {
        return self.trace_count;
    }

    pub fn traceDropped(self: *const Vm) u64 {
        return self.trace_dropped;
    }

    pub fn traceEntry(self: *const Vm, chronological_index: usize) ?TraceEntry {
        if (chronological_index >= self.trace_count) return null;
        const oldest = (self.trace_head + maximum_trace_entries - self.trace_count) % maximum_trace_entries;
        return self.trace_entries[(oldest + chronological_index) % maximum_trace_entries];
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

    pub fn unresolvedAudioFrames(self: *const Vm) u64 {
        return self.audio_engine.unresolvedFrames();
    }

    /// Applies source-frame progress at the AudioService acceptance boundary.
    /// `abandon_pending` is used only when the transport became unavailable or
    /// was explicitly muted. Hardware playback remains deliberately unknown.
    pub fn noteAudioProgress(
        self: *Vm,
        accepted_frames: u64,
        suppressed_frames: u64,
        discarded_frames: u64,
        abandon_pending: bool,
    ) bool {
        self.audio_engine.acceptTransportProgress(accepted_frames, suppressed_frames, discarded_frames);
        if (abandon_pending) self.audio_engine.abandonPending();
        const foreground_ready = self.pending_audio_instruction != bytecode.invalid_index and
            self.audio_engine.fenceResolved(self.audio_fence_frames);
        const terminal_drain_ready = self.status == .halted and self.audio_engine.unresolvedFrames() == 0;
        return foreground_ready or terminal_drain_ready;
    }

    pub fn setInputFocused(self: *Vm, focused: bool) void {
        self.input_focused = focused;
    }

    pub fn noteInputControl(self: *Vm, stamp: InputStamp) void {
        self.recordInputAttempt(stamp);
        self.input_stats.control_events +%= 1;
    }

    pub fn noteInputDrop(self: *Vm, stamp: InputStamp, reason: InputDropReason) InputResult {
        self.recordInputAttempt(stamp);
        return self.recordInputDrop(stamp, reason);
    }

    pub fn acceptTextCodepoint(self: *Vm, codepoint: u32, stamp: InputStamp) InputResult {
        self.recordInputAttempt(stamp);
        if (!self.input_focused) return self.recordInputDrop(stamp, .unfocused);
        if (codepoint < 0x20 or codepoint > 0xFF or codepoint == 0x7F) {
            return self.recordInputDrop(stamp, .invalid_codepoint);
        }
        return self.appendInput(@intCast(codepoint), stamp);
    }

    pub fn acceptKeyCode(self: *Vm, code: u32, stamp: InputStamp) InputResult {
        self.recordInputAttempt(stamp);
        if (!self.input_focused) return self.recordInputDrop(stamp, .unfocused);
        const byte: ?u8 = switch (code) {
            1, 3, 8, 9, 22, 24, 27 => @intCast(code),
            10, 13 => 13,
            else => null,
        };
        if (byte) |value| return self.appendInput(value, stamp);
        const scan: u8 = switch (code) {
            0x7F => 83,
            0x80 => 72,
            0x81 => 80,
            0x82 => 61,
            0x84 => 15,
            0x88 => 75,
            0x89 => 77,
            0x8A => 71,
            0x8B => 79,
            0x8D => 73,
            0x8E => 81,
            0x90 => 68,
            else => return self.recordInputDrop(stamp, .unsupported_key),
        };
        return self.appendExtendedInput(scan, stamp);
    }

    pub fn enqueueTextCodepoint(self: *Vm, codepoint: u32) std.mem.Allocator.Error!bool {
        return self.acceptTextCodepoint(codepoint, .{}).accepted;
    }

    pub fn enqueueKeyCode(self: *Vm, code: u32) std.mem.Allocator.Error!bool {
        return self.acceptKeyCode(code, .{}).accepted;
    }

    pub fn queuedInputBytes(self: *const Vm) usize {
        return self.keyboard.items.len - self.keyboard_head;
    }

    pub fn inputStats(self: *const Vm) InputStats {
        return self.input_stats;
    }

    fn appendInput(self: *Vm, byte: u8, stamp: InputStamp) InputResult {
        if (self.keyboard.items.len - self.keyboard_head >= maximum_keyboard_bytes) {
            return self.recordInputDrop(stamp, .queue_full);
        }
        self.keyboard.append(self.allocator, .{
            .value = byte,
            .sequence = stamp.sequence,
            .tick = stamp.tick,
        }) catch return self.recordInputDrop(stamp, .out_of_memory);
        self.keyboard_generation +%= 1;
        self.input_stats.accepted_bytes +%= 1;
        self.input_stats.last_accepted_sequence = stamp.sequence;
        self.input_stats.last_accepted_tick = stamp.tick;
        self.input_stats.maximum_queue_depth = @max(
            self.input_stats.maximum_queue_depth,
            @as(u64, @intCast(self.keyboard.items.len - self.keyboard_head)),
        );
        return .{ .accepted = true, .accepted_bytes = 1 };
    }

    fn appendExtendedInput(self: *Vm, scan: u8, stamp: InputStamp) InputResult {
        if (self.keyboard.items.len - self.keyboard_head > maximum_keyboard_bytes - 2) {
            return self.recordInputDrop(stamp, .queue_full);
        }
        self.keyboard.ensureUnusedCapacity(self.allocator, 2) catch return self.recordInputDrop(stamp, .out_of_memory);
        self.keyboard.appendAssumeCapacity(.{ .value = 0, .sequence = stamp.sequence, .tick = stamp.tick });
        self.keyboard.appendAssumeCapacity(.{ .value = scan, .sequence = stamp.sequence, .tick = stamp.tick });
        self.keyboard_generation +%= 1;
        self.input_stats.accepted_bytes +%= 2;
        self.input_stats.last_accepted_sequence = stamp.sequence;
        self.input_stats.last_accepted_tick = stamp.tick;
        self.input_stats.maximum_queue_depth = @max(
            self.input_stats.maximum_queue_depth,
            @as(u64, @intCast(self.keyboard.items.len - self.keyboard_head)),
        );
        return .{ .accepted = true, .accepted_bytes = 2 };
    }

    fn recordInputAttempt(self: *Vm, stamp: InputStamp) void {
        self.input_stats.logical_events +%= 1;
        self.input_stats.last_event_sequence = stamp.sequence;
        self.input_stats.last_event_tick = stamp.tick;
    }

    fn recordInputDrop(self: *Vm, stamp: InputStamp, reason: InputDropReason) InputResult {
        self.input_stats.dropped_events +%= 1;
        self.input_stats.last_dropped_sequence = stamp.sequence;
        self.input_stats.last_dropped_tick = stamp.tick;
        self.input_stats.last_drop_reason = reason;
        switch (reason) {
            .none => {},
            .unfocused => self.input_stats.unfocused_drops +%= 1,
            .invalid_codepoint => self.input_stats.invalid_codepoint_drops +%= 1,
            .unsupported_key => self.input_stats.unsupported_key_drops +%= 1,
            .unsupported_event => self.input_stats.unsupported_event_drops +%= 1,
            .queue_full => self.input_stats.queue_full_drops +%= 1,
            .out_of_memory => self.input_stats.out_of_memory_drops +%= 1,
        }
        return .{ .accepted = false, .reason = reason };
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

    pub fn takeGraphicsDamage(self: *Vm) graphics_screen.Damage {
        self.syncTextToGraphics();
        return self.graphics.takeDamage();
    }

    pub fn graphicsPoint(self: *const Vm, x: i32, y: i32) ?i32 {
        if (self.screen_mode == 0) return null;
        return self.graphics.point(.{ .x = x, .y = y }) catch null;
    }

    pub fn reset(self: *Vm) InitError!void {
        self.host.file_quiesce(self.fileHostContext());
        self.host.platform_quiesce(self.platformHostContext());
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
        self.file_input_refills = 0;
        self.file_output_flushes = 0;
        self.file_io_waits = 0;
        self.file_input_compaction_bytes = 0;
        self.file_output_compaction_bytes = 0;
        self.maximum_file_input_buffer_bytes = 0;
        self.maximum_file_output_buffer_bytes = 0;
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
        self.input_stats = .{};
        self.input_line.clearRetainingCapacity();
        self.numeric_scratch.clearRetainingCapacity();
        self.format_scratch.clearRetainingCapacity();
        self.pending_input_instruction = bytecode.invalid_index;
        self.guest_now_ns = 0;
        self.wait_wake_ns = 0;
        self.next_timer_poll_ns = 0;
        self.pending_sleep_instruction = bytecode.invalid_index;
        self.sleep_deadline_ns = 0;
        self.sleep_input_generation = 0;
        self.audio_engine.reset();
        self.pending_audio_instruction = bytecode.invalid_index;
        self.audio_fence_frames = 0;
        self.random_state = normalizeRandomSeed(self.host.initial_random_seed);
        self.random_last = randomValue(self.random_state);
        self.discardPendingFileTransfer();
        self.discardFiles();
        self.discardPendingDirectory();
        if (self.transition) |*transition| transition.deinit(self.allocator);
        self.transition = null;
        try self.resetPlatformState();
        self.active_print_file = null;
        self.print_using_cursor = 0;
        self.write_item_count = 0;
        self.statement_stack_base = 0;
        self.current_statement_start = bytecode.invalid_index;
        self.current_statement_next = bytecode.invalid_index;
        self.raised_error_number = 0;
        self.stopped = false;
        self.trace_enabled = false;
        self.trace_entries = [_]TraceEntry{.{}} ** maximum_trace_entries;
        self.trace_head = 0;
        self.trace_count = 0;
        self.trace_dropped = 0;
        self.cancel_requested = false;
    }

    pub fn runSlice(self: *Vm, instruction_budget: u32) SliceResult {
        if (self.status == .halted or self.status == .cancelled or self.status == .runtime_error or self.status == .transition) {
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
        if (self.stopped) {
            self.status = .waiting;
            return .{ .status = .waiting, .instructions = 0 };
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
                const diagnostic = if (fault == error.Rethrow and self.active_error != null)
                    self.active_error.?.diagnostic
                else
                    self.makeDiagnosticNumber(
                        runtimeCode(fault),
                        instruction_index,
                        if (fault == error.RaisedError) self.raised_error_number else 0,
                    );
                self.raised_error_number = 0;
                if (fault != error.Rethrow and self.trapError(diagnostic, instruction_index)) {
                    const group = self.recordOperation(instruction.op);
                    if (group == .text) {
                        self.host_display_requested = true;
                        self.syncTextToGraphics();
                    }
                    executed += 1;
                    self.total_instructions += 1;
                    continue;
                }
                self.recordDiagnostic(diagnostic);
                return .{ .status = self.status, .instructions = executed };
            };
            const group = self.recordOperation(instruction.op);
            if (group == .text) {
                self.host_display_requested = true;
                self.syncTextToGraphics();
            }
            executed += 1;
            self.total_instructions += 1;
            if (self.status == .halted or self.status == .transition) return .{ .status = self.status, .instructions = executed };
            if (self.stopped) {
                self.status = .waiting;
                return .{ .status = .waiting, .instructions = executed };
            }
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
            .file_input_refills = self.file_input_refills,
            .file_output_flushes = self.file_output_flushes,
            .file_io_waits = self.file_io_waits,
            .file_input_compaction_bytes = self.file_input_compaction_bytes,
            .file_output_compaction_bytes = self.file_output_compaction_bytes,
            .maximum_file_input_buffer_bytes = self.maximum_file_input_buffer_bytes,
            .maximum_file_output_buffer_bytes = self.maximum_file_output_buffer_bytes,
            .raster = self.graphics.performanceStats(),
            .input = self.input_stats,
        };
    }

    pub fn global(self: *const Vm, name: []const u8) ?*const values.Value {
        for (self.program.globals, 0..) |variable, index| {
            if (variable.hidden) continue;
            if (std.ascii.eqlIgnoreCase(variable.name.bytes(self.program.source), name)) {
                const cell = resolveCellConst(&self.globals[index]) orelse return null;
                return switch (cell.owned) {
                    .scalar => |*scalar| scalar,
                    .fixed_string => |*string| &string.value,
                    .field_string => |*string| &string.value,
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

    pub fn globalArrayBound(self: *const Vm, name: []const u8, dimension: usize, upper: bool) ?i32 {
        const root = self.globalCell(name) orelse return null;
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return null,
        };
        if (dimension == 0 or dimension > array.dimensions.len) return null;
        const selected = array.dimensions[dimension - 1];
        return if (upper) selected.upper else selected.lower;
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
                    .fixed_string => |*string| &string.value,
                    .field_string => |*string| &string.value,
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
        if (self.trace_enabled) self.recordTrace(
            .{
                .instruction = self.current_statement_start,
                .basic_line = metadata.basic_line,
            },
            if (metadata.basic_line != 0) metadata.basic_line else metadata.span.line,
        );
        self.statement_stack_base = self.stack.items.len;
        self.active_print_file = null;
        self.print_using_cursor = 0;
        self.write_item_count = 0;
    }

    fn recordTrace(self: *Vm, entry: TraceEntry, display_line: u32) void {
        self.trace_entries[self.trace_head] = entry;
        self.trace_head = (self.trace_head + 1) % maximum_trace_entries;
        if (self.trace_count < maximum_trace_entries) {
            self.trace_count += 1;
        } else {
            self.trace_dropped +%= 1;
        }
        var storage: [16]u8 = undefined;
        const marker = std.fmt.bufPrint(&storage, "[{d}]", .{display_line}) catch return;
        self.text.write(marker);
        self.host_display_requested = true;
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
            .erase_array,
            .array_bound,
            .clear_state,
            .justify_string,
            .copy_record,
            .lset_record,
            .swap_values,
            .read_data,
            .restore_data,
            .mid_string_assign,
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
            .logical_eqv,
            .logical_imp,
            => .arithmetic,
            .set_error_handler,
            .raise_error,
            .resume_error,
            .resume_next,
            .resume_label,
            .call,
            .return_procedure,
            .jump,
            .jump_if_false,
            .jump_if_true,
            .gosub,
            .on_goto,
            .on_gosub,
            .return_gosub,
            .trace_on,
            .trace_off,
            .stop,
            .program_run,
            .program_chain,
            .system_exit,
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
            .print_using_begin,
            .print_using_value,
            .print_using_end,
            .print_spc,
            .print_tab,
            .print_comma,
            .print_question,
            .print_newline,
            .write_begin,
            .write_value,
            .print_end,
            .input_console,
            => .text,
            .set_segment,
            .reset_segment,
            .peek,
            .poke,
            .print_begin_file,
            .input_file,
            .input_string,
            .randomize,
            .sleep,
            .file_open,
            .file_close,
            .file_get,
            .file_put,
            .file_field,
            .file_seek,
            .file_lock,
            .file_unlock,
            .file_reset,
            .path_chdir,
            .path_mkdir,
            .path_rmdir,
            .path_files,
            .path_kill,
            .path_rename,
            .environment_set,
            .wall_date_set,
            .wall_time_set,
            .process_shell,
            .audio_beep,
            .audio_play,
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
            .array_default_lower => try self.arrayDefaultLower(instruction.a),
            .select_array_element => try self.selectArrayElement(instruction.a),
            .select_record_field => try self.selectRecordField(instruction.a),
            .load_reference => try self.load(try self.popReference()),
            .store_reference => try self.storeReference(bytecode.decodeValueType(instruction.a)),
            .dimension => try self.dimensionArray(instruction.a, false, instruction.b != 0),
            .redimension => try self.dimensionArray(instruction.a, true, instruction.b != 0),
            .erase_array => try self.eraseArray(),
            .array_bound => try self.arrayBound(instruction.a != 0),
            .clear_state => try self.clearState(instruction.a != 0),
            .justify_string => try self.justifyString(instruction.a != 0),
            .copy_record => try self.copyRecord(),
            .lset_record => try self.lsetRecord(),
            .swap_values => try self.swapValues(),
            .read_data => try self.readData(bytecode.decodeValueType(instruction.a)),
            .restore_data => self.data_pointer = instruction.a,
            .set_error_handler => try self.setErrorHandler(instruction.a),
            .raise_error => try self.raiseError(),
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
            .mid_string_assign => try self.midStringAssign(instruction.a != 0),
            .print_begin_screen => self.active_print_file = null,
            .print_begin_file => try self.printBeginFile(),
            .print_value => try self.printValue(),
            .print_using_begin => try self.printUsingBegin(),
            .print_using_value => try self.printUsingValue(),
            .print_using_end => try self.printUsingEnd(),
            .print_spc => try self.printSpc(),
            .print_tab => try self.printTab(),
            .print_comma => try self.printComma(),
            .print_question => try self.printBytes("? "),
            .print_newline => try self.printNewline(),
            .write_begin => self.write_item_count = 0,
            .write_value => try self.writeValue(),
            .print_end => self.active_print_file = null,
            .input_console => try self.consoleInput(instruction_index, instruction.a, instruction.b),
            .input_file => try self.fileInput(instruction.a, instruction.b != 0),
            .input_string => try self.inputString(instruction_index, instruction.a, instruction.b != 0),
            .randomize => try self.randomize(instruction_index, instruction.a),
            .sleep => try self.sleep(instruction_index, instruction.a),
            .file_open => try self.openFile(instruction_index, @enumFromInt(@as(u8, @intCast(instruction.a))), instruction.b),
            .file_close => try self.closeFiles(instruction.a),
            .file_get => try self.fileTransfer(instruction_index, false, instruction.a),
            .file_put => try self.fileTransfer(instruction_index, true, instruction.a),
            .file_field => try self.bindFileFields(instruction.a),
            .file_seek => try self.seekFile(),
            .file_lock => try self.lockFile(false, instruction.a),
            .file_unlock => try self.lockFile(true, instruction.a),
            .file_reset => try self.resetFiles(),
            .path_chdir => try self.changeDirectory(),
            .path_mkdir => try self.makeDirectory(),
            .path_rmdir => try self.removeDirectory(),
            .path_files => try self.processDirectory(instruction_index, false),
            .path_kill => try self.processDirectory(instruction_index, true),
            .path_rename => try self.renamePath(),
            .environment_set => try self.setEnvironment(),
            .wall_date_set => try self.setWallDate(),
            .wall_time_set => try self.setWallTime(),
            .program_run => try self.runProgram(instruction.a, instruction.b),
            .program_chain => try self.chainProgram(instruction.a, instruction.b),
            .process_shell => try self.shellCommand(),
            .system_exit => try self.systemExit(),
            .audio_beep => try self.audioBeep(instruction_index),
            .audio_play => try self.audioPlay(instruction_index),
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
            .logical_eqv => try self.binary(.logical_eqv, .long),
            .logical_imp => try self.binary(.logical_imp, .long),
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
            .on_goto => try self.onBranch(instruction.a, instruction.b, false),
            .on_gosub => try self.onBranch(instruction.a, instruction.b, true),
            .return_gosub => try self.returnGosub(instruction.a),
            .trace_on => self.trace_enabled = true,
            .trace_off => self.trace_enabled = false,
            .stop => self.stopped = true,
            .pop => {
                var item = self.stack.pop() orelse return error.StackUnderflow;
                item.deinit(self.allocator);
            },
            .halt => {
                if (self.active_error != null and self.active_error.?.handler_frame == module_frame) return error.NoResume;
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

    fn midStringAssign(self: *Vm, has_length: bool) ExecutionError!void {
        var replacement = try self.popValue();
        defer replacement.deinit(self.allocator);
        const replacement_bytes = switch (replacement) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const requested_length = if (has_length) try self.popLong() else @as(i32, @intCast(replacement_bytes.len));
        const start = try self.popLong();
        const reference = try self.popReference();
        const target_value = try reference.value();
        const target = switch (target_value) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        if (start < 1 or start > values.maximum_string_bytes or start > target.len or
            requested_length < 1 or requested_length > values.maximum_string_bytes)
        {
            return error.IllegalFunctionCall;
        }
        const first: usize = @intCast(start - 1);
        const amount = @min(@as(usize, @intCast(requested_length)), @min(replacement_bytes.len, target.len - first));
        std.mem.copyForwards(u8, target[first .. first + amount], replacement_bytes[0..amount]);
    }

    fn arrayDefaultLower(self: *Vm, lower: u32) ExecutionError!void {
        if (lower > 1) return error.InvalidInstruction;
        var upper = try self.popValue();
        self.pushValue(.{ .integer = @intCast(lower) }) catch |fault| {
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

    fn dimensionArray(self: *Vm, dimension_count: u32, redimension: bool, preserve_or_once: bool) ExecutionError!void {
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
        if (!redimension and array.dimensions.len != 0) {
            if (preserve_or_once) return;
            return error.ArrayAlreadyDimensioned;
        }
        if (redimension and preserve_or_once and array.dimensions.len != 0) {
            try self.preserveArray(array, lowers[0..dimension_count], uppers[0..dimension_count]);
        } else {
            try self.resizeArray(array, lowers[0..dimension_count], uppers[0..dimension_count]);
        }
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
        const old_payload_bytes = try arrayLogicalPayloadBytes(
            self.program,
            array.value_type,
            array.record_type,
            array.fixed_string_length,
            array.storage.len(),
        );
        const new_payload_bytes = try arrayLogicalPayloadBytes(
            self.program,
            array.value_type,
            array.record_type,
            array.fixed_string_length,
            total,
        );
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
                element.* = try allocateElement(
                    self.allocator,
                    self.program,
                    array.value_type,
                    array.record_type,
                    array.fixed_string_length,
                );
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

    fn preserveArray(self: *Vm, array: *ArrayValue, lowers: []const i32, uppers: []const i32) ExecutionError!void {
        if (array.dimensions.len != lowers.len or lowers.len == 0) return error.SubscriptOutOfRange;
        for (array.dimensions, 0..) |dimension, index| {
            if (dimension.lower != lowers[index]) return error.SubscriptOutOfRange;
            if (index + 1 != lowers.len and dimension.upper != uppers[index]) return error.SubscriptOutOfRange;
        }

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

        const old_count = array.storage.len();
        const old_payload_bytes = try arrayLogicalPayloadBytes(
            self.program,
            array.value_type,
            array.record_type,
            array.fixed_string_length,
            old_count,
        );
        const new_payload_bytes = try arrayLogicalPayloadBytes(
            self.program,
            array.value_type,
            array.record_type,
            array.fixed_string_length,
            total,
        );
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

        const old_final_length: usize = @intCast(array.dimensions[array.dimensions.len - 1].upper -
            array.dimensions[array.dimensions.len - 1].lower + 1);
        const new_final_length: usize = @intCast(uppers[uppers.len - 1] - lowers[lowers.len - 1] + 1);
        const row_count = if (old_final_length == 0) 0 else old_count / old_final_length;
        const copied_per_row = @min(old_final_length, new_final_length);

        var replacement: ArrayStorage = undefined;
        if (array.record_type == bytecode.invalid_index and array.value_type.isNumeric()) {
            replacement = switch (array.value_type) {
                .integer => .{ .integer = try self.allocator.alloc(i16, total) },
                .long => .{ .long = try self.allocator.alloc(i32, total) },
                .single => .{ .single = try self.allocator.alloc(f32, total) },
                .double => .{ .double = try self.allocator.alloc(f64, total) },
                .string => unreachable,
            };
            errdefer replacement.deinit(self.allocator);
            switch (replacement) {
                .integer => |items| @memset(items, 0),
                .long => |items| @memset(items, 0),
                .single => |items| @memset(items, 0),
                .double => |items| @memset(items, 0),
                .cells => unreachable,
            }
            for (0..row_count) |row| {
                const old_first = row * old_final_length;
                const new_first = row * new_final_length;
                switch (array.storage) {
                    .integer => |old| @memcpy(replacement.integer[new_first .. new_first + copied_per_row], old[old_first .. old_first + copied_per_row]),
                    .long => |old| @memcpy(replacement.long[new_first .. new_first + copied_per_row], old[old_first .. old_first + copied_per_row]),
                    .single => |old| @memcpy(replacement.single[new_first .. new_first + copied_per_row], old[old_first .. old_first + copied_per_row]),
                    .double => |old| @memcpy(replacement.double[new_first .. new_first + copied_per_row], old[old_first .. old_first + copied_per_row]),
                    .cells => unreachable,
                }
            }
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
                element.* = try allocateElement(
                    self.allocator,
                    self.program,
                    array.value_type,
                    array.record_type,
                    array.fixed_string_length,
                );
                initialized += 1;
            }
            const old_elements = switch (array.storage) {
                .cells => |items| items,
                else => return error.InvalidInstruction,
            };
            for (0..row_count) |row| {
                const old_first = row * old_final_length;
                const new_first = row * new_final_length;
                for (0..copied_per_row) |column| {
                    const cloned = try cloneCell(self.allocator, self.program, &old_elements[old_first + column]);
                    elements[new_first + column].deinit(self.allocator);
                    elements[new_first + column] = cloned;
                }
            }
            replacement = .{ .cells = elements };
            self.generic_array_resizes +%= 1;
            self.generic_array_initializations +|= @intCast(total);
        }

        array.storage.deinit(self.allocator);
        self.allocator.free(array.dimensions);
        array.storage = replacement;
        array.dimensions = dimensions;
        self.array_live_payload_bytes = @intCast(final_live_bytes);
        self.maximum_array_live_payload_bytes = @max(self.maximum_array_live_payload_bytes, self.array_live_payload_bytes);
        self.maximum_array_resize_live_bytes = @max(self.maximum_array_resize_live_bytes, @as(u64, @intCast(resize_live_bytes)));
    }

    fn eraseArray(self: *Vm) ExecutionError!void {
        const root = try (try self.popReference()).aggregateCell();
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return error.TypeMismatch,
        };
        try self.eraseArrayValue(array);
    }

    fn eraseArrayValue(self: *Vm, array: *ArrayValue) ExecutionError!void {
        if (!array.is_dynamic) {
            switch (array.storage) {
                .integer => |items| @memset(items, 0),
                .long => |items| @memset(items, 0),
                .single => |items| @memset(items, 0),
                .double => |items| @memset(items, 0),
                .cells => |items| for (items) |*item| try self.clearCell(item),
            }
            return;
        }

        const replacement_dimensions = try self.allocator.alloc(Dimension, 0);
        errdefer self.allocator.free(replacement_dimensions);
        var replacement_storage = try allocateEmptyArrayStorage(self.allocator, array.value_type, array.record_type);
        errdefer replacement_storage.deinit(self.allocator);
        const payload_bytes = try arrayLogicalPayloadBytes(
            self.program,
            array.value_type,
            array.record_type,
            array.fixed_string_length,
            array.storage.len(),
        );
        array.storage.deinit(self.allocator);
        self.allocator.free(array.dimensions);
        array.storage = replacement_storage;
        array.dimensions = replacement_dimensions;
        self.array_live_payload_bytes -|= @intCast(payload_bytes);
    }

    fn clearCell(self: *Vm, source: *Cell) ExecutionError!void {
        const cell = resolveCell(source) orelse return error.InvalidInstruction;
        switch (cell.owned) {
            .scalar => |*value| switch (value.*) {
                .integer => value.* = .{ .integer = 0 },
                .long => value.* = .{ .long = 0 },
                .single => value.* = .{ .single = 0 },
                .double => value.* = .{ .double = 0 },
                .string => |bytes| {
                    const empty = try self.allocator.alloc(u8, 0);
                    self.allocator.free(bytes);
                    value.* = .{ .string = empty };
                },
            },
            .fixed_string => |*string| {
                const bytes = switch (string.value) {
                    .string => |value| value,
                    else => return error.InvalidInstruction,
                };
                @memset(bytes, ' ');
            },
            .field_string => |*string| switch (string.value) {
                .string => |bytes| @memset(bytes, ' '),
                else => return error.InvalidInstruction,
            },
            .record => |*record| for (record.fields) |*field| try self.clearCell(field),
            .array => |*array| try self.eraseArrayValue(array),
        }
    }

    fn arrayBound(self: *Vm, upper: bool) ExecutionError!void {
        var dimension_value = try self.popValue();
        defer dimension_value.deinit(self.allocator);
        const dimension = try values.asLong(dimension_value);
        const root = try (try self.popReference()).aggregateCell();
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return error.TypeMismatch,
        };
        if (dimension < 1 or dimension > array.dimensions.len) return error.SubscriptOutOfRange;
        const selected = array.dimensions[@intCast(dimension - 1)];
        try self.pushValue(.{ .integer = @intCast(if (upper) selected.upper else selected.lower) });
    }

    fn clearState(self: *Vm, has_stack: bool) ExecutionError!void {
        try self.closeAllFiles();
        if (has_stack) {
            var stack_value = try self.popValue();
            defer stack_value.deinit(self.allocator);
            const requested = try values.asLong(stack_value);
            if (requested < 0) return error.IllegalFunctionCall;
        }
        self.discardStackFrom(0);
        self.gosub_stack.clearRetainingCapacity();
        for (self.globals) |*global_cell| try self.clearCell(global_cell);
    }

    fn justifyString(self: *Vm, right: bool) ExecutionError!void {
        var incoming = try self.popValue();
        defer incoming.deinit(self.allocator);
        const source = switch (incoming) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const destination = try self.popReference();
        const current = try destination.value();
        const field = switch (current) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const direct = switch (destination) {
            .cell => |cell| blk: {
                const resolved = resolveCell(cell) orelse return error.InvalidInstruction;
                break :blk switch (resolved.owned) {
                    .field_string => |value| switch (value.value) {
                        .string => |bytes| bytes,
                        else => return error.InvalidInstruction,
                    },
                    else => null,
                };
            },
            else => null,
        };
        const replacement = if (direct) |bytes| bytes else try self.allocator.alloc(u8, field.len);
        errdefer if (direct == null) self.allocator.free(replacement);
        @memset(replacement, ' ');
        const amount = @min(replacement.len, source.len);
        const first = if (right and source.len < replacement.len) replacement.len - amount else 0;
        @memcpy(replacement[first .. first + amount], source[0..amount]);
        if (direct == null) try destination.replace(self.allocator, .{ .string = replacement });
    }

    fn copyRecord(self: *Vm) ExecutionError!void {
        const source = try (try self.popReference()).aggregateCell();
        const destination = try (try self.popReference()).aggregateCell();
        const source_record = switch (source.owned) {
            .record => |record| record,
            else => return error.TypeMismatch,
        };
        const destination_record = switch (destination.owned) {
            .record => |record| record,
            else => return error.TypeMismatch,
        };
        if (source_record.record_type != destination_record.record_type) return error.TypeMismatch;
        var replacement = try cloneCell(self.allocator, self.program, source);
        const replacement_owned = switch (replacement) {
            .owned => |owned| owned,
            .alias => return error.InvalidInstruction,
        };
        destination.owned.deinit(self.allocator);
        destination.owned = replacement_owned;
        replacement = undefined;
    }

    fn lsetRecord(self: *Vm) ExecutionError!void {
        const source = try (try self.popReference()).aggregateCell();
        const destination = try (try self.popReference()).aggregateCell();
        const source_type = switch (source.owned) {
            .record => |record| record.record_type,
            else => return error.TypeMismatch,
        };
        const destination_type = switch (destination.owned) {
            .record => |record| record.record_type,
            else => return error.TypeMismatch,
        };
        if (source_type >= self.program.record_types.len or destination_type >= self.program.record_types.len) {
            return error.InvalidInstruction;
        }
        const source_bytes = try self.allocator.alloc(u8, self.program.record_types[source_type].byte_size);
        defer self.allocator.free(source_bytes);
        const destination_bytes = try self.allocator.alloc(u8, self.program.record_types[destination_type].byte_size);
        defer self.allocator.free(destination_bytes);
        try encodeRecord(self.program, source, source_bytes);
        try encodeRecord(self.program, destination, destination_bytes);
        @memcpy(destination_bytes[0..@min(source_bytes.len, destination_bytes.len)], source_bytes[0..@min(source_bytes.len, destination_bytes.len)]);
        try decodeRecord(self.program, destination, destination_bytes);
    }

    fn swapValues(self: *Vm) ExecutionError!void {
        const second = try self.popReference();
        const first = try self.popReference();
        if (first == .cell and second == .cell) {
            const first_cell = try first.aggregateCell();
            const second_cell = try second.aggregateCell();
            const swappable_cells = switch (first_cell.owned) {
                .scalar => |first_value| switch (second_cell.owned) {
                    .scalar => |second_value| first_value.valueType() == .string and second_value.valueType() == .string,
                    else => false,
                },
                .fixed_string => |first_string| switch (second_cell.owned) {
                    .fixed_string => |second_string| first_string.length == second_string.length,
                    else => false,
                },
                .field_string => false,
                .record => |first_record| switch (second_cell.owned) {
                    .record => |second_record| first_record.record_type == second_record.record_type,
                    else => false,
                },
                .array => false,
            };
            if (swappable_cells) {
                std.mem.swap(OwnedValue, &first_cell.owned, &second_cell.owned);
                return;
            }
            if (first_cell.owned == .record or second_cell.owned == .record or
                first_cell.owned == .fixed_string or second_cell.owned == .fixed_string or
                first_cell.owned == .field_string or second_cell.owned == .field_string)
            {
                return error.TypeMismatch;
            }
        }
        const first_type = try first.valueType();
        const second_type = try second.valueType();
        if (first_type != second_type) return error.TypeMismatch;
        if (first_type.isNumeric()) {
            const first_value = try first.value();
            const second_value = try second.value();
            try first.replaceNumeric(second_value);
            try second.replaceNumeric(first_value);
            return;
        }
        return error.TypeMismatch;
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

    fn raiseError(self: *Vm) ExecutionError!void {
        var value = try self.popValue();
        defer value.deinit(self.allocator);
        const number = try values.asLong(value);
        if (number < 1 or number > 255) return error.IllegalFunctionCall;
        self.raised_error_number = @intCast(number);
        return error.RaisedError;
    }

    fn resumeError(self: *Vm, mode: ResumeMode, label: u32) ExecutionError!void {
        const active = self.active_error orelse return error.ResumeWithoutError;
        if (mode != .retry) self.discardPendingFileTransfer();
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

    fn trapError(self: *Vm, diagnostic: RuntimeDiagnostic, instruction_index: u32) bool {
        if (!isCatchable(diagnostic.code)) return false;
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
        const bytes = try arrayRawBytes(array);
        _ = self.graphics.captureInto(first, second, bytes) catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            error.IllegalFunctionCall => error.IllegalFunctionCall,
        };
    }

    fn graphicsPut(self: *Vm, flags: u32, encoded_action: u32) ExecutionError!void {
        if ((flags & ~bytecode.graphics_point_relative) != 0 or encoded_action > @intFromEnum(bytecode.GraphicsPutAction.xor)) {
            return error.InvalidInstruction;
        }
        const array = try self.popArrayReference();
        const raw = try self.popGraphicsPoint();
        const target = self.graphics.resolvePoint(raw.x, raw.y, (flags & bytecode.graphics_point_relative) != 0);
        const bytes = try arrayRawBytesConst(array);
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
        const dirty = self.text.takeDirty();
        if (dirty.count != 0) {
            self.text_sync_renders +%= 1;
            for (dirty.slice()) |region| self.graphics.renderText(&self.text, region);
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
        if (file.mode != .output and file.mode != .append) return error.BadFileMode;
        self.active_print_file = @intCast(file_number);
    }

    fn printValue(self: *Vm) ExecutionError!void {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        const value = try self.stackValueAt(self.stack.items.len - 1);
        switch (value) {
            .string => |bytes| try self.printBytes(bytes),
            .integer => |number| try self.printNumber(number, number >= 0),
            .long => |number| try self.printNumber(number, number >= 0),
            .single => |number| try self.printNumber(number, number >= 0),
            .double => |number| try self.printNumber(number, number >= 0),
        }
        self.discardStackFrom(self.stack.items.len - 1);
    }

    fn printUsingBegin(self: *Vm) ExecutionError!void {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        const format = try self.stackValueAt(self.stack.items.len - 1);
        if (format.valueType() != .string or format.string.len == 0) return error.IllegalFunctionCall;
        self.print_using_cursor = 0;
    }

    fn printUsingValue(self: *Vm) ExecutionError!void {
        if (self.stack.items.len < 2) return error.StackUnderflow;
        const format = try self.stackValueAt(self.stack.items.len - 2);
        const value = try self.stackValueAt(self.stack.items.len - 1);
        if (format.valueType() != .string) return error.InvalidInstruction;
        self.format_scratch.clearRetainingCapacity();
        try self.formatUsingValue(format.string, value);
        try self.printBytes(self.format_scratch.items);
        self.discardStackFrom(self.stack.items.len - 1);
    }

    fn printUsingEnd(self: *Vm) ExecutionError!void {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        const format = try self.stackValueAt(self.stack.items.len - 1);
        if (format.valueType() != .string) return error.InvalidInstruction;
        self.discardStackFrom(self.stack.items.len - 1);
        self.print_using_cursor = 0;
    }

    fn printSpc(self: *Vm) ExecutionError!void {
        const count = try self.popLong();
        if (count < 0 or count > values.maximum_string_bytes) return error.IllegalFunctionCall;
        try self.printSpaces(@intCast(count));
    }

    fn writeValue(self: *Vm) ExecutionError!void {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        const value = try self.stackValueAt(self.stack.items.len - 1);
        if (self.write_item_count != 0) try self.printBytes(",");
        switch (value) {
            .string => |bytes| {
                try self.printBytes("\"");
                var start: usize = 0;
                for (bytes, 0..) |byte, index| {
                    if (byte != '"') continue;
                    try self.printBytes(bytes[start .. index + 1]);
                    try self.printBytes("\"");
                    start = index + 1;
                }
                try self.printBytes(bytes[start..]);
                try self.printBytes("\"");
            },
            inline else => |number| {
                var storage: [numeric_format_buffer_bytes]u8 = undefined;
                const body = try self.formatNumber(&storage, number);
                try self.printBytes(body);
            },
        }
        self.write_item_count += 1;
        self.discardStackFrom(self.stack.items.len - 1);
    }

    fn printNumber(self: *Vm, number: anytype, positive: bool) ExecutionError!void {
        var number_storage: [numeric_format_buffer_bytes]u8 = undefined;
        const formatted = try self.formatNumber(&number_storage, number);
        var output: [numeric_format_buffer_bytes + 2]u8 = undefined;
        var len: usize = 0;
        if (positive) {
            output[len] = ' ';
            len += 1;
        }
        @memcpy(output[len .. len + formatted.len], formatted);
        len += formatted.len;
        output[len] = ' ';
        len += 1;
        try self.printBytes(output[0..len]);
    }

    fn formatNumber(self: *Vm, storage: *[numeric_format_buffer_bytes]u8, number: anytype) ExecutionError![]const u8 {
        self.numeric_format_stack_uses +%= 1;
        return switch (@typeInfo(@TypeOf(number))) {
            .int, .comptime_int => std.fmt.bufPrint(storage, "{d}", .{number}) catch return error.Overflow,
            .float => |info| switch (info.bits) {
                32 => formatQuickBasicFloat(storage, @as(f32, number), 7, 'E'),
                64 => formatQuickBasicFloat(storage, @as(f64, number), 16, 'D'),
                else => error.InvalidInstruction,
            },
            else => error.InvalidInstruction,
        };
    }

    fn appendFormatBytes(self: *Vm, bytes: []const u8) ExecutionError!void {
        if (bytes.len > values.maximum_string_bytes -| self.format_scratch.items.len) return error.IllegalFunctionCall;
        try self.format_scratch.appendSlice(self.allocator, bytes);
    }

    fn appendFormatByte(self: *Vm, byte: u8) ExecutionError!void {
        if (self.format_scratch.items.len >= values.maximum_string_bytes) return error.IllegalFunctionCall;
        try self.format_scratch.append(self.allocator, byte);
    }

    fn formatUsingValue(self: *Vm, format: []const u8, value: values.Value) ExecutionError!void {
        var cursor = if (self.print_using_cursor < format.len) self.print_using_cursor else 0;
        var wrapped = false;
        const field = while (true) {
            if (try self.appendUsingLiteralsUntilField(format, &cursor)) |found| break found;
            if (wrapped or cursor == 0) return error.IllegalFunctionCall;
            cursor = 0;
            wrapped = true;
        };
        switch (field.kind) {
            .first_character => {
                const bytes = switch (value) {
                    .string => |string| string,
                    else => return error.TypeMismatch,
                };
                try self.appendFormatByte(if (bytes.len == 0) ' ' else bytes[0]);
            },
            .fixed_string => {
                const bytes = switch (value) {
                    .string => |string| string,
                    else => return error.TypeMismatch,
                };
                const width = field.end - field.start;
                const used = @min(width, bytes.len);
                try self.appendFormatBytes(bytes[0..used]);
                var remaining = width - used;
                while (remaining != 0) : (remaining -= 1) try self.appendFormatByte(' ');
            },
            .variable_string => {
                const bytes = switch (value) {
                    .string => |string| string,
                    else => return error.TypeMismatch,
                };
                try self.appendFormatBytes(bytes);
            },
            .number => try self.formatUsingNumber(format[field.start..field.end], value),
        }
        cursor = field.end;
        _ = try self.appendUsingLiteralsUntilField(format, &cursor);
        self.print_using_cursor = cursor;
    }

    fn appendUsingLiteralsUntilField(self: *Vm, format: []const u8, cursor: *usize) ExecutionError!?UsingField {
        while (cursor.* < format.len) {
            if (format[cursor.*] == '_') {
                if (cursor.* + 1 >= format.len) return error.IllegalFunctionCall;
                try self.appendFormatByte(format[cursor.* + 1]);
                cursor.* += 2;
                continue;
            }
            if (usingFieldAt(format, cursor.*)) |field| return field;
            try self.appendFormatByte(format[cursor.*]);
            cursor.* += 1;
        }
        return null;
    }

    fn formatUsingNumber(self: *Vm, spec: []const u8, input: values.Value) ExecutionError!void {
        if (!input.valueType().isNumeric()) return error.TypeMismatch;
        const parsed = parseUsingNumberSpec(spec) orelse return error.IllegalFunctionCall;
        if (parsed.digit_positions > 24) return error.IllegalFunctionCall;
        const number = try values.asDouble(input);
        if (!std.math.isFinite(number)) return error.Overflow;
        var raw_storage: [512]u8 = undefined;
        const raw = if (parsed.exponent_digits != 0)
            try formatUsingExponent(&raw_storage, @abs(number), parsed)
        else
            try formatUsingFixed(&raw_storage, @abs(number), parsed);

        var decorated_storage: [640]u8 = undefined;
        var decorated_len: usize = 0;
        const negative = number < 0;
        if (parsed.leading_sign) {
            decorated_storage[decorated_len] = if (negative) '-' else '+';
            decorated_len += 1;
        } else if (negative and !parsed.trailing_sign) {
            decorated_storage[decorated_len] = '-';
            decorated_len += 1;
        }
        if (parsed.currency) {
            decorated_storage[decorated_len] = '$';
            decorated_len += 1;
        }
        @memcpy(decorated_storage[decorated_len .. decorated_len + raw.len], raw);
        decorated_len += raw.len;
        if (parsed.trailing_sign) {
            decorated_storage[decorated_len] = if (negative) '-' else if (parsed.trailing_plus) '+' else ' ';
            decorated_len += 1;
        }

        if (decorated_len > spec.len) {
            try self.appendFormatByte('%');
            try self.appendFormatBytes(decorated_storage[0..decorated_len]);
            return;
        }
        const padding = spec.len - decorated_len;
        var remaining = padding;
        while (remaining != 0) : (remaining -= 1) try self.appendFormatByte(if (parsed.star_fill) '*' else ' ');
        try self.appendFormatBytes(decorated_storage[0..decorated_len]);
    }

    fn printBytes(self: *Vm, bytes: []const u8) ExecutionError!void {
        if (self.active_print_file) |raw_number| {
            const file = try self.fileAt(raw_number);
            if (file.mode != .output and file.mode != .append) return error.BadFileMode;
            try self.appendFileBytes(file, bytes);
            return;
        }
        self.text.write(bytes);
    }

    fn printTab(self: *Vm) ExecutionError!void {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        const requested = try values.asLong(try self.stackValueAt(self.stack.items.len - 1));
        if (requested < 1 or requested > 255) return error.IllegalFunctionCall;
        if (self.active_print_file) |raw_number| {
            const file = try self.fileAt(raw_number);
            const target: usize = @intCast(requested - 1);
            const newline = target < file.print_column;
            const spaces = if (newline) target else target - file.print_column;
            const additional = spaces + if (newline) @as(usize, 2) else 0;
            try self.ensureFileOutputSpace(file, additional);
            if (newline) try file.output.appendSlice(self.allocator, "\r\n");
            try file.output.appendNTimes(self.allocator, ' ', spaces);
            file.output_total_bytes += additional;
            file.next_position +|= @intCast(additional);
            file.size = @max(file.size, file.next_position - 1);
            file.print_column = target;
            self.noteFileOutputBuffer(file);
            self.discardStackFrom(self.stack.items.len - 1);
            return;
        }
        self.discardStackFrom(self.stack.items.len - 1);
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
        if (self.active_print_file) |raw_number| {
            const file = try self.fileAt(raw_number);
            try self.ensureFileOutputSpace(file, count);
            try file.output.appendNTimes(self.allocator, ' ', count);
            file.output_total_bytes += count;
            file.next_position +|= @intCast(count);
            file.size = @max(file.size, file.next_position - 1);
            file.print_column +|= count;
            self.noteFileOutputBuffer(file);
            return;
        }
        const spaces = [_]u8{' '} ** text_screen.columns;
        var remaining = count;
        while (remaining != 0) {
            const amount = @min(remaining, spaces.len);
            self.text.write(spaces[0..amount]);
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

    fn appendFileBytes(self: *Vm, file: *SequentialFile, bytes: []const u8) ExecutionError!void {
        try self.ensureFileOutputSpace(file, bytes.len);
        try file.output.appendSlice(self.allocator, bytes);
        file.output_total_bytes += bytes.len;
        file.next_position +|= @intCast(bytes.len);
        file.size = @max(file.size, file.next_position - 1);
        for (bytes) |byte| switch (byte) {
            '\r', '\n' => file.print_column = 0,
            else => file.print_column +|= 1,
        };
        self.noteFileOutputBuffer(file);
    }

    fn ensureFileOutputSpace(self: *Vm, file: *SequentialFile, additional: usize) ExecutionError!void {
        if (additional > sequential_file_transfer_bytes or additional > maximum_sequential_file_bytes -| file.output_total_bytes) {
            return error.OutOfMemory;
        }
        self.compactFileOutput(file);
        if (file.output.items.len + additional > sequential_file_transfer_bytes) try self.flushFileOutput(file);
        try self.ensureFileBufferCapacity(
            &file.output,
            file.output.items.len + additional,
            sequential_file_transfer_bytes,
        );
    }

    fn compactFileOutput(self: *Vm, file: *SequentialFile) void {
        if (file.output_head == 0) return;
        const remaining = file.output.items.len - file.output_head;
        if (remaining != 0) {
            std.mem.copyForwards(u8, file.output.items[0..remaining], file.output.items[file.output_head..]);
            self.file_output_compaction_bytes +|= @intCast(remaining);
        }
        file.output.items.len = remaining;
        file.output_head = 0;
    }

    fn noteFileOutputBuffer(self: *Vm, file: *const SequentialFile) void {
        self.maximum_file_output_buffer_bytes = @max(
            self.maximum_file_output_buffer_bytes,
            @as(u64, @intCast(file.output.capacity)),
        );
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
        try self.assignInputValues(target_base, parsed);
        self.allocator.free(parsed);
        self.discardStackFrom(target_base);
        self.pending_input_instruction = bytecode.invalid_index;
        self.input_line.clearRetainingCapacity();
    }

    fn inputString(self: *Vm, instruction_index: u32, argument_count: u32, from_file: bool) ExecutionError!void {
        const expected: u32 = if (from_file) 2 else 1;
        if (argument_count != expected or argument_count > self.stack.items.len) return error.InvalidInstruction;
        const base = self.stack.items.len - argument_count;
        const requested = try values.asLong(try self.stackValueAt(base));
        if (requested < 1 or requested > values.maximum_string_bytes) return error.IllegalFunctionCall;
        const count: usize = @intCast(requested);

        if (from_file) {
            const raw_file = try values.asLong(try self.stackValueAt(base + 1));
            if (raw_file < 1 or raw_file > maximum_file_number) return error.BadFileNumber;
            const file = try self.fileAt(@intCast(raw_file));
            if (file.mode != .input and file.mode != .binary) return error.BadFileMode;
            if (!fileCanRead(file)) return error.BadFileMode;
            const available = file.input.items.len - file.input_head;
            if (available < count) {
                if (file.input_eof) return error.InputPastEnd;
                try self.refillFileInput(file);
                self.scheduleFilePoll();
                return error.WouldBlock;
            }
            const result = try self.allocator.dupe(u8, file.input.items[file.input_head .. file.input_head + count]);
            file.input_head += count;
            file.next_position +|= @intCast(count);
            if (file.input_head == file.input.items.len) {
                file.input.clearRetainingCapacity();
                file.input_head = 0;
            }
            self.discardStackFrom(base);
            try self.pushValue(.{ .string = result });
            return;
        }

        if (self.pending_input_instruction != instruction_index) {
            self.pending_input_instruction = instruction_index;
            self.input_line.clearRetainingCapacity();
        }
        while (self.input_line.items.len < count) {
            const byte = self.popKeyboardByte() orelse {
                self.wait_wake_ns = 0;
                return error.WouldBlock;
            };
            try self.input_line.append(self.allocator, byte);
        }
        const result = try self.allocator.dupe(u8, self.input_line.items[0..count]);
        self.input_line.clearRetainingCapacity();
        self.pending_input_instruction = bytecode.invalid_index;
        self.discardStackFrom(base);
        try self.pushValue(.{ .string = result });
    }

    fn acquireInputLine(self: *Vm, instruction_index: u32) ExecutionError!bool {
        if (self.pending_input_instruction != instruction_index) {
            self.pending_input_instruction = instruction_index;
            self.input_line.clearRetainingCapacity();
        }
        while (self.popKeyboardByte()) |byte| {
            switch (byte) {
                0 => _ = self.popKeyboardByte(),
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
        const queued = self.keyboard.items[self.keyboard_head];
        self.keyboard_head += 1;
        if (self.keyboard_head >= 1024 and self.keyboard_head * 2 >= self.keyboard.items.len) {
            const remaining = self.keyboard.items.len - self.keyboard_head;
            std.mem.copyForwards(QueuedInput, self.keyboard.items[0..remaining], self.keyboard.items[self.keyboard_head..]);
            self.keyboard.items.len = remaining;
            self.keyboard_head = 0;
        }
        self.input_stats.consumed_bytes +%= 1;
        self.input_stats.last_consumed_sequence = queued.sequence;
        self.input_stats.last_consumed_tick = queued.tick;
        return queued.value;
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

    fn assignInputValues(self: *Vm, target_base: usize, parsed: []values.Value) ExecutionError!void {
        for (parsed, 0..) |*value, index| {
            const reference = try self.inputTargetCell(target_base + index);
            const fixed_length = try reference.fixedStringLength() orelse continue;
            const source = switch (value.*) {
                .string => |bytes| bytes,
                else => return error.TypeMismatch,
            };
            if (source.len == fixed_length) continue;
            const replacement = try self.allocator.alloc(u8, fixed_length);
            @memset(replacement, ' ');
            const used = @min(replacement.len, source.len);
            @memcpy(replacement[0..used], source[0..used]);
            value.deinit(self.allocator);
            value.* = .{ .string = replacement };
        }
        for (parsed, 0..) |value, index| {
            const reference = self.inputTargetCell(target_base + index) catch unreachable;
            reference.replace(self.allocator, value) catch unreachable;
        }
    }

    fn decodeInputField(self: *Vm, field: InputField, target: bytecode.ValueType) ExecutionError!values.Value {
        if (target == .string) {
            if (!field.quoted) return .{ .string = try self.allocator.dupe(u8, field.bytes) };
            var escaped_quotes: usize = 0;
            var probe: usize = 0;
            while (probe + 1 < field.bytes.len) : (probe += 1) {
                if (field.bytes[probe] == '"' and field.bytes[probe + 1] == '"') {
                    escaped_quotes += 1;
                    probe += 1;
                }
            }
            const decoded = try self.allocator.alloc(u8, field.bytes.len - escaped_quotes);
            var source: usize = 0;
            var target_index: usize = 0;
            while (source < field.bytes.len) {
                decoded[target_index] = field.bytes[source];
                target_index += 1;
                if (field.bytes[source] == '"' and source + 1 < field.bytes.len and field.bytes[source + 1] == '"') source += 1;
                source += 1;
            }
            return .{ .string = decoded };
        }
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
        const original_cursor = file.input_head;
        var cursor = original_cursor;
        if (line_input) {
            if (target_count != 1 or try self.inputTargetType(statement_base + 1) != .string) return error.TypeMismatch;
            if (cursor >= file.input.items.len) {
                if (file.input_eof) return error.InputPastEnd;
                try self.refillFileInput(file);
                self.scheduleFilePoll();
                return error.WouldBlock;
            }
            const start = cursor;
            while (cursor < file.input.items.len and file.input.items[cursor] != '\r' and file.input.items[cursor] != '\n') cursor += 1;
            if (!file.input_eof and (cursor == file.input.items.len or cursor + 1 == file.input.items.len)) {
                try self.refillFileInput(file);
                self.scheduleFilePoll();
                return error.WouldBlock;
            }
            parsed[0] = .{ .string = try self.allocator.dupe(u8, file.input.items[start..cursor]) };
            initialized = 1;
            consumeLineEnding(file.input.items, &cursor);
        } else {
            var target: usize = 0;
            while (target < target_count) : (target += 1) {
                const field = switch (nextSequentialField(file.input.items, &cursor, file.input_eof)) {
                    .field => |value| value,
                    .need_more => {
                        try self.refillFileInput(file);
                        self.scheduleFilePoll();
                        return error.WouldBlock;
                    },
                    .end => return error.InputPastEnd,
                };
                parsed[target] = try self.decodeInputField(
                    field,
                    try self.inputTargetType(statement_base + 1 + target),
                );
                initialized += 1;
            }
        }
        try self.assignInputValues(statement_base + 1, parsed);
        self.allocator.free(parsed);
        file.next_position +|= @intCast(cursor - original_cursor);
        file.input_head = cursor;
        if (file.input_head == file.input.items.len) {
            file.input.clearRetainingCapacity();
            file.input_head = 0;
        }
        self.discardStackFrom(statement_base);
    }

    fn randomize(self: *Vm, instruction_index: u32, argument_count: u32) ExecutionError!void {
        if (argument_count > 1) return error.InvalidInstruction;
        if (argument_count == 1) {
            var seed_value = try self.popValue();
            defer seed_value.deinit(self.allocator);
            self.randomizeSeed(try values.asDouble(seed_value));
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
        self.randomizeSeed(seed);
        self.pending_input_instruction = bytecode.invalid_index;
        self.input_line.clearRetainingCapacity();
    }

    fn randomizeSeed(self: *Vm, seed: f64) void {
        const bits: u64 = @bitCast(seed);
        const high_words = ((bits >> 24) ^ (bits >> 40)) & 0x00FF_FF00;
        self.random_state = @as(u32, @intCast(high_words)) | (self.random_state & 0xFF);
        self.random_last = randomValue(self.random_state);
    }

    fn seedNegativeRandom(self: *Vm, seed: f32) void {
        const bits: u32 = @bitCast(seed);
        self.random_state = ((bits & random_mask) +% (bits >> 24)) & random_mask;
        self.random_last = randomValue(self.random_state);
    }

    fn nextRandom(self: *Vm) f32 {
        self.random_state = (self.random_state *% 0x00FD_43FD +% 0x00C3_9EC3) & random_mask;
        self.random_last = randomValue(self.random_state);
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
            self.audio_fence_frames = result.fence_frames;
            self.audio_engine.noteForegroundWait();
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
            if (result.mode == .background or result.event_count == 0) return;
            self.pending_audio_instruction = instruction_index;
            self.audio_fence_frames = result.fence_frames;
            self.audio_engine.noteForegroundWait();
        }
        try self.waitForForegroundAudio();
    }

    fn waitForForegroundAudio(self: *Vm) ExecutionError!void {
        if (self.audio_engine.fenceResolved(self.audio_fence_frames)) {
            self.pending_audio_instruction = bytecode.invalid_index;
            self.audio_fence_frames = 0;
            self.audio_engine.noteForegroundWake();
            return;
        }
        // Service acceptance, suppression, or an explicit discard wakes this
        // event-only wait through the subsystem runtime feedback callback.
        self.wait_wake_ns = 0;
        return error.WouldBlock;
    }

    fn openFile(self: *Vm, instruction_index: u32, mode: bytecode.FileMode, flags: u32) ExecutionError!void {
        self.openFileStep(instruction_index, mode, flags) catch |fault| {
            if (fault != error.WouldBlock) self.discardPendingOpen();
            return fault;
        };
    }

    fn openFileStep(self: *Vm, _: u32, encoded_mode: bytecode.FileMode, flags: u32) ExecutionError!void {
        const legacy = (flags & bytecode.file_open_legacy) != 0;
        const has_length = (flags & bytecode.file_open_has_length) != 0;
        const argument_count: usize = (if (legacy) @as(usize, 3) else 2) + @intFromBool(has_length);
        if (self.stack.items.len < argument_count) return error.StackUnderflow;
        const statement_base = self.stack.items.len - argument_count;
        const mode = if (legacy) try legacyFileMode(try self.stackValueAt(statement_base)) else encoded_mode;
        const file_index = statement_base + if (legacy) @as(usize, 1) else 1;
        const path_index = statement_base + if (legacy) @as(usize, 2) else 0;
        const length_index = statement_base + if (legacy) @as(usize, 3) else 2;
        const file_number = try self.fileNumberAt(file_index);
        const path_value = try self.stackValueAt(path_index);
        const raw_path = switch (path_value) {
            .string => |value| value,
            else => return error.TypeMismatch,
        };
        const record_length: u16 = if (has_length) blk: {
            const requested = try values.asLong(try self.stackValueAt(length_index));
            if (requested < 1 or requested > 32_767) return error.BadRecordLength;
            break :blk @intCast(requested);
        } else if (mode == .binary) 1 else 128;
        const access: bytecode.FileAccess = if (legacy)
            .default
        else blk: {
            const raw = (flags >> bytecode.file_open_access_shift) & 0x0F;
            if (raw > @intFromEnum(bytecode.FileAccess.read_write)) return error.InvalidInstruction;
            break :blk @enumFromInt(@as(u8, @intCast(raw)));
        };
        const open_lock: bytecode.FileLock = if (legacy)
            .default
        else blk: {
            const raw = (flags >> bytecode.file_open_lock_shift) & 0x0F;
            if (raw > @intFromEnum(bytecode.FileLock.read_write)) return error.InvalidInstruction;
            break :blk @enumFromInt(@as(u8, @intCast(raw)));
        };
        try validateFileAccess(mode, access);

        if (self.pending_open_file == null) {
            if (self.fileSlotIndex(file_number) != null) return error.FileAlreadyOpen;
            self.pending_open_file = blk: {
                const resolved_path = try self.resolveGuestPath(raw_path);
                errdefer self.allocator.free(resolved_path);
                const record_buffer: []u8 = if (mode == .random or mode == .binary)
                    try self.allocator.alloc(u8, record_length)
                else
                    &.{};
                errdefer if (record_buffer.len != 0) self.allocator.free(record_buffer);
                if (record_buffer.len != 0) @memset(record_buffer, 0);
                break :blk .{
                    .mode = mode,
                    .access = access,
                    .open_lock = open_lock,
                    .path = resolved_path,
                    .record_length = record_length,
                    .generation = self.next_file_generation,
                    .record_buffer = record_buffer,
                };
            };
            self.next_file_generation +%= 1;
            if (self.next_file_generation == 0) self.next_file_generation = 1;
            self.pending_open_number = @intCast(file_number);
        } else if (self.pending_open_number != file_number or self.pending_open_file.?.mode != mode or
            self.pending_open_file.?.access != access or self.pending_open_file.?.record_length != record_length)
        {
            return error.InvalidInstruction;
        }

        const pending = &self.pending_open_file.?;
        if (!pending.storage_ready) switch (mode) {
            .input => {
                if (pending.input_offset == 0 and pending.input.items.len == 0 and !pending.input_eof) try self.refillFileInput(pending);
                pending.storage_ready = true;
            },
            .output => switch (self.host.file_write(self.fileHostContext(), pending.path, "", false)) {
                .bytes => |count| {
                    if (count != 0) return error.PathFileAccess;
                    pending.storage_ready = true;
                    pending.size = 0;
                },
                .pending => {
                    self.file_io_waits +%= 1;
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                },
                .failure => |failure| return fileHostFault(failure),
            },
            .append => {
                if (!pending.create_pending) switch (self.host.file_write(self.fileHostContext(), pending.path, "", true)) {
                    .bytes => |count| {
                        if (count != 0) return error.PathFileAccess;
                        pending.create_pending = true;
                    },
                    .pending => {
                        self.file_io_waits +%= 1;
                        self.scheduleFilePoll();
                        return error.WouldBlock;
                    },
                    .failure => |failure| return fileHostFault(failure),
                };
                switch (self.host.file_info(self.fileHostContext(), pending.path)) {
                    .info => |info| {
                        pending.size = info.size;
                        pending.next_position = info.size +| 1;
                        pending.input_offset = info.size;
                        pending.storage_ready = true;
                        pending.create_pending = false;
                    },
                    .missing => return error.FileNotFound,
                    .pending => {
                        self.file_io_waits +%= 1;
                        self.scheduleFilePoll();
                        return error.WouldBlock;
                    },
                    .failure => |failure| if (failure == .unavailable) {
                        // Legacy embedders only supplied the original read/
                        // write callbacks. Their append behavior remains
                        // usable, while the R4OS adapter reports the exact EOF.
                        pending.size = 0;
                        pending.next_position = 1;
                        pending.storage_ready = true;
                        pending.create_pending = false;
                    } else return fileHostFault(failure),
                }
            },
            .random, .binary => if (pending.create_pending) switch (self.host.file_write_at(self.fileHostContext(), pending.path, 0, "", true)) {
                .bytes => |count| {
                    if (count != 0) return error.PathFileAccess;
                    pending.size = 0;
                    pending.storage_ready = true;
                    pending.create_pending = false;
                },
                .pending => {
                    self.file_io_waits +%= 1;
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                },
                .failure => |failure| return fileHostFault(failure),
            } else switch (self.host.file_info(self.fileHostContext(), pending.path)) {
                .info => |info| {
                    pending.size = info.size;
                    pending.storage_ready = true;
                },
                .missing => {
                    if (!fileCanWrite(pending)) return error.FileNotFound;
                    pending.create_pending = true;
                    switch (self.host.file_write_at(self.fileHostContext(), pending.path, 0, "", true)) {
                        .bytes => |count| {
                            if (count != 0) return error.PathFileAccess;
                            pending.size = 0;
                            pending.storage_ready = true;
                            pending.create_pending = false;
                        },
                        .pending => {
                            self.file_io_waits +%= 1;
                            self.scheduleFilePoll();
                            return error.WouldBlock;
                        },
                        .failure => |failure| return fileHostFault(failure),
                    }
                },
                .pending => {
                    self.file_io_waits +%= 1;
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                },
                .failure => |failure| return fileHostFault(failure),
            },
        };
        if (!pending.open_lock_ready) {
            if (pending.open_lock != .default and pending.open_lock != .shared) {
                switch (self.host.file_lock(self.fileHostContext(), pending.path, 0, std.math.maxInt(u32), false)) {
                    .success => {},
                    .pending => {
                        self.file_io_waits +%= 1;
                        self.scheduleFilePoll();
                        return error.WouldBlock;
                    },
                    .failure => |failure| return fileHostFault(failure),
                }
            }
            pending.open_lock_ready = true;
        }

        const previous_capacity = self.open_files.capacity;
        try self.open_files.ensureUnusedCapacity(self.allocator, 1);
        if (self.open_files.capacity != previous_capacity) self.file_table_capacity_grows +%= 1;
        const opened = self.pending_open_file.?;
        self.pending_open_file = null;
        self.pending_open_number = 0;
        self.open_files.appendAssumeCapacity(.{
            .number = @intCast(file_number),
            .file = opened,
        });
        self.file_slot_indices[file_number] = @intCast(self.open_files.items.len);
        self.maximum_open_files = @max(self.maximum_open_files, @as(u64, @intCast(self.open_files.items.len)));
        self.discardStackFrom(statement_base);
    }

    fn fileTransfer(self: *Vm, instruction_index: u32, write: bool, flags: u32) ExecutionError!void {
        if ((flags & ~(bytecode.file_argument_position | bytecode.file_argument_variable)) != 0) return error.InvalidInstruction;
        const argument_count: usize = 1 + @as(usize, @intFromBool((flags & bytecode.file_argument_position) != 0)) +
            @as(usize, @intFromBool((flags & bytecode.file_argument_variable) != 0));
        if (self.stack.items.len < argument_count) return error.StackUnderflow;
        const stack_base = self.stack.items.len - argument_count;
        const file_number = try self.fileNumberAt(stack_base);
        const file = try self.fileAt(file_number);
        if (file.mode != .random and file.mode != .binary) return error.BadFileMode;
        if (write) {
            if (!fileCanWrite(file)) return error.BadFileMode;
        } else if (!fileCanRead(file)) return error.BadFileMode;

        var stack_index = stack_base + 1;
        const position: u32 = if ((flags & bytecode.file_argument_position) != 0) blk: {
            const raw = try values.asLong(try self.stackValueAt(stack_index));
            stack_index += 1;
            if (raw < 1) return error.BadRecordNumber;
            break :blk @intCast(raw);
        } else file.next_position;
        const has_variable = (flags & bytecode.file_argument_variable) != 0;
        const variable = if (has_variable) try self.stackReferenceAt(stack_index) else null;
        if (has_variable and file.mode == .random and self.hasFieldBindings(file.generation)) return error.FieldActive;
        if (!has_variable and file.mode == .binary) return error.BadRecordLength;

        const byte_length = if (variable) |reference|
            try referenceByteLength(self.program, reference)
        else
            file.record_buffer.len;
        if (byte_length == 0 or byte_length > std.math.maxInt(u32)) return error.BadRecordLength;
        if (file.mode == .random and byte_length != file.record_length) return error.BadRecordLength;
        const offset64: u64 = if (file.mode == .random)
            @as(u64, position - 1) * file.record_length
        else
            position - 1;
        if (offset64 > std.math.maxInt(u32) or offset64 + byte_length > @as(u64, std.math.maxInt(u32)) + 1) {
            return error.BadRecordNumber;
        }

        if (self.pending_file_transfer == null) {
            const buffer = try self.allocator.alloc(u8, byte_length);
            errdefer self.allocator.free(buffer);
            if (write) {
                if (variable) |reference| {
                    try encodeReference(self.program, reference, buffer);
                } else {
                    @memcpy(buffer, file.record_buffer);
                }
            }
            self.pending_file_transfer = .{
                .instruction = instruction_index,
                .file_number = @intCast(file_number),
                .write = write,
                .offset = @intCast(offset64),
                .buffer = buffer,
                .stack_base = stack_base,
                .flags = flags,
                .position = position,
            };
        } else {
            const pending = self.pending_file_transfer.?;
            if (pending.instruction != instruction_index or pending.file_number != file_number or pending.write != write or
                pending.offset != offset64 or pending.flags != flags or pending.position != position or pending.buffer.len != byte_length)
            {
                return error.InvalidInstruction;
            }
            self.pending_file_transfer.?.stack_base = stack_base;
        }

        const pending = &self.pending_file_transfer.?;
        if (pending.transferred < pending.buffer.len) {
            const request = @min(sequential_file_transfer_bytes, pending.buffer.len - pending.transferred);
            const first = pending.transferred;
            const transfer_offset: u32 = @intCast(@as(u64, pending.offset) + first);
            if (write) {
                switch (self.host.file_write_at(
                    self.fileHostContext(),
                    file.path,
                    transfer_offset,
                    pending.buffer[first .. first + request],
                    true,
                )) {
                    .bytes => |raw_count| {
                        const count: usize = @intCast(raw_count);
                        if (count == 0 or count > request) return error.PathFileAccess;
                        pending.transferred += count;
                    },
                    .pending => {
                        self.file_io_waits +%= 1;
                        self.scheduleFilePoll();
                        return error.WouldBlock;
                    },
                    .failure => |failure| return fileHostFault(failure),
                }
            } else switch (self.host.file_read(
                self.fileHostContext(),
                file.path,
                transfer_offset,
                pending.buffer[first .. first + request],
            )) {
                .bytes => |raw_count| {
                    const count: usize = @intCast(raw_count);
                    if (count == 0 or count > request) return error.PathFileAccess;
                    pending.transferred += count;
                },
                .end => return error.InputPastEnd,
                .pending => {
                    self.file_io_waits +%= 1;
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                },
                .failure => |failure| return fileHostFault(failure),
            }
            if (pending.transferred != pending.buffer.len) {
                self.scheduleFilePoll();
                return error.WouldBlock;
            }
        }

        if (!write) {
            if (variable) |reference| {
                try decodeReference(self.program, reference, pending.buffer);
            } else {
                @memcpy(file.record_buffer, pending.buffer);
            }
        }
        if (write) file.size = @max(file.size, @as(u32, @intCast(@as(u64, pending.offset) + pending.buffer.len)));
        file.next_position = if (file.mode == .random)
            pending.position +| 1
        else
            @intCast(@as(u64, pending.position) + pending.buffer.len);
        if (file.mode == .binary) {
            file.input.clearRetainingCapacity();
            file.input_head = 0;
            file.input_offset = file.next_position - 1;
            file.input_eof = false;
        }
        const completed_base = pending.stack_base;
        self.discardPendingFileTransfer();
        self.discardStackFrom(completed_base);
    }

    fn bindFileFields(self: *Vm, count: u32) ExecutionError!void {
        if (count == 0) return error.InvalidInstruction;
        const argument_count = 1 + @as(usize, count) * 2;
        if (self.stack.items.len < argument_count) return error.StackUnderflow;
        const base = self.stack.items.len - argument_count;
        const file = try self.fileAt(try self.fileNumberAt(base));
        if (file.mode != .random) return error.BadFileMode;

        var total: usize = 0;
        for (0..count) |index| {
            const width_value = try self.stackValueAt(base + 1 + index * 2);
            const raw_width = try values.asLong(width_value);
            if (raw_width < 1 or raw_width > 32_767) return error.IllegalFunctionCall;
            total = std.math.add(usize, total, @intCast(raw_width)) catch return error.FieldOverflow;
            if (total > file.record_length) return error.FieldOverflow;
            const reference = try self.stackReferenceAt(base + 2 + index * 2);
            const cell = switch (reference) {
                .cell => |value| resolveCell(value) orelse return error.InvalidInstruction,
                else => return error.TypeMismatch,
            };
            switch (cell.owned) {
                .scalar => |value| if (value != .string) return error.TypeMismatch,
                .field_string => {},
                else => return error.TypeMismatch,
            }
        }

        var first: usize = 0;
        for (0..count) |index| {
            const width: usize = @intCast(try values.asLong(try self.stackValueAt(base + 1 + index * 2)));
            const reference = try self.stackReferenceAt(base + 2 + index * 2);
            const cell = resolveCell(reference.cell) orelse return error.InvalidInstruction;
            cell.owned.deinit(self.allocator);
            cell.owned = .{ .field_string = .{
                .value = .{ .string = file.record_buffer[first .. first + width] },
                .file_generation = file.generation,
            } };
            first += width;
        }
        self.discardStackFrom(base);
    }

    fn seekFile(self: *Vm) ExecutionError!void {
        if (self.stack.items.len < 2) return error.StackUnderflow;
        const base = self.stack.items.len - 2;
        const file = try self.fileAt(try self.fileNumberAt(base));
        const raw_position = try values.asLong(try self.stackValueAt(base + 1));
        if (raw_position < 1) return error.BadRecordNumber;
        if (file.output_head != file.output.items.len) try self.flushFileOutput(file);
        if (file.mode == .input or file.mode == .binary) {
            file.input.clearRetainingCapacity();
            file.input_head = 0;
            file.input_offset = @intCast(raw_position - 1);
            file.input_eof = false;
        }
        file.next_position = @intCast(raw_position);
        self.discardStackFrom(base);
    }

    fn lockFile(self: *Vm, unlock: bool, flags: u32) ExecutionError!void {
        if ((flags & ~(bytecode.file_range_first | bytecode.file_range_last)) != 0) return error.InvalidInstruction;
        const argument_count: usize = 1 + @as(usize, @intFromBool((flags & bytecode.file_range_first) != 0)) +
            @as(usize, @intFromBool((flags & bytecode.file_range_last) != 0));
        if (self.stack.items.len < argument_count) return error.StackUnderflow;
        const base = self.stack.items.len - argument_count;
        const file = try self.fileAt(try self.fileNumberAt(base));
        var stack_index = base + 1;
        const first_unit: u32 = if ((flags & bytecode.file_range_first) != 0) blk: {
            const raw = try values.asLong(try self.stackValueAt(stack_index));
            stack_index += 1;
            if (raw < 1) return error.BadRecordNumber;
            break :blk @intCast(raw);
        } else 1;
        const last_unit: u32 = if ((flags & bytecode.file_range_last) != 0) blk: {
            const raw = try values.asLong(try self.stackValueAt(stack_index));
            if (raw < 1) return error.BadRecordNumber;
            break :blk @intCast(raw);
        } else if ((flags & bytecode.file_range_first) != 0) first_unit else std.math.maxInt(u32);
        if (last_unit < first_unit) return error.BadRecordNumber;

        const range = try fileByteRange(file, first_unit, last_unit);
        var existing: ?usize = null;
        for (file.locks.items, 0..) |held, index| {
            if (held.first == range.first and held.last == range.last) {
                existing = index;
                break;
            }
        }
        if (unlock and existing == null) return error.PermissionDenied;
        if (!unlock) try file.locks.ensureUnusedCapacity(self.allocator, 1);
        const length = range.last - range.first +| 1;
        switch (self.host.file_lock(self.fileHostContext(), file.path, range.first, length, unlock)) {
            .success => {},
            .pending => {
                self.file_io_waits +%= 1;
                self.scheduleFilePoll();
                return error.WouldBlock;
            },
            .failure => |failure| return fileHostFault(failure),
        }
        if (unlock) {
            _ = file.locks.swapRemove(existing.?);
        } else {
            file.locks.appendAssumeCapacity(range);
        }
        self.discardStackFrom(base);
    }

    fn resetFiles(self: *Vm) ExecutionError!void {
        try self.closeAllFiles();
    }

    fn releaseFileLocks(self: *Vm, file: *SequentialFile) ExecutionError!void {
        while (file.locks.items.len != 0) {
            const range = file.locks.items[file.locks.items.len - 1];
            switch (self.host.file_lock(self.fileHostContext(), file.path, range.first, range.last - range.first +| 1, true)) {
                .success => _ = file.locks.pop(),
                .pending => {
                    self.file_io_waits +%= 1;
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                },
                .failure => |failure| return fileHostFault(failure),
            }
        }
        if (file.open_lock_ready and file.open_lock != .default and file.open_lock != .shared) {
            switch (self.host.file_lock(self.fileHostContext(), file.path, 0, std.math.maxInt(u32), true)) {
                .success => file.open_lock_ready = false,
                .pending => {
                    self.file_io_waits +%= 1;
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                },
                .failure => |failure| return fileHostFault(failure),
            }
        }
    }

    fn stackReferenceAt(self: *Vm, index: usize) ExecutionError!Reference {
        if (index >= self.stack.items.len) return error.StackUnderflow;
        return switch (self.stack.items[index]) {
            .reference => |reference| reference,
            .value => error.InvalidInstruction,
        };
    }

    fn discardPendingFileTransfer(self: *Vm) void {
        if (self.pending_file_transfer) |*pending| pending.deinit(self.allocator);
        self.pending_file_transfer = null;
    }

    fn hasFieldBindings(self: *const Vm, generation: u64) bool {
        for (self.globals) |*cell| if (cellHasFieldBinding(cell, generation)) return true;
        for (self.frames.items) |frame| {
            const storage = &self.frame_local_storage.items[frame.local_pool_index];
            var current = frame.initialized_local_head;
            while (current != bytecode.invalid_index) {
                const slot = &storage.slots.items[current];
                if (slot.generation == frame.local_generation and cellHasFieldBinding(&slot.cell, generation)) return true;
                current = slot.next_initialized;
            }
        }
        return false;
    }

    fn invalidateFieldBindings(self: *Vm, generation: u64) ExecutionError!void {
        for (self.globals) |*cell| try self.invalidateFieldCell(cell, generation);
        for (self.frames.items) |frame| {
            var storage = &self.frame_local_storage.items[frame.local_pool_index];
            var current = frame.initialized_local_head;
            while (current != bytecode.invalid_index) {
                var slot = &storage.slots.items[current];
                if (slot.generation == frame.local_generation) try self.invalidateFieldCell(&slot.cell, generation);
                current = slot.next_initialized;
            }
        }
    }

    fn invalidateFieldCell(self: *Vm, cell: *Cell, generation: u64) ExecutionError!void {
        switch (cell.*) {
            .alias => {},
            .owned => |*owned| switch (owned.*) {
                .field_string => |field| if (field.file_generation == generation) {
                    owned.* = .{ .scalar = .{ .string = try self.allocator.alloc(u8, 0) } };
                },
                .record => |*record| for (record.fields) |*field| try self.invalidateFieldCell(field, generation),
                .array => |*array| switch (array.storage) {
                    .cells => |cells| for (cells) |*item| try self.invalidateFieldCell(item, generation),
                    else => {},
                },
                else => {},
            },
        }
    }

    fn closeFiles(self: *Vm, argument_count: u32) ExecutionError!void {
        if (argument_count == 0) return self.closeAllFiles();
        if (argument_count > self.stack.items.len) return error.StackUnderflow;
        const count: usize = @intCast(argument_count);
        const first = self.stack.items.len - count;

        var current = count;
        while (current != 0) {
            current -= 1;
            const file_number = try self.fileNumberAt(first + current);
            const file = try self.fileAt(file_number);
            try self.flushFileOutput(file);
            try self.releaseFileLocks(file);
        }
        current = count;
        while (current != 0) {
            current -= 1;
            try self.removeFile(try self.fileNumberAt(first + current));
        }
        self.discardStackFrom(first);
    }

    fn closeAllFiles(self: *Vm) ExecutionError!void {
        var current = self.open_files.items.len;
        while (current != 0) {
            current -= 1;
            const file = &self.open_files.items[current].file;
            try self.flushFileOutput(file);
            try self.releaseFileLocks(file);
        }
        while (self.open_files.items.len != 0) try self.removeFile(self.open_files.items[self.open_files.items.len - 1].number);
    }

    fn flushFileOutput(self: *Vm, file: *SequentialFile) ExecutionError!void {
        if (file.mode == .input or file.output_head == file.output.items.len) {
            if (file.output_head != 0) {
                file.output.clearRetainingCapacity();
                file.output_head = 0;
            }
            return;
        }
        const remaining = file.output.items[file.output_head..];
        const buffer_start = @as(u64, file.next_position - 1) - file.output.items.len;
        const write_offset: u32 = @intCast(buffer_start + file.output_head);
        const positional = self.host.file_write_at(self.fileHostContext(), file.path, write_offset, remaining, true);
        const result: FileWriteResult = switch (positional) {
            .failure => |failure| if (failure == .unavailable)
                self.host.file_write(self.fileHostContext(), file.path, remaining, true)
            else
                .{ .failure = failure },
            else => positional,
        };
        switch (result) {
            .bytes => |raw_count| {
                const count: usize = @intCast(raw_count);
                if (count == 0 or count > remaining.len) return error.PathFileAccess;
                file.output_head += count;
                self.file_output_flushes +%= 1;
                if (file.output_head != file.output.items.len) {
                    self.scheduleFilePoll();
                    return error.WouldBlock;
                }
                file.output.clearRetainingCapacity();
                file.output_head = 0;
            },
            .pending => {
                self.file_io_waits +%= 1;
                self.scheduleFilePoll();
                return error.WouldBlock;
            },
            .failure => |failure| return fileHostFault(failure),
        }
    }

    fn removeFile(self: *Vm, file_number: usize) ExecutionError!void {
        const slot_index = self.fileSlotIndex(file_number) orelse return error.BadFileNumber;
        var removed = self.open_files.swapRemove(slot_index);
        try self.invalidateFieldBindings(removed.file.generation);
        removed.file.deinit(self.allocator);
        self.file_slot_indices[file_number] = 0;
        if (slot_index < self.open_files.items.len) {
            const moved_number = self.open_files.items[slot_index].number;
            self.file_slot_indices[moved_number] = @intCast(slot_index + 1);
        }
        if (self.active_print_file != null and self.active_print_file.? == @as(u8, @intCast(file_number))) self.active_print_file = null;
    }

    fn discardFiles(self: *Vm) void {
        self.discardPendingFileTransfer();
        self.discardPendingOpen();
        for (self.open_files.items) |*slot| slot.file.deinit(self.allocator);
        self.open_files.clearRetainingCapacity();
        self.file_slot_indices = .{0} ** (maximum_file_number + 1);
    }

    fn discardPendingOpen(self: *Vm) void {
        if (self.pending_open_file) |*file| file.deinit(self.allocator);
        self.pending_open_file = null;
        self.pending_open_number = 0;
    }

    fn refillFileInput(self: *Vm, file: *SequentialFile) ExecutionError!void {
        if (file.input_eof) return;
        self.compactFileInput(file);
        const is_binary = file.mode == .binary;
        if (!is_binary and file.input_offset > maximum_sequential_file_bytes) return error.OutOfMemory;
        const buffer_limit = if (is_binary) sequential_file_transfer_bytes else maximum_sequential_file_bytes + 1;
        const remaining_limit = if (is_binary)
            buffer_limit - file.input.items.len
        else
            maximum_sequential_file_bytes + 1 - file.input_offset;
        const requested = @min(sequential_file_transfer_bytes, remaining_limit);
        if (requested == 0) return error.OutOfMemory;
        try self.ensureFileBufferCapacity(
            &file.input,
            file.input.items.len + requested,
            buffer_limit,
        );
        self.maximum_file_input_buffer_bytes = @max(
            self.maximum_file_input_buffer_bytes,
            @as(u64, @intCast(file.input.capacity)),
        );
        const available = file.input.items.ptr[file.input.items.len..file.input.capacity];
        const target = available[0..requested];
        switch (self.host.file_read(
            self.fileHostContext(),
            file.path,
            @intCast(file.input_offset),
            target,
        )) {
            .bytes => |raw_count| {
                const count: usize = @intCast(raw_count);
                if (count == 0 or count > requested) return error.PathFileAccess;
                file.input.items.len += count;
                file.input_offset += count;
                self.file_input_refills +%= 1;
                if (!is_binary and file.input_offset > maximum_sequential_file_bytes) return error.OutOfMemory;
            },
            .end => file.input_eof = true,
            .pending => {
                self.file_io_waits +%= 1;
                self.scheduleFilePoll();
                return error.WouldBlock;
            },
            .failure => |failure| return fileHostFault(failure),
        }
    }

    fn compactFileInput(self: *Vm, file: *SequentialFile) void {
        if (file.input_head == 0) return;
        const remaining = file.input.items.len - file.input_head;
        if (remaining != 0) {
            std.mem.copyForwards(u8, file.input.items[0..remaining], file.input.items[file.input_head..]);
            self.file_input_compaction_bytes +|= @intCast(remaining);
        }
        file.input.items.len = remaining;
        file.input_head = 0;
    }

    fn scheduleFilePoll(self: *Vm) void {
        self.wait_wake_ns = self.guest_now_ns +| file_poll_interval_ns;
    }

    fn ensureFileBufferCapacity(
        self: *Vm,
        buffer: *std.ArrayList(u8),
        required: usize,
        limit: usize,
    ) ExecutionError!void {
        if (required > limit) return error.OutOfMemory;
        if (required <= buffer.capacity) return;
        const geometric = buffer.capacity +| buffer.capacity / 2;
        const target = @min(limit, @max(required, geometric));
        try buffer.ensureTotalCapacityPrecise(self.allocator, target);
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

    fn platformHostContext(self: *Vm) ?*anyopaque {
        return self.host.platform_context orelse self.host.context;
    }

    pub fn inheritPlatformState(self: *Vm, source: *const Vm) InitError!void {
        var replacement_directories: [26]?[]u8 = .{null} ** 26;
        errdefer for (&replacement_directories) |*directory| if (directory.*) |bytes| self.allocator.free(bytes);
        for (source.drive_directories, 0..) |directory, index| {
            if (directory) |bytes| replacement_directories[index] = try self.allocator.dupe(u8, bytes);
        }
        var replacement_environment = try self.cloneEnvironment(&source.environment);
        errdefer deinitEnvironmentList(self.allocator, &replacement_environment);

        for (self.environment.items) |entry| _ = self.host.environment_set(self.platformHostContext(), entry.name, "");
        for (replacement_environment.items) |entry| _ = self.host.environment_set(self.platformHostContext(), entry.name, entry.value);
        for (&self.drive_directories) |*directory| if (directory.*) |bytes| self.allocator.free(bytes);
        deinitEnvironmentList(self.allocator, &self.environment);
        self.drive_directories = replacement_directories;
        self.current_drive = source.current_drive;
        self.environment = replacement_environment;
        self.guest_now_ns = source.guest_now_ns;
        self.random_state = source.random_state;
        self.random_last = source.random_last;
    }

    pub fn transferCommonTo(self: *const Vm, target: *Vm, preserve_all: bool) ProgramTransferError!void {
        for (target.program.common_blocks) |target_block| {
            const source_block = self.findCommonBlock(target.program, target_block) orelse return error.IncompatibleCommon;
            if (source_block.entries.len != target_block.entries.len or source_block.byte_size != target_block.byte_size) {
                return error.IncompatibleCommon;
            }
            for (target_block.entries, 0..) |target_entry, index| {
                const source_entry = source_block.entries[index];
                if (source_entry.byte_size != target_entry.byte_size or
                    source_entry.global_index >= self.program.globals.len or target_entry.global_index >= target.program.globals.len)
                {
                    return error.IncompatibleCommon;
                }
                try self.transferGlobalTo(target, source_entry.global_index, target_entry.global_index);
            }
        }
        if (!preserve_all) return;
        for (target.program.globals, 0..) |target_variable, target_index| {
            if (target_variable.is_common or target_variable.hidden) continue;
            const target_name = target_variable.name.bytes(target.program.source);
            const source_index = self.findGlobalByName(target_name) orelse continue;
            if (self.program.globals[source_index].is_common or self.program.globals[source_index].hidden) continue;
            try self.transferGlobalTo(target, source_index, target_index);
        }
    }

    fn findCommonBlock(
        self: *const Vm,
        target_program: *const bytecode.Program,
        target: bytecode.CommonBlock,
    ) ?bytecode.CommonBlock {
        for (self.program.common_blocks) |candidate| {
            if (candidate.named != target.named) continue;
            if (!target.named or std.ascii.eqlIgnoreCase(
                candidate.name.bytes(self.program.source),
                target.name.bytes(target_program.source),
            )) return candidate;
        }
        return null;
    }

    fn findGlobalByName(self: *const Vm, name: []const u8) ?usize {
        for (self.program.globals, 0..) |variable, index| {
            if (std.ascii.eqlIgnoreCase(variable.name.bytes(self.program.source), name)) return index;
        }
        return null;
    }

    fn transferGlobalTo(self: *const Vm, target: *Vm, source_index: usize, target_index: usize) ProgramTransferError!void {
        const source_variable = self.program.globals[source_index];
        const target_variable = target.program.globals[target_index];
        if (!variablesTransferCompatible(self.program, source_variable, target.program, target_variable)) {
            return error.IncompatibleCommon;
        }
        var replacement = cloneVariableAcrossPrograms(
            target.allocator,
            self.program,
            source_variable,
            target.program,
            target_variable,
            &self.globals[source_index],
        ) catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.IncompatibleCommon,
        };
        errdefer replacement.deinit(target.allocator);
        const old_payload = arrayCellPayloadBytes(target.program, &target.globals[target_index]) catch return error.IncompatibleCommon;
        const new_payload = arrayCellPayloadBytes(target.program, &replacement) catch return error.IncompatibleCommon;
        const live_without_old = target.array_live_payload_bytes -| @as(u64, @intCast(old_payload));
        if (live_without_old +| @as(u64, @intCast(new_payload)) > array_live_payload_limit_bytes) return error.OutOfMemory;
        target.globals[target_index].deinit(target.allocator);
        target.globals[target_index] = replacement;
        target.array_live_payload_bytes = live_without_old + @as(u64, @intCast(new_payload));
        target.maximum_array_live_payload_bytes = @max(target.maximum_array_live_payload_bytes, target.array_live_payload_bytes);
    }

    fn initializePlatformState(self: *Vm) InitError!void {
        const requested_base = if (self.host.guest_directory.len != 0)
            self.host.guest_directory
        else if (isAbsoluteGuestPath(self.program.file_name))
            self.program.file_name[0 .. lastPathSeparator(self.program.file_name) orelse 3]
        else
            "C:\\";
        self.initial_guest_directory = normalizeAbsoluteGuestPath(self.allocator, requested_base) catch
            try self.allocator.dupe(u8, "C:\\");
        self.current_drive = std.ascii.toUpper(self.initial_guest_directory[0]) - 'A';
        self.drive_directories[self.current_drive] = try self.allocator.dupe(u8, self.initial_guest_directory);

        self.command_line = try self.allocator.dupe(u8, self.host.command_line);

        for (self.host.initial_environment) |entry| {
            try self.setEnvironmentIn(&self.initial_environment, entry.name, entry.value);
        }
        self.environment = try self.cloneEnvironment(&self.initial_environment);
        for (self.environment.items) |entry| _ = self.host.environment_set(self.platformHostContext(), entry.name, entry.value);
    }

    fn resetPlatformState(self: *Vm) InitError!void {
        const replacement_directory = try self.allocator.dupe(u8, self.initial_guest_directory);
        errdefer self.allocator.free(replacement_directory);
        var replacement_environment = try self.cloneEnvironment(&self.initial_environment);
        errdefer deinitEnvironmentList(self.allocator, &replacement_environment);

        for (self.environment.items) |entry| _ = self.host.environment_set(self.platformHostContext(), entry.name, "");
        for (replacement_environment.items) |entry| _ = self.host.environment_set(self.platformHostContext(), entry.name, entry.value);
        for (&self.drive_directories) |*directory| if (directory.*) |bytes| {
            self.allocator.free(bytes);
            directory.* = null;
        };
        self.current_drive = std.ascii.toUpper(self.initial_guest_directory[0]) - 'A';
        self.drive_directories[self.current_drive] = replacement_directory;
        deinitEnvironmentList(self.allocator, &self.environment);
        self.environment = replacement_environment;
    }

    fn deinitPlatformState(self: *Vm) void {
        for (&self.drive_directories) |*directory| if (directory.*) |bytes| {
            self.allocator.free(bytes);
            directory.* = null;
        };
        if (self.initial_guest_directory.len != 0) self.allocator.free(self.initial_guest_directory);
        if (self.command_line.len != 0) self.allocator.free(self.command_line);
        deinitEnvironmentList(self.allocator, &self.initial_environment);
        deinitEnvironmentList(self.allocator, &self.environment);
        self.initial_guest_directory = &.{};
        self.command_line = &.{};
    }

    fn cloneEnvironment(self: *Vm, source: *const std.ArrayList(EnvironmentValue)) InitError!std.ArrayList(EnvironmentValue) {
        var result: std.ArrayList(EnvironmentValue) = .empty;
        errdefer deinitEnvironmentList(self.allocator, &result);
        try result.ensureTotalCapacityPrecise(self.allocator, source.items.len);
        for (source.items) |entry| {
            const name = try self.allocator.dupe(u8, entry.name);
            const value = self.allocator.dupe(u8, entry.value) catch |fault| {
                self.allocator.free(name);
                return fault;
            };
            result.appendAssumeCapacity(.{ .name = name, .value = value });
        }
        return result;
    }

    fn setEnvironmentIn(
        self: *Vm,
        target: *std.ArrayList(EnvironmentValue),
        raw_name: []const u8,
        value: []const u8,
    ) InitError!void {
        const name = std.mem.trim(u8, raw_name, " \t");
        if (!validEnvironmentName(name) or value.len > maximum_environment_value_bytes) return error.InvalidProgram;
        var existing: ?usize = null;
        for (target.items, 0..) |entry, index| if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            existing = index;
            break;
        };
        const replaced = if (existing) |index| environmentEntryBytes(target.items[index]) else 0;
        const total = environmentListBytes(target) - replaced + name.len + 1 + value.len + 1;
        if (total > maximum_environment_block_bytes or (existing == null and target.items.len >= maximum_environment_entries)) {
            return error.InvalidProgram;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        if (existing) |index| {
            var previous = target.items[index];
            target.items[index] = .{ .name = owned_name, .value = owned_value };
            previous.deinit(self.allocator);
        } else {
            try target.append(self.allocator, .{ .name = owned_name, .value = owned_value });
        }
    }

    fn discardPendingDirectory(self: *Vm) void {
        if (self.pending_directory) |*pending| pending.deinit(self.allocator);
        self.pending_directory = null;
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
        if (raw_path.len == 0 or raw_path.len > maximum_guest_path_bytes or containsInvalidPathByte(raw_path) or isReservedDevicePath(raw_path)) {
            return error.BadFileName;
        }
        var drive_index: u8 = self.current_drive;
        var suffix = raw_path;
        var rooted = false;
        if (raw_path.len >= 2 and std.ascii.isAlphabetic(raw_path[0]) and raw_path[1] == ':') {
            drive_index = std.ascii.toUpper(raw_path[0]) - 'A';
            suffix = raw_path[2..];
            rooted = suffix.len != 0 and (suffix[0] == '\\' or suffix[0] == '/');
        } else if (std.mem.indexOfScalar(u8, raw_path, ':') != null) {
            return error.BadFileName;
        } else {
            rooted = raw_path[0] == '\\' or raw_path[0] == '/';
        }
        if (isAbsoluteGuestPath(raw_path)) return normalizeAbsoluteGuestPath(self.allocator, raw_path);

        var root_storage = [_]u8{ @as(u8, 'A') + drive_index, ':', '\\' };
        const base = if (rooted)
            root_storage[0..]
        else if (self.drive_directories[drive_index]) |directory|
            directory
        else
            root_storage[0..];
        if (suffix.len == 0) return self.allocator.dupe(u8, base);
        var relative_start: usize = 0;
        while (relative_start < suffix.len and (suffix[relative_start] == '\\' or suffix[relative_start] == '/')) : (relative_start += 1) {}
        const relative = suffix[relative_start..];
        const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            base,
            if (base.len == 3 or base[base.len - 1] == '\\' or base[base.len - 1] == '/') "" else "\\",
            relative,
        });
        defer self.allocator.free(combined);
        return normalizeAbsoluteGuestPath(self.allocator, combined);
    }

    fn changeDirectory(self: *Vm) ExecutionError!void {
        var raw = try self.popValue();
        defer raw.deinit(self.allocator);
        const path = switch (raw) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const resolved = try self.resolveGuestPath(path);
        var resolved_owned = true;
        defer if (resolved_owned) self.allocator.free(resolved);
        switch (self.host.path_info(self.platformHostContext(), resolved)) {
            .info => |kind| if (kind != .directory) return error.PathNotFound,
            .missing => return error.PathNotFound,
            .failure => |failure| return fileHostFault(failure),
        }
        const drive: u8 = std.ascii.toUpper(resolved[0]) - 'A';
        if (self.drive_directories[drive]) |previous| self.allocator.free(previous);
        self.drive_directories[drive] = resolved;
        resolved_owned = false;
        self.current_drive = drive;
    }

    fn makeDirectory(self: *Vm) ExecutionError!void {
        var raw = try self.popValue();
        defer raw.deinit(self.allocator);
        const path = switch (raw) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const resolved = try self.resolveGuestPath(path);
        defer self.allocator.free(resolved);
        switch (self.host.path_info(self.platformHostContext(), resolved)) {
            .info => return error.FileExists,
            .missing => {},
            .failure => |failure| return fileHostFault(failure),
        }
        switch (self.host.directory_create(self.platformHostContext(), resolved)) {
            .success => {},
            .missing => return error.FileExists,
            .failure => |failure| return fileHostFault(failure),
        }
    }

    fn removeDirectory(self: *Vm) ExecutionError!void {
        var raw = try self.popValue();
        defer raw.deinit(self.allocator);
        const path = switch (raw) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const resolved = try self.resolveGuestPath(path);
        defer self.allocator.free(resolved);
        for (self.drive_directories) |directory| {
            if (directory) |current| {
                if (std.ascii.eqlIgnoreCase(current, resolved)) return error.PathFileAccess;
            }
        }
        switch (self.host.directory_delete(self.platformHostContext(), resolved)) {
            .success => {},
            .missing => return error.PathNotFound,
            .failure => |failure| return fileHostFault(failure),
        }
    }

    fn renamePath(self: *Vm) ExecutionError!void {
        var target_value = try self.popValue();
        defer target_value.deinit(self.allocator);
        var source_value = try self.popValue();
        defer source_value.deinit(self.allocator);
        const target_raw = switch (target_value) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const source_raw = switch (source_value) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const source = try self.resolveGuestPath(source_raw);
        defer self.allocator.free(source);
        const target = try self.resolveGuestPath(target_raw);
        defer self.allocator.free(target);
        if (std.ascii.toUpper(source[0]) != std.ascii.toUpper(target[0])) return error.PathFileAccess;
        switch (self.host.path_info(self.platformHostContext(), source)) {
            .info => {},
            .missing => return error.FileNotFound,
            .failure => |failure| return fileHostFault(failure),
        }
        switch (self.host.path_info(self.platformHostContext(), target)) {
            .info => return error.FileExists,
            .missing => {},
            .failure => |failure| return fileHostFault(failure),
        }
        switch (self.host.path_rename(self.platformHostContext(), source, target)) {
            .success => {},
            .missing => return error.FileNotFound,
            .failure => |failure| return fileHostFault(failure),
        }
    }

    fn processDirectory(self: *Vm, instruction_index: u32, kill: bool) ExecutionError!void {
        if (self.pending_directory == null) {
            const raw = try self.stackStringAt(self.stack.items.len -| 1);
            self.pending_directory = try self.prepareDirectoryOperation(instruction_index, raw, kill);
        }
        var pending = &self.pending_directory.?;
        if (pending.instruction != instruction_index or pending.kill != kill) return error.InvalidInstruction;

        var storage: [maximum_guest_path_bytes + 1]u8 = undefined;
        const result = self.host.directory_read(
            self.platformHostContext(),
            pending.directory,
            pending.index,
            &storage,
        );
        switch (result) {
            .entry => |entry| {
                if (entry.path_length == 0 or entry.path_length > storage.len) {
                    self.discardPendingDirectory();
                    return error.PathFileAccess;
                }
                const canonical = normalizeAbsoluteGuestPath(self.allocator, storage[0..entry.path_length]) catch |fault| {
                    self.discardPendingDirectory();
                    return fault;
                };
                defer self.allocator.free(canonical);
                const separator = lastPathSeparator(canonical) orelse {
                    self.discardPendingDirectory();
                    return error.PathFileAccess;
                };
                const name = canonical[separator + 1 ..];
                const pattern_matches = dosWildcardMatch(pending.pattern, name);
                const deletes_entry = kill and pattern_matches and entry.kind == .file;
                if (pattern_matches and (!kill or entry.kind == .file)) {
                    pending.matches +|= 1;
                    if (deletes_entry) {
                        switch (self.host.path_delete(self.platformHostContext(), canonical)) {
                            .success => {},
                            .missing => {
                                self.discardPendingDirectory();
                                return error.FileNotFound;
                            },
                            .failure => |failure| {
                                self.discardPendingDirectory();
                                return fileHostFault(failure);
                            },
                        }
                    } else {
                        try self.printBytes(name);
                        try self.printNewline();
                        self.host_display_requested = true;
                    }
                }
                // KILL ignores directories. Only a successfully removed file
                // keeps the same live index so the shifted successor is read.
                if (!deletes_entry) pending.index +|= 1;
                self.wait_wake_ns = self.guest_now_ns;
                return error.WouldBlock;
            },
            .end => {
                const matches = pending.matches;
                self.discardPendingDirectory();
                self.discardStackFrom(self.stack.items.len - 1);
                if (matches == 0) return error.FileNotFound;
            },
            .failure => |failure| {
                self.discardPendingDirectory();
                return fileHostFault(failure);
            },
        }
    }

    fn prepareDirectoryOperation(self: *Vm, instruction: u32, raw: []const u8, kill: bool) ExecutionError!PendingDirectory {
        var component_start: usize = 0;
        if (lastPathSeparator(raw)) |separator| {
            component_start = separator + 1;
        } else if (raw.len >= 2 and std.ascii.isAlphabetic(raw[0]) and raw[1] == ':') {
            component_start = 2;
        }
        const raw_directory = raw[0..component_start];
        const raw_pattern = if (raw.len == 0 or component_start == raw.len) "*.*" else raw[component_start..];
        if (!validDosPattern(raw_pattern)) return error.BadFileName;

        const directory = if (raw_directory.len == 0)
            try self.allocator.dupe(u8, self.drive_directories[self.current_drive] orelse "C:\\")
        else
            try self.resolveGuestPath(raw_directory);
        errdefer self.allocator.free(directory);
        const pattern = try self.allocator.dupe(u8, raw_pattern);
        return .{
            .instruction = instruction,
            .kill = kill,
            .directory = directory,
            .pattern = pattern,
        };
    }

    fn setEnvironment(self: *Vm) ExecutionError!void {
        var input_value = try self.popValue();
        defer input_value.deinit(self.allocator);
        const input = switch (input_value) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const separator = std.mem.indexOfScalar(u8, input, '=') orelse blk: {
            if (input.len != 0 and input[input.len - 1] == ';') break :blk input.len - 1;
            return error.IllegalFunctionCall;
        };
        const raw_name = std.mem.trim(u8, input[0..separator], " \t");
        const value = input[separator + 1 ..];
        if (!validEnvironmentName(raw_name) or value.len > maximum_environment_value_bytes) return error.IllegalFunctionCall;

        var existing: ?usize = null;
        for (self.environment.items, 0..) |entry, index| if (std.ascii.eqlIgnoreCase(entry.name, raw_name)) {
            existing = index;
            break;
        };
        if (value.len == 0) {
            if (!self.host.environment_set(self.platformHostContext(), raw_name, "")) return error.HostFailure;
            if (existing) |index| {
                self.environment.items[index].deinit(self.allocator);
                _ = self.environment.orderedRemove(index);
            }
            return;
        }

        const replaced = if (existing) |index| environmentEntryBytes(self.environment.items[index]) else 0;
        const total = environmentListBytes(&self.environment) - replaced + raw_name.len + 1 + value.len + 1;
        if (total > maximum_environment_block_bytes or
            (existing == null and self.environment.items.len >= maximum_environment_entries)) return error.OutOfMemory;
        const owned_name = try self.allocator.alloc(u8, raw_name.len);
        errdefer self.allocator.free(owned_name);
        for (raw_name, 0..) |byte, index| owned_name[index] = std.ascii.toUpper(byte);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        if (existing == null) try self.environment.ensureUnusedCapacity(self.allocator, 1);
        if (!self.host.environment_set(self.platformHostContext(), owned_name, owned_value)) return error.HostFailure;
        if (existing) |index| {
            var previous = self.environment.items[index];
            self.environment.items[index] = .{ .name = owned_name, .value = owned_value };
            previous.deinit(self.allocator);
        } else {
            self.environment.appendAssumeCapacity(.{ .name = owned_name, .value = owned_value });
        }
    }

    fn setWallDate(self: *Vm) ExecutionError!void {
        var input_value = try self.popValue();
        defer input_value.deinit(self.allocator);
        const input = switch (input_value) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const parsed = parseWallDate(input) orelse return error.IllegalFunctionCall;
        var clock = try self.currentWallClock();
        clock.year = parsed.year;
        clock.month = parsed.month;
        clock.day = parsed.day;
        clock.weekday = weekdayForDate(clock.year, clock.month, clock.day);
        if (!self.host.wall_clock_set(self.platformHostContext(), clock)) return error.HostFailure;
    }

    fn setWallTime(self: *Vm) ExecutionError!void {
        var input_value = try self.popValue();
        defer input_value.deinit(self.allocator);
        const input = switch (input_value) {
            .string => |bytes| bytes,
            else => return error.TypeMismatch,
        };
        const parsed = parseWallTime(input) orelse return error.IllegalFunctionCall;
        var clock = try self.currentWallClock();
        clock.hour = parsed.hour;
        clock.minute = parsed.minute;
        clock.second = parsed.second;
        if (!self.host.wall_clock_set(self.platformHostContext(), clock)) return error.HostFailure;
    }

    fn currentWallClock(self: *Vm) ExecutionError!WallClock {
        return switch (self.host.wall_clock(self.platformHostContext())) {
            .value => |clock| if (validWallClock(clock)) clock else error.HostFailure,
            .failure => error.HostFailure,
        };
    }

    fn runProgram(self: *Vm, target: u32, flags: u32) ExecutionError!void {
        if ((flags & ~bytecode.program_run_path) != 0) return error.InvalidInstruction;
        if ((flags & bytecode.program_run_path) != 0) {
            const raw = try self.stackStringAt(self.stack.items.len -| 1);
            const path = try self.resolveGuestPath(raw);
            defer self.allocator.free(path);
            try self.closeAllFiles();
            const owned_path = try self.allocator.dupe(u8, path);
            self.discardStackFrom(self.stack.items.len - 1);
            self.transition = .{ .kind = .run, .path = owned_path };
            self.status = .transition;
            return;
        }
        const restart_at = if (target == bytecode.invalid_index) self.program.module_entry else target;
        if (restart_at >= self.program.instructions.len) return error.InvalidInstruction;
        self.reset() catch |fault| return switch (fault) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidProgram => error.InvalidInstruction,
        };
        self.instruction_pointer = restart_at;
    }

    fn chainProgram(self: *Vm, flags: u32, packed_range: u32) ExecutionError!void {
        if ((flags & ~(bytecode.program_chain_all | bytecode.program_chain_delete)) != 0) return error.InvalidInstruction;
        const raw = try self.stackStringAt(self.stack.items.len -| 1);
        const path = try self.resolveGuestPath(raw);
        defer self.allocator.free(path);
        try self.closeAllFiles();
        const owned_path = try self.allocator.dupe(u8, path);
        self.discardStackFrom(self.stack.items.len - 1);
        self.transition = .{
            .kind = .chain,
            .path = owned_path,
            .preserve_all = (flags & bytecode.program_chain_all) != 0,
            .delete_enabled = (flags & bytecode.program_chain_delete) != 0,
            .delete_first = if ((flags & bytecode.program_chain_delete) != 0) @truncate(packed_range >> 16) else 0,
            .delete_last = if ((flags & bytecode.program_chain_delete) != 0) @truncate(packed_range) else 0,
        };
        self.status = .transition;
    }

    fn shellCommand(self: *Vm) ExecutionError!void {
        const command = try self.stackStringAt(self.stack.items.len -| 1);
        switch (self.host.shell(self.platformHostContext(), command)) {
            .pending => {
                self.wait_wake_ns = self.guest_now_ns +| file_poll_interval_ns;
                return error.WouldBlock;
            },
            .exited => self.discardStackFrom(self.stack.items.len - 1),
            .failure => |failure| return fileHostFault(failure),
        }
    }

    fn systemExit(self: *Vm) ExecutionError!void {
        try self.closeAllFiles();
        self.host.platform_quiesce(self.platformHostContext());
        self.discardStackFrom(0);
        self.status = .halted;
        self.exit_code = 0;
    }

    fn stackStringAt(self: *Vm, index: usize) ExecutionError![]const u8 {
        if (index >= self.stack.items.len) return error.StackUnderflow;
        const value = try self.stackValueAt(index);
        return switch (value) {
            .string => |bytes| bytes,
            else => error.TypeMismatch,
        };
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
        const result = self.host.math(self.host.context, .power, first, second) catch return error.Overflow;
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
        if (self.active_error) |active| {
            if (active.handler_frame == @as(u32, @intCast(frame_depth - 1))) return error.NoResume;
        }
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
                .array => |*array| arrayLogicalPayloadBytes(
                    self.program,
                    array.value_type,
                    array.record_type,
                    array.fixed_string_length,
                    array.storage.len(),
                ) catch 0,
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

    fn onBranch(self: *Vm, first_target: u32, count: u32, use_gosub: bool) ExecutionError!void {
        var value = try self.popValue();
        defer value.deinit(self.allocator);
        const selection = try values.asLong(value);
        if (selection < 0 or selection > 255) return error.IllegalFunctionCall;
        if (selection == 0 or selection > count) return;
        const target_index = @as(usize, first_target) + @as(usize, @intCast(selection - 1));
        if (target_index >= self.program.on_branch_targets.len) return error.InvalidInstruction;
        const target = self.program.on_branch_targets[target_index];
        if (target >= self.program.instructions.len) return error.InvalidInstruction;
        if (use_gosub) return self.gosub(target);
        self.instruction_pointer = target;
    }

    fn returnGosub(self: *Vm, target: u32) ExecutionError!void {
        if (self.gosub_stack.items.len == 0) return error.GosubWithoutReturn;
        const entry = self.gosub_stack.items[self.gosub_stack.items.len - 1];
        if (entry.frame_depth != self.frames.items.len) return error.GosubWithoutReturn;
        _ = self.gosub_stack.pop();
        self.instruction_pointer = if (target == bytecode.invalid_index) entry.return_ip else target;
    }

    fn callBuiltin(self: *Vm, builtin: bytecode.Builtin, argument_count: u32) ExecutionError!void {
        if (argument_count > 3 or argument_count > self.stack.items.len) return error.InvalidInstruction;
        var arguments: [3]values.Value = undefined;
        const count: usize = @intCast(argument_count);
        const first = self.stack.items.len - count;
        var owned_arguments: u64 = 0;
        var borrowed_arguments: u64 = 0;
        for (self.stack.items[first..], 0..) |item, index| {
            arguments[index] = switch (item) {
                .value => |value| blk: {
                    owned_arguments += 1;
                    break :blk value;
                },
                .reference => |cell| blk: {
                    borrowed_arguments += 1;
                    break :blk try cell.value();
                },
            };
        }

        const result = try self.evaluateBuiltin(builtin, arguments[0..count]);
        self.builtin_owned_arguments +%= owned_arguments;
        self.builtin_borrowed_arguments +%= borrowed_arguments;
        self.discardStackFrom(first);
        try self.pushValue(result);
    }

    fn evaluateBuiltin(self: *Vm, builtin: bytecode.Builtin, arguments: []const values.Value) ExecutionError!values.Value {
        return switch (builtin) {
            .abs => absolute(arguments[0]),
            .asc => asciiValue(arguments[0]),
            .atn => self.hostMath(.atn, arguments[0], .{ .single = 0 }),
            .cdbl => values.convert(self.allocator, arguments[0], .double),
            .cos => self.hostMath(.cos, arguments[0], .{ .single = 0 }),
            .csrlin => .{ .integer = self.text.cursorRow() },
            .clng => values.convert(self.allocator, arguments[0], .long),
            .csng => values.convert(self.allocator, arguments[0], .single),
            .cvd => decodeIeeeString(arguments[0], .double),
            .cvdmbf => decodeMbfString(arguments[0], .double),
            .cvi => decodeIeeeString(arguments[0], .integer),
            .cvl => decodeIeeeString(arguments[0], .long),
            .cvs => decodeIeeeString(arguments[0], .single),
            .cvsmbf => decodeMbfString(arguments[0], .single),
            .exp => self.hostMath(.exp, arguments[0], .{ .single = 0 }),
            .fix => truncate(arguments[0]),
            .hex_string => self.basedString(arguments[0], 16),
            .log => self.hostMath(.log, arguments[0], .{ .single = 0 }),
            .sin => self.hostMath(.sin, arguments[0], .{ .single = 0 }),
            .sqr => self.hostMath(.sqr, arguments[0], .{ .single = 0 }),
            .tan => self.hostMath(.tan, arguments[0], .{ .single = 0 }),
            .chr_string => self.character(arguments[0]),
            .cint => values.convert(self.allocator, arguments[0], .integer),
            .instr => self.instr(arguments),
            .int => integerFloor(arguments[0]),
            .left_string => self.leftString(arguments[0], arguments[1]),
            .lcase_string => self.lowerString(arguments[0]),
            .len => .{ .integer = @intCast(arguments[0].string.len) },
            .ltrim_string => self.leftTrim(arguments[0]),
            .mid_string => self.midString(arguments),
            .mkd_string => self.encodeIeeeString(arguments[0], .double),
            .mkdmbf_string => self.encodeMbfString(arguments[0], .double),
            .mki_string => self.encodeIeeeString(arguments[0], .integer),
            .mkl_string => self.encodeIeeeString(arguments[0], .long),
            .mks_string => self.encodeIeeeString(arguments[0], .single),
            .mksmbf_string => self.encodeMbfString(arguments[0], .single),
            .oct_string => self.basedString(arguments[0], 8),
            .peek => error.HostFailure,
            .pos => .{ .integer = self.text.cursorColumn() },
            .right_string => self.rightString(arguments[0], arguments[1]),
            .rtrim_string => self.rightTrim(arguments[0]),
            .screen => self.screenValue(arguments),
            .space_string => self.spaceString(arguments[0]),
            .str_string => self.numberString(arguments[0]),
            .string_string => self.repeatString(arguments[0], arguments[1]),
            .ucase_string => self.upperString(arguments[0]),
            .val => self.val(arguments[0]),
            .eof => self.endOfFile(arguments[0]),
            .fileattr => self.fileAttribute(arguments[0], arguments[1]),
            .freefile => self.freeFileNumber(),
            .loc => self.fileLocation(arguments[0]),
            .lof => self.fileLength(arguments[0]),
            .seek => self.fileSeekPosition(arguments[0]),
            .err => self.errorNumber(),
            .erl => self.errorLine(),
            .inkey_string => self.inkeyString(),
            .rnd => self.randomNumber(arguments),
            .sgn => signum(arguments[0]),
            .timer => self.timerValue(),
            .command_string => .{ .string = try self.allocator.dupe(u8, self.command_line) },
            .date_string => self.dateString(),
            .environ_string => self.environmentString(arguments[0]),
            .time_string => self.timeString(),
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
        if (!fileCanRead(file)) return error.BadFileMode;
        if (file.mode == .random) {
            const offset = @as(u64, file.next_position - 1) * file.record_length;
            return .{ .integer = if (offset >= file.size) -1 else 0 };
        }
        if (file.mode == .binary) return .{ .integer = if (file.next_position - 1 >= file.size) -1 else 0 };
        if (file.mode != .input) return error.BadFileMode;
        if (file.input_head < file.input.items.len) return .{ .integer = 0 };
        if (!file.input_eof) try self.refillFileInput(file);
        return .{ .integer = if (file.input_eof and file.input_head >= file.input.items.len) -1 else 0 };
    }

    fn freeFileNumber(self: *const Vm) values.Value {
        var number: usize = 1;
        while (number <= maximum_file_number) : (number += 1) {
            if (self.fileSlotIndex(number) == null) return .{ .integer = @intCast(number) };
        }
        return .{ .integer = 0 };
    }

    fn fileAttribute(self: *Vm, file_value: values.Value, attribute_value: values.Value) ExecutionError!values.Value {
        const raw_number = try values.asLong(file_value);
        if (raw_number < 1 or raw_number > maximum_file_number) return error.BadFileNumber;
        const file = try self.fileAt(@intCast(raw_number));
        const attribute = try values.asLong(attribute_value);
        if (attribute == 1) return .{ .integer = switch (file.mode) {
            .input => 1,
            .output => 2,
            .random => 4,
            .append => 8,
            .binary => 32,
        } };
        // R4OS intentionally exposes no DOS handle. Attribute 2 is a stable,
        // instance-local virtual slot and therefore remains typed and bounded.
        if (attribute == 2) return .{ .integer = @intCast(raw_number) };
        return error.IllegalFunctionCall;
    }

    fn fileLocation(self: *Vm, file_value: values.Value) ExecutionError!values.Value {
        const raw_number = try values.asLong(file_value);
        if (raw_number < 1 or raw_number > maximum_file_number) return error.BadFileNumber;
        const file = try self.fileAt(@intCast(raw_number));
        const result: u32 = switch (file.mode) {
            .random, .binary => file.next_position - 1,
            .input, .output, .append => (file.next_position - 1) / 128,
        };
        return .{ .long = @intCast(@min(result, @as(u32, std.math.maxInt(i32)))) };
    }

    fn fileLength(self: *Vm, file_value: values.Value) ExecutionError!values.Value {
        const raw_number = try values.asLong(file_value);
        if (raw_number < 1 or raw_number > maximum_file_number) return error.BadFileNumber;
        const file = try self.fileAt(@intCast(raw_number));
        if (file.mode == .random or file.mode == .binary) return .{ .long = @intCast(@min(file.size, @as(u32, std.math.maxInt(i32)))) };
        switch (self.host.file_info(self.fileHostContext(), file.path)) {
            .info => |info| file.size = @max(info.size, file.size),
            .missing => return error.FileNotFound,
            .pending => {
                self.file_io_waits +%= 1;
                self.scheduleFilePoll();
                return error.WouldBlock;
            },
            .failure => |failure| return fileHostFault(failure),
        }
        return .{ .long = @intCast(@min(file.size, @as(u32, std.math.maxInt(i32)))) };
    }

    fn fileSeekPosition(self: *Vm, file_value: values.Value) ExecutionError!values.Value {
        const raw_number = try values.asLong(file_value);
        if (raw_number < 1 or raw_number > maximum_file_number) return error.BadFileNumber;
        const file = try self.fileAt(@intCast(raw_number));
        return .{ .long = @intCast(@min(file.next_position, @as(u32, std.math.maxInt(i32)))) };
    }

    fn errorLine(self: *const Vm) values.Value {
        const diagnostic = self.trapped_diagnostic orelse return .{ .long = 0 };
        if (diagnostic.instruction >= self.program.instruction_metadata.len) return .{ .long = 0 };
        return .{ .long = self.program.instruction_metadata[diagnostic.instruction].basic_line };
    }

    fn errorNumber(self: *const Vm) values.Value {
        const diagnostic = self.trapped_diagnostic orelse return .{ .integer = 0 };
        return .{ .integer = @intCast(diagnostic.qbasicErrorNumber()) };
    }

    fn inkeyString(self: *Vm) ExecutionError!values.Value {
        const byte = self.popKeyboardByte() orelse return .{ .string = try self.allocator.alloc(u8, 0) };
        const extended = byte == 0 and self.queuedInputBytes() != 0;
        const result = try self.allocator.alloc(u8, if (extended) 2 else 1);
        result[0] = byte;
        if (extended) result[1] = self.popKeyboardByte().?;
        return .{ .string = result };
    }

    fn randomNumber(self: *Vm, arguments: []const values.Value) ExecutionError!values.Value {
        if (arguments.len > 1) return error.InvalidInstruction;
        if (arguments.len == 0) return .{ .single = self.nextRandom() };
        const argument = try values.asDouble(arguments[0]);
        if (!std.math.isFinite(argument)) return error.IllegalFunctionCall;
        if (argument < 0) {
            self.seedNegativeRandom(try values.asSingle(arguments[0]));
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
        const fraction = @as(f32, @floatFromInt(self.guest_now_ns % std.time.ns_per_s)) /
            @as(f32, @floatFromInt(std.time.ns_per_s));
        return .{ .single = switch (self.host.wall_clock(self.platformHostContext())) {
            .value => |clock| if (validWallClock(clock))
                @as(f32, @floatFromInt(clock.secondsSinceMidnight())) + fraction
            else
                self.timerSeconds(),
            .failure => self.timerSeconds(),
        } };
    }

    fn dateString(self: *Vm) ExecutionError!values.Value {
        const clock = try self.currentWallClock();
        return .{ .string = try std.fmt.allocPrint(self.allocator, "{d:0>2}-{d:0>2}-{d:0>4}", .{
            clock.month,
            clock.day,
            clock.year,
        }) };
    }

    fn timeString(self: *Vm) ExecutionError!values.Value {
        const clock = try self.currentWallClock();
        return .{ .string = try std.fmt.allocPrint(self.allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{
            clock.hour,
            clock.minute,
            clock.second,
        }) };
    }

    fn environmentString(self: *Vm, argument: values.Value) ExecutionError!values.Value {
        switch (argument) {
            .string => |name| {
                if (!validEnvironmentName(name)) return .{ .string = try self.allocator.alloc(u8, 0) };
                for (self.environment.items) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                        return .{ .string = try self.allocator.dupe(u8, entry.value) };
                    }
                }
                return .{ .string = try self.allocator.alloc(u8, 0) };
            },
            .integer, .long, .single, .double => {
                const raw_index = try values.asLong(argument);
                if (raw_index < 1) return error.IllegalFunctionCall;
                const index: usize = @intCast(raw_index - 1);
                if (index >= self.environment.items.len) return .{ .string = try self.allocator.alloc(u8, 0) };
                const entry = self.environment.items[index];
                return .{ .string = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.name, entry.value }) };
            },
        }
    }

    fn hostMath(self: *Vm, operation: MathOperation, input: values.Value, unused: values.Value) ExecutionError!values.Value {
        _ = unused;
        const number = try values.asDouble(input);
        switch (operation) {
            .log => if (number <= 0) return error.IllegalFunctionCall,
            .sqr => if (number < 0) return error.IllegalFunctionCall,
            else => {},
        }
        const result = self.host.math(self.host.context, operation, number, 0) catch return error.Overflow;
        if (!std.math.isFinite(result)) return error.Overflow;
        if (input.valueType() == .double) return .{ .double = result };
        const single: f32 = @floatCast(result);
        if (!std.math.isFinite(single)) return error.Overflow;
        return .{ .single = single };
    }

    fn encodeIeeeString(self: *Vm, input: values.Value, target: bytecode.ValueType) ExecutionError!values.Value {
        const length: usize = switch (target) {
            .integer => 2,
            .long, .single => 4,
            .double => 8,
            .string => return error.TypeMismatch,
        };
        const raw: u64 = switch (target) {
            .integer => @as(u16, @bitCast(try values.asInteger(input))),
            .long => @as(u32, @bitCast(try values.asLong(input))),
            .single => @as(u32, @bitCast(try values.asSingle(input))),
            .double => @bitCast(try values.asDouble(input)),
            .string => unreachable,
        };
        const result = try self.allocator.alloc(u8, length);
        writeUnsignedLittle(result, raw);
        return .{ .string = result };
    }

    fn encodeMbfString(self: *Vm, input: values.Value, target: bytecode.ValueType) ExecutionError!values.Value {
        const length: usize = switch (target) {
            .single => 4,
            .double => 8,
            else => return error.TypeMismatch,
        };
        const raw = switch (target) {
            .single => @as(u64, try encodeMbfSingle(try values.asSingle(input))),
            .double => try encodeMbfDouble(try values.asDouble(input)),
            else => unreachable,
        };
        const result = try self.allocator.alloc(u8, length);
        writeUnsignedLittle(result, raw);
        return .{ .string = result };
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
        if (count < 0 or count > values.maximum_string_bytes) return error.IllegalFunctionCall;
        const length = @min(string_value.string.len, @as(usize, @intCast(count)));
        return .{ .string = try self.allocator.dupe(u8, string_value.string[0..length]) };
    }

    fn rightString(self: *Vm, string_value: values.Value, count_value: values.Value) ExecutionError!values.Value {
        const count = try values.asLong(count_value);
        if (count < 0 or count > values.maximum_string_bytes) return error.IllegalFunctionCall;
        const length = @min(string_value.string.len, @as(usize, @intCast(count)));
        return .{ .string = try self.allocator.dupe(u8, string_value.string[string_value.string.len - length ..]) };
    }

    fn leftTrim(self: *Vm, input: values.Value) ExecutionError!values.Value {
        var start: usize = 0;
        while (start < input.string.len and input.string[start] == ' ') start += 1;
        return .{ .string = try self.allocator.dupe(u8, input.string[start..]) };
    }

    fn rightTrim(self: *Vm, input: values.Value) ExecutionError!values.Value {
        var end = input.string.len;
        while (end != 0 and input.string[end - 1] == ' ') end -= 1;
        return .{ .string = try self.allocator.dupe(u8, input.string[0..end]) };
    }

    fn midString(self: *Vm, arguments: []const values.Value) ExecutionError!values.Value {
        const start = try values.asLong(arguments[1]);
        if (start < 1 or start > values.maximum_string_bytes) return error.IllegalFunctionCall;
        const start_index: usize = @intCast(start - 1);
        if (start_index >= arguments[0].string.len) return .{ .string = try self.allocator.dupe(u8, "") };
        var end = arguments[0].string.len;
        if (arguments.len == 3) {
            const count = try values.asLong(arguments[2]);
            if (count < 1 or count > values.maximum_string_bytes) return error.IllegalFunctionCall;
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

    fn repeatString(self: *Vm, count_value: values.Value, character_value: values.Value) ExecutionError!values.Value {
        const count = try values.asLong(count_value);
        if (count < 0 or count > values.maximum_string_bytes) return error.IllegalFunctionCall;
        const repeated_byte: u8 = switch (character_value) {
            .string => |bytes| if (bytes.len == 0) return error.IllegalFunctionCall else bytes[0],
            else => blk: {
                const number = try values.asLong(character_value);
                if (number < 0 or number > 255) return error.IllegalFunctionCall;
                break :blk @intCast(number);
            },
        };
        const result = try self.allocator.alloc(u8, @intCast(count));
        @memset(result, repeated_byte);
        return .{ .string = result };
    }

    fn basedString(self: *Vm, input: values.Value, base: u8) ExecutionError!values.Value {
        const number = try values.asDouble(input);
        var storage: [32]u8 = undefined;
        const formatted = integer: {
            if (values.roundToInteger(number)) |short| {
                const bits: u16 = @bitCast(short);
                break :integer if (base == 16)
                    std.fmt.bufPrint(&storage, "{X}", .{bits}) catch return error.Overflow
                else
                    std.fmt.bufPrint(&storage, "{o}", .{bits}) catch return error.Overflow;
            } else |fault| switch (fault) {
                error.Overflow => {},
                else => return fault,
            }
            const long = try values.roundToLong(number);
            const bits: u32 = @bitCast(long);
            break :integer if (base == 16)
                std.fmt.bufPrint(&storage, "{X}", .{bits}) catch return error.Overflow
            else
                std.fmt.bufPrint(&storage, "{o}", .{bits}) catch return error.Overflow;
        };
        return .{ .string = try self.allocator.dupe(u8, formatted) };
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

    fn lowerString(self: *Vm, input: values.Value) ExecutionError!values.Value {
        const result = try self.allocator.dupe(u8, input.string);
        for (result) |*byte| byte.* = std.ascii.toLower(byte.*);
        return .{ .string = result };
    }

    fn screenValue(self: *Vm, arguments: []const values.Value) ExecutionError!values.Value {
        if (arguments.len < 2 or arguments.len > 3) return error.InvalidInstruction;
        const row = try values.asLong(arguments[0]);
        const column = try values.asLong(arguments[1]);
        const color = arguments.len == 3 and try values.asLong(arguments[2]) != 0;
        return .{ .integer = self.text.screenValue(row, column, color) catch return error.IllegalFunctionCall };
    }

    fn val(self: *Vm, input: values.Value) ExecutionError!values.Value {
        const trimmed = std.mem.trimStart(u8, input.string, " \t\r\n");
        if (trimmed.len == 0) return .{ .double = 0 };
        if (trimmed.len >= 2 and trimmed[0] == '&' and
            (trimmed[1] == 'H' or trimmed[1] == 'h' or trimmed[1] == 'O' or trimmed[1] == 'o'))
        {
            const base: u8 = if (trimmed[1] == 'H' or trimmed[1] == 'h') 16 else 8;
            var cursor: usize = 2;
            var raw: u64 = 0;
            while (cursor < trimmed.len) : (cursor += 1) {
                const digit = std.fmt.charToDigit(trimmed[cursor], base) catch break;
                raw = std.math.mul(u64, raw, base) catch return error.Overflow;
                raw = std.math.add(u64, raw, digit) catch return error.Overflow;
                if (raw > std.math.maxInt(u32)) return error.Overflow;
            }
            if (cursor == 2) return .{ .double = 0 };
            if (raw <= std.math.maxInt(u16)) {
                const signed: i16 = @bitCast(@as(u16, @intCast(raw)));
                return .{ .double = @floatFromInt(signed) };
            }
            const signed: i32 = @bitCast(@as(u32, @intCast(raw)));
            return .{ .double = @floatFromInt(signed) };
        }
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

    fn stackValueAt(self: *Vm, index: usize) ExecutionError!values.Value {
        if (index >= self.stack.items.len) return error.StackUnderflow;
        return switch (self.stack.items[index]) {
            .value => |value| value,
            .reference => |reference| try reference.value(),
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
        const frame = self.frames.items[self.frames.items.len - 1];
        if (index >= self.program.procedures[frame.procedure_id].locals.len) return error.InvalidInstruction;
        const variable = self.program.procedures[frame.procedure_id].locals[index];
        if (variable.backing_global_index != bytecode.invalid_index) {
            return self.globalCellAt(variable.backing_global_index);
        }
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
        return self.makeDiagnosticNumber(code, instruction, 0);
    }

    fn makeDiagnosticNumber(self: *Vm, code: RuntimeCode, instruction: u32, error_number: u8) RuntimeDiagnostic {
        const span: frontend.Span = if (instruction < self.program.instructions.len)
            self.readInstructionMetadata(instruction).span
        else
            .{ .start = 0, .end = 0, .line = 1, .column = 1 };
        return .{
            .code = code,
            .file_name = self.program.fileNameForSpan(span),
            .span = span,
            .instruction = instruction,
            .error_number = error_number,
        };
    }
};

const UsingFieldKind = enum {
    first_character,
    fixed_string,
    variable_string,
    number,
};

fn formatQuickBasicFloat(
    storage: *[numeric_format_buffer_bytes]u8,
    number: anytype,
    significant_digits: u8,
    exponent_marker: u8,
) ExecutionError![]const u8 {
    if (!std.math.isFinite(number)) return error.Overflow;
    if (number == 0) return std.fmt.bufPrint(storage, "0", .{}) catch return error.Overflow;

    var scientific_storage: [numeric_format_buffer_bytes]u8 = undefined;
    const scientific = std.fmt.bufPrint(
        &scientific_storage,
        "{e:.[1]}",
        .{ number, significant_digits - 1 },
    ) catch return error.Overflow;
    const scientific_marker = std.mem.indexOfAny(u8, scientific, "eE") orelse return error.Overflow;
    const exponent = std.fmt.parseInt(i32, scientific[scientific_marker + 1 ..], 10) catch return error.Overflow;

    const magnitude = @abs(number);
    const lower: @TypeOf(number) = if (significant_digits == 7) 1.0e-6 else 1.0e-15;
    const upper: @TypeOf(number) = if (significant_digits == 7) 1.0e7 else 1.0e16;
    if (magnitude >= lower and magnitude < upper) {
        const decimal_places: usize = @intCast(@max(0, @as(i32, significant_digits - 1) - exponent));
        var result = std.fmt.bufPrint(storage, "{d:.[1]}", .{ number, decimal_places }) catch return error.Overflow;
        if (std.mem.indexOfScalar(u8, result, '.')) |decimal| {
            var end = result.len;
            while (end > decimal + 1 and result[end - 1] == '0') end -= 1;
            if (end == decimal + 1) end = decimal;
            result = result[0..end];
        }
        const zero = if (result.len >= 2 and result[0] == '0' and result[1] == '.')
            @as(?usize, 0)
        else if (result.len >= 3 and result[0] == '-' and result[1] == '0' and result[2] == '.')
            @as(?usize, 1)
        else
            null;
        if (zero) |index| {
            std.mem.copyForwards(u8, storage[index .. result.len - 1], storage[index + 1 .. result.len]);
            result = storage[0 .. result.len - 1];
        }
        return result;
    }

    var mantissa_end = scientific_marker;
    while (mantissa_end != 0 and scientific[mantissa_end - 1] == '0') mantissa_end -= 1;
    if (mantissa_end != 0 and scientific[mantissa_end - 1] == '.') mantissa_end -= 1;
    @memcpy(storage[0..mantissa_end], scientific[0..mantissa_end]);
    var output = mantissa_end;
    storage[output] = exponent_marker;
    output += 1;
    storage[output] = if (exponent < 0) '-' else '+';
    output += 1;
    const absolute_exponent: u32 = @intCast(@abs(exponent));
    const exponent_text = std.fmt.bufPrint(storage[output..], "{d}", .{absolute_exponent}) catch return error.Overflow;
    output += exponent_text.len;
    return storage[0..output];
}

const UsingField = struct {
    kind: UsingFieldKind,
    start: usize,
    end: usize,
};

const UsingNumberSpec = struct {
    end: usize,
    integer_positions: usize = 0,
    fraction_positions: usize = 0,
    digit_positions: usize = 0,
    exponent_digits: usize = 0,
    leading_sign: bool = false,
    trailing_sign: bool = false,
    trailing_plus: bool = false,
    star_fill: bool = false,
    currency: bool = false,
    grouping: bool = false,
};

fn usingFieldAt(format: []const u8, start: usize) ?UsingField {
    if (start >= format.len) return null;
    if (format[start] == '!') return .{ .kind = .first_character, .start = start, .end = start + 1 };
    if (format[start] == '&') return .{ .kind = .variable_string, .start = start, .end = start + 1 };
    if (format[start] == '\\') {
        var end = start + 1;
        while (end < format.len and format[end] == ' ') end += 1;
        if (end < format.len and format[end] == '\\') {
            return .{ .kind = .fixed_string, .start = start, .end = end + 1 };
        }
    }
    const number = parseUsingNumberAt(format, start) orelse return null;
    return .{ .kind = .number, .start = start, .end = number.end };
}

fn parseUsingNumberSpec(spec: []const u8) ?UsingNumberSpec {
    const result = parseUsingNumberAt(spec, 0) orelse return null;
    return if (result.end == spec.len) result else null;
}

fn parseUsingNumberAt(format: []const u8, start: usize) ?UsingNumberSpec {
    if (start >= format.len) return null;
    var result = UsingNumberSpec{ .end = start };
    var cursor = start;
    if (format[cursor] == '+') {
        result.leading_sign = true;
        cursor += 1;
    }
    if (cursor + 2 < format.len and format[cursor] == '*' and format[cursor + 1] == '*' and format[cursor + 2] == '$') {
        result.star_fill = true;
        result.currency = true;
        result.digit_positions += 3;
        cursor += 3;
    } else if (cursor + 1 < format.len and format[cursor] == '*' and format[cursor + 1] == '*') {
        result.star_fill = true;
        result.digit_positions += 2;
        cursor += 2;
    } else if (cursor + 1 < format.len and format[cursor] == '$' and format[cursor + 1] == '$') {
        result.currency = true;
        result.digit_positions += 2;
        cursor += 2;
    }

    var decimal_seen = false;
    var actual_digits: usize = 0;
    while (cursor < format.len) {
        switch (format[cursor]) {
            '#' => {
                actual_digits += 1;
                result.digit_positions += 1;
                if (decimal_seen) result.fraction_positions += 1 else result.integer_positions += 1;
                cursor += 1;
            },
            '.' => {
                if (decimal_seen) break;
                decimal_seen = true;
                cursor += 1;
            },
            ',' => {
                if (decimal_seen or cursor + 1 >= format.len or
                    (format[cursor + 1] != '#' and format[cursor + 1] != '.')) break;
                result.grouping = true;
                result.digit_positions += 1;
                cursor += 1;
            },
            else => break,
        }
    }
    if (actual_digits == 0) return null;
    if (cursor < format.len and format[cursor] == '^') {
        const first = cursor;
        while (cursor < format.len and format[cursor] == '^' and cursor - first < 5) cursor += 1;
        const count = cursor - first;
        if (count < 4) cursor = first else result.exponent_digits = if (count == 5) 3 else 2;
    }
    if (cursor < format.len and (format[cursor] == '+' or format[cursor] == '-')) {
        result.trailing_sign = true;
        result.trailing_plus = format[cursor] == '+';
        cursor += 1;
    }
    result.end = cursor;
    return result;
}

fn formatUsingFixed(storage: *[512]u8, magnitude: f64, spec: UsingNumberSpec) ExecutionError![]const u8 {
    var plain_storage: [512]u8 = undefined;
    const plain = std.fmt.bufPrint(&plain_storage, "{d:.[1]}", .{ magnitude, spec.fraction_positions }) catch return error.Overflow;
    const decimal = std.mem.indexOfScalar(u8, plain, '.') orelse plain.len;
    const skip_zero: usize = @intFromBool(spec.integer_positions == 0 and decimal == 1 and plain[0] == '0');
    if (!spec.grouping) {
        const result = plain[skip_zero..];
        @memcpy(storage[0..result.len], result);
        return storage[0..result.len];
    }

    const integer_start = skip_zero;
    const integer_length = decimal - integer_start;
    var output: usize = 0;
    for (plain[integer_start..decimal], 0..) |byte, index| {
        if (index != 0 and (integer_length - index) % 3 == 0) {
            storage[output] = ',';
            output += 1;
        }
        storage[output] = byte;
        output += 1;
    }
    if (decimal < plain.len) {
        @memcpy(storage[output .. output + plain.len - decimal], plain[decimal..]);
        output += plain.len - decimal;
    }
    return storage[0..output];
}

fn formatUsingExponent(storage: *[512]u8, magnitude: f64, spec: UsingNumberSpec) ExecutionError![]const u8 {
    var scientific_storage: [512]u8 = undefined;
    const precision = if (spec.integer_positions == 0 and spec.fraction_positions != 0)
        spec.fraction_positions - 1
    else
        spec.fraction_positions;
    const scientific = std.fmt.bufPrint(&scientific_storage, "{e:.[1]}", .{ magnitude, precision }) catch return error.Overflow;
    const marker = std.mem.indexOfAny(u8, scientific, "eE") orelse return error.Overflow;
    var exponent = std.fmt.parseInt(i32, scientific[marker + 1 ..], 10) catch return error.Overflow;
    var output: usize = 0;
    if (spec.integer_positions == 0) {
        storage[output] = '.';
        output += 1;
        exponent += 1;
        for (scientific[0..marker]) |byte| {
            if (byte == '.') continue;
            storage[output] = byte;
            output += 1;
        }
    } else {
        @memcpy(storage[0..marker], scientific[0..marker]);
        output = marker;
    }
    storage[output] = 'E';
    output += 1;
    storage[output] = if (exponent < 0) '-' else '+';
    output += 1;
    const absolute_exponent: u32 = @intCast(@abs(exponent));
    var exponent_storage: [16]u8 = undefined;
    const exponent_text = std.fmt.bufPrint(&exponent_storage, "{d}", .{absolute_exponent}) catch return error.Overflow;
    const padding = spec.exponent_digits -| exponent_text.len;
    @memset(storage[output .. output + padding], '0');
    output += padding;
    @memcpy(storage[output .. output + exponent_text.len], exponent_text);
    output += exponent_text.len;
    return storage[0..output];
}

const InputField = struct {
    bytes: []const u8,
    quoted: bool = false,
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
        while (cursor.* < bytes.len) {
            if (bytes[cursor.*] != '"') {
                cursor.* += 1;
                continue;
            }
            if (cursor.* + 1 < bytes.len and bytes[cursor.* + 1] == '"') {
                cursor.* += 2;
                continue;
            }
            break;
        }
        if (cursor.* >= bytes.len) return null;
        const result = bytes[start..cursor.*];
        cursor.* += 1;
        while (cursor.* < bytes.len and (bytes[cursor.*] == ' ' or bytes[cursor.*] == '\t')) cursor.* += 1;
        if (cursor.* < bytes.len) {
            if (bytes[cursor.*] != ',') return null;
            cursor.* += 1;
        }
        return .{ .bytes = result, .quoted = true };
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

const SequentialFieldResult = union(enum) {
    field: InputField,
    need_more,
    end,
};

fn nextSequentialField(bytes: []const u8, cursor: *usize, eof: bool) SequentialFieldResult {
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        if (byte != ' ' and byte != '\t' and byte != ',' and byte != '\r' and byte != '\n') break;
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return if (eof) .end else .need_more;
    if (bytes[cursor.*] == '"') {
        cursor.* += 1;
        const start = cursor.*;
        while (cursor.* < bytes.len) {
            if (bytes[cursor.*] != '"') {
                cursor.* += 1;
                continue;
            }
            if (cursor.* + 1 < bytes.len and bytes[cursor.* + 1] == '"') {
                cursor.* += 2;
                continue;
            }
            break;
        }
        if (cursor.* >= bytes.len) return if (eof) .end else .need_more;
        const result = bytes[start..cursor.*];
        cursor.* += 1;
        while (cursor.* < bytes.len and bytes[cursor.*] != ',' and bytes[cursor.*] != '\r' and bytes[cursor.*] != '\n') cursor.* += 1;
        if (cursor.* < bytes.len) {
            if (bytes[cursor.*] == '\r' or bytes[cursor.*] == '\n') {
                if (!eof and cursor.* + 1 == bytes.len) return .need_more;
                consumeLineEnding(bytes, cursor);
            } else {
                cursor.* += 1;
            }
        }
        return .{ .field = .{ .bytes = result, .quoted = true } };
    }
    const start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != ',' and bytes[cursor.*] != '\r' and bytes[cursor.*] != '\n') cursor.* += 1;
    if (cursor.* == bytes.len and !eof) return .need_more;
    const result = std.mem.trim(u8, bytes[start..cursor.*], " \t");
    if (cursor.* < bytes.len) {
        if (bytes[cursor.*] == '\r' or bytes[cursor.*] == '\n') {
            if (!eof and cursor.* + 1 == bytes.len) return .need_more;
            consumeLineEnding(bytes, cursor);
        } else {
            cursor.* += 1;
        }
    }
    return .{ .field = .{ .bytes = result } };
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
    return seed & random_mask;
}

fn randomValue(state: u32) f32 {
    return @as(f32, @floatFromInt(state & random_mask)) / 16_777_216.0;
}

fn legacyFileMode(value: values.Value) ExecutionError!bytecode.FileMode {
    const text = switch (value) {
        .string => |bytes| std.mem.trim(u8, bytes, " \t"),
        else => return error.TypeMismatch,
    };
    if (text.len != 1) return error.BadFileMode;
    return switch (std.ascii.toUpper(text[0])) {
        'I' => .input,
        'O' => .output,
        'A' => .append,
        'R' => .random,
        'B' => .binary,
        else => error.BadFileMode,
    };
}

fn validateFileAccess(mode: bytecode.FileMode, access: bytecode.FileAccess) ExecutionError!void {
    const valid = switch (mode) {
        .input => access == .default or access == .read,
        .output, .append => access == .default or access == .write,
        .random, .binary => true,
    };
    if (!valid) return error.BadFileMode;
}

fn fileCanRead(file: *const SequentialFile) bool {
    return switch (file.mode) {
        .input => true,
        .output, .append => false,
        .random, .binary => file.access == .default or file.access == .read or file.access == .read_write,
    };
}

fn fileCanWrite(file: *const SequentialFile) bool {
    return switch (file.mode) {
        .input => false,
        .output, .append => true,
        .random, .binary => file.access == .default or file.access == .write or file.access == .read_write,
    };
}

fn fileByteRange(file: *const SequentialFile, first_unit: u32, last_unit: u32) ExecutionError!FileRange {
    if (file.mode == .input or file.mode == .output or file.mode == .append or last_unit == std.math.maxInt(u32)) {
        return .{ .first = 0, .last = std.math.maxInt(u32) };
    }
    const scale: u64 = if (file.mode == .random) file.record_length else 1;
    const first = @as(u64, first_unit - 1) * scale;
    const exclusive_last = @as(u64, last_unit) * scale;
    if (first > std.math.maxInt(u32) or exclusive_last == 0 or exclusive_last - 1 > std.math.maxInt(u32)) {
        return error.BadRecordNumber;
    }
    return .{ .first = @intCast(first), .last = @intCast(exclusive_last - 1) };
}

fn referenceByteLength(program: *const bytecode.Program, reference: Reference) ExecutionError!usize {
    return switch (reference) {
        .integer => 2,
        .long, .single => 4,
        .double => 8,
        .cell => |cell| ownedByteLength(program, &(resolveCellConst(cell) orelse return error.InvalidInstruction).owned),
    };
}

fn ownedByteLength(program: *const bytecode.Program, owned: *const OwnedValue) ExecutionError!usize {
    return switch (owned.*) {
        .scalar => |value| switch (value) {
            .integer => 2,
            .long, .single => 4,
            .double => 8,
            .string => |bytes| bytes.len,
        },
        .fixed_string => |string| string.length,
        .field_string => |string| switch (string.value) {
            .string => |bytes| bytes.len,
            else => error.InvalidInstruction,
        },
        .record => |record| if (record.record_type < program.record_types.len)
            program.record_types[record.record_type].byte_size
        else
            error.InvalidInstruction,
        .array => |array| switch (array.storage) {
            .integer => |items| items.len * 2,
            .long => |items| items.len * 4,
            .single => |items| items.len * 4,
            .double => |items| items.len * 8,
            .cells => |items| blk: {
                var total: usize = 0;
                for (items) |*item| {
                    const resolved = resolveCellConst(item) orelse return error.InvalidInstruction;
                    total = std.math.add(usize, total, try ownedByteLength(program, &resolved.owned)) catch return error.OutOfMemory;
                }
                break :blk total;
            },
        },
    };
}

fn encodeReference(program: *const bytecode.Program, reference: Reference, out: []u8) ExecutionError!void {
    if (out.len != try referenceByteLength(program, reference)) return error.InvalidInstruction;
    switch (reference) {
        .integer => |number| std.mem.writeInt(u16, out[0..2], @bitCast(number.*), .little),
        .long => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number.*), .little),
        .single => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number.*), .little),
        .double => |number| std.mem.writeInt(u64, out[0..8], @bitCast(number.*), .little),
        .cell => |cell| try encodeOwned(program, &(resolveCellConst(cell) orelse return error.InvalidInstruction).owned, out),
    }
}

fn encodeOwned(program: *const bytecode.Program, owned: *const OwnedValue, out: []u8) ExecutionError!void {
    switch (owned.*) {
        .scalar => |value| switch (value) {
            .integer => |number| std.mem.writeInt(u16, out[0..2], @bitCast(number), .little),
            .long => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number), .little),
            .single => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number), .little),
            .double => |number| std.mem.writeInt(u64, out[0..8], @bitCast(number), .little),
            .string => |bytes| @memcpy(out, bytes),
        },
        .fixed_string => |string| @memcpy(out, string.value.string),
        .field_string => |string| @memcpy(out, string.value.string),
        .record => |record| {
            var temporary: Cell = .{ .owned = .{ .record = record } };
            try encodeRecord(program, &temporary, out);
        },
        .array => |array| switch (array.storage) {
            .integer => |items| @memcpy(out, std.mem.sliceAsBytes(items)),
            .long => |items| @memcpy(out, std.mem.sliceAsBytes(items)),
            .single => |items| @memcpy(out, std.mem.sliceAsBytes(items)),
            .double => |items| @memcpy(out, std.mem.sliceAsBytes(items)),
            .cells => |items| {
                var cursor: usize = 0;
                for (items) |*item| {
                    const resolved = resolveCellConst(item) orelse return error.InvalidInstruction;
                    const length = try ownedByteLength(program, &resolved.owned);
                    try encodeOwned(program, &resolved.owned, out[cursor .. cursor + length]);
                    cursor += length;
                }
            },
        },
    }
}

fn decodeReference(program: *const bytecode.Program, reference: Reference, bytes: []const u8) ExecutionError!void {
    if (bytes.len != try referenceByteLength(program, reference)) return error.InvalidInstruction;
    switch (reference) {
        .integer => |number| number.* = @bitCast(std.mem.readInt(u16, bytes[0..2], .little)),
        .long => |number| number.* = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)),
        .single => |number| number.* = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)),
        .double => |number| number.* = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)),
        .cell => |cell| try decodeOwned(program, &(resolveCell(cell) orelse return error.InvalidInstruction).owned, bytes),
    }
}

fn decodeOwned(program: *const bytecode.Program, owned: *OwnedValue, bytes: []const u8) ExecutionError!void {
    switch (owned.*) {
        .scalar => |*value| switch (value.*) {
            .integer => value.* = .{ .integer = @bitCast(std.mem.readInt(u16, bytes[0..2], .little)) },
            .long => value.* = .{ .long = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)) },
            .single => value.* = .{ .single = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)) },
            .double => value.* = .{ .double = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)) },
            .string => |out| @memcpy(out, bytes),
        },
        .fixed_string => |*string| @memcpy(string.value.string, bytes),
        .field_string => |*string| @memcpy(string.value.string, bytes),
        .record => |record| {
            var temporary: Cell = .{ .owned = .{ .record = record } };
            try decodeRecord(program, &temporary, bytes);
        },
        .array => |*array| switch (array.storage) {
            .integer => |items| @memcpy(std.mem.sliceAsBytes(items), bytes),
            .long => |items| @memcpy(std.mem.sliceAsBytes(items), bytes),
            .single => |items| @memcpy(std.mem.sliceAsBytes(items), bytes),
            .double => |items| @memcpy(std.mem.sliceAsBytes(items), bytes),
            .cells => |items| {
                var cursor: usize = 0;
                for (items) |*item| {
                    const resolved = resolveCell(item) orelse return error.InvalidInstruction;
                    const length = try ownedByteLength(program, &resolved.owned);
                    try decodeOwned(program, &resolved.owned, bytes[cursor .. cursor + length]);
                    cursor += length;
                }
            },
        },
    }
}

fn cellHasFieldBinding(cell: *const Cell, generation: u64) bool {
    return switch (cell.*) {
        .alias => false,
        .owned => |owned| switch (owned) {
            .field_string => |field| field.file_generation == generation,
            .record => |record| blk: {
                for (record.fields) |*field| if (cellHasFieldBinding(field, generation)) break :blk true;
                break :blk false;
            },
            .array => |array| switch (array.storage) {
                .cells => |items| blk: {
                    for (items) |*item| if (cellHasFieldBinding(item, generation)) break :blk true;
                    break :blk false;
                },
                else => false,
            },
            else => false,
        },
    };
}

fn fileHostFault(failure: FileHostError) ExecutionError {
    return switch (failure) {
        .unavailable => error.HostFailure,
        .not_found => error.FileNotFound,
        .path_not_found => error.PathNotFound,
        .file_exists => error.FileExists,
        .disk_full => error.DiskFull,
        .too_many_files => error.TooManyFiles,
        .lock_violation => error.PermissionDenied,
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

fn normalizeAbsoluteGuestPath(allocator: std.mem.Allocator, input: []const u8) ExecutionError![]u8 {
    if (!isAbsoluteGuestPath(input) or input.len > maximum_guest_path_bytes) return error.BadFileName;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacityPrecise(allocator, @min(input.len, maximum_guest_path_bytes));
    try result.appendSlice(allocator, &.{ std.ascii.toUpper(input[0]), ':', '\\' });

    var component_starts: [256]u16 = undefined;
    var depth: usize = 0;
    var cursor: usize = 3;
    while (cursor <= input.len) {
        const start = cursor;
        while (cursor < input.len and input[cursor] != '\\' and input[cursor] != '/') : (cursor += 1) {}
        const component = input[start..cursor];
        cursor += 1;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.PathFileAccess;
            depth -= 1;
            const component_start: usize = component_starts[depth];
            result.items.len = if (component_start == 3) 3 else component_start - 1;
            continue;
        }
        if (component.len > 255 or component[component.len - 1] == ' ' or component[component.len - 1] == '.' or
            containsInvalidPathByte(component) or std.mem.indexOfScalar(u8, component, ':') != null or
            isReservedDevicePath(component) or depth == component_starts.len)
        {
            return error.BadFileName;
        }
        if (result.items.len != 3) try result.append(allocator, '\\');
        component_starts[depth] = @intCast(result.items.len);
        depth += 1;
        try result.appendSlice(allocator, component);
        if (result.items.len > maximum_guest_path_bytes) return error.BadFileName;
    }
    return result.toOwnedSlice(allocator);
}

fn deinitEnvironmentList(allocator: std.mem.Allocator, list: *std.ArrayList(EnvironmentValue)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
    list.* = .empty;
}

fn environmentEntryBytes(entry: EnvironmentValue) usize {
    return entry.name.len + 1 + entry.value.len + 1;
}

fn environmentListBytes(list: *const std.ArrayList(EnvironmentValue)) usize {
    var total: usize = 0;
    for (list.items) |entry| total += environmentEntryBytes(entry);
    return total;
}

fn validEnvironmentName(name: []const u8) bool {
    if (name.len == 0 or name.len > maximum_environment_name_bytes) return false;
    for (name) |byte| if (byte < 0x21 or byte > 0x7E or byte == '=') return false;
    return true;
}

fn validDosPattern(pattern: []const u8) bool {
    if (pattern.len == 0 or pattern.len > 255 or pattern[pattern.len - 1] == ' ') return false;
    for (pattern) |byte| {
        if (byte < 0x20 or byte == 0x7F or byte == '"' or byte == '<' or byte == '>' or byte == '|' or
            byte == ':' or byte == '\\' or byte == '/') return false;
    }
    if (std.mem.indexOfAny(u8, pattern, "*?") == null and isReservedDevicePath(pattern)) return false;
    return true;
}

fn dosWildcardMatch(pattern: []const u8, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(pattern, "*.*")) return true;
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_index: ?usize = null;
    var star_name_index: usize = 0;
    while (name_index < name.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or std.ascii.toUpper(pattern[pattern_index]) == std.ascii.toUpper(name[name_index])))
        {
            pattern_index += 1;
            name_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_name_index = name_index;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            star_name_index += 1;
            name_index = star_name_index;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn parseWallDate(input: []const u8) ?WallClock {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    for (input, 0..) |byte, index| {
        if (byte != '-' and byte != '/') continue;
        if (count >= parts.len) return null;
        parts[count] = input[start..index];
        count += 1;
        start = index + 1;
    }
    if (count != 2) return null;
    parts[2] = input[start..];
    const month = parseUnsigned(u8, parts[0]) orelse return null;
    const day = parseUnsigned(u8, parts[1]) orelse return null;
    var year = parseUnsigned(u16, parts[2]) orelse return null;
    if (parts[2].len == 2) year += if (year < 80) 2000 else 1900;
    if (parts[2].len != 2 and parts[2].len != 4) return null;
    const result = WallClock{ .valid = true, .year = year, .month = month, .day = day };
    return if (validWallDate(result)) result else null;
}

fn parseWallTime(input: []const u8) ?WallClock {
    var parts: [3][]const u8 = .{ "", "0", "0" };
    var count: usize = 0;
    var start: usize = 0;
    for (input, 0..) |byte, index| {
        if (byte != ':') continue;
        if (count >= 2) return null;
        parts[count] = input[start..index];
        count += 1;
        start = index + 1;
    }
    parts[count] = input[start..];
    count += 1;
    if (count == 0 or count > 3) return null;
    const hour = parseUnsigned(u8, parts[0]) orelse return null;
    const minute = parseUnsigned(u8, parts[1]) orelse return null;
    const second = parseUnsigned(u8, parts[2]) orelse return null;
    const result = WallClock{ .valid = true, .hour = hour, .minute = minute, .second = second };
    return if (validWallTime(result)) result else null;
}

fn parseUnsigned(comptime T: type, bytes: []const u8) ?T {
    if (bytes.len == 0) return null;
    return std.fmt.parseInt(T, bytes, 10) catch null;
}

fn validWallClock(clock: WallClock) bool {
    return clock.valid and validWallDate(clock) and validWallTime(clock) and clock.weekday <= 6;
}

fn validWallDate(clock: WallClock) bool {
    if (clock.year < 1980 or clock.year > 2099 or clock.month < 1 or clock.month > 12 or clock.day < 1) return false;
    return clock.day <= daysInMonth(clock.year, clock.month);
}

fn validWallTime(clock: WallClock) bool {
    return clock.hour < 24 and clock.minute < 60 and clock.second < 60;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        else => 0,
    };
}

fn weekdayForDate(year_value: u16, month_value: u8, day: u8) u8 {
    const offsets = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var year: u32 = year_value;
    if (month_value < 3) year -= 1;
    return @intCast((year + year / 4 - year / 100 + year / 400 + offsets[month_value - 1] + day) % 7);
}

fn decodeIeeeString(input: values.Value, target: bytecode.ValueType) ExecutionError!values.Value {
    const length: usize = switch (target) {
        .integer => 2,
        .long, .single => 4,
        .double => 8,
        .string => return error.TypeMismatch,
    };
    const bytes = try stringAtLeast(input, length);
    const raw = readUnsignedLittle(bytes[0..length]);
    return switch (target) {
        .integer => .{ .integer = @bitCast(@as(u16, @truncate(raw))) },
        .long => .{ .long = @bitCast(@as(u32, @truncate(raw))) },
        .single => blk: {
            const number: f32 = @bitCast(@as(u32, @truncate(raw)));
            if (!std.math.isFinite(number)) return error.Overflow;
            break :blk .{ .single = number };
        },
        .double => blk: {
            const number: f64 = @bitCast(raw);
            if (!std.math.isFinite(number)) return error.Overflow;
            break :blk .{ .double = number };
        },
        .string => unreachable,
    };
}

fn decodeMbfString(input: values.Value, target: bytecode.ValueType) ExecutionError!values.Value {
    return switch (target) {
        .single => blk: {
            const bytes = try stringAtLeast(input, 4);
            const raw: u32 = @truncate(readUnsignedLittle(bytes[0..4]));
            break :blk .{ .single = decodeMbfSingle(raw) };
        },
        .double => blk: {
            const bytes = try stringAtLeast(input, 8);
            break :blk .{ .double = decodeMbfDouble(readUnsignedLittle(bytes[0..8])) };
        },
        else => error.TypeMismatch,
    };
}

fn stringAtLeast(input: values.Value, length: usize) ExecutionError![]const u8 {
    return switch (input) {
        .string => |bytes| if (bytes.len < length) error.IllegalFunctionCall else bytes,
        else => error.TypeMismatch,
    };
}

fn writeUnsignedLittle(bytes: []u8, raw: u64) void {
    for (bytes, 0..) |*byte, index| byte.* = @truncate(raw >> @intCast(index * 8));
}

fn readUnsignedLittle(bytes: []const u8) u64 {
    var raw: u64 = 0;
    for (bytes, 0..) |byte, index| raw |= @as(u64, byte) << @intCast(index * 8);
    return raw;
}

fn encodeMbfSingle(number: f32) ExecutionError!u32 {
    if (!std.math.isFinite(number)) return error.Overflow;
    const bits: u32 = @bitCast(number);
    const magnitude = bits & 0x7FFF_FFFF;
    if (magnitude == 0) return 0;

    const ieee_exponent = (bits >> 23) & 0xFF;
    var exponent: i32 = undefined;
    var significand: u32 = undefined;
    if (ieee_exponent == 0) {
        const fraction = bits & 0x007F_FFFF;
        const highest: u5 = @intCast(31 - @clz(fraction));
        exponent = @as(i32, highest) - 149;
        significand = fraction << @intCast(23 - highest);
    } else {
        exponent = @as(i32, @intCast(ieee_exponent)) - 127;
        significand = 0x0080_0000 | (bits & 0x007F_FFFF);
    }

    if (exponent > 126) return error.Overflow;
    if (exponent < -129) return 0;
    const sign_bits = ((bits >> 31) & 1) << 23;
    if (exponent == -129) {
        if (significand <= 0x0080_0000) return 0;
        return sign_bits | (1 << 24);
    }
    const mbf_exponent: u32 = @intCast(exponent + 129);
    return (mbf_exponent << 24) | sign_bits | (significand & 0x007F_FFFF);
}

fn decodeMbfSingle(raw: u32) f32 {
    const mbf_exponent = raw >> 24;
    if (mbf_exponent == 0) return 0;
    const exponent = @as(i32, @intCast(mbf_exponent)) - 129;
    const sign_bits = (raw & 0x0080_0000) << 8;
    const significand = 0x0080_0000 | (raw & 0x007F_FFFF);
    const ieee_bits: u32 = if (exponent >= -126)
        sign_bits | (@as(u32, @intCast(exponent + 127)) << 23) | (significand & 0x007F_FFFF)
    else
        sign_bits | @as(u32, @intCast(roundShiftRightEven(significand, @intCast(-126 - exponent))));
    return @bitCast(ieee_bits);
}

fn encodeMbfDouble(number: f64) ExecutionError!u64 {
    if (!std.math.isFinite(number)) return error.Overflow;
    const bits: u64 = @bitCast(number);
    const magnitude = bits & 0x7FFF_FFFF_FFFF_FFFF;
    if (magnitude == 0) return 0;

    const ieee_exponent = (bits >> 52) & 0x7FF;
    var exponent: i32 = undefined;
    var significand: u64 = undefined;
    if (ieee_exponent == 0) {
        const fraction = bits & 0x000F_FFFF_FFFF_FFFF;
        const highest: u6 = @intCast(63 - @clz(fraction));
        exponent = @as(i32, highest) - 1074;
        significand = fraction << @intCast(52 - highest);
    } else {
        exponent = @as(i32, @intCast(ieee_exponent)) - 1023;
        significand = 0x0010_0000_0000_0000 | (bits & 0x000F_FFFF_FFFF_FFFF);
    }

    if (exponent > 126) return error.Overflow;
    if (exponent < -129) return 0;
    const sign_bits = ((bits >> 63) & 1) << 55;
    if (exponent == -129) {
        if (significand <= 0x0010_0000_0000_0000) return 0;
        return sign_bits | (@as(u64, 1) << 56);
    }
    const mbf_exponent: u64 = @intCast(exponent + 129);
    const fraction = (significand & 0x000F_FFFF_FFFF_FFFF) << 3;
    return (mbf_exponent << 56) | sign_bits | fraction;
}

fn decodeMbfDouble(raw: u64) f64 {
    const mbf_exponent = raw >> 56;
    if (mbf_exponent == 0) return 0;
    var exponent = @as(i32, @intCast(mbf_exponent)) - 129;
    const sign_bits = (raw & (@as(u64, 1) << 55)) << 8;
    const significand = (@as(u64, 1) << 55) | (raw & 0x007F_FFFF_FFFF_FFFF);
    var rounded = roundShiftRightEven(significand, 3);
    if (rounded == (@as(u64, 1) << 53)) {
        rounded >>= 1;
        exponent += 1;
    }
    const ieee_exponent: u64 = @intCast(exponent + 1023);
    const ieee_bits = sign_bits | (ieee_exponent << 52) | (rounded & 0x000F_FFFF_FFFF_FFFF);
    return @bitCast(ieee_bits);
}

fn roundShiftRightEven(value: anytype, shift: u6) @TypeOf(value) {
    std.debug.assert(shift != 0);
    const Shift = std.math.Log2Int(@TypeOf(value));
    const amount: Shift = @intCast(shift);
    const result = value >> amount;
    const mask = (@as(@TypeOf(value), 1) << amount) - 1;
    const remainder = value & mask;
    const halfway = @as(@TypeOf(value), 1) << @as(Shift, @intCast(shift - 1));
    return result + @intFromBool(remainder > halfway or (remainder == halfway and (result & 1) != 0));
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

fn asciiValue(input: values.Value) ExecutionError!values.Value {
    const bytes = switch (input) {
        .string => |value| value,
        else => return error.TypeMismatch,
    };
    if (bytes.len == 0) return error.IllegalFunctionCall;
    return .{ .integer = bytes[0] };
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

fn truncate(input: values.Value) ExecutionError!values.Value {
    return switch (input) {
        .integer => |number| .{ .integer = number },
        .long => |number| .{ .long = number },
        .single => |number| .{ .single = @trunc(number) },
        .double => |number| .{ .double = @trunc(number) },
        .string => error.TypeMismatch,
    };
}

fn signum(input: values.Value) ExecutionError!values.Value {
    const number = try values.asDouble(input);
    return .{ .integer = if (number < 0) -1 else if (number > 0) 1 else 0 };
}

fn saturatingCoordinateAdd(first: i32, second: i32) i32 {
    const result = @as(i64, first) + second;
    return @intCast(std.math.clamp(result, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn arrayRawBytesConst(array: *const ArrayValue) ExecutionError![]const u8 {
    if (array.record_type != bytecode.invalid_index or !array.value_type.isNumeric()) return error.TypeMismatch;
    return switch (array.storage) {
        .integer => |items| std.mem.sliceAsBytes(items),
        .long => |items| std.mem.sliceAsBytes(items),
        .single => |items| std.mem.sliceAsBytes(items),
        .double => |items| std.mem.sliceAsBytes(items),
        .cells => error.TypeMismatch,
    };
}

fn arrayRawBytes(array: *ArrayValue) ExecutionError![]u8 {
    if (array.record_type != bytecode.invalid_index or !array.value_type.isNumeric()) return error.TypeMismatch;
    return switch (array.storage) {
        .integer => |items| std.mem.sliceAsBytes(items),
        .long => |items| std.mem.sliceAsBytes(items),
        .single => |items| std.mem.sliceAsBytes(items),
        .double => |items| std.mem.sliceAsBytes(items),
        .cells => error.TypeMismatch,
    };
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
        error.RaisedError => .raised_error,
        error.NoResume => .no_resume,
        error.RestrictedMemory => .restricted_memory,
        error.BadFileNumber => .bad_file_number,
        error.FileNotFound => .file_not_found,
        error.BadFileMode => .bad_file_mode,
        error.FileAlreadyOpen => .file_already_open,
        error.InputPastEnd => .input_past_end,
        error.BadFileName => .bad_file_name,
        error.FieldOverflow => .field_overflow,
        error.FieldActive => .field_active,
        error.FileExists => .file_exists,
        error.BadRecordLength => .bad_record_length,
        error.DiskFull => .disk_full,
        error.BadRecordNumber => .bad_record_number,
        error.TooManyFiles => .too_many_files,
        error.PermissionDenied => .permission_denied,
        error.PathNotFound => .path_not_found,
        error.PathFileAccess => .path_file_access,
        error.Rethrow => .invalid_instruction,
        error.WouldBlock => .invalid_instruction,
    };
}

fn isCatchable(code: RuntimeCode) bool {
    return switch (code) {
        .overflow, .division_by_zero, .type_mismatch, .illegal_function_call, .out_of_memory, .gosub_without_return, .raised_error, .subscript_out_of_range, .array_already_dimensioned, .out_of_data, .restricted_memory, .bad_file_number, .file_not_found, .bad_file_mode, .file_already_open, .input_past_end, .bad_file_name, .field_overflow, .field_active, .file_exists, .bad_record_length, .disk_full, .bad_record_number, .too_many_files, .permission_denied, .path_not_found, .path_file_access => true,
        .stack_overflow, .stack_underflow, .call_depth_exceeded, .invalid_instruction, .host_failure, .no_resume, .resume_without_error => false,
    };
}

fn defaultMath(_: ?*anyopaque, operation: MathOperation, first: f64, second: f64) HostMathError!f64 {
    const result = switch (operation) {
        .atn => std.math.atan(first),
        .cos => @cos(first),
        .exp => @exp(first),
        .log => @log(first),
        .sin => @sin(first),
        .sqr => @sqrt(first),
        .tan => @tan(first),
        .power => std.math.pow(f64, first, second),
    };
    if (!std.math.isFinite(result)) return error.MathFault;
    return result;
}

fn acceptScreenMode(_: ?*anyopaque, _: i32) ScreenModeError!void {}

fn neverCancel(_: ?*anyopaque) bool {
    return false;
}

fn unavailableFileRead(_: ?*anyopaque, _: []const u8, _: u32, _: []u8) FileReadResult {
    return .{ .failure = .unavailable };
}

fn unavailableFileWrite(_: ?*anyopaque, _: []const u8, _: []const u8, _: bool) FileWriteResult {
    return .{ .failure = .unavailable };
}

fn unavailableFileWriteAt(_: ?*anyopaque, _: []const u8, _: u32, _: []const u8, _: bool) FileWriteResult {
    return .{ .failure = .unavailable };
}

fn unavailableFileInfo(_: ?*anyopaque, _: []const u8) FileInfoResult {
    return .{ .failure = .unavailable };
}

fn unavailableFileLock(_: ?*anyopaque, _: []const u8, _: u32, _: u32, _: bool) FileLockResult {
    return .{ .failure = .unavailable };
}

fn unavailablePathInfo(_: ?*anyopaque, _: []const u8) PathInfoResult {
    return .{ .failure = .unavailable };
}

fn unavailablePathOperation(_: ?*anyopaque, _: []const u8) PathOperationResult {
    return .{ .failure = .unavailable };
}

fn unavailablePathRename(_: ?*anyopaque, _: []const u8, _: []const u8) PathOperationResult {
    return .{ .failure = .unavailable };
}

fn unavailableDirectoryRead(_: ?*anyopaque, _: []const u8, _: u32, _: []u8) DirectoryReadResult {
    return .{ .failure = .unavailable };
}

fn unavailableWallClock(_: ?*anyopaque) WallClockResult {
    return .failure;
}

fn rejectWallClock(_: ?*anyopaque, _: WallClock) bool {
    return false;
}

fn rejectEnvironment(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
    return false;
}

fn unavailableShell(_: ?*anyopaque, _: []const u8) ShellResult {
    return .{ .failure = .unavailable };
}

fn ignoreFileQuiesce(_: ?*anyopaque) void {}

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
            .fixed_string_length = variable.fixed_string_length,
            .expected_dimensions = variable.dimensions,
            .is_dynamic = variable.is_dynamic,
            .dimensions = dimensions,
            .storage = storage,
        } } };
    }
    return allocateElement(
        allocator,
        program,
        variable.value_type,
        variable.record_type,
        variable.fixed_string_length,
    );
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
    fixed_string_length: u16,
    element_count: usize,
) ExecutionError!usize {
    const bytes_per_element: usize = if (record_type == bytecode.invalid_index)
        switch (value_type) {
            .integer => @sizeOf(i16),
            .long => @sizeOf(i32),
            .single => @sizeOf(f32),
            .double => @sizeOf(f64),
            .string => std.math.add(usize, @sizeOf(Cell), fixed_string_length) catch return error.OutOfMemory,
        }
    else record: {
        if (record_type >= program.record_types.len) return error.InvalidInstruction;
        const field_bytes = try recordLogicalPayloadBytes(program, record_type);
        break :record std.math.add(usize, @sizeOf(Cell), field_bytes) catch return error.OutOfMemory;
    };
    return std.math.mul(usize, element_count, bytes_per_element) catch return error.OutOfMemory;
}

fn recordLogicalPayloadBytes(program: *const bytecode.Program, record_type: u32) ExecutionError!usize {
    if (record_type >= program.record_types.len) return error.InvalidInstruction;
    var total: usize = 0;
    for (program.record_types[record_type].fields) |field| {
        total = std.math.add(usize, total, @sizeOf(Cell)) catch return error.OutOfMemory;
        if (field.record_type != bytecode.invalid_index) {
            total = std.math.add(usize, total, try recordLogicalPayloadBytes(program, field.record_type)) catch return error.OutOfMemory;
        } else {
            total = std.math.add(usize, total, field.fixed_string_length) catch return error.OutOfMemory;
        }
    }
    return total;
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
    fixed_string_length: u16,
) ExecutionError!Cell {
    if (record_type == bytecode.invalid_index) {
        if (value_type == .string and fixed_string_length != 0) {
            const bytes = try allocator.alloc(u8, fixed_string_length);
            @memset(bytes, ' ');
            return .{ .owned = .{ .fixed_string = .{
                .value = .{ .string = bytes },
                .length = fixed_string_length,
            } } };
        }
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
        fields[index] = try allocateElement(
            allocator,
            program,
            field.value_type,
            field.record_type,
            field.fixed_string_length,
        );
        initialized += 1;
    }
    return .{ .owned = .{ .record = .{ .record_type = record_type, .fields = fields } } };
}

fn cloneCell(allocator: std.mem.Allocator, program: *const bytecode.Program, source: *const Cell) ExecutionError!Cell {
    const resolved = resolveCellConst(source) orelse return error.InvalidInstruction;
    return switch (resolved.*) {
        .alias => unreachable,
        .owned => |owned| switch (owned) {
            .scalar => |value| .{ .owned = .{ .scalar = try value.clone(allocator) } },
            .fixed_string => |string| .{ .owned = .{ .fixed_string = .{
                .value = try string.value.clone(allocator),
                .length = string.length,
            } } },
            .field_string => |string| .{ .owned = .{ .scalar = try string.value.clone(allocator) } },
            .record => |record| blk: {
                if (record.record_type >= program.record_types.len) return error.InvalidInstruction;
                const fields = try allocator.alloc(Cell, record.fields.len);
                var initialized: usize = 0;
                errdefer {
                    for (fields[0..initialized]) |*field| field.deinit(allocator);
                    allocator.free(fields);
                }
                for (record.fields, 0..) |*field, index| {
                    fields[index] = try cloneCell(allocator, program, field);
                    initialized += 1;
                }
                break :blk .{ .owned = .{ .record = .{ .record_type = record.record_type, .fields = fields } } };
            },
            .array => return error.TypeMismatch,
        },
    };
}

fn variablesTransferCompatible(
    source_program: *const bytecode.Program,
    source: bytecode.Variable,
    target_program: *const bytecode.Program,
    target: bytecode.Variable,
) bool {
    if (source.value_type != target.value_type or source.isArray() != target.isArray() or
        source.fixed_string_length != target.fixed_string_length) return false;
    if ((source.record_type == bytecode.invalid_index) != (target.record_type == bytecode.invalid_index)) return false;
    if (source.record_type != bytecode.invalid_index and
        !recordTypesTransferCompatible(source_program, source.record_type, target_program, target.record_type, 0)) return false;
    return true;
}

fn recordTypesTransferCompatible(
    source_program: *const bytecode.Program,
    source_index: u32,
    target_program: *const bytecode.Program,
    target_index: u32,
    depth: usize,
) bool {
    if (depth > 32 or source_index >= source_program.record_types.len or target_index >= target_program.record_types.len) return false;
    const source = source_program.record_types[source_index];
    const target = target_program.record_types[target_index];
    if (source.byte_size != target.byte_size or source.fields.len != target.fields.len) return false;
    for (source.fields, target.fields) |source_field, target_field| {
        if (source_field.value_type != target_field.value_type or source_field.fixed_string_length != target_field.fixed_string_length or
            source_field.offset != target_field.offset or
            ((source_field.record_type == bytecode.invalid_index) != (target_field.record_type == bytecode.invalid_index))) return false;
        if (source_field.record_type != bytecode.invalid_index and !recordTypesTransferCompatible(
            source_program,
            source_field.record_type,
            target_program,
            target_field.record_type,
            depth + 1,
        )) return false;
    }
    return true;
}

fn cloneVariableAcrossPrograms(
    allocator: std.mem.Allocator,
    source_program: *const bytecode.Program,
    source_variable: bytecode.Variable,
    target_program: *const bytecode.Program,
    target_variable: bytecode.Variable,
    source_cell: *const Cell,
) ExecutionError!Cell {
    const resolved = resolveCellConst(source_cell) orelse return error.InvalidInstruction;
    if (!source_variable.isArray()) return cloneElementAcrossPrograms(
        allocator,
        source_program,
        source_variable,
        target_program,
        target_variable,
        resolved,
    );
    const source_array = switch (resolved.owned) {
        .array => |array| array,
        else => return error.TypeMismatch,
    };
    if (source_array.value_type != target_variable.value_type or
        source_array.fixed_string_length != target_variable.fixed_string_length) return error.TypeMismatch;
    const dimensions = try allocator.dupe(Dimension, source_array.dimensions);
    errdefer allocator.free(dimensions);
    var storage: ArrayStorage = switch (source_array.storage) {
        .integer => |items| .{ .integer = try allocator.dupe(i16, items) },
        .long => |items| .{ .long = try allocator.dupe(i32, items) },
        .single => |items| .{ .single = try allocator.dupe(f32, items) },
        .double => |items| .{ .double = try allocator.dupe(f64, items) },
        .cells => |items| cells: {
            const replacement = try allocator.alloc(Cell, items.len);
            var initialized: usize = 0;
            errdefer {
                for (replacement[0..initialized]) |*cell| cell.deinit(allocator);
                allocator.free(replacement);
            }
            for (items, 0..) |*item, index| {
                replacement[index] = try cloneElementAcrossPrograms(
                    allocator,
                    source_program,
                    source_variable,
                    target_program,
                    target_variable,
                    resolveCellConst(item) orelse return error.InvalidInstruction,
                );
                initialized += 1;
            }
            break :cells .{ .cells = replacement };
        },
    };
    errdefer storage.deinit(allocator);
    return .{ .owned = .{ .array = .{
        .value_type = target_variable.value_type,
        .record_type = target_variable.record_type,
        .fixed_string_length = target_variable.fixed_string_length,
        .expected_dimensions = target_variable.dimensions,
        .is_dynamic = target_variable.is_dynamic,
        .dimensions = dimensions,
        .storage = storage,
    } } };
}

fn cloneElementAcrossPrograms(
    allocator: std.mem.Allocator,
    source_program: *const bytecode.Program,
    source_variable: bytecode.Variable,
    target_program: *const bytecode.Program,
    target_variable: bytecode.Variable,
    source: *const Cell,
) ExecutionError!Cell {
    if (target_variable.record_type == bytecode.invalid_index) {
        return switch (source.owned) {
            .scalar => |value| .{ .owned = .{ .scalar = try value.clone(allocator) } },
            .fixed_string => |string| if (string.length == target_variable.fixed_string_length)
                .{ .owned = .{ .fixed_string = .{ .value = try string.value.clone(allocator), .length = string.length } } }
            else
                error.TypeMismatch,
            else => error.TypeMismatch,
        };
    }
    if (!recordTypesTransferCompatible(
        source_program,
        source_variable.record_type,
        target_program,
        target_variable.record_type,
        0,
    )) return error.TypeMismatch;
    const byte_size: usize = target_program.record_types[target_variable.record_type].byte_size;
    const bytes = try allocator.alloc(u8, byte_size);
    defer allocator.free(bytes);
    try encodeRecord(source_program, source, bytes);
    var replacement = try allocateElement(
        allocator,
        target_program,
        target_variable.value_type,
        target_variable.record_type,
        target_variable.fixed_string_length,
    );
    errdefer replacement.deinit(allocator);
    try decodeRecord(target_program, &replacement, bytes);
    return replacement;
}

fn arrayCellPayloadBytes(program: *const bytecode.Program, cell: *const Cell) ExecutionError!usize {
    const resolved = resolveCellConst(cell) orelse return error.InvalidInstruction;
    return switch (resolved.owned) {
        .array => |array| arrayLogicalPayloadBytes(
            program,
            array.value_type,
            array.record_type,
            array.fixed_string_length,
            array.storage.len(),
        ),
        else => 0,
    };
}

fn encodeRecord(program: *const bytecode.Program, source: *const Cell, out: []u8) ExecutionError!void {
    const resolved = resolveCellConst(source) orelse return error.InvalidInstruction;
    const record = switch (resolved.owned) {
        .record => |value| value,
        else => return error.TypeMismatch,
    };
    if (record.record_type >= program.record_types.len) return error.InvalidInstruction;
    const definition = program.record_types[record.record_type];
    if (out.len != definition.byte_size or record.fields.len != definition.fields.len) return error.InvalidInstruction;
    for (definition.fields, 0..) |field, index| {
        const first: usize = field.offset;
        const length: usize = if (field.record_type != bytecode.invalid_index)
            program.record_types[field.record_type].byte_size
        else switch (field.value_type) {
            .integer => 2,
            .long, .single => 4,
            .double => 8,
            .string => field.fixed_string_length,
        };
        try encodeRecordField(program, field, &record.fields[index], out[first .. first + length]);
    }
}

fn encodeRecordField(
    program: *const bytecode.Program,
    definition: bytecode.RecordField,
    source: *const Cell,
    out: []u8,
) ExecutionError!void {
    if (definition.record_type != bytecode.invalid_index) return encodeRecord(program, source, out);
    const resolved = resolveCellConst(source) orelse return error.InvalidInstruction;
    switch (resolved.owned) {
        .scalar => |value| switch (value) {
            .integer => |number| std.mem.writeInt(u16, out[0..2], @bitCast(number), .little),
            .long => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number), .little),
            .single => |number| std.mem.writeInt(u32, out[0..4], @bitCast(number), .little),
            .double => |number| std.mem.writeInt(u64, out[0..8], @bitCast(number), .little),
            .string => return error.InvalidInstruction,
        },
        .fixed_string => |string| {
            const bytes = switch (string.value) {
                .string => |value| value,
                else => return error.InvalidInstruction,
            };
            if (bytes.len != out.len) return error.InvalidInstruction;
            @memcpy(out, bytes);
        },
        else => return error.InvalidInstruction,
    }
}

fn decodeRecord(program: *const bytecode.Program, destination: *Cell, bytes: []const u8) ExecutionError!void {
    const resolved = resolveCell(destination) orelse return error.InvalidInstruction;
    const record = switch (resolved.owned) {
        .record => |*value| value,
        else => return error.TypeMismatch,
    };
    if (record.record_type >= program.record_types.len) return error.InvalidInstruction;
    const definition = program.record_types[record.record_type];
    if (bytes.len != definition.byte_size or record.fields.len != definition.fields.len) return error.InvalidInstruction;
    for (definition.fields, 0..) |field, index| {
        const first: usize = field.offset;
        const length: usize = if (field.record_type != bytecode.invalid_index)
            program.record_types[field.record_type].byte_size
        else switch (field.value_type) {
            .integer => 2,
            .long, .single => 4,
            .double => 8,
            .string => field.fixed_string_length,
        };
        try decodeRecordField(program, field, &record.fields[index], bytes[first .. first + length]);
    }
}

fn decodeRecordField(
    program: *const bytecode.Program,
    definition: bytecode.RecordField,
    destination: *Cell,
    bytes: []const u8,
) ExecutionError!void {
    if (definition.record_type != bytecode.invalid_index) return decodeRecord(program, destination, bytes);
    const resolved = resolveCell(destination) orelse return error.InvalidInstruction;
    switch (resolved.owned) {
        .scalar => |*value| switch (value.*) {
            .integer => value.* = .{ .integer = @bitCast(std.mem.readInt(u16, bytes[0..2], .little)) },
            .long => value.* = .{ .long = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)) },
            .single => value.* = .{ .single = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)) },
            .double => value.* = .{ .double = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)) },
            .string => return error.InvalidInstruction,
        },
        .fixed_string => |*string| {
            const out = switch (string.value) {
                .string => |value| value,
                else => return error.InvalidInstruction,
            };
            if (out.len != bytes.len) return error.InvalidInstruction;
            @memcpy(out, bytes);
        },
        else => return error.InvalidInstruction,
    }
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
        .fixed_string => |*string| &string.value,
        .field_string => |*string| &string.value,
        else => error.TypeMismatch,
    };
}

fn scalarAtMutable(cell: *Cell) ExecutionError!*values.Value {
    const resolved = resolveCell(cell) orelse return error.InvalidInstruction;
    return switch (resolved.owned) {
        .scalar => |*scalar| scalar,
        .fixed_string => |*string| &string.value,
        .field_string => |*string| &string.value,
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
