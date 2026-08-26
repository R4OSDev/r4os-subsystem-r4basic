const std = @import("std");
const frontend = @import("frontend");

var tokens: [frontend.recommended_token_capacity]frontend.Token = undefined;
var diagnostics: [frontend.recommended_diagnostic_capacity]frontend.Diagnostic = undefined;
var repeat_tokens: [frontend.recommended_token_capacity]frontend.Token = undefined;
var repeat_diagnostics: [frontend.recommended_diagnostic_capacity]frontend.Diagnostic = undefined;

const positive_fixtures = [_][]const u8{
    "Tests/Fixtures/positive_source_contract.bas",
    "Tests/Fixtures/positive_declarations.bas",
    "Tests/Fixtures/positive_control_flow.bas",
    "Tests/Fixtures/positive_io_graphics.bas",
};

const ExpectedDiagnostic = struct {
    code: frontend.DiagnosticCode,
    line: u32,
};

const NegativeFixture = struct {
    path: []const u8,
    expected: []const ExpectedDiagnostic,
};

const negative_fixtures = [_]NegativeFixture{
    .{
        .path = "Tests/Fixtures/negative_lexical.bas",
        .expected = &.{
            .{ .code = .unsupported_metacommand, .line = 1 },
            .{ .code = .invalid_byte, .line = 2 },
            .{ .code = .invalid_identifier, .line = 3 },
            .{ .code = .invalid_number, .line = 4 },
            .{ .code = .invalid_byte, .line = 5 },
            .{ .code = .invalid_byte, .line = 6 },
            .{ .code = .unterminated_string, .line = 7 },
        },
    },
    .{
        .path = "Tests/Fixtures/negative_structure.bas",
        .expected = &.{
            .{ .code = .expected_identifier, .line = 1 },
            .{ .code = .expected_identifier, .line = 2 },
            .{ .code = .unmatched_block, .line = 3 },
            .{ .code = .unmatched_block, .line = 5 },
            .{ .code = .unmatched_block, .line = 6 },
            .{ .code = .unclosed_block, .line = 8 },
        },
    },
    .{
        .path = "Tests/Fixtures/negative_statements.bas",
        .expected = &.{
            .{ .code = .unsupported_statement, .line = 1 },
            .{ .code = .unsupported_statement, .line = 2 },
            .{ .code = .expected_expression, .line = 3 },
            .{ .code = .expected_token, .line = 4 },
            .{ .code = .unexpected_token, .line = 5 },
            .{ .code = .expected_token, .line = 6 },
            .{ .code = .expected_token, .line = 7 },
            .{ .code = .expected_expression, .line = 8 },
            .{ .code = .expected_expression, .line = 9 },
            .{ .code = .unsupported_statement, .line = 10 },
            .{ .code = .expected_expression, .line = 11 },
        },
    },
    .{
        .path = "Tests/Fixtures/negative_expressions.bas",
        .expected = &.{
            .{ .code = .wrong_argument_count, .line = 1 },
            .{ .code = .wrong_argument_count, .line = 2 },
            .{ .code = .wrong_argument_count, .line = 3 },
            .{ .code = .wrong_argument_count, .line = 4 },
            .{ .code = .wrong_argument_count, .line = 5 },
            .{ .code = .wrong_argument_count, .line = 6 },
            .{ .code = .wrong_argument_count, .line = 7 },
            .{ .code = .wrong_argument_count, .line = 8 },
            .{ .code = .expected_expression, .line = 9 },
            .{ .code = .expected_separator, .line = 10 },
            .{ .code = .invalid_byte, .line = 11 },
            .{ .code = .expected_expression, .line = 12 },
            .{ .code = .expected_expression, .line = 13 },
        },
    },
};

test "all public positive BAS fixtures satisfy the v1 source contract" {
    const allocator = std.testing.allocator;
    for (positive_fixtures) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(frontend.maximum_source_bytes));
        defer allocator.free(source);

        const result = frontend.analyzeNamed(path, source, tokens[0..], diagnostics[0..]);
        if (!result.ok()) dumpDiagnostics(source, result);
        try std.testing.expect(!result.diagnostics_truncated);
        try std.testing.expect(result.ok());
        try std.testing.expect(result.summary.statements != 0);
    }
}

test "negative BAS fixtures produce their contracted diagnostics" {
    const allocator = std.testing.allocator;
    for (negative_fixtures) |fixture| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture.path, allocator, .limited(frontend.maximum_source_bytes));
        defer allocator.free(source);

        const result = frontend.analyzeNamed(fixture.path, source, tokens[0..], diagnostics[0..]);
        if (result.ok()) std.debug.print("negative fixture unexpectedly passed: {s}\n", .{fixture.path});
        try std.testing.expect(!result.ok());
        try std.testing.expect(!result.diagnostics_truncated);

        const repeated = frontend.analyzeNamed(fixture.path, source, repeat_tokens[0..], repeat_diagnostics[0..]);
        try std.testing.expectEqual(result.token_count, repeated.token_count);
        try std.testing.expectEqual(result.diagnostic_count, repeated.diagnostic_count);
        try std.testing.expectEqual(result.diagnostics_truncated, repeated.diagnostics_truncated);
        for (diagnostics[0..result.diagnostic_count], repeat_diagnostics[0..repeated.diagnostic_count]) |first, second| {
            try std.testing.expectEqual(first.code, second.code);
            try std.testing.expectEqual(first.span, second.span);
            try std.testing.expectEqualStrings(first.file_name, second.file_name);
        }

        for (diagnostics[0..result.diagnostic_count]) |diagnostic| {
            try std.testing.expectEqualStrings(fixture.path, diagnostic.file_name);
        }
        for (fixture.expected) |expected| {
            if (!containsDiagnostic(result, expected)) {
                dumpDiagnostics(source, result);
                std.debug.print("missing diagnostic {s} on line {d} in {s}\n", .{
                    @tagName(expected.code),
                    expected.line,
                    fixture.path,
                });
            }
            try std.testing.expect(containsDiagnostic(result, expected));
        }
    }
}

test "line endings and extended string bytes are source-stable" {
    const sources = [_][]const u8{
        "PRINT \"one\"\nPRINT \"two\"\n",
        "PRINT \"one\"\rPRINT \"two\"\r",
        "PRINT \"one\"\r\nPRINT \"two\"\r\n",
        "Text$ = \"\x80\xFF\"\nEND\n",
    };
    for (sources, 0..) |source, index| {
        const result = frontend.analyzeNamed("line-endings.bas", source, tokens[0..], diagnostics[0..]);
        if (!result.ok()) dumpDiagnostics(source, result);
        try std.testing.expect(result.ok());
        if (index < 3) try std.testing.expectEqual(@as(u32, 2), result.summary.statements);
    }
}

test "keyword matching preserves the original source spelling" {
    const source = "DeFiNt A-Z\n";
    const result = frontend.analyzeNamed("case.bas", source, tokens[0..], diagnostics[0..]);
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

test "expression depth accepts its boundary and rejects the next recursive level" {
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
            const result = frontend.analyzeNamed("depth.bas", source.items, tokens[0..], diagnostics[0..]);
            if (accepted) {
                if (!result.ok()) dumpDiagnostics(source.items, result);
                try std.testing.expect(result.ok());
                try std.testing.expectEqual(
                    @as(u16, @intCast(frontend.maximum_expression_depth)),
                    result.summary.maximum_expression_depth,
                );
            } else {
                try std.testing.expect(!result.ok());
                try std.testing.expect(containsCode(result, .expression_too_deep));
            }
        }
    }
}

test "all supported and unsupported keywords use bounded case-insensitive lookup" {
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

test "diagnostics retain exact file line column and byte span" {
    const source = "PRINT @\r\nPRINT 1\r\n";
    const result = frontend.analyzeNamed("position.bas", source, tokens[0..], diagnostics[0..]);
    try std.testing.expect(!result.ok());
    try std.testing.expect(result.diagnostic_count >= 1);
    const diagnostic = diagnostics[0];
    try std.testing.expectEqual(frontend.DiagnosticCode.invalid_byte, diagnostic.code);
    try std.testing.expectEqualStrings("position.bas", diagnostic.file_name);
    try std.testing.expectEqual(@as(u32, 1), diagnostic.span.line);
    try std.testing.expectEqual(@as(u32, 7), diagnostic.span.column);
    try std.testing.expectEqualStrings("@", diagnostic.span.bytes(source));
}

test "identifiers honor the 40-byte source-contract boundary" {
    var accepted_source: [45]u8 = undefined;
    @memset(accepted_source[0..40], 'A');
    @memcpy(accepted_source[40..], " = 1\n");
    const accepted = frontend.analyzeNamed("identifier-40.bas", accepted_source[0..], tokens[0..], diagnostics[0..]);
    try std.testing.expect(accepted.ok());

    var rejected_source: [46]u8 = undefined;
    @memset(rejected_source[0..41], 'A');
    @memcpy(rejected_source[41..], " = 1\n");
    const rejected = frontend.analyzeNamed("identifier-41.bas", rejected_source[0..], tokens[0..], diagnostics[0..]);
    try std.testing.expect(!rejected.ok());
    try std.testing.expect(containsCode(rejected, .invalid_identifier));
}

test "bounded caller storage fails visibly" {
    var tiny_tokens: [2]frontend.Token = undefined;
    const token_result = frontend.analyzeNamed("tokens.bas", "PRINT 1\n", tiny_tokens[0..], diagnostics[0..]);
    try std.testing.expect(!token_result.ok());
    try std.testing.expect(containsCode(token_result, .token_capacity_exceeded));

    var no_diagnostics: [0]frontend.Diagnostic = .{};
    const diagnostic_result = frontend.analyzeNamed("diagnostics.bas", "@", tokens[0..], no_diagnostics[0..]);
    try std.testing.expect(!diagnostic_result.ok());
    try std.testing.expect(diagnostic_result.diagnostics_truncated);

    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(u8, frontend.maximum_source_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    const source_result = frontend.analyzeNamed("large.bas", oversized, tokens[0..], diagnostics[0..]);
    try std.testing.expect(!source_result.ok());
    try std.testing.expect(containsCode(source_result, .source_too_large));
}

fn containsDiagnostic(result: frontend.Result, expected: ExpectedDiagnostic) bool {
    for (diagnostics[0..result.diagnostic_count]) |diagnostic| {
        if (diagnostic.code == expected.code and diagnostic.span.line == expected.line) return true;
    }
    return false;
}

fn containsCode(result: frontend.Result, code: frontend.DiagnosticCode) bool {
    for (diagnostics[0..result.diagnostic_count]) |diagnostic| {
        if (diagnostic.code == code) return true;
    }
    return false;
}

fn dumpDiagnostics(source: []const u8, result: frontend.Result) void {
    for (diagnostics[0..result.diagnostic_count]) |diagnostic| {
        std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{
            diagnostic.file_name,
            diagnostic.span.line,
            diagnostic.span.column,
            @tagName(diagnostic.code),
            diagnostic.span.bytes(source),
        });
    }
}
