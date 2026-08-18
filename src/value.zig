const std = @import("std");
const bytecode = @import("bytecode.zig");

pub const maximum_string_bytes: usize = 32_767;

pub const Fault = error{
    OutOfMemory,
    TypeMismatch,
    Overflow,
    DivisionByZero,
    IllegalFunctionCall,
};

pub const Value = union(bytecode.ValueType) {
    integer: i16,
    long: i32,
    single: f32,
    double: f64,
    string: []u8,

    pub fn valueType(self: Value) bytecode.ValueType {
        return std.meta.activeTag(self);
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |bytes| allocator.free(bytes),
            else => {},
        }
        self.* = undefined;
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) Fault!Value {
        return switch (self) {
            .integer => |number| .{ .integer = number },
            .long => |number| .{ .long = number },
            .single => |number| .{ .single = number },
            .double => |number| .{ .double = number },
            .string => |bytes| .{ .string = try allocator.dupe(u8, bytes) },
        };
    }
};

pub const BinaryOperation = enum {
    add,
    subtract,
    multiply,
    divide,
    integer_divide,
    modulo,
    logical_and,
    logical_or,
    logical_xor,
};

pub const Comparison = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub fn defaultValue(allocator: std.mem.Allocator, value_type: bytecode.ValueType) Fault!Value {
    return switch (value_type) {
        .integer => .{ .integer = 0 },
        .long => .{ .long = 0 },
        .single => .{ .single = 0 },
        .double => .{ .double = 0 },
        .string => .{ .string = try allocator.dupe(u8, "") },
    };
}

pub fn fromConstant(allocator: std.mem.Allocator, constant: bytecode.Constant, source: []const u8) Fault!Value {
    return switch (constant) {
        .integer => |number| .{ .integer = number },
        .long => |number| .{ .long = number },
        .single => |number| .{ .single = number },
        .double => |number| .{ .double = number },
        .string => |span| blk: {
            const token = span.bytes(source);
            const contents = if (token.len >= 2) token[1 .. token.len - 1] else "";
            if (contents.len > maximum_string_bytes) return error.Overflow;
            break :blk .{ .string = try allocator.dupe(u8, contents) };
        },
    };
}

pub fn convert(allocator: std.mem.Allocator, input: Value, target: bytecode.ValueType) Fault!Value {
    if (input.valueType() == target) return input.clone(allocator);
    if (input.valueType() == .string or target == .string) return error.TypeMismatch;

    return switch (target) {
        .integer => .{ .integer = try toInteger(input) },
        .long => .{ .long = try toLong(input) },
        .single => .{ .single = try toSingle(input) },
        .double => .{ .double = try toDouble(input) },
        .string => unreachable,
    };
}

pub fn isTrue(input: Value) Fault!bool {
    return switch (input) {
        .integer => |number| number != 0,
        .long => |number| number != 0,
        .single => |number| number != 0,
        .double => |number| number != 0,
        .string => error.TypeMismatch,
    };
}

pub fn negate(input: Value, target: bytecode.ValueType) Fault!Value {
    if (!target.isNumeric()) return error.TypeMismatch;
    return switch (target) {
        .integer => blk: {
            const number = try toInteger(input);
            if (number == std.math.minInt(i16)) return error.Overflow;
            break :blk .{ .integer = -number };
        },
        .long => blk: {
            const number = try toLong(input);
            if (number == std.math.minInt(i32)) return error.Overflow;
            break :blk .{ .long = -number };
        },
        .single => blk: {
            const number = -(try toSingle(input));
            if (!std.math.isFinite(number)) return error.Overflow;
            break :blk .{ .single = number };
        },
        .double => blk: {
            const number = -(try toDouble(input));
            if (!std.math.isFinite(number)) return error.Overflow;
            break :blk .{ .double = number };
        },
        .string => unreachable,
    };
}

pub fn logicalNot(input: Value) Fault!Value {
    return .{ .long = ~(try toLong(input)) };
}

pub fn binary(
    allocator: std.mem.Allocator,
    operation: BinaryOperation,
    left: Value,
    right: Value,
    target: bytecode.ValueType,
) Fault!Value {
    if (operation == .add and target == .string) {
        if (left.valueType() != .string or right.valueType() != .string) return error.TypeMismatch;
        const left_bytes = left.string;
        const right_bytes = right.string;
        if (left_bytes.len + right_bytes.len > maximum_string_bytes) return error.Overflow;
        const result = try allocator.alloc(u8, left_bytes.len + right_bytes.len);
        @memcpy(result[0..left_bytes.len], left_bytes);
        @memcpy(result[left_bytes.len..], right_bytes);
        return .{ .string = result };
    }
    if (!left.valueType().isNumeric() or !right.valueType().isNumeric() or !target.isNumeric()) return error.TypeMismatch;

    return switch (operation) {
        .add => numericArithmetic(.add, left, right, target),
        .subtract => numericArithmetic(.subtract, left, right, target),
        .multiply => numericArithmetic(.multiply, left, right, target),
        .divide => floatingDivision(left, right, target),
        .integer_divide => integerDivision(left, right, target),
        .modulo => modulo(left, right, target),
        .logical_and => .{ .long = (try toLong(left)) & (try toLong(right)) },
        .logical_or => .{ .long = (try toLong(left)) | (try toLong(right)) },
        .logical_xor => .{ .long = (try toLong(left)) ^ (try toLong(right)) },
    };
}

pub fn compare(left: Value, right: Value, operation: Comparison) Fault!Value {
    const ordering = if (left.valueType() == .string and right.valueType() == .string)
        std.mem.order(u8, left.string, right.string)
    else if (left.valueType().isNumeric() and right.valueType().isNumeric()) blk: {
        const first = try toDouble(left);
        const second = try toDouble(right);
        break :blk if (first < second) std.math.Order.lt else if (first > second) std.math.Order.gt else std.math.Order.eq;
    } else return error.TypeMismatch;

    const matched = switch (operation) {
        .equal => ordering == .eq,
        .not_equal => ordering != .eq,
        .less => ordering == .lt,
        .less_equal => ordering != .gt,
        .greater => ordering == .gt,
        .greater_equal => ordering != .lt,
    };
    return .{ .integer = if (matched) -1 else 0 };
}

pub fn numericResultType(left: bytecode.ValueType, right: bytecode.ValueType) Fault!bytecode.ValueType {
    if (!left.isNumeric() or !right.isNumeric()) return error.TypeMismatch;
    if (left == .double or right == .double) return .double;
    if (left == .single or right == .single) return .single;
    if (left == .long or right == .long) return .long;
    return .integer;
}

pub fn divisionResultType(left: bytecode.ValueType, right: bytecode.ValueType) Fault!bytecode.ValueType {
    const promoted = try numericResultType(left, right);
    return if (promoted == .double) .double else .single;
}

pub fn roundToInteger(number: f64) Fault!i16 {
    const rounded = try roundedFinite(number);
    if (rounded < -32_768 or rounded > 32_767) return error.Overflow;
    return @intFromFloat(rounded);
}

pub fn roundToLong(number: f64) Fault!i32 {
    const rounded = try roundedFinite(number);
    if (rounded < -2_147_483_648 or rounded > 2_147_483_647) return error.Overflow;
    return @intFromFloat(rounded);
}

pub fn asInteger(input: Value) Fault!i16 {
    return toInteger(input);
}

pub fn asLong(input: Value) Fault!i32 {
    return toLong(input);
}

pub fn asSingle(input: Value) Fault!f32 {
    return toSingle(input);
}

pub fn asDouble(input: Value) Fault!f64 {
    return toDouble(input);
}

fn numericArithmetic(operation: BinaryOperation, left: Value, right: Value, target: bytecode.ValueType) Fault!Value {
    return switch (target) {
        .integer => blk: {
            const first: i32 = try toInteger(left);
            const second: i32 = try toInteger(right);
            const result: i32 = switch (operation) {
                .add => first + second,
                .subtract => first - second,
                .multiply => first * second,
                else => unreachable,
            };
            if (result < std.math.minInt(i16) or result > std.math.maxInt(i16)) return error.Overflow;
            break :blk .{ .integer = @intCast(result) };
        },
        .long => blk: {
            const first: i64 = try toLong(left);
            const second: i64 = try toLong(right);
            const result: i64 = switch (operation) {
                .add => first + second,
                .subtract => first - second,
                .multiply => first * second,
                else => unreachable,
            };
            if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return error.Overflow;
            break :blk .{ .long = @intCast(result) };
        },
        .single => blk: {
            const first = try toSingle(left);
            const second = try toSingle(right);
            const result = switch (operation) {
                .add => first + second,
                .subtract => first - second,
                .multiply => first * second,
                else => unreachable,
            };
            if (!std.math.isFinite(result)) return error.Overflow;
            break :blk .{ .single = result };
        },
        .double => blk: {
            const first = try toDouble(left);
            const second = try toDouble(right);
            const result = switch (operation) {
                .add => first + second,
                .subtract => first - second,
                .multiply => first * second,
                else => unreachable,
            };
            if (!std.math.isFinite(result)) return error.Overflow;
            break :blk .{ .double = result };
        },
        .string => error.TypeMismatch,
    };
}

fn floatingDivision(left: Value, right: Value, target: bytecode.ValueType) Fault!Value {
    return switch (target) {
        .single => blk: {
            const divisor = try toSingle(right);
            if (divisor == 0) return error.DivisionByZero;
            const result = (try toSingle(left)) / divisor;
            if (!std.math.isFinite(result)) return error.Overflow;
            break :blk .{ .single = result };
        },
        .double => blk: {
            const divisor = try toDouble(right);
            if (divisor == 0) return error.DivisionByZero;
            const result = (try toDouble(left)) / divisor;
            if (!std.math.isFinite(result)) return error.Overflow;
            break :blk .{ .double = result };
        },
        else => error.TypeMismatch,
    };
}

fn integerDivision(left: Value, right: Value, target: bytecode.ValueType) Fault!Value {
    const first = try toLong(left);
    const second = try toLong(right);
    if (second == 0) return error.DivisionByZero;
    if (first == std.math.minInt(i32) and second == -1) return error.Overflow;
    const result = @divTrunc(first, second);
    return if (target == .integer)
        if (result < std.math.minInt(i16) or result > std.math.maxInt(i16)) error.Overflow else .{ .integer = @intCast(result) }
    else
        .{ .long = result };
}

fn modulo(left: Value, right: Value, target: bytecode.ValueType) Fault!Value {
    const first = try toLong(left);
    const second = try toLong(right);
    if (second == 0) return error.DivisionByZero;
    if (first == std.math.minInt(i32) and second == -1) return if (target == .integer) .{ .integer = 0 } else .{ .long = 0 };
    const result = @rem(first, second);
    return if (target == .integer)
        if (result < std.math.minInt(i16) or result > std.math.maxInt(i16)) error.Overflow else .{ .integer = @intCast(result) }
    else
        .{ .long = result };
}

fn toInteger(input: Value) Fault!i16 {
    return switch (input) {
        .integer => |number| number,
        .long => |number| if (number < std.math.minInt(i16) or number > std.math.maxInt(i16)) error.Overflow else @intCast(number),
        .single => |number| roundToInteger(number),
        .double => |number| roundToInteger(number),
        .string => error.TypeMismatch,
    };
}

fn toLong(input: Value) Fault!i32 {
    return switch (input) {
        .integer => |number| number,
        .long => |number| number,
        .single => |number| roundToLong(number),
        .double => |number| roundToLong(number),
        .string => error.TypeMismatch,
    };
}

fn toSingle(input: Value) Fault!f32 {
    const number: f32 = switch (input) {
        .integer => |value| @floatFromInt(value),
        .long => |value| @floatFromInt(value),
        .single => |value| value,
        .double => |value| @floatCast(value),
        .string => return error.TypeMismatch,
    };
    if (!std.math.isFinite(number)) return error.Overflow;
    return number;
}

fn toDouble(input: Value) Fault!f64 {
    const number: f64 = switch (input) {
        .integer => |value| @floatFromInt(value),
        .long => |value| @floatFromInt(value),
        .single => |value| value,
        .double => |value| value,
        .string => return error.TypeMismatch,
    };
    if (!std.math.isFinite(number)) return error.Overflow;
    return number;
}

fn roundedFinite(number: f64) Fault!f64 {
    if (!std.math.isFinite(number)) return error.Overflow;
    return if (number >= 0) @floor(number + 0.5) else @ceil(number - 0.5);
}
