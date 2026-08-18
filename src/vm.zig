const std = @import("std");
const bytecode = @import("bytecode.zig");
const frontend = @import("frontend.zig");
const values = @import("value.zig");

pub const contract_version = "1.0.0";
pub const default_instruction_budget: u32 = 4096;
pub const maximum_value_stack: usize = 16_384;
pub const maximum_call_depth: usize = 256;
pub const maximum_gosub_depth: usize = 1024;

pub const MathOperation = enum(u8) {
    atn,
    cos,
    sin,
    power,
};

pub const HostMathError = error{MathFault};

pub const HostServices = struct {
    context: ?*anyopaque = null,
    math: *const fn (?*anyopaque, MathOperation, f64, f64) HostMathError!f64 = defaultMath,
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
};

pub const RuntimeDiagnostic = struct {
    code: RuntimeCode,
    file_name: []const u8,
    span: frontend.Span,
    instruction: u32,

    pub fn qbasicErrorNumber(self: RuntimeDiagnostic) i32 {
        return switch (self.code) {
            .illegal_function_call => 5,
            .overflow => 6,
            .out_of_memory => 7,
            .division_by_zero => 11,
            .type_mismatch => 13,
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
};

const Location = struct {
    frame: u32,
    index: u32,
};

const global_frame = bytecode.invalid_index;

const Cell = union(enum) {
    owned: values.Value,
    alias: Location,

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned => |*value| value.deinit(allocator),
            .alias => {},
        }
        self.* = undefined;
    }
};

const Frame = struct {
    procedure_id: u32,
    return_ip: u32,
    stack_base: usize,
    locals: []Cell,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        for (self.locals) |*cell| cell.deinit(allocator);
        allocator.free(self.locals);
        self.* = undefined;
    }
};

const StackItem = union(enum) {
    value: values.Value,
    reference: Location,

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

pub const Vm = struct {
    allocator: std.mem.Allocator,
    program: *const bytecode.Program,
    host: HostServices,
    globals: []values.Value,
    stack: std.ArrayList(StackItem) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    gosub_stack: std.ArrayList(GosubEntry) = .empty,
    instruction_pointer: u32,
    total_instructions: u64 = 0,
    status: Status = .ready,
    exit_code: i32 = 0,
    runtime_diagnostic: ?RuntimeDiagnostic = null,
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
            self.instruction_pointer += 1;
            self.execute(instruction) catch |fault| {
                self.recordError(runtimeCode(fault), instruction_index);
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
            if (std.ascii.eqlIgnoreCase(variable.name.bytes(self.program.source), name)) return &self.globals[index];
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
            .load_global => try self.load(.{ .frame = global_frame, .index = instruction.a }),
            .load_local => try self.load(try self.localLocation(instruction.a)),
            .store_global, .initialize_global => try self.store(.{ .frame = global_frame, .index = instruction.a }, bytecode.decodeValueType(instruction.b)),
            .store_local, .initialize_local => try self.store(try self.localLocation(instruction.a), bytecode.decodeValueType(instruction.b)),
            .push_global_reference => try self.pushReference(.{ .frame = global_frame, .index = instruction.a }),
            .push_local_reference => try self.pushReference(try self.localLocation(instruction.a)),
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
                self.status = .halted;
                self.exit_code = 0;
            },
        }
    }

    fn load(self: *Vm, location: Location) ExecutionError!void {
        const value = try self.valueAt(location);
        try self.pushValue(try value.clone(self.allocator));
    }

    fn store(self: *Vm, location: Location, target: bytecode.ValueType) ExecutionError!void {
        var incoming = try self.popValue();
        defer incoming.deinit(self.allocator);
        var converted = try values.convert(self.allocator, incoming, target);
        errdefer converted.deinit(self.allocator);
        const destination = try self.valueAtMutable(location);
        destination.deinit(self.allocator);
        destination.* = converted;
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

    fn callProcedure(self: *Vm, procedure_id: u32, argument_count: u32) ExecutionError!void {
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
            locals[index] = .{ .owned = try values.defaultValue(self.allocator, variable.value_type) };
            initialized += 1;
        }

        for (procedure.parameters, 0..) |parameter, index| {
            const item = self.stack.items[stack_base + index];
            switch (parameter.passing_mode) {
                .by_ref => switch (item) {
                    .reference => |location| {
                        locals[parameter.local_index].deinit(self.allocator);
                        locals[parameter.local_index] = .{ .alias = try self.resolveLocation(location) };
                    },
                    .value => return error.TypeMismatch,
                },
                .by_value => {
                    var argument = try self.cloneStackItem(item);
                    defer argument.deinit(self.allocator);
                    var converted = try values.convert(self.allocator, argument, parameter.value_type);
                    errdefer converted.deinit(self.allocator);
                    locals[parameter.local_index].deinit(self.allocator);
                    locals[parameter.local_index] = .{ .owned = converted };
                },
            }
        }

        try self.frames.append(self.allocator, .{
            .procedure_id = procedure_id,
            .return_ip = self.instruction_pointer,
            .stack_base = stack_base,
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
            return_value = try (try self.valueAt(.{
                .frame = @intCast(frame_depth - 1),
                .index = procedure.return_local,
            })).clone(self.allocator);
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
            .space_string => self.spaceString(arguments[0]),
            .str_string => self.numberString(arguments[0]),
            .ucase_string => self.upperString(arguments[0]),
            .val => self.val(arguments[0]),
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

    fn pushReference(self: *Vm, location: Location) ExecutionError!void {
        if (self.stack.items.len >= maximum_value_stack) return error.StackOverflow;
        try self.stack.append(self.allocator, .{ .reference = try self.resolveLocation(location) });
    }

    fn popValue(self: *Vm) ExecutionError!values.Value {
        const item = self.stack.pop() orelse return error.StackUnderflow;
        return switch (item) {
            .value => |value| value,
            .reference => |location| (try self.valueAt(location)).clone(self.allocator),
        };
    }

    fn cloneStackItem(self: *Vm, item: StackItem) ExecutionError!values.Value {
        return switch (item) {
            .value => |value| value.clone(self.allocator),
            .reference => |location| (try self.valueAt(location)).clone(self.allocator),
        };
    }

    fn discardStackFrom(self: *Vm, first: usize) void {
        while (self.stack.items.len > first) {
            var item = self.stack.pop().?;
            item.deinit(self.allocator);
        }
    }

    fn localLocation(self: *Vm, index: u32) ExecutionError!Location {
        if (self.frames.items.len == 0) return error.InvalidInstruction;
        if (index >= self.frames.items[self.frames.items.len - 1].locals.len) return error.InvalidInstruction;
        return .{ .frame = @intCast(self.frames.items.len - 1), .index = index };
    }

    fn resolveLocation(self: *Vm, original: Location) ExecutionError!Location {
        var location = original;
        var depth: usize = 0;
        while (location.frame != global_frame) : (depth += 1) {
            if (depth > maximum_call_depth) return error.InvalidInstruction;
            if (location.frame >= self.frames.items.len) return error.InvalidInstruction;
            const frame = &self.frames.items[location.frame];
            if (location.index >= frame.locals.len) return error.InvalidInstruction;
            switch (frame.locals[location.index]) {
                .owned => return location,
                .alias => |target| location = target,
            }
        }
        if (location.index >= self.globals.len) return error.InvalidInstruction;
        return location;
    }

    fn valueAt(self: *Vm, original: Location) ExecutionError!*const values.Value {
        const location = try self.resolveLocation(original);
        if (location.frame == global_frame) return &self.globals[location.index];
        const cell = &self.frames.items[location.frame].locals[location.index];
        return &cell.owned;
    }

    fn valueAtMutable(self: *Vm, original: Location) ExecutionError!*values.Value {
        const location = try self.resolveLocation(original);
        if (location.frame == global_frame) return &self.globals[location.index];
        const cell = &self.frames.items[location.frame].locals[location.index];
        return &cell.owned;
    }

    fn recordError(self: *Vm, code: RuntimeCode, instruction: u32) void {
        const span: frontend.Span = if (instruction < self.program.instructions.len)
            self.program.instructions[instruction].span
        else
            .{ .start = 0, .end = 0, .line = 1, .column = 1 };
        self.runtime_diagnostic = .{
            .code = code,
            .file_name = self.program.file_name,
            .span = span,
            .instruction = instruction,
        };
        self.status = .runtime_error;
        self.exit_code = self.runtime_diagnostic.?.qbasicErrorNumber();
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

fn neverCancel(_: ?*anyopaque) bool {
    return false;
}

fn allocateGlobals(allocator: std.mem.Allocator, program: *const bytecode.Program) InitError![]values.Value {
    const globals = try allocator.alloc(values.Value, program.globals.len);
    var initialized: usize = 0;
    errdefer {
        for (globals[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(globals);
    }
    for (program.globals, 0..) |variable, index| {
        globals[index] = values.defaultValue(allocator, variable.value_type) catch |fault| switch (fault) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        initialized += 1;
    }
    return globals;
}

fn deinitGlobals(allocator: std.mem.Allocator, globals: []values.Value) void {
    for (globals) |*value| value.deinit(allocator);
    allocator.free(globals);
}
