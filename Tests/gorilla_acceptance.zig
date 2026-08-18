const std = @import("std");
const frontend = @import("frontend");

const canonical_path = "../../../Artifacts/Distribution/Injection/Temp/gorilla.bas";
const canonical_size: usize = 29_434;
const canonical_sha256 = [_]u8{
    0x99, 0x26, 0xFC, 0x1F, 0x50, 0xC4, 0xB4, 0x89,
    0xEC, 0x4C, 0x1B, 0x0D, 0xA5, 0xBD, 0x2C, 0x49,
    0x7E, 0xBF, 0x42, 0x82, 0xB3, 0x25, 0x9C, 0x28,
    0xA8, 0x35, 0xA7, 0x43, 0xE2, 0x46, 0x99, 0xF7,
};

var tokens: [frontend.recommended_token_capacity]frontend.Token = undefined;
var diagnostics: [frontend.recommended_diagnostic_capacity]frontend.Diagnostic = undefined;

test "canonical local GORILLA.BAS tokenizes and parses unchanged" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, canonical_path, allocator, .limited(frontend.maximum_source_bytes));
    defer allocator.free(source);
    try std.testing.expectEqual(canonical_size, source.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualSlices(u8, canonical_sha256[0..], digest[0..]);

    const result = frontend.analyzeNamed(canonical_path, source, tokens[0..], diagnostics[0..]);
    if (!result.ok()) {
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
    try std.testing.expect(result.ok());
}
