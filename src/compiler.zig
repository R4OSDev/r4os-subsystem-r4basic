const std = @import("std");
const frontend = @import("frontend.zig");
const bytecode = @import("bytecode.zig");
const values = @import("value.zig");

pub const maximum_instructions: usize = 262_144;
pub const maximum_constants: usize = 65_536;
pub const maximum_variables_per_scope: usize = 65_536;
pub const maximum_procedures: usize = 4_096;
pub const maximum_block_depth: usize = 128;
pub const maximum_array_dimensions: usize = 60;
pub const maximum_record_types: usize = 4_096;
pub const maximum_record_fields: usize = 4_096;

const ScopeStorage = enum(u8) {
    global,
    local,
};

const VariableReference = struct {
    storage: ScopeStorage,
    index: u32,
    value_type: bytecode.ValueType,
    record_type: u32,
    dimensions: u8,
    is_dynamic: bool,
    is_constant: bool,
    name: frontend.Span,
};

const BoundType = struct {
    value_type: bytecode.ValueType = .single,
    record_type: u32 = bytecode.invalid_index,
    accepts_any: bool = false,

    fn isRecord(self: BoundType) bool {
        return self.record_type != bytecode.invalid_index;
    }
};

const BoundLvalue = struct {
    value_type: bytecode.ValueType,
    record_type: u32 = bytecode.invalid_index,
    is_whole_array: bool = false,
    dimensions: u8 = 0,
    is_constant: bool = false,
};

const RecordTypeBuilder = struct {
    name: frontend.Span,
    fields: std.ArrayList(bytecode.RecordField) = .empty,

    fn deinit(self: *RecordTypeBuilder, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
    }
};

const ProcedureBuilder = struct {
    name: frontend.Span,
    kind: bytecode.ProcedureKind,
    entry_ip: u32 = bytecode.invalid_index,
    end_ip: u32 = bytecode.invalid_index,
    return_local: u32 = bytecode.invalid_index,
    return_type: bytecode.ValueType = .single,
    declared: bool = false,
    defined: bool = false,
    called: bool = false,
    locals: std.ArrayList(bytecode.Variable) = .empty,
    parameters: std.ArrayList(bytecode.Parameter) = .empty,

    fn deinit(self: *ProcedureBuilder, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
        self.parameters.deinit(allocator);
    }
};

const Label = struct {
    name: frontend.Span,
    procedure: u32,
    instruction: u32,
    data_index: u32,
};

const LabelFixup = struct {
    name: frontend.Span,
    procedure: u32,
    instruction: u32,
};

const DataFixup = struct {
    name: frontend.Span,
    instruction: u32,
};

const BlockKind = enum(u8) {
    if_block,
    select_block,
    for_block,
    while_block,
    do_block,
};

const Block = struct {
    kind: BlockKind,
    span: frontend.Span,
    procedure: u32,
    start_ip: u32 = 0,
    body_ip: u32 = 0,
    false_jump: u32 = bytecode.invalid_index,
    control: ?VariableReference = null,
    limit: ?VariableReference = null,
    step: ?VariableReference = null,
    has_case: bool = false,
    has_else: bool = false,
    has_leading_condition: bool = false,
    exit_jumps: std.ArrayList(u32) = .empty,
    end_jumps: std.ArrayList(u32) = .empty,

    fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.exit_jumps.deinit(allocator);
        self.end_jumps.deinit(allocator);
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    file_name: []u8,
    source: []u8,
    tokens: []const frontend.Token,
    index: usize = 0,
    instructions: std.ArrayList(bytecode.Instruction) = .empty,
    constants: std.ArrayList(bytecode.Constant) = .empty,
    globals: std.ArrayList(bytecode.Variable) = .empty,
    procedures: std.ArrayList(ProcedureBuilder) = .empty,
    record_types: std.ArrayList(RecordTypeBuilder) = .empty,
    data_items: std.ArrayList(bytecode.DataItem) = .empty,
    diagnostics: std.ArrayList(bytecode.Diagnostic) = .empty,
    labels: std.ArrayList(Label) = .empty,
    label_fixups: std.ArrayList(LabelFixup) = .empty,
    data_fixups: std.ArrayList(DataFixup) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    default_types: [26]bytecode.ValueType = [_]bytecode.ValueType{.single} ** 26,
    current_procedure: u32 = bytecode.invalid_index,
    current_procedure_skip: u32 = bytecode.invalid_index,
    arrays_dynamic: bool = false,
    stopped: bool = false,

    fn deinit(self: *Builder) void {
        for (self.procedures.items) |*procedure| procedure.deinit(self.allocator);
        for (self.record_types.items) |*record_type| record_type.deinit(self.allocator);
        for (self.blocks.items) |*block| block.deinit(self.allocator);
        self.instructions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.procedures.deinit(self.allocator);
        self.record_types.deinit(self.allocator);
        self.data_items.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.label_fixups.deinit(self.allocator);
        self.data_fixups.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.allocator.free(self.source);
        self.allocator.free(self.file_name);
    }

    fn parse(self: *Builder) !void {
        while (!self.at(.eof) and !self.stopped) {
            if (self.consume(.newline) or self.consume(.colon)) continue;
            if (self.at(.metacommand)) {
                const command = self.advance();
                if (command.keyword == .dynamic) self.arrays_dynamic = true;
                if (command.keyword == .static) self.arrays_dynamic = false;
                continue;
            }
            if (self.at(.identifier) and self.peek(1).kind == .colon) {
                try self.defineLabel();
                continue;
            }

            const before = self.index;
            if (!try self.parseBoundStatement(false)) {
                if (self.index == before) _ = self.advance();
                self.synchronize();
            } else if (!self.atBoundary() and !self.atKeyword(.else_)) {
                try self.addDiagnostic(.unexpected_token, self.current().span);
                self.synchronize();
            }
        }

        if (self.current_procedure != bytecode.invalid_index) {
            try self.addDiagnostic(.block_not_closed, self.procedures.items[self.current_procedure].name);
        }
        while (self.blocks.items.len != 0) {
            var block = self.blocks.pop().?;
            try self.addDiagnostic(.block_not_closed, block.span);
            block.deinit(self.allocator);
        }
        if (self.instructions.items.len == 0 or self.instructions.items[self.instructions.items.len - 1].op != .halt) {
            _ = try self.emit(.halt, 0, 0, self.current().span);
        }
        try self.resolveLabels();
        try self.resolveDataFixups();
        for (self.procedures.items) |procedure| {
            if (procedure.called and !procedure.defined) try self.addDiagnostic(.unknown_procedure, procedure.name);
        }
    }

    fn parseBoundStatement(self: *Builder, inline_statement: bool) std.mem.Allocator.Error!bool {
        const start = self.currentIp();
        const result = try self.parseStatement(inline_statement);
        const next = self.currentIp();
        for (self.instructions.items[start..next]) |*instruction| {
            if (instruction.statement_start == bytecode.invalid_index) {
                instruction.statement_start = start;
                instruction.statement_next = next;
            }
        }
        return result;
    }

    fn parseStatement(self: *Builder, inline_statement: bool) std.mem.Allocator.Error!bool {
        if (self.at(.identifier)) return self.parseAssignmentOrImplicitCall();
        if (!self.at(.keyword)) return self.fail(.unexpected_token);

        return switch (self.current().keyword) {
            .const_ => self.parseConst(),
            .defint => self.parseDefInt(),
            .dim => self.parseDim(),
            .redim => self.parseRedim(),
            .type => self.parseTypeBlock(),
            .data => self.parseData(),
            .read => self.parseRead(),
            .restore => self.parseRestore(),
            .declare => self.parseDeclare(),
            .def => self.parseDefFn(),
            .sub => self.parseProcedureDefinition(.sub),
            .function => self.parseProcedureDefinition(.function),
            .let => self.parseLet(),
            .call => self.parseCallStatement(),
            .if_ => self.parseIf(inline_statement),
            .elseif => self.parseElseIf(),
            .else_ => self.parseElse(),
            .select => self.parseSelect(),
            .case => self.parseCase(),
            .for_ => self.parseFor(),
            .next => self.parseNext(),
            .while_ => self.parseWhile(),
            .wend => self.parseWend(),
            .do_ => self.parseDo(),
            .loop => self.parseLoop(),
            .goto_ => self.parseBranch(.jump),
            .gosub => self.parseBranch(.gosub),
            .on => self.parseOnError(),
            .resume_ => self.parseResume(),
            .poke => self.parsePoke(),
            .screen => self.parseScreen(),
            .width => self.parseTextWidth(),
            .color => self.parseTextColor(),
            .cls => self.parseTextCls(),
            .locate => self.parseTextLocate(),
            .view => self.parseTextView(),
            .print => self.parsePrintStatement(),
            .input => self.parseInputStatement(false),
            .line => self.parseLineStatement(),
            .palette => self.parseGraphicsPalette(),
            .pset => self.parseGraphicsPset(),
            .circle => self.parseGraphicsCircle(),
            .paint => self.parseGraphicsPaint(),
            .get => self.parseGraphicsGet(),
            .put => self.parseGraphicsPut(),
            .randomize => self.parseRandomize(),
            .sleep => self.parseSleep(),
            .open => self.parseOpen(),
            .close => self.parseClose(),
            .beep => self.parseAudioBeep(),
            .play => self.parseAudioPlay(),
            .return_ => self.parseReturn(),
            .exit => self.parseExit(),
            .end => self.parseEnd(),
            .unsupported => self.fail(.unsupported_core_feature),
            else => self.parseDeferredStatement(),
        };
    }

    fn tokenText(self: Builder, token: frontend.Token) []const u8 {
        return token.text(self.source);
    }

    fn namesEqual(self: Builder, first: frontend.Span, second: frontend.Span) bool {
        return std.ascii.eqlIgnoreCase(first.bytes(self.source), second.bytes(self.source));
    }

    fn suffixType(self: Builder, span: frontend.Span) ?bytecode.ValueType {
        const text = span.bytes(self.source);
        if (text.len == 0) return null;
        return switch (text[text.len - 1]) {
            '%' => .integer,
            '&' => .long,
            '!' => .single,
            '#' => .double,
            '$' => .string,
            else => null,
        };
    }

    fn inferredType(self: Builder, span: frontend.Span) bytecode.ValueType {
        if (self.suffixType(span)) |explicit| return explicit;
        const text = span.bytes(self.source);
        if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return .single;
        return self.default_types[std.ascii.toUpper(text[0]) - 'A'];
    }

    fn parseBoundType(self: *Builder) !?BoundType {
        if (self.at(.identifier)) {
            const name = self.advance();
            const record_type = self.findRecordType(name.span) orelse {
                try self.addDiagnostic(.unknown_type, name.span);
                return null;
            };
            return .{ .record_type = record_type };
        }
        if (!self.at(.keyword)) {
            _ = try self.fail(.expected_identifier);
            return null;
        }
        const result: BoundType = switch (self.current().keyword) {
            .integer => .{ .value_type = .integer },
            .long => .{ .value_type = .long },
            .single => .{ .value_type = .single },
            .double => .{ .value_type = .double },
            .string => .{ .value_type = .string },
            .any => .{ .accepts_any = true },
            else => {
                _ = try self.fail(.expected_identifier);
                return null;
            },
        };
        _ = self.advance();
        return result;
    }

    fn findRecordType(self: Builder, name: frontend.Span) ?u32 {
        for (self.record_types.items, 0..) |record_type, index| {
            if (self.namesEqual(record_type.name, name)) return @intCast(index);
        }
        return null;
    }

    fn findRecordField(self: Builder, record_type: u32, name: frontend.Span) ?u32 {
        if (record_type >= self.record_types.items.len) return null;
        for (self.record_types.items[record_type].fields.items, 0..) |field, index| {
            if (self.namesEqual(field.name, name)) return @intCast(index);
        }
        return null;
    }

    fn findGlobal(self: Builder, name: frontend.Span) ?u32 {
        for (self.globals.items, 0..) |variable, index| {
            if (!variable.hidden and self.namesEqual(variable.name, name)) return @intCast(index);
        }
        return null;
    }

    fn findLocal(self: Builder, procedure_id: u32, name: frontend.Span) ?u32 {
        if (procedure_id == bytecode.invalid_index) return null;
        for (self.procedures.items[procedure_id].locals.items, 0..) |variable, index| {
            if (!variable.hidden and self.namesEqual(variable.name, name)) return @intCast(index);
        }
        return null;
    }

    fn variableReference(self: Builder, storage: ScopeStorage, index: u32) VariableReference {
        const variable = switch (storage) {
            .global => self.globals.items[index],
            .local => self.procedures.items[self.current_procedure].locals.items[index],
        };
        return .{
            .storage = storage,
            .index = index,
            .value_type = variable.value_type,
            .record_type = variable.record_type,
            .dimensions = variable.dimensions,
            .is_dynamic = variable.is_dynamic,
            .is_constant = variable.is_constant,
            .name = variable.name,
        };
    }

    fn resolveVariable(self: *Builder, name: frontend.Span, create: bool) !?VariableReference {
        if (self.current_procedure != bytecode.invalid_index) {
            if (self.findLocal(self.current_procedure, name)) |index| return self.variableReference(.local, index);

            const procedure = self.procedures.items[self.current_procedure];
            if (self.findGlobal(name)) |index| {
                const global = self.globals.items[index];
                if (procedure.kind == .def_fn or global.is_shared or global.is_constant) return self.variableReference(.global, index);
            }
            if (!create) return null;
            const local_index = try self.addLocal(self.current_procedure, .{
                .name = name,
                .value_type = self.inferredType(name),
            });
            return self.variableReference(.local, local_index);
        }

        if (self.findGlobal(name)) |index| return self.variableReference(.global, index);
        if (!create) return null;
        const global_index = try self.addGlobal(.{ .name = name, .value_type = self.inferredType(name) });
        return self.variableReference(.global, global_index);
    }

    fn addGlobal(self: *Builder, variable: bytecode.Variable) !u32 {
        if (self.globals.items.len >= maximum_variables_per_scope) {
            try self.addDiagnostic(.capacity_exceeded, variable.name);
            self.stopped = true;
            return 0;
        }
        const index: u32 = @intCast(self.globals.items.len);
        try self.globals.append(self.allocator, variable);
        return index;
    }

    fn addLocal(self: *Builder, procedure_id: u32, variable: bytecode.Variable) !u32 {
        var procedure = &self.procedures.items[procedure_id];
        if (procedure.locals.items.len >= maximum_variables_per_scope) {
            try self.addDiagnostic(.capacity_exceeded, variable.name);
            self.stopped = true;
            return 0;
        }
        const index: u32 = @intCast(procedure.locals.items.len);
        try procedure.locals.append(self.allocator, variable);
        return index;
    }

    fn addHidden(self: *Builder, value_type: bytecode.ValueType, span: frontend.Span) !VariableReference {
        if (self.current_procedure == bytecode.invalid_index) {
            const index = try self.addGlobal(.{ .name = span, .value_type = value_type, .hidden = true });
            return self.variableReference(.global, index);
        }
        const index = try self.addLocal(self.current_procedure, .{ .name = span, .value_type = value_type, .hidden = true });
        return self.variableReference(.local, index);
    }

    fn emitLoad(self: *Builder, variable: VariableReference, span: frontend.Span) !void {
        _ = try self.emit(if (variable.storage == .global) .load_global else .load_local, variable.index, 0, span);
    }

    fn emitStore(self: *Builder, variable: VariableReference, initialize: bool, span: frontend.Span) !void {
        if (variable.is_constant and !initialize) {
            try self.addDiagnostic(.constant_assignment, span);
            return;
        }
        const op: bytecode.OpCode = if (initialize)
            if (variable.storage == .global) .initialize_global else .initialize_local
        else if (variable.storage == .global)
            .store_global
        else
            .store_local;
        _ = try self.emit(op, variable.index, bytecode.encodeValueType(variable.value_type), span);
    }

    fn emitReference(self: *Builder, variable: VariableReference, span: frontend.Span) !void {
        _ = try self.emit(if (variable.storage == .global) .push_global_reference else .push_local_reference, variable.index, 0, span);
    }

    fn findProcedure(self: Builder, name: frontend.Span) ?u32 {
        for (self.procedures.items, 0..) |procedure, index| {
            if (self.namesEqual(procedure.name, name)) return @intCast(index);
        }
        return null;
    }

    fn addProcedure(self: *Builder, name: frontend.Span, kind: bytecode.ProcedureKind) !u32 {
        if (self.procedures.items.len >= maximum_procedures) {
            try self.addDiagnostic(.capacity_exceeded, name);
            self.stopped = true;
            return 0;
        }
        const index: u32 = @intCast(self.procedures.items.len);
        try self.procedures.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .return_type = if (kind == .sub) .single else self.inferredType(name),
        });
        return index;
    }

    fn defineLabel(self: *Builder) !void {
        const name = self.advance().span;
        _ = self.advance();
        for (self.labels.items) |label| {
            if (label.procedure == self.currentScope() and self.namesEqual(label.name, name)) {
                try self.addDiagnostic(.duplicate_symbol, name);
                return;
            }
        }
        try self.labels.append(self.allocator, .{
            .name = name,
            .procedure = self.currentScope(),
            .instruction = self.currentIp(),
            .data_index = @intCast(self.data_items.items.len),
        });
    }

    fn addLabelFixup(self: *Builder, name: frontend.Span, instruction: u32) !void {
        try self.label_fixups.append(self.allocator, .{
            .name = name,
            .procedure = self.currentScope(),
            .instruction = instruction,
        });
    }

    fn resolveLabels(self: *Builder) !void {
        for (self.label_fixups.items) |fixup| {
            var target: ?u32 = null;
            for (self.labels.items) |label| {
                if (label.procedure == fixup.procedure and self.namesEqual(label.name, fixup.name)) {
                    target = label.instruction;
                    break;
                }
            }
            if (target) |instruction| {
                self.patchJump(fixup.instruction, instruction);
            } else {
                try self.addDiagnostic(.unknown_label, fixup.name);
            }
        }
    }

    fn resolveDataFixups(self: *Builder) !void {
        for (self.data_fixups.items) |fixup| {
            var target: ?u32 = null;
            for (self.labels.items) |label| {
                if (label.procedure == bytecode.invalid_index and self.namesEqual(label.name, fixup.name)) {
                    target = label.data_index;
                    break;
                }
            }
            if (target) |data_index| {
                self.instructions.items[fixup.instruction].a = data_index;
            } else {
                try self.addDiagnostic(.unknown_label, fixup.name);
            }
        }
    }

    fn parseConst(self: *Builder) !bool {
        const statement = self.advance();
        while (true) {
            const name_token = (try self.expectIdentifier()) orelse return false;
            if (!try self.expect(.equal)) return false;
            const expression_type = (try self.parseExpression()) orelse return false;
            const value_type = self.suffixType(name_token.span) orelse expression_type;
            if (!typesCompatible(value_type, expression_type)) try self.addDiagnostic(.type_mismatch, name_token.span);

            var reference: VariableReference = undefined;
            if (self.current_procedure == bytecode.invalid_index) {
                if (self.findGlobal(name_token.span) != null) {
                    try self.addDiagnostic(.duplicate_symbol, name_token.span);
                    _ = try self.emit(.pop, 0, 0, name_token.span);
                } else {
                    const index = try self.addGlobal(.{
                        .name = name_token.span,
                        .value_type = value_type,
                        .is_constant = true,
                        .is_shared = true,
                    });
                    reference = self.variableReference(.global, index);
                    try self.emitStore(reference, true, statement.span);
                }
            } else {
                if (self.findLocal(self.current_procedure, name_token.span) != null) {
                    try self.addDiagnostic(.duplicate_symbol, name_token.span);
                    _ = try self.emit(.pop, 0, 0, name_token.span);
                } else {
                    const index = try self.addLocal(self.current_procedure, .{
                        .name = name_token.span,
                        .value_type = value_type,
                        .is_constant = true,
                    });
                    reference = self.variableReference(.local, index);
                    try self.emitStore(reference, true, statement.span);
                }
            }
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseDefInt(self: *Builder) !bool {
        _ = self.advance();
        while (true) {
            const first = (try self.expectIdentifier()) orelse return false;
            var last = first;
            if (self.consume(.minus)) last = (try self.expectIdentifier()) orelse return false;
            const first_text = self.tokenText(first);
            const last_text = self.tokenText(last);
            if (first_text.len == 0 or last_text.len == 0) return self.fail(.expected_identifier);
            const first_letter = std.ascii.toUpper(first_text[0]);
            const last_letter = std.ascii.toUpper(last_text[0]);
            if (first_letter < 'A' or first_letter > 'Z' or last_letter < first_letter or last_letter > 'Z') {
                try self.addDiagnostic(.unexpected_token, first.span);
            } else {
                var letter = first_letter;
                while (letter <= last_letter) : (letter += 1) self.default_types[letter - 'A'] = .integer;
            }
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseDim(self: *Builder) !bool {
        const statement = self.advance();
        const shared = self.consumeKeyword(.shared);
        while (true) {
            const name_token = (try self.expectIdentifier()) orelse return false;
            var dimensions: u8 = 0;
            if (self.consume(.left_paren)) {
                dimensions = (try self.parseArrayBounds()) orelse return false;
            }

            var bound_type = BoundType{ .value_type = self.inferredType(name_token.span) };
            if (self.consumeKeyword(.as)) {
                bound_type = (try self.parseBoundType()) orelse return false;
                if (bound_type.accepts_any) {
                    try self.addDiagnostic(.unknown_type, name_token.span);
                    return false;
                }
                if (self.suffixType(name_token.span)) |suffix| {
                    if (bound_type.isRecord() or suffix != bound_type.value_type) try self.addDiagnostic(.type_mismatch, name_token.span);
                }
            }

            const variable = try self.declareVariable(name_token.span, bound_type, shared, dimensions, self.arrays_dynamic);
            if (dimensions != 0) {
                try self.emitReference(variable, name_token.span);
                _ = try self.emit(.dimension, dimensions, 0, statement.span);
            }
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseArrayBounds(self: *Builder) !?u8 {
        if (self.consume(.right_paren)) {
            try self.addDiagnostic(.invalid_array_bounds, self.tokens[self.index - 1].span);
            return null;
        }
        var dimensions: usize = 0;
        while (true) {
            if (dimensions >= maximum_array_dimensions) {
                try self.addDiagnostic(.capacity_exceeded, self.current().span);
                return null;
            }
            _ = (try self.parseExpression()) orelse return null;
            if (self.consumeKeyword(.to)) {
                _ = (try self.parseExpression()) orelse return null;
            } else {
                _ = try self.emit(.array_default_lower, 0, 0, self.tokens[self.index - 1].span);
            }
            dimensions += 1;
            if (!self.consume(.comma)) break;
        }
        if (!try self.expect(.right_paren)) return null;
        return @intCast(dimensions);
    }

    fn declareVariable(
        self: *Builder,
        name: frontend.Span,
        bound_type: BoundType,
        shared: bool,
        dimensions: u8,
        is_dynamic: bool,
    ) !VariableReference {
        if (self.current_procedure == bytecode.invalid_index or shared) {
            if (self.findGlobal(name)) |index| {
                var variable = &self.globals.items[index];
                if (variable.value_type != bound_type.value_type or variable.record_type != bound_type.record_type) {
                    try self.addDiagnostic(.type_mismatch, name);
                }
                if (variable.dimensions != dimensions) try self.addDiagnostic(.wrong_dimension_count, name);
                if (shared) variable.is_shared = true;
                if (is_dynamic) variable.is_dynamic = true;
                return self.variableReference(.global, index);
            }
            const index = try self.addGlobal(.{
                .name = name,
                .value_type = bound_type.value_type,
                .record_type = bound_type.record_type,
                .dimensions = dimensions,
                .is_dynamic = is_dynamic,
                .is_shared = shared,
            });
            return self.variableReference(.global, index);
        }

        if (self.findLocal(self.current_procedure, name)) |index| {
            const variable = &self.procedures.items[self.current_procedure].locals.items[index];
            if (variable.value_type != bound_type.value_type or variable.record_type != bound_type.record_type) {
                try self.addDiagnostic(.type_mismatch, name);
            }
            if (variable.dimensions != dimensions) try self.addDiagnostic(.wrong_dimension_count, name);
            if (is_dynamic) variable.is_dynamic = true;
            return self.variableReference(.local, index);
        }
        const index = try self.addLocal(self.current_procedure, .{
            .name = name,
            .value_type = bound_type.value_type,
            .record_type = bound_type.record_type,
            .dimensions = dimensions,
            .is_dynamic = is_dynamic,
        });
        return self.variableReference(.local, index);
    }

    fn parseRedim(self: *Builder) !bool {
        const statement = self.advance();
        const shared = self.consumeKeyword(.shared);
        while (true) {
            const name = (try self.expectIdentifier()) orelse return false;
            if (!try self.expect(.left_paren)) return false;
            const dimensions = (try self.parseArrayBounds()) orelse return false;
            const existing = try self.resolveVariable(name.span, false);
            var bound_type = if (existing) |reference|
                BoundType{ .value_type = reference.value_type, .record_type = reference.record_type }
            else
                BoundType{ .value_type = self.inferredType(name.span) };
            if (self.consumeKeyword(.as)) bound_type = (try self.parseBoundType()) orelse return false;

            var reference = existing orelse try self.declareVariable(name.span, bound_type, shared, dimensions, true);
            if (reference.dimensions == 0) try self.addDiagnostic(.invalid_array_argument, name.span);
            if (reference.dimensions != bytecode.unknown_dimensions and reference.dimensions != dimensions) {
                try self.addDiagnostic(.wrong_dimension_count, name.span);
            }
            if (reference.value_type != bound_type.value_type or reference.record_type != bound_type.record_type) {
                try self.addDiagnostic(.type_mismatch, name.span);
            }
            reference.is_dynamic = true;
            switch (reference.storage) {
                .global => self.globals.items[reference.index].is_dynamic = true,
                .local => self.procedures.items[self.current_procedure].locals.items[reference.index].is_dynamic = true,
            }
            try self.emitReference(reference, name.span);
            _ = try self.emit(.redimension, dimensions, 0, statement.span);
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseTypeBlock(self: *Builder) !bool {
        const statement = self.advance();
        if (self.current_procedure != bytecode.invalid_index) return self.fail(.unexpected_token);
        const name = (try self.expectIdentifier()) orelse return false;
        if (self.findRecordType(name.span) != null) {
            try self.addDiagnostic(.duplicate_symbol, name.span);
            return false;
        }
        if (self.record_types.items.len >= maximum_record_types) {
            try self.addDiagnostic(.capacity_exceeded, name.span);
            return false;
        }
        const record_index: u32 = @intCast(self.record_types.items.len);
        try self.record_types.append(self.allocator, .{ .name = name.span });
        errdefer {
            var record_type = self.record_types.pop().?;
            record_type.deinit(self.allocator);
        }

        if (!self.atBoundary()) return self.fail(.unexpected_token);
        while (self.consume(.newline) or self.consume(.colon)) {}
        while (!self.at(.eof)) {
            if (self.atKeyword(.end) and self.peek(1).kind == .keyword and self.peek(1).keyword == .type) {
                _ = self.advance();
                _ = self.advance();
                return true;
            }
            const field_name = (try self.expectIdentifier()) orelse return false;
            if (!try self.expectKeyword(.as)) return false;
            const field_type = (try self.parseBoundType()) orelse return false;
            if (field_type.accepts_any or field_type.isRecord()) {
                try self.addDiagnostic(.unsupported_core_feature, field_name.span);
            }
            var record_type = &self.record_types.items[record_index];
            if (record_type.fields.items.len >= maximum_record_fields) {
                try self.addDiagnostic(.capacity_exceeded, field_name.span);
                return false;
            }
            for (record_type.fields.items) |field| {
                if (self.namesEqual(field.name, field_name.span)) {
                    try self.addDiagnostic(.duplicate_symbol, field_name.span);
                    break;
                }
            }
            try record_type.fields.append(self.allocator, .{ .name = field_name.span, .value_type = field_type.value_type });
            if (!self.atBoundary()) return self.fail(.unexpected_token);
            while (self.consume(.newline) or self.consume(.colon)) {}
        }
        try self.addDiagnostic(.block_not_closed, statement.span);
        return false;
    }

    fn parseData(self: *Builder) !bool {
        _ = self.advance();
        if (self.current_procedure != bytecode.invalid_index) {
            try self.addDiagnostic(.unexpected_token, self.current().span);
            return false;
        }
        if (self.atBoundary()) return self.fail(.invalid_data_item);
        while (true) {
            var negative = false;
            if (self.consume(.plus)) {
                negative = false;
            } else if (self.consume(.minus)) {
                negative = true;
            }
            if (self.at(.number)) {
                const token = self.advance();
                const constant = parseSignedNumericConstant(self.allocator, self.tokenText(token), negative) catch {
                    try self.addDiagnostic(.invalid_number, token.span);
                    return false;
                };
                try self.data_items.append(self.allocator, .{ .constant = constant });
            } else if (!negative and self.at(.string)) {
                const token = self.advance();
                try self.data_items.append(self.allocator, .{ .constant = .{ .string = token.span }, .string_is_quoted = true });
            } else if (!negative and (self.at(.identifier) or self.at(.keyword))) {
                const token = self.advance();
                try self.data_items.append(self.allocator, .{ .constant = .{ .string = token.span } });
            } else {
                return self.fail(.invalid_data_item);
            }
            if (!self.consume(.comma)) break;
            if (self.atBoundary()) return self.fail(.invalid_data_item);
        }
        return true;
    }

    fn parseRead(self: *Builder) !bool {
        const statement = self.advance();
        while (true) {
            const name = (try self.expectIdentifier()) orelse return false;
            const target = (try self.parseLvalueReference(name, true)) orelse return false;
            if (target.is_whole_array or target.record_type != bytecode.invalid_index) {
                try self.addDiagnostic(.invalid_record_access, name.span);
                return false;
            }
            _ = try self.emit(.read_data, bytecode.encodeValueType(target.value_type), 0, statement.span);
            if (!self.consume(.comma)) break;
        }
        return true;
    }

    fn parseRestore(self: *Builder) !bool {
        const statement = self.advance();
        if (self.atBoundary() or self.atKeyword(.else_)) {
            _ = try self.emit(.restore_data, 0, 0, statement.span);
            return true;
        }
        const label = (try self.expectIdentifier()) orelse return false;
        const instruction = try self.emit(.restore_data, bytecode.invalid_index, 0, statement.span);
        try self.data_fixups.append(self.allocator, .{ .name = label.span, .instruction = instruction });
        return true;
    }

    fn parseOnError(self: *Builder) !bool {
        const statement = self.advance();
        if (!try self.expectKeyword(.error_)) return false;
        if (!try self.expectKeyword(.goto_)) return false;
        if (self.at(.number)) {
            const target = self.advance();
            if (!std.mem.eql(u8, self.tokenText(target), "0")) {
                try self.addDiagnostic(.invalid_error_handler, target.span);
                return false;
            }
            _ = try self.emit(.set_error_handler, bytecode.invalid_index, 0, statement.span);
            return true;
        }
        const label = (try self.expectIdentifier()) orelse return false;
        const instruction = try self.emit(.set_error_handler, bytecode.invalid_index, 0, statement.span);
        try self.addLabelFixup(label.span, instruction);
        return true;
    }

    fn parseResume(self: *Builder) !bool {
        const statement = self.advance();
        if (self.consumeKeyword(.next)) {
            _ = try self.emit(.resume_next, 0, 0, statement.span);
            return true;
        }
        if (self.at(.number)) {
            const zero = self.advance();
            if (!std.mem.eql(u8, self.tokenText(zero), "0")) {
                try self.addDiagnostic(.invalid_error_handler, zero.span);
                return false;
            }
            _ = try self.emit(.resume_error, 0, 0, statement.span);
            return true;
        }
        if (self.at(.identifier)) {
            const label = self.advance();
            const instruction = try self.emit(.resume_label, bytecode.invalid_index, 0, statement.span);
            try self.addLabelFixup(label.span, instruction);
            return true;
        }
        _ = try self.emit(.resume_error, 0, 0, statement.span);
        return true;
    }

    fn parsePoke(self: *Builder) !bool {
        const statement = self.advance();
        const address_type = (try self.parseExpression()) orelse return false;
        if (!address_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        if (!try self.expect(.comma)) return false;
        const byte_type = (try self.parseExpression()) orelse return false;
        if (!byte_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        _ = try self.emit(.poke, 0, 0, statement.span);
        return true;
    }

    fn parseScreen(self: *Builder) !bool {
        const statement = self.advance();
        const mode_type = (try self.parseExpression()) orelse return false;
        if (!mode_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        _ = try self.emit(.screen_mode_probe, 0, 0, statement.span);
        return true;
    }

    fn parseTextWidth(self: *Builder) !bool {
        const statement = self.advance();
        const columns_type = (try self.parseExpression()) orelse return false;
        if (!columns_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        var count: u32 = 1;
        if (self.consume(.comma)) {
            const rows_type = (try self.parseExpression()) orelse return false;
            if (!rows_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            count = 2;
        }
        _ = try self.emit(.text_width, count, 0, statement.span);
        return true;
    }

    fn parseTextColor(self: *Builder) !bool {
        const statement = self.advance();
        var mask: u32 = 0;
        var count: u32 = 0;
        var position: u32 = 0;
        while (position < 2 and !self.atBoundary() and !self.atKeyword(.else_)) : (position += 1) {
            if (!self.at(.comma)) {
                const value_type = (try self.parseExpression()) orelse return false;
                if (!value_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
                mask |= @as(u32, 1) << @intCast(position);
                count += 1;
            }
            if (!self.consume(.comma)) break;
        }
        _ = try self.emit(.text_color, mask, count, statement.span);
        return true;
    }

    fn parseTextCls(self: *Builder) !bool {
        const statement = self.advance();
        var count: u32 = 0;
        if (!self.atBoundary() and !self.atKeyword(.else_)) {
            const mode_type = (try self.parseExpression()) orelse return false;
            if (!mode_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            count = 1;
        }
        _ = try self.emit(.text_cls, count, 0, statement.span);
        return true;
    }

    fn parseTextLocate(self: *Builder) !bool {
        const statement = self.advance();
        var mask: u32 = 0;
        var count: u32 = 0;
        var position: u32 = 0;
        while (position < 5 and !self.atBoundary() and !self.atKeyword(.else_)) : (position += 1) {
            if (!self.at(.comma)) {
                const value_type = (try self.parseExpression()) orelse return false;
                if (!value_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
                mask |= @as(u32, 1) << @intCast(position);
                count += 1;
            }
            if (!self.consume(.comma)) break;
        }
        _ = try self.emit(.text_locate, mask, count, statement.span);
        return true;
    }

    fn parseTextView(self: *Builder) !bool {
        const statement = self.advance();
        if (!try self.expectKeyword(.print)) return false;
        if (self.atBoundary() or self.atKeyword(.else_)) {
            _ = try self.emit(.text_view_print, 0, 0, statement.span);
            return true;
        }
        const top_type = (try self.parseExpression()) orelse return false;
        if (!top_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        if (!try self.expectKeyword(.to)) return false;
        const bottom_type = (try self.parseExpression()) orelse return false;
        if (!bottom_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        _ = try self.emit(.text_view_print, 2, 0, statement.span);
        return true;
    }

    fn parsePrintStatement(self: *Builder) !bool {
        const statement = self.advance();
        if (self.consume(.hash)) {
            const file_type = (try self.parseExpression()) orelse return false;
            if (!file_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            if (!try self.expect(.comma)) return false;
            _ = try self.emit(.print_begin_file, 0, 0, statement.span);
        } else {
            _ = try self.emit(.print_begin_screen, 0, 0, statement.span);
        }

        var trailing_separator = false;
        while (!self.atBoundary() and !self.atKeyword(.else_)) {
            if (self.consume(.semicolon)) {
                trailing_separator = true;
                continue;
            }
            if (self.consume(.comma)) {
                _ = try self.emit(.print_comma, 0, 0, statement.span);
                trailing_separator = true;
                continue;
            }
            if (self.consumeKeyword(.tab)) {
                if (!try self.expect(.left_paren)) return false;
                const column_type = (try self.parseExpression()) orelse return false;
                if (!column_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
                if (!try self.expect(.right_paren)) return false;
                _ = try self.emit(.print_tab, 0, 0, statement.span);
                trailing_separator = false;
                continue;
            }
            const value_type = (try self.parseExpression()) orelse return false;
            _ = value_type;
            _ = try self.emit(.print_value, 0, 0, statement.span);
            trailing_separator = false;
        }
        if (!trailing_separator) _ = try self.emit(.print_newline, 0, 0, statement.span);
        _ = try self.emit(.print_end, 0, 0, statement.span);
        return true;
    }

    fn parseInputStatement(self: *Builder, line_input: bool) !bool {
        const statement = self.advance();
        return self.parseInputBody(statement, line_input);
    }

    fn parseLineStatement(self: *Builder) !bool {
        const statement = self.advance();
        if (self.consumeKeyword(.input)) return self.parseInputBody(statement, true);

        const first_relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        if (!try self.expect(.minus)) return false;
        const second_relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        var flags: u32 = if (first_relative) bytecode.graphics_point_relative else 0;
        if (second_relative) flags |= bytecode.graphics_second_point_relative;
        var box_mode: bytecode.GraphicsBoxMode = .line;
        if (self.consume(.comma)) {
            if (!self.at(.comma) and !self.atBoundary() and !self.atKeyword(.else_)) {
                const color_type = (try self.parseExpression()) orelse return false;
                if (!color_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
                flags |= bytecode.graphics_color_present;
            }
            if (self.consume(.comma)) {
                const mode = (try self.expectIdentifier()) orelse return false;
                const text = self.tokenText(mode);
                if (std.ascii.eqlIgnoreCase(text, "B")) {
                    box_mode = .box;
                } else if (std.ascii.eqlIgnoreCase(text, "BF")) {
                    box_mode = .filled_box;
                } else {
                    try self.addDiagnostic(.unexpected_token, mode.span);
                    return false;
                }
            }
        }
        flags |= @as(u32, @intFromEnum(box_mode)) << bytecode.graphics_box_shift;
        _ = try self.emit(.graphics_line, flags, 0, statement.span);
        return true;
    }

    fn parseGraphicsPalette(self: *Builder) !bool {
        const statement = self.advance();
        const attribute_type = (try self.parseExpression()) orelse return false;
        if (!attribute_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        if (!try self.expect(.comma)) return false;
        const color_type = (try self.parseExpression()) orelse return false;
        if (!color_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        _ = try self.emit(.graphics_palette, 0, 0, statement.span);
        return true;
    }

    fn parseGraphicsPset(self: *Builder) !bool {
        const statement = self.advance();
        const relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        var flags: u32 = if (relative) bytecode.graphics_point_relative else 0;
        if (self.consume(.comma)) {
            const color_type = (try self.parseExpression()) orelse return false;
            if (!color_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            flags |= bytecode.graphics_color_present;
        }
        _ = try self.emit(.graphics_pset, flags, 0, statement.span);
        return true;
    }

    fn parseGraphicsCircle(self: *Builder) !bool {
        const statement = self.advance();
        const relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        if (!try self.expect(.comma)) return false;
        const radius_type = (try self.parseExpression()) orelse return false;
        if (!radius_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        const optional = try self.parseGraphicsOptionalNumbers(4, statement.span);
        const flags: u32 = if (relative) bytecode.graphics_point_relative else 0;
        const encoded = optional.mask | (optional.count << bytecode.graphics_optional_count_shift);
        _ = try self.emit(.graphics_circle, flags, encoded, statement.span);
        return true;
    }

    fn parseGraphicsPaint(self: *Builder) !bool {
        const statement = self.advance();
        const relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        const optional = try self.parseGraphicsOptionalNumbers(2, statement.span);
        const flags: u32 = if (relative) bytecode.graphics_point_relative else 0;
        const encoded = optional.mask | (optional.count << bytecode.graphics_optional_count_shift);
        _ = try self.emit(.graphics_paint, flags, encoded, statement.span);
        return true;
    }

    fn parseGraphicsGet(self: *Builder) !bool {
        const statement = self.advance();
        const first_relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        if (!try self.expect(.minus)) return false;
        const second_relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        if (!try self.expect(.comma)) return false;
        if (!try self.parseGraphicsArrayReference(statement.span)) return false;
        var flags: u32 = if (first_relative) bytecode.graphics_point_relative else 0;
        if (second_relative) flags |= bytecode.graphics_second_point_relative;
        _ = try self.emit(.graphics_get, flags, 0, statement.span);
        return true;
    }

    fn parseGraphicsPut(self: *Builder) !bool {
        const statement = self.advance();
        const relative = (try self.parseGraphicsPoint(statement.span)) orelse return false;
        if (!try self.expect(.comma)) return false;
        if (!try self.parseGraphicsArrayReference(statement.span)) return false;
        if (!try self.expect(.comma)) return false;
        const action: bytecode.GraphicsPutAction = if (self.consumeKeyword(.pset))
            .pset
        else if (self.consumeKeyword(.xor))
            .xor
        else
            return self.fail(.expected_token);
        const flags: u32 = if (relative) bytecode.graphics_point_relative else 0;
        _ = try self.emit(.graphics_put, flags, @intFromEnum(action), statement.span);
        return true;
    }

    const GraphicsOptionalNumbers = struct {
        mask: u32 = 0,
        count: u32 = 0,
    };

    fn parseGraphicsOptionalNumbers(self: *Builder, maximum: u32, span: frontend.Span) !GraphicsOptionalNumbers {
        var result: GraphicsOptionalNumbers = .{};
        var position: u32 = 0;
        while (position < maximum and self.consume(.comma)) : (position += 1) {
            if (self.at(.comma) or self.atBoundary() or self.atKeyword(.else_)) continue;
            const value_type = (try self.parseExpression()) orelse return result;
            if (!value_type.isNumeric()) try self.addDiagnostic(.type_mismatch, span);
            result.mask |= @as(u32, 1) << @intCast(position);
            result.count += 1;
        }
        return result;
    }

    fn parseGraphicsPoint(self: *Builder, span: frontend.Span) !?bool {
        const relative = self.consumeKeyword(.step);
        if (!try self.expect(.left_paren)) return null;
        const x_type = (try self.parseExpression()) orelse return null;
        if (!x_type.isNumeric()) try self.addDiagnostic(.type_mismatch, span);
        if (!try self.expect(.comma)) return null;
        const y_type = (try self.parseExpression()) orelse return null;
        if (!y_type.isNumeric()) try self.addDiagnostic(.type_mismatch, span);
        if (!try self.expect(.right_paren)) return null;
        return relative;
    }

    fn parseGraphicsArrayReference(self: *Builder, span: frontend.Span) !bool {
        const name = (try self.expectIdentifier()) orelse return false;
        const target = (try self.parseLvalueReference(name, true)) orelse return false;
        if (!target.is_whole_array or target.dimensions == 0 or !target.value_type.isNumeric() or
            target.record_type != bytecode.invalid_index)
        {
            try self.addDiagnostic(.invalid_array_argument, span);
            return false;
        }
        return true;
    }

    fn parseInputBody(self: *Builder, statement: frontend.Token, line_input: bool) !bool {
        const keep_same_line = self.consume(.semicolon);
        if (self.consume(.hash)) {
            const file_type = (try self.parseExpression()) orelse return false;
            if (!file_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            if (!try self.expect(.comma)) return false;
            const count = try self.parseInputTargets(statement.span, line_input);
            if (count == 0) return false;
            _ = try self.emit(.input_file, count, @intFromBool(line_input), statement.span);
            return true;
        }

        var has_prompt = false;
        if (self.at(.string)) {
            _ = try self.emit(.print_begin_screen, 0, 0, statement.span);
            const prompt_type = (try self.parseExpression()) orelse return false;
            if (prompt_type != .string) try self.addDiagnostic(.type_mismatch, statement.span);
            _ = try self.emit(.print_value, 0, 0, statement.span);
            const question = if (self.consume(.semicolon))
                !line_input
            else if (self.consume(.comma))
                false
            else
                return self.fail(.expected_token);
            if (question) _ = try self.emit(.print_question, 0, 0, statement.span);
            _ = try self.emit(.print_end, 0, 0, statement.span);
            has_prompt = true;
        }
        if (!has_prompt and !line_input) {
            _ = try self.emit(.print_begin_screen, 0, 0, statement.span);
            _ = try self.emit(.print_question, 0, 0, statement.span);
            _ = try self.emit(.print_end, 0, 0, statement.span);
        }

        const count = try self.parseInputTargets(statement.span, line_input);
        if (count == 0) return false;
        const flags = @as(u32, @intFromBool(line_input)) | (@as(u32, @intFromBool(keep_same_line)) << 1);
        _ = try self.emit(.input_console, count, flags, statement.span);
        return true;
    }

    fn parseInputTargets(self: *Builder, span: frontend.Span, line_input: bool) !u32 {
        var count: u32 = 0;
        while (true) {
            const name = (try self.expectIdentifier()) orelse return 0;
            const target = (try self.parseLvalueReference(name, true)) orelse return 0;
            if (target.is_whole_array or target.record_type != bytecode.invalid_index) {
                try self.addDiagnostic(.invalid_record_access, name.span);
                return 0;
            }
            if (line_input and target.value_type != .string) try self.addDiagnostic(.type_mismatch, span);
            count += 1;
            if (!self.consume(.comma)) break;
            if (line_input) {
                try self.addDiagnostic(.wrong_argument_count, span);
                return 0;
            }
        }
        return count;
    }

    fn parseRandomize(self: *Builder) !bool {
        const statement = self.advance();
        var count: u32 = 0;
        if (!self.atBoundary() and !self.atKeyword(.else_)) {
            const seed_type = (try self.parseExpression()) orelse return false;
            if (!seed_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            count = 1;
        }
        _ = try self.emit(.randomize, count, 0, statement.span);
        return true;
    }

    fn parseSleep(self: *Builder) !bool {
        const statement = self.advance();
        var count: u32 = 0;
        if (!self.atBoundary() and !self.atKeyword(.else_)) {
            const seconds_type = (try self.parseExpression()) orelse return false;
            if (!seconds_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            count = 1;
        }
        _ = try self.emit(.sleep, count, 0, statement.span);
        return true;
    }

    fn parseOpen(self: *Builder) !bool {
        const statement = self.advance();
        const path_type = (try self.parseExpression()) orelse return false;
        if (path_type != .string) try self.addDiagnostic(.type_mismatch, statement.span);
        if (!try self.expectKeyword(.for_)) return false;
        const mode: bytecode.FileMode = if (self.consumeKeyword(.input))
            .input
        else if (self.consumeKeyword(.output))
            .output
        else if (self.consumeKeyword(.append))
            .append
        else
            return self.fail(.unsupported_core_feature);
        if (!try self.expectKeyword(.as)) return false;
        if (!try self.expect(.hash)) return false;
        const file_type = (try self.parseExpression()) orelse return false;
        if (!file_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        _ = try self.emit(.file_open, @intFromEnum(mode), 0, statement.span);
        return true;
    }

    fn parseClose(self: *Builder) !bool {
        const statement = self.advance();
        var count: u32 = 0;
        if (!self.atBoundary() and !self.atKeyword(.else_)) {
            while (true) {
                if (!try self.expect(.hash)) return false;
                const file_type = (try self.parseExpression()) orelse return false;
                if (!file_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
                count += 1;
                if (!self.consume(.comma)) break;
            }
        }
        _ = try self.emit(.file_close, count, 0, statement.span);
        return true;
    }

    fn parseAudioBeep(self: *Builder) !bool {
        const statement = self.advance();
        _ = try self.emit(.audio_beep, 0, 0, statement.span);
        return true;
    }

    fn parseAudioPlay(self: *Builder) !bool {
        const statement = self.advance();
        const command_type = (try self.parseExpression()) orelse return false;
        if (command_type != .string) try self.addDiagnostic(.type_mismatch, statement.span);
        _ = try self.emit(.audio_play, 0, 0, statement.span);
        return true;
    }

    fn parseDeferredStatement(self: *Builder) !bool {
        const statement = self.advance();
        while (!self.atBoundary() and !self.atKeyword(.else_)) _ = self.advance();
        _ = try self.emit(.deferred_statement, @intFromEnum(statement.keyword), 0, statement.span);
        return true;
    }

    fn parseDeclare(self: *Builder) !bool {
        const statement = self.advance();
        if (self.current_procedure != bytecode.invalid_index) {
            try self.addDiagnostic(.unexpected_token, statement.span);
            return false;
        }
        const kind: bytecode.ProcedureKind = if (self.consumeKeyword(.sub))
            .sub
        else if (self.consumeKeyword(.function))
            .function
        else
            return self.fail(.expected_token);
        const name = (try self.expectIdentifier()) orelse return false;

        var procedure_id: u32 = undefined;
        if (self.findProcedure(name.span)) |existing| {
            try self.addDiagnostic(.duplicate_symbol, name.span);
            procedure_id = existing;
        } else {
            procedure_id = try self.addProcedure(name.span, kind);
        }
        var procedure = &self.procedures.items[procedure_id];
        procedure.declared = true;
        if (procedure.kind != kind) try self.addDiagnostic(.symbol_kind_conflict, name.span);
        if (self.at(.left_paren)) {
            if (!try self.parseParameters(procedure_id, false)) return false;
        }
        return true;
    }

    fn parseProcedureDefinition(self: *Builder, kind: bytecode.ProcedureKind) !bool {
        const statement = self.advance();
        if (self.current_procedure != bytecode.invalid_index) {
            try self.addDiagnostic(.unexpected_token, statement.span);
            return false;
        }
        const name = (try self.expectIdentifier()) orelse return false;
        const procedure_id = self.findProcedure(name.span) orelse try self.addProcedure(name.span, kind);
        var procedure = &self.procedures.items[procedure_id];
        if (procedure.defined) try self.addDiagnostic(.duplicate_symbol, name.span);
        if (procedure.kind != kind) try self.addDiagnostic(.symbol_kind_conflict, name.span);

        const declared_types = try self.copyParameterSignature(procedure.parameters.items);
        defer self.allocator.free(declared_types);
        procedure.locals.clearRetainingCapacity();
        procedure.parameters.clearRetainingCapacity();
        procedure.name = name.span;
        procedure.defined = true;
        procedure.return_type = if (kind == .sub) .single else self.inferredType(name.span);

        if (kind == .function) {
            procedure.return_local = try self.addLocal(procedure_id, .{
                .name = name.span,
                .value_type = procedure.return_type,
            });
        }
        if (self.at(.left_paren) and !try self.parseParameters(procedure_id, false)) return false;
        _ = self.consumeKeyword(.static);
        try self.validateDeclaredSignature(name.span, declared_types, procedure.parameters.items);

        self.current_procedure_skip = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
        self.current_procedure = procedure_id;
        self.procedures.items[procedure_id].entry_ip = self.currentIp();
        return true;
    }

    fn parseDefFn(self: *Builder) !bool {
        const statement = self.advance();
        if (self.consumeKeyword(.seg)) {
            if (self.consume(.equal)) {
                const segment_type = (try self.parseExpression()) orelse return false;
                if (!segment_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
                _ = try self.emit(.set_segment, 0, 0, statement.span);
            } else {
                _ = try self.emit(.reset_segment, 0, 0, statement.span);
            }
            return true;
        }
        _ = self.consumeKeyword(.fn_);
        const name = (try self.expectIdentifier()) orelse return false;
        if (self.findProcedure(name.span) != null) {
            try self.addDiagnostic(.duplicate_symbol, name.span);
            return false;
        }
        const procedure_id = try self.addProcedure(name.span, .def_fn);
        var procedure = &self.procedures.items[procedure_id];
        procedure.defined = true;
        procedure.return_type = self.inferredType(name.span);
        procedure.return_local = try self.addLocal(procedure_id, .{
            .name = name.span,
            .value_type = procedure.return_type,
        });
        if (!try self.parseParameters(procedure_id, true)) return false;
        if (!try self.expect(.equal)) return false;

        const skip = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
        const previous_procedure = self.current_procedure;
        self.current_procedure = procedure_id;
        self.procedures.items[procedure_id].entry_ip = self.currentIp();
        const expression_type = (try self.parseExpression()) orelse {
            self.current_procedure = previous_procedure;
            return false;
        };
        if (!typesCompatible(procedure.return_type, expression_type)) try self.addDiagnostic(.type_mismatch, name.span);
        try self.emitStore(self.variableReference(.local, procedure.return_local), false, name.span);
        _ = try self.emit(.return_procedure, 0, 0, statement.span);
        self.procedures.items[procedure_id].end_ip = self.currentIp();
        self.current_procedure = previous_procedure;
        self.patchJump(skip, self.currentIp());
        return true;
    }

    fn parseParameters(self: *Builder, procedure_id: u32, force_by_value: bool) !bool {
        if (!try self.expect(.left_paren)) return false;
        if (self.consume(.right_paren)) return true;
        while (true) {
            var mode: bytecode.PassingMode = if (force_by_value) .by_value else .by_ref;
            if (self.consumeKeyword(.byval)) mode = .by_value else if (self.consumeKeyword(.byref)) mode = .by_ref;
            const name = (try self.expectIdentifier()) orelse return false;
            var is_array = false;
            if (self.consume(.left_paren)) {
                is_array = true;
                if (!try self.expect(.right_paren)) return false;
            }
            var bound_type = BoundType{ .value_type = self.inferredType(name.span) };
            if (self.consumeKeyword(.as)) bound_type = (try self.parseBoundType()) orelse return false;
            if (bound_type.accepts_any and (!is_array or mode == .by_value)) {
                try self.addDiagnostic(.type_mismatch, name.span);
            }
            if (is_array and mode == .by_value) try self.addDiagnostic(.invalid_array_argument, name.span);
            const local_index = try self.addLocal(procedure_id, .{
                .name = name.span,
                .value_type = bound_type.value_type,
                .record_type = bound_type.record_type,
                .dimensions = if (is_array) bytecode.unknown_dimensions else 0,
                .is_parameter = true,
            });
            try self.procedures.items[procedure_id].parameters.append(self.allocator, .{
                .local_index = local_index,
                .value_type = bound_type.value_type,
                .record_type = bound_type.record_type,
                .is_array = is_array,
                .accepts_any = bound_type.accepts_any,
                .passing_mode = mode,
            });
            if (!self.consume(.comma)) break;
        }
        return self.expect(.right_paren);
    }

    fn copyParameterSignature(self: *Builder, parameters: []const bytecode.Parameter) ![]bytecode.Parameter {
        return self.allocator.dupe(bytecode.Parameter, parameters);
    }

    fn validateDeclaredSignature(
        self: *Builder,
        span: frontend.Span,
        declared: []const bytecode.Parameter,
        defined: []const bytecode.Parameter,
    ) !void {
        if (declared.len == 0) return;
        if (declared.len != defined.len) {
            try self.addDiagnostic(.wrong_argument_count, span);
            return;
        }
        for (declared, defined) |first, second| {
            const type_matches = first.accepts_any or
                (first.value_type == second.value_type and first.record_type == second.record_type);
            if (!type_matches or first.is_array != second.is_array or first.passing_mode != second.passing_mode) {
                try self.addDiagnostic(.type_mismatch, span);
                return;
            }
        }
    }

    fn parseAssignmentOrImplicitCall(self: *Builder) !bool {
        const name = self.advance();
        if (self.at(.equal) or self.findGlobal(name.span) != null or
            (self.current_procedure != bytecode.invalid_index and self.findLocal(self.current_procedure, name.span) != null))
        {
            const target = (try self.parseLvalueReference(name, true)) orelse return false;
            if (!try self.expect(.equal)) return false;
            return self.parseAssignment(name, target);
        }
        if (self.findProcedure(name.span)) |procedure_id| {
            if (self.procedures.items[procedure_id].kind != .sub) return self.fail(.unexpected_token);
            return self.emitProcedureCall(procedure_id, false, name.span, false);
        }
        const target = (try self.parseLvalueReference(name, true)) orelse return false;
        if (!try self.expect(.equal)) return false;
        return self.parseAssignment(name, target);
    }

    fn parseLet(self: *Builder) !bool {
        _ = self.advance();
        const name = (try self.expectIdentifier()) orelse return false;
        const target = (try self.parseLvalueReference(name, true)) orelse return false;
        if (!try self.expect(.equal)) return false;
        return self.parseAssignment(name, target);
    }

    fn parseAssignment(self: *Builder, name: frontend.Token, target: BoundLvalue) !bool {
        const expression_type = (try self.parseExpression()) orelse return false;
        if (target.is_whole_array or target.record_type != bytecode.invalid_index) {
            try self.addDiagnostic(.invalid_record_access, name.span);
            return false;
        }
        if (target.is_constant) try self.addDiagnostic(.constant_assignment, name.span);
        if ((target.value_type == .string) != (expression_type == .string)) {
            try self.addDiagnostic(.type_mismatch, name.span);
        }
        _ = try self.emit(.store_reference, bytecode.encodeValueType(target.value_type), 0, name.span);
        return true;
    }

    fn parseLvalueReference(self: *Builder, name: frontend.Token, create: bool) !?BoundLvalue {
        const variable = (try self.resolveVariable(name.span, create)) orelse {
            try self.addDiagnostic(.expected_identifier, name.span);
            return null;
        };
        try self.emitReference(variable, name.span);
        var result = BoundLvalue{
            .value_type = variable.value_type,
            .record_type = variable.record_type,
            .dimensions = variable.dimensions,
            .is_constant = variable.is_constant,
        };

        if (self.consume(.left_paren)) {
            if (variable.dimensions == 0) {
                try self.addDiagnostic(.invalid_array_argument, name.span);
                self.skipToMatchingRightParen();
                return null;
            }
            if (self.consume(.right_paren)) {
                result.is_whole_array = true;
                return result;
            }
            var count: usize = 0;
            while (true) {
                _ = (try self.parseExpression()) orelse return null;
                count += 1;
                if (!self.consume(.comma)) break;
            }
            if (!try self.expect(.right_paren)) return null;
            if (count > maximum_array_dimensions) {
                try self.addDiagnostic(.capacity_exceeded, name.span);
                return null;
            }
            if (variable.dimensions != bytecode.unknown_dimensions and count != variable.dimensions) {
                try self.addDiagnostic(.wrong_dimension_count, name.span);
            }
            _ = try self.emit(.select_array_element, @intCast(count), 0, name.span);
            result.dimensions = 0;
        } else if (variable.dimensions != 0) {
            result.is_whole_array = true;
            return result;
        }

        if (self.consume(.dot)) {
            if (result.record_type == bytecode.invalid_index) {
                try self.addDiagnostic(.invalid_record_access, name.span);
                return null;
            }
            const field = (try self.expectIdentifier()) orelse return null;
            const field_index = self.findRecordField(result.record_type, field.span) orelse {
                try self.addDiagnostic(.unknown_field, field.span);
                return null;
            };
            const field_type = self.record_types.items[result.record_type].fields.items[field_index].value_type;
            _ = try self.emit(.select_record_field, field_index, 0, field.span);
            result.value_type = field_type;
            result.record_type = bytecode.invalid_index;
        }
        return result;
    }

    fn skipToMatchingRightParen(self: *Builder) void {
        var depth: usize = 1;
        while (!self.at(.eof) and !self.atBoundary() and depth != 0) {
            if (self.consume(.left_paren)) depth += 1 else if (self.consume(.right_paren)) depth -= 1 else _ = self.advance();
        }
    }

    fn parseCallStatement(self: *Builder) !bool {
        const statement = self.advance();
        const name = (try self.expectIdentifier()) orelse return false;
        const procedure_id = self.findProcedure(name.span) orelse {
            try self.addDiagnostic(.unknown_procedure, name.span);
            return false;
        };
        if (!try self.emitProcedureCall(procedure_id, self.at(.left_paren), statement.span, false)) return false;
        if (self.procedures.items[procedure_id].kind != .sub) _ = try self.emit(.pop, 0, 0, statement.span);
        return true;
    }

    fn emitProcedureCall(
        self: *Builder,
        procedure_id: u32,
        parenthesized: bool,
        span: frontend.Span,
        value_required: bool,
    ) !bool {
        const procedure = &self.procedures.items[procedure_id];
        procedure.called = true;
        if (value_required and procedure.kind == .sub) {
            try self.addDiagnostic(.symbol_kind_conflict, span);
            return false;
        }
        if (!value_required and procedure.kind != .sub and !parenthesized) {
            try self.addDiagnostic(.symbol_kind_conflict, span);
            return false;
        }

        if (parenthesized) _ = self.advance();
        var argument_count: usize = 0;
        const empty = parenthesized and self.consume(.right_paren);
        if (!empty and !(self.atBoundary() or self.atKeyword(.else_))) {
            while (true) {
                if (argument_count < procedure.parameters.items.len and procedure.parameters.items[argument_count].passing_mode == .by_ref) {
                    const parameter = procedure.parameters.items[argument_count];
                    if (parameter.is_array) {
                        if (!self.at(.identifier)) {
                            try self.addDiagnostic(.invalid_array_argument, self.current().span);
                            _ = (try self.parseExpression()) orelse return false;
                            argument_count += 1;
                            if (!self.consume(.comma)) break;
                            continue;
                        }
                        const argument = self.advance();
                        const target = (try self.parseLvalueReference(argument, true)) orelse return false;
                        if (!target.is_whole_array or target.dimensions == 0) {
                            try self.addDiagnostic(.invalid_array_argument, argument.span);
                        }
                        if (!parameter.accepts_any and
                            (target.value_type != parameter.value_type or target.record_type != parameter.record_type))
                        {
                            try self.addDiagnostic(.invalid_array_argument, argument.span);
                        }
                    } else if (self.canAliasScalarArgument()) {
                        const argument = self.advance();
                        const target = (try self.parseLvalueReference(argument, true)) orelse return false;
                        if (target.is_whole_array or target.record_type != parameter.record_type or
                            target.value_type != parameter.value_type)
                        {
                            try self.addDiagnostic(.invalid_byref_argument, argument.span);
                        }
                    } else {
                        const argument_type = (try self.parseExpression()) orelse return false;
                        if (!typesCompatible(parameter.value_type, argument_type)) {
                            try self.addDiagnostic(.type_mismatch, span);
                        }
                    }
                } else {
                    const argument_type = (try self.parseExpression()) orelse return false;
                    if (argument_count < procedure.parameters.items.len and
                        !typesCompatible(procedure.parameters.items[argument_count].value_type, argument_type))
                    {
                        try self.addDiagnostic(.type_mismatch, span);
                    }
                }
                argument_count += 1;
                if (!self.consume(.comma)) break;
            }
        }
        if (parenthesized and !empty and !try self.expect(.right_paren)) return false;
        if (argument_count != procedure.parameters.items.len) {
            try self.addDiagnostic(.wrong_argument_count, span);
        }
        _ = try self.emit(.call, procedure_id, @intCast(argument_count), span);
        return true;
    }

    fn canAliasScalarArgument(self: Builder) bool {
        if (!self.at(.identifier)) return false;
        const name = self.current();
        if (self.current_procedure != bytecode.invalid_index) {
            if (self.findLocal(self.current_procedure, name.span)) |index| {
                if (self.procedures.items[self.current_procedure].locals.items[index].is_constant) return false;
            }
        }
        if (self.findGlobal(name.span)) |index| {
            if (self.globals.items[index].is_constant) return false;
        }
        const next = self.peek(1);
        if (next.kind == .dot) return true;
        if (next.kind == .left_paren) {
            if (self.current_procedure != bytecode.invalid_index) {
                if (self.findLocal(self.current_procedure, name.span)) |index| {
                    return self.procedures.items[self.current_procedure].locals.items[index].isArray();
                }
            }
            if (self.findGlobal(name.span)) |index| return self.globals.items[index].isArray();
            return false;
        }
        return next.kind == .comma or next.kind == .right_paren or next.kind == .newline or
            next.kind == .colon or next.kind == .eof or (next.kind == .keyword and next.keyword == .else_);
    }

    fn parseExpression(self: *Builder) std.mem.Allocator.Error!?bytecode.ValueType {
        return self.parseLogicalOr();
    }

    fn parseLogicalOr(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseLogicalXor()) orelse return null;
        while (self.consumeKeyword(.or_)) {
            const operator = self.tokens[self.index - 1];
            const right = (try self.parseLogicalXor()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            _ = try self.emit(.logical_or, bytecode.encodeValueType(.long), 0, operator.span);
            left = .long;
        }
        return left;
    }

    fn parseLogicalXor(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseLogicalAnd()) orelse return null;
        while (self.consumeKeyword(.xor)) {
            const operator = self.tokens[self.index - 1];
            const right = (try self.parseLogicalAnd()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            _ = try self.emit(.logical_xor, bytecode.encodeValueType(.long), 0, operator.span);
            left = .long;
        }
        return left;
    }

    fn parseLogicalAnd(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseLogicalNot()) orelse return null;
        while (self.consumeKeyword(.and_)) {
            const operator = self.tokens[self.index - 1];
            const right = (try self.parseLogicalNot()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            _ = try self.emit(.logical_and, bytecode.encodeValueType(.long), 0, operator.span);
            left = .long;
        }
        return left;
    }

    fn parseLogicalNot(self: *Builder) !?bytecode.ValueType {
        if (self.consumeKeyword(.not)) {
            const operator = self.tokens[self.index - 1];
            const operand = (try self.parseLogicalNot()) orelse return null;
            if (!operand.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            _ = try self.emit(.logical_not, bytecode.encodeValueType(.long), 0, operator.span);
            return .long;
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseAdditive()) orelse return null;
        while (comparisonOp(self.current().kind)) |op| {
            const operator = self.advance();
            const right = (try self.parseAdditive()) orelse return null;
            if ((left == .string) != (right == .string)) try self.addDiagnostic(.type_mismatch, operator.span);
            _ = try self.emit(op, 0, 0, operator.span);
            left = .integer;
        }
        return left;
    }

    fn parseAdditive(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseModulo()) orelse return null;
        while (self.at(.plus) or self.at(.minus)) {
            const operator = self.advance();
            const right = (try self.parseModulo()) orelse return null;
            var result_type: bytecode.ValueType = undefined;
            if (operator.kind == .plus and left == .string and right == .string) {
                result_type = .string;
            } else if (left.isNumeric() and right.isNumeric()) {
                result_type = values.numericResultType(left, right) catch .single;
            } else {
                try self.addDiagnostic(.type_mismatch, operator.span);
                result_type = left;
            }
            _ = try self.emit(if (operator.kind == .plus) .add else .subtract, bytecode.encodeValueType(result_type), 0, operator.span);
            left = result_type;
        }
        return left;
    }

    fn parseModulo(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseIntegerDivision()) orelse return null;
        while (self.consumeKeyword(.mod)) {
            const operator = self.tokens[self.index - 1];
            const right = (try self.parseIntegerDivision()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            const result_type: bytecode.ValueType = if (left == .integer and right == .integer) .integer else .long;
            _ = try self.emit(.modulo, bytecode.encodeValueType(result_type), 0, operator.span);
            left = result_type;
        }
        return left;
    }

    fn parseIntegerDivision(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseMultiplicative()) orelse return null;
        while (self.at(.integer_divide)) {
            const operator = self.advance();
            const right = (try self.parseMultiplicative()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            const result_type: bytecode.ValueType = if (left == .integer and right == .integer) .integer else .long;
            _ = try self.emit(.integer_divide, bytecode.encodeValueType(result_type), 0, operator.span);
            left = result_type;
        }
        return left;
    }

    fn parseMultiplicative(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parseArithmeticUnary()) orelse return null;
        while (self.at(.multiply) or self.at(.divide)) {
            const operator = self.advance();
            const right = (try self.parseArithmeticUnary()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            const result_type = if (operator.kind == .divide)
                values.divisionResultType(left, right) catch .single
            else
                values.numericResultType(left, right) catch .single;
            _ = try self.emit(if (operator.kind == .divide) .divide else .multiply, bytecode.encodeValueType(result_type), 0, operator.span);
            left = result_type;
        }
        return left;
    }

    fn parseArithmeticUnary(self: *Builder) std.mem.Allocator.Error!?bytecode.ValueType {
        if (self.consume(.plus)) return self.parseArithmeticUnary();
        if (self.consume(.minus)) {
            const operator = self.tokens[self.index - 1];
            const operand = (try self.parseArithmeticUnary()) orelse return null;
            if (!operand.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            _ = try self.emit(.negate, bytecode.encodeValueType(operand), 0, operator.span);
            return operand;
        }
        return self.parsePower();
    }

    fn parsePower(self: *Builder) !?bytecode.ValueType {
        var left = (try self.parsePrimary()) orelse return null;
        if (self.consume(.power)) {
            const operator = self.tokens[self.index - 1];
            const right = (try self.parseArithmeticUnary()) orelse return null;
            if (!left.isNumeric() or !right.isNumeric()) try self.addDiagnostic(.type_mismatch, operator.span);
            const result_type: bytecode.ValueType = if (left == .double or right == .double) .double else .single;
            _ = try self.emit(.power, bytecode.encodeValueType(result_type), 0, operator.span);
            left = result_type;
        }
        return left;
    }

    fn parsePrimary(self: *Builder) !?bytecode.ValueType {
        if (self.at(.number)) return self.parseNumber();
        if (self.at(.string)) {
            const token = self.advance();
            const constant_index = try self.addConstant(.{ .string = token.span });
            _ = try self.emit(.push_constant, constant_index, 0, token.span);
            return .string;
        }
        if (self.at(.identifier)) {
            const name = self.advance();
            if (self.at(.left_paren)) {
                if (self.findProcedure(name.span)) |procedure_id| {
                    if (!try self.emitProcedureCall(procedure_id, true, name.span, true)) return null;
                    return self.procedures.items[procedure_id].return_type;
                }
            }
            const target = (try self.parseLvalueReference(name, true)) orelse return null;
            if (target.is_whole_array or target.record_type != bytecode.invalid_index) {
                try self.addDiagnostic(.invalid_record_access, name.span);
                return null;
            }
            _ = try self.emit(.load_reference, 0, 0, name.span);
            return target.value_type;
        }
        if (self.at(.keyword)) {
            if (builtinForKeyword(self.current().keyword)) |builtin| return self.parseBuiltin(builtin);
        }
        if (self.consume(.left_paren)) {
            const value_type = (try self.parseExpression()) orelse return null;
            if (!try self.expect(.right_paren)) return null;
            return value_type;
        }
        _ = try self.fail(.expected_expression);
        return null;
    }

    fn parseNumber(self: *Builder) !?bytecode.ValueType {
        const token = self.advance();
        const text = self.tokenText(token);
        const constant = parseNumericConstant(self.allocator, text) catch {
            try self.addDiagnostic(.invalid_number, token.span);
            return null;
        };
        const value_type = constant.valueType();
        const constant_index = try self.addConstant(constant);
        _ = try self.emit(.push_constant, constant_index, 0, token.span);
        return value_type;
    }

    fn addConstant(self: *Builder, constant: bytecode.Constant) !u32 {
        if (self.constants.items.len >= maximum_constants) {
            try self.addDiagnostic(.capacity_exceeded, self.current().span);
            self.stopped = true;
            return 0;
        }
        const index: u32 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, constant);
        return index;
    }

    fn parseBuiltin(self: *Builder, builtin: bytecode.Builtin) !?bytecode.ValueType {
        const function_token = self.advance();
        var argument_types: [3]bytecode.ValueType = undefined;
        var argument_count: usize = 0;
        const allows_bare = builtin == .inkey_string or builtin == .timer or builtin == .rnd;
        if (self.consume(.left_paren)) {
            if (!self.consume(.right_paren)) {
                while (true) {
                    if (argument_count >= argument_types.len) {
                        try self.addDiagnostic(.wrong_argument_count, function_token.span);
                        return null;
                    }
                    argument_types[argument_count] = (try self.parseExpression()) orelse return null;
                    argument_count += 1;
                    if (!self.consume(.comma)) break;
                }
                if (!try self.expect(.right_paren)) return null;
            }
        } else if (!allows_bare) {
            _ = try self.fail(.expected_token);
            return null;
        }
        const result_type = try self.validateBuiltin(builtin, argument_types[0..argument_count], function_token.span) orelse return null;
        switch (builtin) {
            .peek => _ = try self.emit(.peek, 0, 0, function_token.span),
            else => _ = try self.emit(.call_builtin, @intFromEnum(builtin), @intCast(argument_count), function_token.span),
        }
        return result_type;
    }

    fn validateBuiltin(
        self: *Builder,
        builtin: bytecode.Builtin,
        arguments: []const bytecode.ValueType,
        span: frontend.Span,
    ) !?bytecode.ValueType {
        const expected_min: usize = switch (builtin) {
            .instr, .mid_string => 2,
            .left_string => 2,
            .point => 2,
            .rnd, .inkey_string, .timer => 0,
            else => 1,
        };
        const expected_max: usize = switch (builtin) {
            .instr, .mid_string => 3,
            .rnd => 1,
            else => expected_min,
        };
        if (arguments.len < expected_min or arguments.len > expected_max) {
            try self.addDiagnostic(.wrong_argument_count, span);
            return null;
        }

        const result: bytecode.ValueType = switch (builtin) {
            .abs => if (arguments[0].isNumeric()) arguments[0] else blk: {
                try self.addDiagnostic(.type_mismatch, span);
                break :blk .single;
            },
            .atn, .cos, .sin => if (arguments[0] == .double) .double else .single,
            .chr_string, .left_string, .ltrim_string, .mid_string, .space_string, .str_string, .ucase_string => .string,
            .inkey_string => .string,
            .cint, .instr, .len, .eof, .peek, .point => .integer,
            .int => arguments[0],
            .val => .double,
            .rnd, .timer => .single,
        };

        switch (builtin) {
            .chr_string, .cint, .space_string, .peek, .eof => if (!arguments[0].isNumeric()) try self.addDiagnostic(.type_mismatch, span),
            .atn, .cos, .sin, .abs, .int, .str_string => if (!arguments[0].isNumeric()) try self.addDiagnostic(.type_mismatch, span),
            .ltrim_string, .len, .ucase_string, .val => if (arguments[0] != .string) try self.addDiagnostic(.type_mismatch, span),
            .left_string => if (arguments[0] != .string or !arguments[1].isNumeric()) try self.addDiagnostic(.type_mismatch, span),
            .instr => {
                const offset: usize = if (arguments.len == 3) 1 else 0;
                if (offset == 1 and !arguments[0].isNumeric()) try self.addDiagnostic(.type_mismatch, span);
                if (arguments[offset] != .string or arguments[offset + 1] != .string) try self.addDiagnostic(.type_mismatch, span);
            },
            .mid_string => {
                if (arguments[0] != .string or !arguments[1].isNumeric() or (arguments.len == 3 and !arguments[2].isNumeric())) {
                    try self.addDiagnostic(.type_mismatch, span);
                }
            },
            .point => if (!arguments[0].isNumeric() or !arguments[1].isNumeric()) try self.addDiagnostic(.type_mismatch, span),
            .rnd => if (arguments.len == 1 and !arguments[0].isNumeric()) try self.addDiagnostic(.type_mismatch, span),
            .inkey_string, .timer => {},
        }
        return result;
    }

    fn skipParenthesized(self: *Builder) void {
        if (!self.consume(.left_paren)) return;
        var depth: usize = 1;
        while (!self.at(.eof) and depth != 0) {
            if (self.consume(.left_paren)) depth += 1 else if (self.consume(.right_paren)) depth -= 1 else _ = self.advance();
        }
    }

    fn parseIf(self: *Builder, inline_statement: bool) !bool {
        const statement = self.advance();
        const condition_type = (try self.parseExpression()) orelse return false;
        if (!condition_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        if (!try self.expectKeyword(.then)) return false;
        const false_jump = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);

        if (!inline_statement and self.atBoundary()) {
            try self.pushBlock(.{
                .kind = .if_block,
                .span = statement.span,
                .procedure = self.currentScope(),
                .false_jump = false_jump,
            });
            return true;
        }

        if (!try self.parseBoundStatement(true)) return false;
        if (self.consumeKeyword(.else_)) {
            const end_jump = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
            self.patchJump(false_jump, self.currentIp());
            if (!try self.parseBoundStatement(true)) return false;
            self.patchJump(end_jump, self.currentIp());
        } else {
            self.patchJump(false_jump, self.currentIp());
        }
        return true;
    }

    fn parseElseIf(self: *Builder) !bool {
        const statement = self.advance();
        var block = (try self.requireTop(.if_block, statement.span)) orelse return false;
        if (block.has_else) {
            try self.addDiagnostic(.block_mismatch, statement.span);
            return false;
        }
        const end_jump = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
        try block.end_jumps.append(self.allocator, end_jump);
        self.patchJump(block.false_jump, self.currentIp());
        const condition_type = (try self.parseExpression()) orelse return false;
        if (!condition_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        if (!try self.expectKeyword(.then)) return false;
        block.false_jump = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);
        return true;
    }

    fn parseElse(self: *Builder) !bool {
        const statement = self.advance();
        var block = (try self.requireTop(.if_block, statement.span)) orelse return false;
        if (block.has_else) {
            try self.addDiagnostic(.block_mismatch, statement.span);
            return false;
        }
        const end_jump = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
        try block.end_jumps.append(self.allocator, end_jump);
        self.patchJump(block.false_jump, self.currentIp());
        block.false_jump = bytecode.invalid_index;
        block.has_else = true;
        return true;
    }

    fn closeIf(self: *Builder, span: frontend.Span) !bool {
        var block = (try self.popBlock(.if_block, span)) orelse return false;
        defer block.deinit(self.allocator);
        self.patchJump(block.false_jump, self.currentIp());
        for (block.end_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        return true;
    }

    fn parseSelect(self: *Builder) !bool {
        const statement = self.advance();
        if (!try self.expectKeyword(.case)) return false;
        const selector_type = (try self.parseExpression()) orelse return false;
        const selector = try self.addHidden(selector_type, statement.span);
        try self.emitStore(selector, false, statement.span);
        try self.pushBlock(.{
            .kind = .select_block,
            .span = statement.span,
            .procedure = self.currentScope(),
            .control = selector,
        });
        return true;
    }

    fn parseCase(self: *Builder) !bool {
        const statement = self.advance();
        var block = (try self.requireTop(.select_block, statement.span)) orelse return false;
        if (block.has_else) {
            try self.addDiagnostic(.block_mismatch, statement.span);
            return false;
        }
        if (block.has_case) {
            const end_jump = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
            try block.end_jumps.append(self.allocator, end_jump);
            self.patchJump(block.false_jump, self.currentIp());
        }
        block.has_case = true;

        if (self.consumeKeyword(.else_)) {
            block.has_else = true;
            block.false_jump = bytecode.invalid_index;
            return true;
        }

        var first_condition = true;
        while (true) {
            const selector = block.control.?;
            try self.emitLoad(selector, statement.span);
            const lower_type = (try self.parseExpression()) orelse return false;
            if (!typesCompatible(selector.value_type, lower_type)) try self.addDiagnostic(.type_mismatch, statement.span);
            if (self.consumeKeyword(.to)) {
                _ = try self.emit(.compare_greater_equal, 0, 0, statement.span);
                try self.emitLoad(selector, statement.span);
                const upper_type = (try self.parseExpression()) orelse return false;
                if (!typesCompatible(selector.value_type, upper_type)) try self.addDiagnostic(.type_mismatch, statement.span);
                _ = try self.emit(.compare_less_equal, 0, 0, statement.span);
                _ = try self.emit(.logical_and, bytecode.encodeValueType(.long), 0, statement.span);
            } else {
                _ = try self.emit(.compare_equal, 0, 0, statement.span);
            }
            if (!first_condition) _ = try self.emit(.logical_or, bytecode.encodeValueType(.long), 0, statement.span);
            first_condition = false;
            if (!self.consume(.comma)) break;
        }
        block.false_jump = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);
        return true;
    }

    fn closeSelect(self: *Builder, span: frontend.Span) !bool {
        var block = (try self.popBlock(.select_block, span)) orelse return false;
        defer block.deinit(self.allocator);
        self.patchJump(block.false_jump, self.currentIp());
        for (block.end_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        return true;
    }

    fn parseFor(self: *Builder) !bool {
        const statement = self.advance();
        const name = (try self.expectIdentifier()) orelse return false;
        const control = (try self.resolveVariable(name.span, true)) orelse return false;
        if (!control.value_type.isNumeric()) try self.addDiagnostic(.type_mismatch, name.span);
        if (!try self.expect(.equal)) return false;
        const initial_type = (try self.parseExpression()) orelse return false;
        if (!initial_type.isNumeric()) try self.addDiagnostic(.type_mismatch, name.span);
        try self.emitStore(control, false, name.span);
        if (!try self.expectKeyword(.to)) return false;
        const limit_type = (try self.parseExpression()) orelse return false;
        if (!limit_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        const limit = try self.addHidden(control.value_type, statement.span);
        try self.emitStore(limit, false, statement.span);
        const step = try self.addHidden(control.value_type, statement.span);
        if (self.consumeKeyword(.step)) {
            const step_type = (try self.parseExpression()) orelse return false;
            if (!step_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        } else {
            try self.emitNumericOne(control.value_type, statement.span);
        }
        try self.emitStore(step, false, statement.span);

        const check_ip = self.currentIp();
        try self.emitLoad(step, statement.span);
        try self.emitNumericZero(control.value_type, statement.span);
        _ = try self.emit(.compare_greater_equal, 0, 0, statement.span);
        const negative_jump = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);
        try self.emitLoad(control, statement.span);
        try self.emitLoad(limit, statement.span);
        _ = try self.emit(.compare_less_equal, 0, 0, statement.span);
        const positive_exit = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);
        const body_jump = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
        self.patchJump(negative_jump, self.currentIp());
        try self.emitLoad(control, statement.span);
        try self.emitLoad(limit, statement.span);
        _ = try self.emit(.compare_greater_equal, 0, 0, statement.span);
        const negative_exit = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);
        self.patchJump(body_jump, self.currentIp());

        var block = Block{
            .kind = .for_block,
            .span = statement.span,
            .procedure = self.currentScope(),
            .start_ip = check_ip,
            .body_ip = self.currentIp(),
            .control = control,
            .limit = limit,
            .step = step,
        };
        try block.exit_jumps.append(self.allocator, positive_exit);
        try block.exit_jumps.append(self.allocator, negative_exit);
        try self.pushBlock(block);
        return true;
    }

    fn parseNext(self: *Builder) !bool {
        const statement = self.advance();
        var block = (try self.popBlock(.for_block, statement.span)) orelse return false;
        defer block.deinit(self.allocator);
        if (self.at(.identifier)) {
            const name = self.advance();
            if (!self.namesEqual(name.span, block.control.?.name)) try self.addDiagnostic(.block_mismatch, name.span);
            if (self.consume(.comma)) try self.addDiagnostic(.unsupported_core_feature, name.span);
        }
        try self.emitLoad(block.control.?, statement.span);
        try self.emitLoad(block.step.?, statement.span);
        _ = try self.emit(.add, bytecode.encodeValueType(block.control.?.value_type), 0, statement.span);
        try self.emitStore(block.control.?, false, statement.span);
        _ = try self.emit(.jump, block.start_ip, 0, statement.span);
        for (block.exit_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        for (block.end_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        return true;
    }

    fn parseWhile(self: *Builder) !bool {
        const statement = self.advance();
        const condition_ip = self.currentIp();
        const condition_type = (try self.parseExpression()) orelse return false;
        if (!condition_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
        const exit_jump = try self.emit(.jump_if_false, bytecode.invalid_index, 0, statement.span);
        var block = Block{
            .kind = .while_block,
            .span = statement.span,
            .procedure = self.currentScope(),
            .start_ip = condition_ip,
            .body_ip = self.currentIp(),
        };
        try block.exit_jumps.append(self.allocator, exit_jump);
        try self.pushBlock(block);
        return true;
    }

    fn parseWend(self: *Builder) !bool {
        const statement = self.advance();
        var block = (try self.popBlock(.while_block, statement.span)) orelse return false;
        defer block.deinit(self.allocator);
        _ = try self.emit(.jump, block.start_ip, 0, statement.span);
        for (block.exit_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        return true;
    }

    fn parseDo(self: *Builder) !bool {
        const statement = self.advance();
        const condition_ip = self.currentIp();
        var block = Block{
            .kind = .do_block,
            .span = statement.span,
            .procedure = self.currentScope(),
            .start_ip = condition_ip,
        };
        if (self.consumeKeyword(.while_) or self.consumeKeyword(.until)) {
            block.has_leading_condition = true;
            const until = self.tokens[self.index - 1].keyword == .until;
            const condition_type = (try self.parseExpression()) orelse return false;
            if (!condition_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            const exit_jump = try self.emit(if (until) .jump_if_true else .jump_if_false, bytecode.invalid_index, 0, statement.span);
            try block.exit_jumps.append(self.allocator, exit_jump);
        }
        block.body_ip = self.currentIp();
        try self.pushBlock(block);
        return true;
    }

    fn parseLoop(self: *Builder) !bool {
        const statement = self.advance();
        var block = (try self.popBlock(.do_block, statement.span)) orelse return false;
        defer block.deinit(self.allocator);
        if (self.consumeKeyword(.while_) or self.consumeKeyword(.until)) {
            if (block.has_leading_condition) try self.addDiagnostic(.block_mismatch, statement.span);
            const until = self.tokens[self.index - 1].keyword == .until;
            const condition_type = (try self.parseExpression()) orelse return false;
            if (!condition_type.isNumeric()) try self.addDiagnostic(.type_mismatch, statement.span);
            _ = try self.emit(if (until) .jump_if_false else .jump_if_true, block.body_ip, 0, statement.span);
        } else {
            _ = try self.emit(.jump, if (block.has_leading_condition) block.start_ip else block.body_ip, 0, statement.span);
        }
        for (block.exit_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        for (block.end_jumps.items) |jump| self.patchJump(jump, self.currentIp());
        return true;
    }

    fn parseBranch(self: *Builder, op: bytecode.OpCode) !bool {
        const statement = self.advance();
        const label = (try self.expectIdentifier()) orelse return false;
        const instruction = try self.emit(op, bytecode.invalid_index, 0, statement.span);
        try self.addLabelFixup(label.span, instruction);
        return true;
    }

    fn parseReturn(self: *Builder) !bool {
        const statement = self.advance();
        const instruction = try self.emit(.return_gosub, bytecode.invalid_index, 0, statement.span);
        if (self.at(.identifier)) {
            const label = self.advance();
            try self.addLabelFixup(label.span, instruction);
        }
        return true;
    }

    fn parseExit(self: *Builder) !bool {
        const statement = self.advance();
        if (self.consumeKeyword(.sub)) {
            if (self.current_procedure == bytecode.invalid_index or self.procedures.items[self.current_procedure].kind != .sub) {
                try self.addDiagnostic(.block_mismatch, statement.span);
                return false;
            }
            _ = try self.emit(.return_procedure, 0, 0, statement.span);
            return true;
        }
        if (self.consumeKeyword(.function)) {
            if (self.current_procedure == bytecode.invalid_index or self.procedures.items[self.current_procedure].kind != .function) {
                try self.addDiagnostic(.block_mismatch, statement.span);
                return false;
            }
            _ = try self.emit(.return_procedure, 0, 0, statement.span);
            return true;
        }
        const kind: BlockKind = if (self.consumeKeyword(.for_))
            .for_block
        else if (self.consumeKeyword(.do_))
            .do_block
        else
            return self.fail(.expected_token);
        var index = self.blocks.items.len;
        while (index != 0) {
            index -= 1;
            if (self.blocks.items[index].kind == kind and self.blocks.items[index].procedure == self.currentScope()) {
                const jump = try self.emit(.jump, bytecode.invalid_index, 0, statement.span);
                try self.blocks.items[index].end_jumps.append(self.allocator, jump);
                return true;
            }
        }
        return self.fail(.block_mismatch);
    }

    fn parseEnd(self: *Builder) !bool {
        const statement = self.advance();
        if (self.consumeKeyword(.if_)) return self.closeIf(statement.span);
        if (self.consumeKeyword(.select)) return self.closeSelect(statement.span);
        if (self.consumeKeyword(.sub)) return self.closeProcedure(.sub, statement.span);
        if (self.consumeKeyword(.function)) return self.closeProcedure(.function, statement.span);
        _ = try self.emit(.halt, 0, 0, statement.span);
        return true;
    }

    fn closeProcedure(self: *Builder, expected: bytecode.ProcedureKind, span: frontend.Span) !bool {
        if (self.current_procedure == bytecode.invalid_index or self.procedures.items[self.current_procedure].kind != expected) {
            try self.addDiagnostic(.block_mismatch, span);
            return false;
        }
        if (self.blocks.items.len != 0 and self.blocks.items[self.blocks.items.len - 1].procedure == self.currentScope()) {
            try self.addDiagnostic(.block_not_closed, self.blocks.items[self.blocks.items.len - 1].span);
        }
        _ = try self.emit(.return_procedure, 0, 0, span);
        self.procedures.items[self.current_procedure].end_ip = self.currentIp();
        self.current_procedure = bytecode.invalid_index;
        self.patchJump(self.current_procedure_skip, self.currentIp());
        self.current_procedure_skip = bytecode.invalid_index;
        return true;
    }

    fn emitNumericZero(self: *Builder, value_type: bytecode.ValueType, span: frontend.Span) !void {
        const constant: bytecode.Constant = switch (value_type) {
            .integer => .{ .integer = 0 },
            .long => .{ .long = 0 },
            .single => .{ .single = 0 },
            .double => .{ .double = 0 },
            .string => return self.addDiagnostic(.type_mismatch, span),
        };
        _ = try self.emit(.push_constant, try self.addConstant(constant), 0, span);
    }

    fn emitNumericOne(self: *Builder, value_type: bytecode.ValueType, span: frontend.Span) !void {
        const constant: bytecode.Constant = switch (value_type) {
            .integer => .{ .integer = 1 },
            .long => .{ .long = 1 },
            .single => .{ .single = 1 },
            .double => .{ .double = 1 },
            .string => return self.addDiagnostic(.type_mismatch, span),
        };
        _ = try self.emit(.push_constant, try self.addConstant(constant), 0, span);
    }

    fn pushBlock(self: *Builder, block: Block) !void {
        if (self.blocks.items.len >= maximum_block_depth) {
            var owned = block;
            defer owned.deinit(self.allocator);
            try self.addDiagnostic(.capacity_exceeded, block.span);
            self.stopped = true;
            return;
        }
        try self.blocks.append(self.allocator, block);
    }

    fn requireTop(self: *Builder, kind: BlockKind, span: frontend.Span) !?*Block {
        if (self.blocks.items.len == 0) {
            try self.addDiagnostic(.block_mismatch, span);
            return null;
        }
        const block = &self.blocks.items[self.blocks.items.len - 1];
        if (block.kind != kind or block.procedure != self.currentScope()) {
            try self.addDiagnostic(.block_mismatch, span);
            return null;
        }
        return block;
    }

    fn popBlock(self: *Builder, kind: BlockKind, span: frontend.Span) !?Block {
        if (try self.requireTop(kind, span) == null) return null;
        return self.blocks.pop();
    }

    fn finish(self: *Builder) !bytecode.Program {
        var owned_procedures: std.ArrayList(bytecode.Procedure) = .empty;
        var owned_record_types: std.ArrayList(bytecode.RecordType) = .empty;
        errdefer {
            for (owned_procedures.items) |procedure| {
                self.allocator.free(procedure.locals);
                self.allocator.free(procedure.parameters);
            }
            owned_procedures.deinit(self.allocator);
        }
        errdefer {
            for (owned_record_types.items) |record_type| self.allocator.free(record_type.fields);
            owned_record_types.deinit(self.allocator);
        }

        for (self.procedures.items) |*procedure| {
            const locals = try procedure.locals.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(locals);
            const parameters = try procedure.parameters.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(parameters);
            try owned_procedures.append(self.allocator, .{
                .name = procedure.name,
                .kind = procedure.kind,
                .entry_ip = procedure.entry_ip,
                .end_ip = procedure.end_ip,
                .return_local = procedure.return_local,
                .return_type = procedure.return_type,
                .locals = locals,
                .parameters = parameters,
            });
        }

        for (self.record_types.items) |*record_type| {
            const fields = try record_type.fields.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(fields);
            try owned_record_types.append(self.allocator, .{ .name = record_type.name, .fields = fields });
        }

        const instructions = try self.instructions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(instructions);
        const constants = try self.constants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(constants);
        const globals = try self.globals.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(globals);
        const procedures = try owned_procedures.toOwnedSlice(self.allocator);
        errdefer {
            for (procedures) |procedure| {
                self.allocator.free(procedure.locals);
                self.allocator.free(procedure.parameters);
            }
            self.allocator.free(procedures);
        }
        const record_types = try owned_record_types.toOwnedSlice(self.allocator);
        errdefer {
            for (record_types) |record_type| self.allocator.free(record_type.fields);
            self.allocator.free(record_types);
        }
        const data_items = try self.data_items.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(data_items);
        const diagnostics = try self.diagnostics.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(diagnostics);

        self.labels.deinit(self.allocator);
        self.label_fixups.deinit(self.allocator);
        self.data_fixups.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.procedures.deinit(self.allocator);
        self.record_types.deinit(self.allocator);

        return .{
            .allocator = self.allocator,
            .file_name = self.file_name,
            .source = self.source,
            .instructions = instructions,
            .constants = constants,
            .globals = globals,
            .procedures = procedures,
            .record_types = record_types,
            .data_items = data_items,
            .diagnostics = diagnostics,
            .module_entry = 0,
        };
    }

    fn addDiagnostic(self: *Builder, code: bytecode.DiagnosticCode, span: frontend.Span) !void {
        try self.diagnostics.append(self.allocator, .{
            .code = code,
            .span = span,
            .file_name = self.file_name,
        });
    }

    fn fail(self: *Builder, code: bytecode.DiagnosticCode) !bool {
        try self.addDiagnostic(code, self.current().span);
        return false;
    }

    fn emit(self: *Builder, op: bytecode.OpCode, a: u32, b: u32, span: frontend.Span) !u32 {
        if (self.instructions.items.len >= maximum_instructions) {
            try self.addDiagnostic(.capacity_exceeded, span);
            self.stopped = true;
            return bytecode.invalid_index;
        }
        const index: u32 = @intCast(self.instructions.items.len);
        try self.instructions.append(self.allocator, .{ .op = op, .a = a, .b = b, .span = span });
        return index;
    }

    fn patchJump(self: *Builder, instruction: u32, target: u32) void {
        if (instruction == bytecode.invalid_index) return;
        self.instructions.items[instruction].a = target;
    }

    fn currentIp(self: Builder) u32 {
        return @intCast(self.instructions.items.len);
    }

    fn currentScope(self: Builder) u32 {
        return self.current_procedure;
    }

    fn current(self: Builder) frontend.Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peek(self: Builder, distance: usize) frontend.Token {
        return self.tokens[@min(self.index + distance, self.tokens.len - 1)];
    }

    fn advance(self: *Builder) frontend.Token {
        const token = self.current();
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return token;
    }

    fn at(self: Builder, kind: frontend.TokenKind) bool {
        return self.current().kind == kind;
    }

    fn atKeyword(self: Builder, keyword: frontend.Keyword) bool {
        return self.current().kind == .keyword and self.current().keyword == keyword;
    }

    fn consume(self: *Builder, kind: frontend.TokenKind) bool {
        if (!self.at(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn consumeKeyword(self: *Builder, keyword: frontend.Keyword) bool {
        if (!self.atKeyword(keyword)) return false;
        _ = self.advance();
        return true;
    }

    fn expect(self: *Builder, kind: frontend.TokenKind) !bool {
        if (!self.consume(kind)) return self.fail(.expected_token);
        return true;
    }

    fn expectKeyword(self: *Builder, keyword: frontend.Keyword) !bool {
        if (!self.consumeKeyword(keyword)) return self.fail(.expected_token);
        return true;
    }

    fn expectIdentifier(self: *Builder) !?frontend.Token {
        if (!self.at(.identifier)) {
            _ = try self.fail(.expected_identifier);
            return null;
        }
        return self.advance();
    }

    fn atBoundary(self: Builder) bool {
        return self.at(.newline) or self.at(.colon) or self.at(.eof);
    }

    fn synchronize(self: *Builder) void {
        while (!self.atBoundary()) _ = self.advance();
    }
};

pub fn compile(allocator: std.mem.Allocator, file_name: []const u8, source: []const u8) !bytecode.Program {
    const owned_file_name = try allocator.dupe(u8, file_name);
    errdefer allocator.free(owned_file_name);
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);

    const token_capacity = @max(@as(usize, 1), owned_source.len + 1);
    const tokens = try allocator.alloc(frontend.Token, token_capacity);
    defer allocator.free(tokens);
    const lexical_diagnostics = try allocator.alloc(frontend.Diagnostic, frontend.recommended_diagnostic_capacity);
    defer allocator.free(lexical_diagnostics);

    const lexed = frontend.tokenizeNamed(owned_file_name, owned_source, tokens, lexical_diagnostics);
    var builder = Builder{
        .allocator = allocator,
        .file_name = owned_file_name,
        .source = owned_source,
        .tokens = tokens[0..lexed.token_count],
    };
    errdefer builder.deinit();

    for (lexical_diagnostics[0..lexed.diagnostic_count]) |diagnostic| {
        try builder.diagnostics.append(allocator, .{
            .code = .lexical_error,
            .span = diagnostic.span,
            .file_name = owned_file_name,
            .frontend_code = diagnostic.code,
        });
    }
    if (lexed.diagnostics_truncated) {
        try builder.addDiagnostic(.capacity_exceeded, .{ .start = 0, .end = 0, .line = 1, .column = 1 });
    }
    if (lexed.token_count != 0 and lexed.ok()) try builder.parse();
    return builder.finish();
}

fn comparisonOp(kind: frontend.TokenKind) ?bytecode.OpCode {
    return switch (kind) {
        .equal => .compare_equal,
        .not_equal => .compare_not_equal,
        .less => .compare_less,
        .less_equal => .compare_less_equal,
        .greater => .compare_greater,
        .greater_equal => .compare_greater_equal,
        else => null,
    };
}

fn typesCompatible(target: bytecode.ValueType, source: bytecode.ValueType) bool {
    return (target == .string) == (source == .string);
}

fn builtinForKeyword(keyword: frontend.Keyword) ?bytecode.Builtin {
    return switch (keyword) {
        .abs => .abs,
        .atn => .atn,
        .chr_string => .chr_string,
        .cint => .cint,
        .cos => .cos,
        .instr => .instr,
        .int => .int,
        .left_string => .left_string,
        .len => .len,
        .ltrim_string => .ltrim_string,
        .mid_string => .mid_string,
        .peek => .peek,
        .sin => .sin,
        .space_string => .space_string,
        .str_string => .str_string,
        .ucase_string => .ucase_string,
        .val => .val,
        .eof => .eof,
        .inkey_string => .inkey_string,
        .point => .point,
        .rnd => .rnd,
        .timer => .timer,
        else => null,
    };
}

fn parseNumericConstant(allocator: std.mem.Allocator, text: []const u8) !bytecode.Constant {
    if (text.len == 0) return error.InvalidCharacter;
    var end = text.len;
    var suffix: ?u8 = null;
    if (text[end - 1] == '%' or text[end - 1] == '&' or text[end - 1] == '!' or text[end - 1] == '#') {
        suffix = text[end - 1];
        end -= 1;
    }
    const number_text = text[0..end];
    var floating = false;
    var double_exponent = false;
    for (number_text) |byte| {
        if (byte == '.' or byte == 'E' or byte == 'e' or byte == 'D' or byte == 'd') floating = true;
        if (byte == 'D' or byte == 'd') double_exponent = true;
    }

    if (!floating and suffix != '!' and suffix != '#') {
        const number = try std.fmt.parseInt(i64, number_text, 10);
        if (suffix == '%') {
            if (number < std.math.minInt(i16) or number > std.math.maxInt(i16)) return error.Overflow;
            return .{ .integer = @intCast(number) };
        }
        if (suffix == '&') {
            if (number < std.math.minInt(i32) or number > std.math.maxInt(i32)) return error.Overflow;
            return .{ .long = @intCast(number) };
        }
        if (number >= std.math.minInt(i16) and number <= std.math.maxInt(i16)) return .{ .integer = @intCast(number) };
        if (number >= std.math.minInt(i32) and number <= std.math.maxInt(i32)) return .{ .long = @intCast(number) };
        return error.Overflow;
    }

    const normalized = try allocator.dupe(u8, number_text);
    defer allocator.free(normalized);
    for (normalized) |*byte| {
        if (byte.* == 'D' or byte.* == 'd') byte.* = 'E';
    }
    const number = try std.fmt.parseFloat(f64, normalized);
    if (!std.math.isFinite(number)) return error.Overflow;
    if (suffix == '%') return .{ .integer = try values.roundToInteger(number) };
    if (suffix == '&') return .{ .long = try values.roundToLong(number) };
    if (suffix == '#' or double_exponent) return .{ .double = number };
    const single: f32 = @floatCast(number);
    if (!std.math.isFinite(single)) return error.Overflow;
    return .{ .single = single };
}

fn parseSignedNumericConstant(allocator: std.mem.Allocator, text: []const u8, negative: bool) !bytecode.Constant {
    const constant = try parseNumericConstant(allocator, text);
    if (!negative) return constant;
    return switch (constant) {
        .integer => |number| if (number == std.math.minInt(i16)) error.Overflow else .{ .integer = -number },
        .long => |number| if (number == std.math.minInt(i32)) error.Overflow else .{ .long = -number },
        .single => |number| .{ .single = -number },
        .double => |number| .{ .double = -number },
        .string => error.InvalidCharacter,
    };
}
