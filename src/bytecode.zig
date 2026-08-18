const std = @import("std");
const frontend = @import("frontend.zig");

pub const contract_version = "1.0.0";
pub const invalid_index: u32 = std.math.maxInt(u32);

pub const ValueType = enum(u8) {
    integer,
    long,
    single,
    double,
    string,

    pub fn isNumeric(self: ValueType) bool {
        return self != .string;
    }
};

pub const Constant = union(ValueType) {
    integer: i16,
    long: i32,
    single: f32,
    double: f64,
    string: frontend.Span,

    pub fn valueType(self: Constant) ValueType {
        return std.meta.activeTag(self);
    }
};

pub const Variable = struct {
    name: frontend.Span,
    value_type: ValueType,
    is_constant: bool = false,
    is_parameter: bool = false,
    is_shared: bool = false,
    hidden: bool = false,
};

pub const PassingMode = enum(u8) {
    by_ref,
    by_value,
};

pub const Parameter = struct {
    local_index: u32,
    value_type: ValueType,
    passing_mode: PassingMode,
};

pub const ProcedureKind = enum(u8) {
    sub,
    function,
    def_fn,
};

pub const Procedure = struct {
    name: frontend.Span,
    kind: ProcedureKind,
    entry_ip: u32 = invalid_index,
    end_ip: u32 = invalid_index,
    return_local: u32 = invalid_index,
    return_type: ValueType = .single,
    locals: []Variable = &.{},
    parameters: []Parameter = &.{},

    pub fn returnsValue(self: Procedure) bool {
        return self.kind != .sub;
    }
};

pub const OpCode = enum(u8) {
    push_constant,
    load_global,
    load_local,
    store_global,
    store_local,
    initialize_global,
    initialize_local,
    push_global_reference,
    push_local_reference,
    convert,
    negate,
    logical_not,
    add,
    subtract,
    multiply,
    divide,
    integer_divide,
    modulo,
    power,
    compare_equal,
    compare_not_equal,
    compare_less,
    compare_less_equal,
    compare_greater,
    compare_greater_equal,
    logical_and,
    logical_or,
    logical_xor,
    call_builtin,
    call,
    return_procedure,
    jump,
    jump_if_false,
    jump_if_true,
    gosub,
    return_gosub,
    pop,
    halt,
};

pub const Builtin = enum(u8) {
    abs,
    atn,
    chr_string,
    cint,
    cos,
    instr,
    int,
    left_string,
    len,
    ltrim_string,
    mid_string,
    sin,
    space_string,
    str_string,
    ucase_string,
    val,
};

pub const Instruction = struct {
    op: OpCode,
    a: u32 = 0,
    b: u32 = 0,
    span: frontend.Span,
};

pub const DiagnosticCode = enum(u8) {
    lexical_error,
    expected_token,
    expected_identifier,
    expected_expression,
    unexpected_token,
    unsupported_core_feature,
    duplicate_symbol,
    symbol_kind_conflict,
    constant_assignment,
    type_mismatch,
    unknown_label,
    unknown_procedure,
    wrong_argument_count,
    invalid_byref_argument,
    invalid_number,
    block_mismatch,
    block_not_closed,
    capacity_exceeded,
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    span: frontend.Span,
    file_name: []const u8,
    frontend_code: ?frontend.DiagnosticCode = null,

    pub fn message(self: Diagnostic) []const u8 {
        return switch (self.code) {
            .lexical_error => "invalid BASIC source token",
            .expected_token => "required token is missing",
            .expected_identifier => "expected BASIC identifier",
            .expected_expression => "expected BASIC expression",
            .unexpected_token => "unexpected token in core-language compiler",
            .unsupported_core_feature => "feature belongs to a later R4BASIC layer",
            .duplicate_symbol => "symbol is already defined in this scope",
            .symbol_kind_conflict => "name conflicts with another symbol kind",
            .constant_assignment => "constant cannot be assigned",
            .type_mismatch => "numeric and string values cannot be combined",
            .unknown_label => "label is not defined in this scope",
            .unknown_procedure => "procedure or function is not declared",
            .wrong_argument_count => "procedure or function has the wrong number of arguments",
            .invalid_byref_argument => "ByRef argument must be a compatible scalar variable",
            .invalid_number => "numeric literal is outside the v1 value range",
            .block_mismatch => "block terminator does not match the active block",
            .block_not_closed => "block is not closed before end of source",
            .capacity_exceeded => "compiled program exceeds a deterministic v1 capacity",
        };
    }
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    file_name: []u8,
    source: []u8,
    instructions: []Instruction,
    constants: []Constant,
    globals: []Variable,
    procedures: []Procedure,
    diagnostics: []Diagnostic,
    module_entry: u32,
    parse_passes: u32 = 1,
    bind_passes: u32 = 1,

    pub fn ok(self: Program) bool {
        return self.diagnostics.len == 0;
    }

    pub fn sourceBytes(self: Program, span: frontend.Span) []const u8 {
        return span.bytes(self.source);
    }

    pub fn deinit(self: *Program) void {
        for (self.procedures) |procedure| {
            self.allocator.free(procedure.locals);
            self.allocator.free(procedure.parameters);
        }
        self.allocator.free(self.procedures);
        self.allocator.free(self.globals);
        self.allocator.free(self.constants);
        self.allocator.free(self.instructions);
        self.allocator.free(self.diagnostics);
        self.allocator.free(self.source);
        self.allocator.free(self.file_name);
        self.* = undefined;
    }
};

pub fn encodeValueType(value_type: ValueType) u32 {
    return @intFromEnum(value_type);
}

pub fn decodeValueType(value: u32) ValueType {
    return @enumFromInt(@as(u8, @intCast(value)));
}
