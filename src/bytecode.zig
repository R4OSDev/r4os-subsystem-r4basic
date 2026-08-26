const std = @import("std");
const frontend = @import("frontend.zig");

pub const contract_version = "1.3.0";
pub const invalid_index: u32 = std.math.maxInt(u32);
pub const unknown_dimensions: u8 = std.math.maxInt(u8);

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

    pub fn eql(self: Constant, source: []const u8, other: Constant) bool {
        if (self.valueType() != other.valueType()) return false;
        return switch (self) {
            .integer => |value| value == other.integer,
            .long => |value| value == other.long,
            .single => |value| @as(u32, @bitCast(value)) == @as(u32, @bitCast(other.single)),
            .double => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(other.double)),
            .string => |span| std.mem.eql(u8, span.bytes(source), other.string.bytes(source)),
        };
    }
};

pub const Variable = struct {
    name: frontend.Span,
    value_type: ValueType,
    record_type: u32 = invalid_index,
    dimensions: u8 = 0,
    is_dynamic: bool = false,
    is_constant: bool = false,
    is_parameter: bool = false,
    is_shared: bool = false,
    hidden: bool = false,

    pub fn isArray(self: Variable) bool {
        return self.dimensions != 0;
    }

    pub fn isRecord(self: Variable) bool {
        return self.record_type != invalid_index;
    }
};

pub const PassingMode = enum(u8) {
    by_ref,
    by_value,
};

pub const Parameter = struct {
    local_index: u32,
    value_type: ValueType,
    record_type: u32 = invalid_index,
    is_array: bool = false,
    accepts_any: bool = false,
    passing_mode: PassingMode,
};

pub const RecordField = struct {
    name: frontend.Span,
    value_type: ValueType,
};

pub const RecordType = struct {
    name: frontend.Span,
    fields: []RecordField,
};

pub const DataItem = struct {
    constant: Constant,
    string_is_quoted: bool = false,
};

pub const ProcedureKind = enum(u8) {
    sub,
    function,
    def_fn,
};

pub const FileMode = enum(u8) {
    input,
    output,
    append,
};

pub const GraphicsBoxMode = enum(u8) {
    line,
    box,
    filled_box,
};

pub const GraphicsPutAction = enum(u8) {
    pset,
    xor,
};

pub const graphics_point_relative: u32 = 1 << 0;
pub const graphics_second_point_relative: u32 = 1 << 1;
pub const graphics_color_present: u32 = 1 << 2;
pub const graphics_box_shift: u5 = 8;
pub const graphics_optional_count_shift: u5 = 8;

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
    array_default_lower,
    select_array_element,
    select_record_field,
    load_reference,
    store_reference,
    dimension,
    redimension,
    read_data,
    restore_data,
    set_error_handler,
    resume_error,
    resume_next,
    resume_label,
    set_segment,
    reset_segment,
    peek,
    poke,
    screen_mode_probe,
    graphics_palette,
    graphics_pset,
    graphics_line,
    graphics_circle,
    graphics_paint,
    graphics_get,
    graphics_put,
    text_width,
    text_color,
    text_cls,
    text_locate,
    text_view_print,
    print_begin_screen,
    print_begin_file,
    print_value,
    print_tab,
    print_comma,
    print_question,
    print_newline,
    print_end,
    input_console,
    input_file,
    randomize,
    sleep,
    file_open,
    file_close,
    audio_beep,
    audio_play,
    deferred_statement,
    deferred_builtin,
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
    peek,
    sin,
    space_string,
    str_string,
    ucase_string,
    val,
    eof,
    inkey_string,
    point,
    rnd,
    timer,
};

pub const Instruction = struct {
    op: OpCode,
    a: u32 = 0,
    b: u32 = 0,
    span: frontend.Span,
    statement_start: u32 = invalid_index,
    statement_next: u32 = invalid_index,
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
    invalid_array_bounds,
    wrong_dimension_count,
    unknown_type,
    unknown_field,
    invalid_record_access,
    invalid_array_argument,
    invalid_error_handler,
    invalid_data_item,
    block_mismatch,
    block_not_closed,
    expression_too_deep,
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
            .invalid_array_bounds => "array bounds are invalid",
            .wrong_dimension_count => "array reference has the wrong number of dimensions",
            .unknown_type => "user-defined type is not declared",
            .unknown_field => "record field is not declared",
            .invalid_record_access => "record value requires a declared field",
            .invalid_array_argument => "array argument must be a compatible whole array",
            .invalid_error_handler => "error handler target is invalid",
            .invalid_data_item => "DATA item is not a supported constant",
            .block_mismatch => "block terminator does not match the active block",
            .block_not_closed => "block is not closed before end of source",
            .expression_too_deep => "BASIC expression nesting exceeds the deterministic compiler limit",
            .capacity_exceeded => "compiled program exceeds a deterministic v1 capacity",
        };
    }
};

pub const CompileStats = struct {
    source_bytes: u32 = 0,
    tokens: u32 = 0,
    token_capacity: u32 = 0,
    token_bytes: u64 = 0,
    keyword_lookups: u64 = 0,
    keyword_probes: u64 = 0,
    keyword_max_probe: u16 = 0,
    name_lookups: u64 = 0,
    name_insertions: u64 = 0,
    name_probes: u64 = 0,
    name_max_probe: u16 = 0,
    index_rebuilds: u32 = 0,
    label_fixups: u32 = 0,
    data_fixups: u32 = 0,
    reused_statement_bindings: u32 = 0,
    constant_lookups: u32 = 0,
    constant_reuses: u32 = 0,
    constant_probes: u64 = 0,
    constant_max_probe: u16 = 0,
    diagnostics_total: u32 = 0,
    diagnostics_stored: u16 = 0,
    diagnostics_truncated: bool = false,
    maximum_expression_depth: u16 = 0,
    list_reservations: u16 = 0,
    initial_list_bytes: u64 = 0,
    allocator_allocations: u64 = 0,
    allocator_reallocations: u64 = 0,
    allocator_copy_bytes: u64 = 0,
    compiler_peak_bytes: u64 = 0,
    program_bytes: u64 = 0,
    adopted_source_bytes: u32 = 0,
    progress_updates: u32 = 0,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    file_name: []u8,
    source: []u8,
    instructions: []Instruction,
    constants: []Constant,
    globals: []Variable,
    procedures: []Procedure,
    record_types: []RecordType,
    data_items: []DataItem,
    diagnostics: []Diagnostic,
    diagnostics_total: u32 = 0,
    diagnostics_truncated: bool = false,
    module_entry: u32,
    parse_passes: u32 = 1,
    bind_passes: u32 = 1,
    compile_stats: CompileStats = .{},

    pub fn ok(self: Program) bool {
        return self.diagnostics_total == 0;
    }

    pub fn sourceBytes(self: Program, span: frontend.Span) []const u8 {
        return span.bytes(self.source);
    }

    pub fn deinit(self: *Program) void {
        for (self.procedures) |procedure| {
            self.allocator.free(procedure.locals);
            self.allocator.free(procedure.parameters);
        }
        for (self.record_types) |record_type| self.allocator.free(record_type.fields);
        self.allocator.free(self.record_types);
        self.allocator.free(self.data_items);
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
