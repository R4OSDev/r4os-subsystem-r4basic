const std = @import("std");
const core = @import("core");
const frontend = core.frontend;

var tokens: [frontend.recommended_token_capacity]frontend.Token = undefined;
var diagnostics: [frontend.recommended_diagnostic_capacity]frontend.Diagnostic = undefined;

const positive_fixtures = [_][]const u8{
    "Tests/Fixtures/positive_source_contract.bas",
    "Tests/Fixtures/positive_declarations.bas",
    "Tests/Fixtures/positive_control_flow.bas",
    "Tests/Fixtures/positive_io_graphics.bas",
};

const negative_binding_fixtures = [_][]const u8{
    "Tests/Fixtures/negative_structure.bas",
    "Tests/Fixtures/negative_statements.bas",
    "Tests/Fixtures/negative_expressions.bas",
};

const ExpectedLexicalDiagnostic = struct {
    code: frontend.DiagnosticCode,
    line: u32,
};

const negative_lexical_diagnostics = [_]ExpectedLexicalDiagnostic{
    .{ .code = .invalid_include, .line = 1 },
    .{ .code = .invalid_line_continuation, .line = 2 },
    .{ .code = .invalid_identifier, .line = 3 },
    .{ .code = .invalid_number, .line = 4 },
    .{ .code = .invalid_byte, .line = 5 },
    .{ .code = .invalid_byte, .line = 6 },
    .{ .code = .unterminated_string, .line = 7 },
};

test "all public positive BAS fixtures use the sole compiler parser and binder" {
    const allocator = std.testing.allocator;
    for (positive_fixtures) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(frontend.maximum_source_bytes));
        defer allocator.free(source);

        var program = try core.compiler.compile(allocator, path, source);
        defer program.deinit();
        if (!program.ok()) dumpCompilerDiagnostics(&program);
        try std.testing.expect(program.ok());
        try std.testing.expectEqual(@as(u32, 1), program.parse_passes);
        try std.testing.expectEqual(@as(u32, 1), program.bind_passes);
        try std.testing.expect(program.instructions.len != 0);
    }
}

test "negative lexical fixture retains exact deterministic lexer diagnostics" {
    const path = "Tests/Fixtures/negative_lexical.bas";
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(frontend.maximum_source_bytes));
    defer std.testing.allocator.free(source);

    const result = frontend.tokenizeNamed(path, source, tokens[0..], diagnostics[0..]);
    try std.testing.expect(!result.ok());
    try std.testing.expect(!result.diagnostics_truncated);
    for (negative_lexical_diagnostics) |expected| {
        try std.testing.expect(containsLexicalDiagnostic(result, expected));
    }
}

test "negative grammar fixtures are rejected deterministically by the sole compiler parser" {
    const allocator = std.testing.allocator;
    for (negative_binding_fixtures) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(frontend.maximum_source_bytes));
        defer allocator.free(source);

        var first = try core.compiler.compile(allocator, path, source);
        defer first.deinit();
        var second = try core.compiler.compile(allocator, path, source);
        defer second.deinit();
        if (first.ok()) std.debug.print("negative fixture unexpectedly passed: {s}\n", .{path});
        try std.testing.expect(!first.ok());
        try std.testing.expect(!first.diagnostics_truncated);
        try std.testing.expectEqual(first.diagnostics_total, second.diagnostics_total);
        try std.testing.expectEqual(first.diagnostics.len, second.diagnostics.len);
        for (first.diagnostics, second.diagnostics) |left, right| {
            try std.testing.expectEqual(left.code, right.code);
            try std.testing.expectEqual(left.span, right.span);
            try std.testing.expectEqualStrings(left.file_name, right.file_name);
            try std.testing.expectEqualStrings(left.catalog_id, right.catalog_id);
        }
    }
}

test "line endings and extended string bytes remain valid through binding" {
    const sources = [_][]const u8{
        "PRINT \"one\"\nPRINT \"two\"\n",
        "PRINT \"one\"\rPRINT \"two\"\r",
        "PRINT \"one\"\r\nPRINT \"two\"\r\n",
        "Text$ = \"\x80\xFF\"\nEND\n",
    };
    for (sources) |source| {
        var program = try core.compiler.compile(std.testing.allocator, "line-endings.bas", source);
        defer program.deinit();
        if (!program.ok()) dumpCompilerDiagnostics(&program);
        try std.testing.expect(program.ok());
    }
}

test "keyword matching preserves original spelling" {
    const source = "DeFiNt A-Z\n";
    const result = frontend.tokenizeNamed("case.bas", source, tokens[0..], diagnostics[0..]);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(frontend.TokenKind.keyword, tokens[0].kind);
    try std.testing.expectEqual(frontend.Keyword.defint, tokens[0].keyword);
    try std.testing.expectEqualStrings("DeFiNt", tokens[0].text(source));
}

test "token census follows lexical demand instead of source bytes" {
    const allocator = std.testing.allocator;
    const sparse = try allocator.alloc(u8, frontend.maximum_source_bytes);
    defer allocator.free(sparse);
    @memset(sparse, 'A');
    @memcpy(sparse[0..4], "REM ");
    try std.testing.expectEqual(@as(usize, 1), frontend.countTokens(sparse));

    const dense = try allocator.alloc(u8, frontend.maximum_source_bytes);
    defer allocator.free(dense);
    for (0..dense.len / 4) |index| @memcpy(dense[index * 4 ..][0..4], "A=1:");
    try std.testing.expectEqual(frontend.maximum_source_bytes + 1, frontend.countTokens(dense));
}

test "compiler expression depth accepts its boundary and rejects the next level" {
    const allocator = std.testing.allocator;
    const Shape = enum { parentheses, unary, power };
    for ([_]Shape{ .parentheses, .unary, .power }) |shape| {
        for ([_]bool{ true, false }) |accepted| {
            const nested = frontend.maximum_expression_depth - 1 + @intFromBool(!accepted);
            var source: std.ArrayList(u8) = .empty;
            defer source.deinit(allocator);
            try source.appendSlice(allocator, "A=");
            switch (shape) {
                .parentheses => {
                    try source.appendNTimes(allocator, '(', nested);
                    try source.append(allocator, '1');
                    try source.appendNTimes(allocator, ')', nested);
                },
                .unary => {
                    try source.appendNTimes(allocator, '+', nested);
                    try source.append(allocator, '1');
                },
                .power => {
                    try source.append(allocator, '1');
                    for (0..nested) |_| try source.appendSlice(allocator, "^1");
                },
            }
            try source.append(allocator, '\n');

            var program = try core.compiler.compile(allocator, "depth.bas", source.items);
            defer program.deinit();
            if (accepted) {
                if (!program.ok()) dumpCompilerDiagnostics(&program);
                try std.testing.expect(program.ok());
                try std.testing.expectEqual(
                    @as(u16, @intCast(frontend.maximum_expression_depth)),
                    program.compile_stats.maximum_expression_depth,
                );
            } else {
                try std.testing.expect(!program.ok());
                try std.testing.expect(containsCompilerCode(&program, .expression_too_deep));
            }
        }
    }
}

test "all known keywords use bounded case-insensitive lexical lookup" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    for (frontend.supported_keyword_entries, 0..) |entry, entry_index| {
        for (entry.text, 0..) |byte, byte_index| {
            const mixed = if ((entry_index + byte_index) % 2 == 0) std.ascii.toLower(byte) else std.ascii.toUpper(byte);
            try source.append(allocator, mixed);
        }
        try source.append(allocator, ' ');
    }
    for (frontend.unsupported_keyword_words, 0..) |word, entry_index| {
        for (word, 0..) |byte, byte_index| {
            const mixed = if ((entry_index + byte_index) % 2 == 0) std.ascii.toUpper(byte) else std.ascii.toLower(byte);
            try source.append(allocator, mixed);
        }
        try source.append(allocator, ' ');
    }
    try source.appendSlice(allocator, "NotAKeyword123\n");

    const result = frontend.tokenizeNamed("keywords.bas", source.items, tokens[0..], diagnostics[0..]);
    try std.testing.expect(!result.cancelled);
    try std.testing.expectEqual(
        @as(u64, frontend.supported_keyword_entries.len + frontend.unsupported_keyword_words.len + 1),
        result.keyword_lookups,
    );
    try std.testing.expect(result.keyword_max_probe <= frontend.keyword_lookup_probe_bound);
    try std.testing.expect(result.keyword_probes <= result.keyword_lookups * frontend.keyword_lookup_probe_bound);

    var token_index: usize = 0;
    for (frontend.supported_keyword_entries) |entry| {
        try std.testing.expectEqual(frontend.TokenKind.keyword, tokens[token_index].kind);
        try std.testing.expectEqual(entry.keyword, tokens[token_index].keyword);
        token_index += 1;
    }
    for (frontend.unsupported_keyword_words) |_| {
        try std.testing.expectEqual(frontend.TokenKind.keyword, tokens[token_index].kind);
        try std.testing.expectEqual(frontend.Keyword.unsupported, tokens[token_index].keyword);
        token_index += 1;
    }
    try std.testing.expectEqual(frontend.TokenKind.identifier, tokens[token_index].kind);
}

test "remaining QuickBASIC appendix-E words are reserved" {
    const reference_words = [_][]const u8{
        "ENDIF", "SIGNAL", "LOCAL",
    };
    for (reference_words) |word| {
        const result = frontend.tokenizeNamed("appendix-e.bas", word, tokens[0..], diagnostics[0..]);
        try std.testing.expect(result.ok());
        try std.testing.expectEqual(frontend.TokenKind.keyword, tokens[0].kind);
        try std.testing.expectEqual(frontend.Keyword.unsupported, tokens[0].keyword);
        try std.testing.expectEqualStrings(word, tokens[0].text(word));
    }
}

test "event and soft-key appendix-E words are implemented keywords" {
    const reference_words = [_]struct { text: []const u8, keyword: frontend.Keyword }{
        .{ .text = "OFF", .keyword = .off },
        .{ .text = "PEN", .keyword = .pen },
        .{ .text = "COM", .keyword = .com },
        .{ .text = "UEVENT", .keyword = .uevent },
        .{ .text = "LIST", .keyword = .list },
    };
    for (reference_words) |entry| {
        const result = frontend.tokenizeNamed("appendix-e.bas", entry.text, tokens[0..], diagnostics[0..]);
        try std.testing.expect(result.ok());
        try std.testing.expectEqual(frontend.TokenKind.keyword, tokens[0].kind);
        try std.testing.expectEqual(entry.keyword, tokens[0].keyword);
    }
}

test "continuation question-mark and multiple comment metacommands keep exact spans" {
    const source = "? 1 + _\r\n 2\n'$DYNAMIC $INCLUDE: 'INC.BI' $STATIC\n";
    const result = frontend.tokenizeNamed("source-model.bas", source, tokens[0..], diagnostics[0..]);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(frontend.TokenKind.question, tokens[0].kind);
    var number_two: ?frontend.Token = null;
    var metacommands: [3]frontend.Keyword = undefined;
    var metacommand_count: usize = 0;
    for (tokens[0..result.token_count]) |token| {
        if (token.kind == .number and std.mem.eql(u8, token.text(source), "2")) number_two = token;
        if (token.kind == .metacommand) {
            metacommands[metacommand_count] = token.keyword;
            metacommand_count += 1;
        }
    }
    try std.testing.expect(number_two != null);
    try std.testing.expectEqual(@as(u32, 2), number_two.?.span.line);
    try std.testing.expectEqual(@as(u32, 2), number_two.?.span.column);
    try std.testing.expectEqual(@as(usize, 3), metacommand_count);
    try std.testing.expectEqualSlices(frontend.Keyword, &.{ .dynamic, .include, .static }, &metacommands);

    const ignored = "'text $STATIC $DYNAMIC\nREM text $STATIC\n";
    const ignored_result = frontend.tokenizeNamed("ignored-meta.bas", ignored, tokens[0..], diagnostics[0..]);
    try std.testing.expect(ignored_result.ok());
    for (tokens[0..ignored_result.token_count]) |token| try std.testing.expect(token.kind != .metacommand);

    const data_result = frontend.tokenizeNamed("data-continuation.bas", "10 DATA 1, _\n2\n", tokens[0..], diagnostics[0..]);
    try std.testing.expect(!data_result.ok());
    try std.testing.expect(containsLexicalDiagnostic(data_result, .{ .code = .invalid_line_continuation, .line = 1 }));
}

test "lexical diagnostics retain exact file line column and byte span" {
    const source = "PRINT @\r\nPRINT 1\r\n";
    const result = frontend.tokenizeNamed("position.bas", source, tokens[0..], diagnostics[0..]);
    try std.testing.expect(!result.ok());
    try std.testing.expect(result.diagnostic_count >= 1);
    const diagnostic = diagnostics[0];
    try std.testing.expectEqual(frontend.DiagnosticCode.invalid_byte, diagnostic.code);
    try std.testing.expectEqualStrings("position.bas", diagnostic.file_name);
    try std.testing.expectEqual(@as(u32, 1), diagnostic.span.line);
    try std.testing.expectEqual(@as(u32, 7), diagnostic.span.column);
    try std.testing.expectEqualStrings("@", diagnostic.span.bytes(source));
}

test "identifiers honor the 40-byte lexical boundary" {
    var accepted_source: [45]u8 = undefined;
    @memset(accepted_source[0..40], 'A');
    @memcpy(accepted_source[40..], " = 1\n");
    const accepted = frontend.tokenizeNamed("identifier-40.bas", accepted_source[0..], tokens[0..], diagnostics[0..]);
    try std.testing.expect(accepted.ok());

    var rejected_source: [46]u8 = undefined;
    @memset(rejected_source[0..41], 'A');
    @memcpy(rejected_source[41..], " = 1\n");
    const rejected = frontend.tokenizeNamed("identifier-41.bas", rejected_source[0..], tokens[0..], diagnostics[0..]);
    try std.testing.expect(!rejected.ok());
    try std.testing.expect(containsLexicalCode(rejected, .invalid_identifier));
}

test "bounded caller storage fails visibly in the lexer" {
    var tiny_tokens: [2]frontend.Token = undefined;
    const token_result = frontend.tokenizeNamed("tokens.bas", "PRINT 1\n", tiny_tokens[0..], diagnostics[0..]);
    try std.testing.expect(!token_result.ok());
    try std.testing.expect(containsLexicalCode(token_result, .token_capacity_exceeded));

    var no_diagnostics: [0]frontend.Diagnostic = .{};
    const diagnostic_result = frontend.tokenizeNamed("diagnostics.bas", "@", tokens[0..], no_diagnostics[0..]);
    try std.testing.expect(!diagnostic_result.ok());
    try std.testing.expect(diagnostic_result.diagnostics_truncated);

    const oversized = try std.testing.allocator.alloc(u8, frontend.maximum_source_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    const source_result = frontend.tokenizeNamed("large.bas", oversized, tokens[0..], diagnostics[0..]);
    try std.testing.expect(!source_result.ok());
    try std.testing.expect(containsLexicalCode(source_result, .source_too_large));
}

test "ERROR is accepted through the sole lexer compiler and binder" {
    const source = "ERROR 5\nEND\n";
    const lexed = frontend.tokenizeNamed("deferred.bas", source, tokens[0..], diagnostics[0..]);
    try std.testing.expect(lexed.ok());

    var program = try core.compiler.compile(std.testing.allocator, "deferred.bas", source);
    defer program.deinit();
    try std.testing.expect(program.ok());
}

fn containsLexicalDiagnostic(result: frontend.LexResult, expected: ExpectedLexicalDiagnostic) bool {
    for (diagnostics[0..result.diagnostic_count]) |diagnostic| {
        if (diagnostic.code == expected.code and diagnostic.span.line == expected.line) return true;
    }
    return false;
}

fn containsLexicalCode(result: frontend.LexResult, code: frontend.DiagnosticCode) bool {
    for (diagnostics[0..result.diagnostic_count]) |diagnostic| if (diagnostic.code == code) return true;
    return false;
}

fn containsCompilerCode(program: *const core.bytecode.Program, code: core.bytecode.DiagnosticCode) bool {
    for (program.diagnostics) |diagnostic| if (diagnostic.code == code) return true;
    return false;
}

fn dumpCompilerDiagnostics(program: *const core.bytecode.Program) void {
    for (program.diagnostics) |diagnostic| {
        std.debug.print("{s}:{d}:{d}: {s} {s}: {s}\n", .{
            diagnostic.file_name,
            diagnostic.span.line,
            diagnostic.span.column,
            @tagName(diagnostic.code),
            diagnostic.catalog_id,
            diagnostic.span.bytes(program.source),
        });
    }
}
