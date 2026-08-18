const std = @import("std");
const bytecode = @import("bytecode.zig");
const frontend = @import("frontend.zig");
const values = @import("value.zig");

pub const contract_version = "1.1.0";
pub const default_instruction_budget: u32 = 4096;
pub const maximum_value_stack: usize = 16_384;
pub const maximum_call_depth: usize = 256;
pub const maximum_gosub_depth: usize = 1024;
pub const maximum_array_elements: usize = 16 * 1024 * 1024;

pub const MathOperation = enum(u8) {
    atn,
    cos,
    sin,
    power,
};

pub const HostMathError = error{MathFault};
pub const ScreenModeError = error{ModeUnavailable};

pub const HostServices = struct {
    context: ?*anyopaque = null,
    math: *const fn (?*anyopaque, MathOperation, f64, f64) HostMathError!f64 = defaultMath,
    screen_mode: *const fn (?*anyopaque, i32) ScreenModeError!void = acceptScreenMode,
    should_cancel: *const fn (?*anyopaque) bool = neverCancel,
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
            .stack_overflow, .stack_underflow, .call_depth_exceeded, .gosub_without_return, .invalid_instruction, .host_failure => 70,
        };
    }
};

pub const Status = enum(u8) {
    ready,
    yielded,
    halted,
    cancelled,
    runtime_error,
};

pub const SliceResult = struct {
    status: Status,
    instructions: u32,
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
    elements: []Cell,

    fn deinit(self: *ArrayValue, allocator: std.mem.Allocator) void {
        for (self.elements) |*element| element.deinit(allocator);
        allocator.free(self.elements);
        allocator.free(self.dimensions);
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
    alias: *Cell,

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned => |*owned| owned.deinit(allocator),
            .alias => {},
        }
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
    locals: []Cell,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        for (self.locals) |*cell| cell.deinit(allocator);
        allocator.free(self.locals);
        self.* = undefined;
    }
};

const StackItem = union(enum) {
    value: values.Value,
    reference: *Cell,

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

const module_frame = bytecode.invalid_index;

pub const Vm = struct {
    allocator: std.mem.Allocator,
    program: *const bytecode.Program,
    host: HostServices,
    globals: []Cell,
    stack: std.ArrayList(StackItem) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    gosub_stack: std.ArrayList(GosubEntry) = .empty,
    instruction_pointer: u32,
    total_instructions: u64 = 0,
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
    statement_stack_base: usize = 0,
    current_statement_start: u32 = bytecode.invalid_index,
    cancel_requested: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const bytecode.Program,
        host: HostServices,
    ) InitError!Vm {
        if (!program.ok()) return error.InvalidProgram;
        const globals = try allocateGlobals(allocator, program);
        return .{
            .allocator = allocator,
            .program = program,
            .host = host,
            .globals = globals,
            .instruction_pointer = program.module_entry,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.discardStackFrom(0);
        self.stack.deinit(self.allocator);
        while (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            frame.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
        self.gosub_stack.deinit(self.allocator);
        deinitGlobals(self.allocator, self.globals);
        self.* = undefined;
    }

    pub fn requestCancel(self: *Vm) void {
        self.cancel_requested = true;
    }

    pub fn reset(self: *Vm) InitError!void {
        const replacement = try allocateGlobals(self.allocator, self.program);
        errdefer deinitGlobals(self.allocator, replacement);

        self.discardStackFrom(0);
        while (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            frame.deinit(self.allocator);
        }
        self.gosub_stack.clearRetainingCapacity();
        deinitGlobals(self.allocator, self.globals);
        self.globals = replacement;
        self.instruction_pointer = self.program.module_entry;
        self.total_instructions = 0;
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
        self.statement_stack_base = 0;
        self.current_statement_start = bytecode.invalid_index;
        self.cancel_requested = false;
    }

    pub fn runSlice(self: *Vm, instruction_budget: u32) SliceResult {
        if (self.status == .halted or self.status == .cancelled or self.status == .runtime_error) {
            return .{ .status = self.status, .instructions = 0 };
        }
        if (self.cancel_requested or self.host.should_cancel(self.host.context)) {
            self.status = .cancelled;
            self.exit_code = 130;
            return .{ .status = self.status, .instructions = 0 };
        }
        self.status = .ready;
        var executed: u32 = 0;
        while (executed < instruction_budget) {
            if (self.cancel_requested or self.host.should_cancel(self.host.context)) {
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
            const statement_start = if (instruction.statement_start == bytecode.invalid_index) instruction_index else instruction.statement_start;
            if (self.current_statement_start != statement_start) {
                self.current_statement_start = statement_start;
                self.statement_stack_base = self.stack.items.len;
            }
            self.instruction_pointer += 1;
            self.execute(instruction) catch |fault| {
                const code = if (fault == error.Rethrow and self.active_error != null)
                    self.active_error.?.diagnostic.code
                else
                    runtimeCode(fault);
                if (fault != error.Rethrow and self.trapError(code, instruction_index, instruction)) {
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

    pub fn globalArrayElement(self: *const Vm, name: []const u8, indices: []const i32) ?*const values.Value {
        const root = self.globalCell(name) orelse return null;
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return null,
        };
        const element = arrayElementConst(array, indices) orelse return null;
        return switch (element.owned) {
            .scalar => |*scalar| scalar,
            else => null,
        };
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
        const element = arrayElementConst(array, indices) orelse return null;
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

    fn execute(self: *Vm, instruction: bytecode.Instruction) ExecutionError!void {
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
            .push_global_reference => try self.pushReference(try self.globalCellAt(instruction.a)),
            .push_local_reference => try self.pushReference(try self.localCellAt(instruction.a)),
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
            .deferred_statement => return error.HostFailure,
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
            .compare_equal => try self.comparison(.equal),
            .compare_not_equal => try self.comparison(.not_equal),
            .compare_less => try self.comparison(.less),
            .compare_less_equal => try self.comparison(.less_equal),
            .compare_greater => try self.comparison(.greater),
            .compare_greater_equal => try self.comparison(.greater_equal),
            .call_builtin => try self.callBuiltin(@enumFromInt(@as(u8, @intCast(instruction.a))), instruction.b),
            .call => try self.callProcedure(instruction.a, instruction.b, instruction),
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
                self.status = .halted;
                self.exit_code = 0;
            },
        }
    }

    fn load(self: *Vm, cell: *Cell) ExecutionError!void {
        const value = try scalarAt(cell);
        try self.pushValue(try value.clone(self.allocator));
    }

    fn store(self: *Vm, cell: *Cell, target: bytecode.ValueType) ExecutionError!void {
        var incoming = try self.popValue();
        defer incoming.deinit(self.allocator);
        var converted = try values.convert(self.allocator, incoming, target);
        errdefer converted.deinit(self.allocator);
        const destination = try scalarAtMutable(cell);
        destination.deinit(self.allocator);
        destination.* = converted;
    }

    fn storeReference(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        var incoming = try self.popValue();
        defer incoming.deinit(self.allocator);
        const cell = try self.popReference();
        var converted = try values.convert(self.allocator, incoming, target);
        errdefer converted.deinit(self.allocator);
        const destination = try scalarAtMutable(cell);
        destination.deinit(self.allocator);
        destination.* = converted;
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
        const root = resolveCell(try self.popReference()) orelse return error.InvalidInstruction;
        const array = switch (root.owned) {
            .array => |*value| value,
            else => return error.TypeMismatch,
        };
        const element = arrayElement(array, indices[0..dimension_count]) orelse return error.SubscriptOutOfRange;
        try self.pushReference(element);
    }

    fn selectRecordField(self: *Vm, field_index: u32) ExecutionError!void {
        const root = resolveCell(try self.popReference()) orelse return error.InvalidInstruction;
        const record = switch (root.owned) {
            .record => |*value| value,
            else => return error.TypeMismatch,
        };
        if (field_index >= record.fields.len) return error.InvalidInstruction;
        try self.pushReference(&record.fields[field_index]);
    }

    fn dimensionArray(self: *Vm, dimension_count: u32, redimension: bool) ExecutionError!void {
        if (dimension_count == 0 or dimension_count > 60) return error.InvalidInstruction;
        const root = resolveCell(try self.popReference()) orelse return error.InvalidInstruction;
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

        for (array.elements) |*element| element.deinit(self.allocator);
        self.allocator.free(array.elements);
        self.allocator.free(array.dimensions);
        array.elements = elements;
        array.dimensions = dimensions;
    }

    fn readData(self: *Vm, target: bytecode.ValueType) ExecutionError!void {
        const destination = try self.popReference();
        if (self.data_pointer >= self.program.data_items.len) return error.OutOfData;
        var converted = try dataValue(self.allocator, self.program.data_items[self.data_pointer], self.program.source, target);
        errdefer converted.deinit(self.allocator);
        const scalar = try scalarAtMutable(destination);
        scalar.deinit(self.allocator);
        scalar.* = converted;
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
        self.statement_stack_base = self.stack.items.len;
    }

    fn trapError(self: *Vm, code: RuntimeCode, instruction_index: u32, instruction: bytecode.Instruction) bool {
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

        var resume_ip = if (instruction.statement_start == bytecode.invalid_index) instruction_index else instruction.statement_start;
        var resume_next_ip = if (instruction.statement_next == bytecode.invalid_index) self.instruction_pointer else instruction.statement_next;
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
            frame.deinit(self.allocator);
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
        self.host.screen_mode(self.host.context, mode) catch return error.IllegalFunctionCall;
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

    fn comparison(self: *Vm, operation: values.Comparison) ExecutionError!void {
        var right = try self.popValue();
        defer right.deinit(self.allocator);
        var left = try self.popValue();
        defer left.deinit(self.allocator);
        try self.pushValue(try values.compare(left, right, operation));
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
        call_instruction: bytecode.Instruction,
    ) ExecutionError!void {
        if (procedure_id >= self.program.procedures.len) return error.InvalidInstruction;
        if (self.frames.items.len >= maximum_call_depth) return error.CallDepthExceeded;
        const procedure = self.program.procedures[procedure_id];
        if (argument_count != procedure.parameters.len or argument_count > self.stack.items.len) return error.InvalidInstruction;
        const stack_base = self.stack.items.len - argument_count;

        const locals = try self.allocator.alloc(Cell, procedure.locals.len);
        var initialized: usize = 0;
        errdefer {
            for (locals[0..initialized]) |*cell| cell.deinit(self.allocator);
            self.allocator.free(locals);
        }
        for (procedure.locals, 0..) |variable, index| {
            locals[index] = try allocateVariable(self.allocator, self.program, variable);
            initialized += 1;
        }

        for (procedure.parameters, 0..) |parameter, index| {
            const item = self.stack.items[stack_base + index];
            switch (parameter.passing_mode) {
                .by_ref => switch (item) {
                    .reference => |cell| {
                        locals[parameter.local_index].deinit(self.allocator);
                        locals[parameter.local_index] = .{ .alias = resolveCell(cell) orelse return error.InvalidInstruction };
                    },
                    .value => |value| {
                        var converted = try values.convert(self.allocator, value, parameter.value_type);
                        errdefer converted.deinit(self.allocator);
                        locals[parameter.local_index].deinit(self.allocator);
                        locals[parameter.local_index] = .{ .owned = .{ .scalar = converted } };
                    },
                },
                .by_value => {
                    var argument = try self.cloneStackItem(item);
                    defer argument.deinit(self.allocator);
                    var converted = try values.convert(self.allocator, argument, parameter.value_type);
                    errdefer converted.deinit(self.allocator);
                    locals[parameter.local_index].deinit(self.allocator);
                    locals[parameter.local_index] = .{ .owned = .{ .scalar = converted } };
                },
            }
        }

        try self.frames.append(self.allocator, .{
            .procedure_id = procedure_id,
            .return_ip = self.instruction_pointer,
            .stack_base = stack_base,
            .call_resume_ip = call_instruction.statement_start,
            .call_resume_next = call_instruction.statement_next,
            .locals = locals,
        });
        self.discardStackFrom(stack_base);
        self.instruction_pointer = procedure.entry_ip;
    }

    fn returnProcedure(self: *Vm) ExecutionError!void {
        if (self.frames.items.len == 0) return error.InvalidInstruction;
        const frame_depth = self.frames.items.len;
        const procedure = self.program.procedures[self.frames.items[frame_depth - 1].procedure_id];
        var return_value: ?values.Value = null;
        if (procedure.returnsValue()) {
            return_value = try (try scalarAt(&self.frames.items[frame_depth - 1].locals[procedure.return_local])).clone(self.allocator);
        }

        var frame = self.frames.pop().?;
        self.discardStackFrom(frame.stack_base);
        self.instruction_pointer = frame.return_ip;
        frame.deinit(self.allocator);
        while (self.gosub_stack.items.len != 0 and self.gosub_stack.items[self.gosub_stack.items.len - 1].frame_depth >= frame_depth) {
            _ = self.gosub_stack.pop();
        }
        if (return_value) |value| try self.pushValue(value);
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
        var arguments: [3]values.Value = undefined;
        var first_initialized: usize = argument_count;
        defer for (arguments[first_initialized..argument_count]) |*argument| argument.deinit(self.allocator);
        while (first_initialized != 0) {
            const argument = try self.popValue();
            first_initialized -= 1;
            arguments[first_initialized] = argument;
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
            .eof, .inkey_string, .point, .rnd, .timer => error.HostFailure,
        };
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
        const body = switch (input) {
            .integer => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
            .long => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
            .single => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
            .double => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
            .string => return error.TypeMismatch,
        };
        defer self.allocator.free(body);
        const positive = body.len == 0 or body[0] != '-';
        const result = try self.allocator.alloc(u8, body.len + @intFromBool(positive));
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
        const normalized = try self.allocator.dupe(u8, trimmed[0..length]);
        defer self.allocator.free(normalized);
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
        if (self.stack.items.len >= maximum_value_stack) return error.StackOverflow;
        try self.stack.append(self.allocator, .{ .reference = resolveCell(cell) orelse return error.InvalidInstruction });
    }

    fn popReference(self: *Vm) ExecutionError!*Cell {
        const item = self.stack.pop() orelse return error.StackUnderflow;
        return switch (item) {
            .reference => |cell| resolveCell(cell) orelse error.InvalidInstruction,
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
            .reference => |cell| (try scalarAt(cell)).clone(self.allocator),
        };
    }

    fn cloneStackItem(self: *Vm, item: StackItem) ExecutionError!values.Value {
        return switch (item) {
            .value => |value| value.clone(self.allocator),
            .reference => |cell| (try scalarAt(cell)).clone(self.allocator),
        };
    }

    fn discardStackFrom(self: *Vm, first: usize) void {
        while (self.stack.items.len > first) {
            var item = self.stack.pop().?;
            item.deinit(self.allocator);
        }
    }

    fn localCellAt(self: *Vm, index: u32) ExecutionError!*Cell {
        if (self.frames.items.len == 0) return error.InvalidInstruction;
        if (index >= self.frames.items[self.frames.items.len - 1].locals.len) return error.InvalidInstruction;
        return resolveCell(&self.frames.items[self.frames.items.len - 1].locals[index]) orelse error.InvalidInstruction;
    }

    fn globalCellAt(self: *Vm, index: u32) ExecutionError!*Cell {
        if (index >= self.globals.len) return error.InvalidInstruction;
        return resolveCell(&self.globals[index]) orelse error.InvalidInstruction;
    }

    fn recordError(self: *Vm, code: RuntimeCode, instruction: u32) void {
        self.recordDiagnostic(self.makeDiagnostic(code, instruction));
    }

    fn recordDiagnostic(self: *Vm, diagnostic: RuntimeDiagnostic) void {
        self.runtime_diagnostic = diagnostic;
        self.status = .runtime_error;
        self.exit_code = self.runtime_diagnostic.?.qbasicErrorNumber();
    }

    fn makeDiagnostic(self: *const Vm, code: RuntimeCode, instruction: u32) RuntimeDiagnostic {
        const span: frontend.Span = if (instruction < self.program.instructions.len)
            self.program.instructions[instruction].span
        else
            .{ .start = 0, .end = 0, .line = 1, .column = 1 };
        return .{ .code = code, .file_name = self.program.file_name, .span = span, .instruction = instruction };
    }
};

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
        error.Rethrow => .invalid_instruction,
    };
}

fn isCatchable(code: RuntimeCode) bool {
    return switch (code) {
        .overflow, .division_by_zero, .type_mismatch, .illegal_function_call, .out_of_memory, .subscript_out_of_range, .array_already_dimensioned, .out_of_data, .restricted_memory => true,
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

fn neverCancel(_: ?*anyopaque) bool {
    return false;
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
        const elements = try allocator.alloc(Cell, 0);
        return .{ .owned = .{ .array = .{
            .value_type = variable.value_type,
            .record_type = variable.record_type,
            .expected_dimensions = variable.dimensions,
            .is_dynamic = variable.is_dynamic,
            .dimensions = dimensions,
            .elements = elements,
        } } };
    }
    return allocateElement(allocator, program, variable.value_type, variable.record_type);
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
            .alias => |target| cell = target,
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
            .alias => |target| cell = target,
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

fn arrayElement(array: *ArrayValue, indices: []const i32) ?*Cell {
    if (indices.len != array.dimensions.len) return null;
    var offset: usize = 0;
    for (array.dimensions, indices) |dimension, index| {
        if (index < dimension.lower or index > dimension.upper) return null;
        offset += @as(usize, @intCast(index - dimension.lower)) * dimension.stride;
    }
    if (offset >= array.elements.len) return null;
    return resolveCell(&array.elements[offset]);
}

fn arrayElementConst(array: *const ArrayValue, indices: []const i32) ?*const Cell {
    if (indices.len != array.dimensions.len) return null;
    var offset: usize = 0;
    for (array.dimensions, indices) |dimension, index| {
        if (index < dimension.lower or index > dimension.upper) return null;
        offset += @as(usize, @intCast(index - dimension.lower)) * dimension.stride;
    }
    if (offset >= array.elements.len) return null;
    return resolveCellConst(&array.elements[offset]);
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
