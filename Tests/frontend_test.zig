const std = @import("std");
const frontend = @import("frontend");

var tokens: [frontend.recommended_token_capacity]frontend.Token = undefined;
var diagnostics: [frontend.recommended_diagnostic_capacity]frontend.Diagnostic = undefined;

test "frontend accepts a minimal structured BASIC program" {
    const source =
        \\'$DYNAMIC
        \\DEFINT A-Z
        \\DECLARE SUB Hello (Name$)
        \\CONST TRUE = -1
        \\DIM SHARED Values(1 TO 4) AS INTEGER
        \\IF TRUE THEN
        \\  Hello "R4OS"
        \\END IF
        \\END
        \\SUB Hello (Name$)
        \\  PRINT UCASE$(Name$);
        \\END SUB
    ;
    const result = frontend.analyze(source, tokens[0..], diagnostics[0..]);
    if (!result.ok()) dumpDiagnostics(source, result);
    try std.testing.expect(result.ok());
    try std.testing.expect(result.summary.statements >= 8);
    try std.testing.expectEqual(@as(u32, 1), result.summary.metacommands);
}

fn dumpDiagnostics(source: []const u8, result: frontend.Result) void {
    for (diagnostics[0..result.diagnostic_count]) |diagnostic| {
        std.debug.print("{d}:{d}: {s}: {s}\n", .{
            diagnostic.span.line,
            diagnostic.span.column,
            @tagName(diagnostic.code),
            diagnostic.span.bytes(source),
        });
    }
}

