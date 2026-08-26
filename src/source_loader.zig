const std = @import("std");
const frontend = @import("frontend.zig");

pub const Stats = struct {
    info_calls: u32 = 0,
    read_calls: u32 = 0,
    read_bytes: u64 = 0,
};

pub const Loaded = struct {
    bytes: []u8,
    stats: Stats,
};

pub const Error = error{
    OutOfMemory,
    Missing,
    Directory,
    TooLarge,
    ReadFailure,
    ShortRead,
};

/// Allocates the exact source size once and fills that same caller-owned
/// buffer with range reads. Ownership passes unchanged to the compiler.
pub fn load(allocator: std.mem.Allocator, reader: anytype, path: anytype) Error!Loaded {
    var stats: Stats = .{ .info_calls = 1 };
    const info = switch (reader.info(path)) {
        .value => |value| value,
        .missing => return error.Missing,
        .failure => return error.ReadFailure,
    };
    if (info.is_dir != 0) return error.Directory;
    if (info.size > frontend.maximum_source_bytes or info.size > std.math.maxInt(usize)) return error.TooLarge;
    const source = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(source);
    var offset: usize = 0;
    while (offset < source.len) {
        const read_offset: u32 = std.math.cast(u32, offset) orelse return error.TooLarge;
        stats.read_calls +|= 1;
        switch (reader.readAt(path, read_offset, source[offset..])) {
            .bytes => |count| {
                if (count == 0 or count > source.len - offset) return error.ReadFailure;
                stats.read_bytes +|= count;
                offset += count;
            },
            .end => return error.ShortRead,
            .failure => return error.ReadFailure,
        }
    }
    return .{ .bytes = source, .stats = stats };
}
