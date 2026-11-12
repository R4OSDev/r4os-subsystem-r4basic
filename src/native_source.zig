//! Native source boundary; BASIC bytes and graph/compiler semantics stay exact.
const std = @import("std");
const r4os = @import("r4os");

pub const Info = union(enum) {
    value: struct { size: u64, is_dir: u8 },
    missing,
    failure: i32,
};

pub fn Reader(comptime Files: type) type {
    return struct {
        files: *const Files,
        const Self = @This();

        pub fn info(self: *const Self, path: []const u8) Info {
            var parsed = r4os.AbsoluteFilePath.parse(path) catch return .missing;
            return switch (self.files.metadata(parsed.asZ())) {
                .missing => .missing,
                .failure => |code| .{ .failure = code },
                .found => |value| blk: {
                    const directory = value.flags & r4os.abi.file_metadata2_flag_directory != 0;
                    if (!directory and value.flags & r4os.abi.file_metadata2_flag_byte_size_valid == 0)
                        break :blk .{ .failure = r4os.abi.file_metadata2_error_unsupported };
                    // The graph needs size/type, never a narrowed legacy backend node.
                    break :blk .{ .value = .{ .size = if (directory) 0 else value.byte_size, .is_dir = @intFromBool(directory) } };
                },
            };
        }

        pub fn readAt(self: *const Self, path: []const u8, offset: u32, out: []u8) r4os.app_storage.Transfer {
            // source_loader supplies its one exact whole-file allocation.
            // A changed size cannot turn a bounded prefix into a whole source.
            if (offset != 0) return .{ .failure = r4os.abi.file_metadata2_error_invalid };
            if (out.len == 0) return .end;
            if (out.len > std.math.maxInt(i32)) return .{ .failure = r4os.abi.file_metadata2_error_invalid };
            var parsed = r4os.AbsoluteFilePath.parse(path) catch return .{ .failure = -1 };
            return switch (self.files.readDocumentPrefix(parsed.asZ(), out, r4os.time_contract.timeoutFinite(.{ .nanoseconds = 5_000_000_000 }))) {
                .failure => |code| .{ .failure = code },
                .value => |result| if (result.bytes == out.len and result.file_size == out.len)
                    .{ .bytes = @intCast(result.bytes) }
                else
                    .{ .failure = r4os.abi.file_stream_error_size_mismatch },
            };
        }
    };
}
