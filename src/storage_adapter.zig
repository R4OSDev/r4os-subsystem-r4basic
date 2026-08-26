const r4os = @import("r4os");
const vm = @import("vm.zig");

pub const Adapter = struct {
    files: r4os.Files,
    stats: Stats = .{},

    pub const Stats = struct {
        read_calls: u64 = 0,
        read_bytes: u64 = 0,
        write_calls: u64 = 0,
        write_bytes: u64 = 0,
        failures: u64 = 0,
    };

    pub fn init(files: r4os.Files) Adapter {
        return .{ .files = files };
    }

    pub fn install(self: *Adapter, services: *vm.HostServices) void {
        services.file_context = self;
        services.file_read = read;
        services.file_write = write;
    }

    fn read(context: ?*anyopaque, raw_path: []const u8, offset: u32, out: []u8) vm.FileReadResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        self.stats.read_calls +%= 1;
        var path = r4os.AbsoluteFilePath.parse(raw_path) catch {
            self.stats.failures +%= 1;
            return .{ .failure = .path_error };
        };
        return switch (self.files.readAt(path.asZ(), offset, out)) {
            .bytes => |count| blk: {
                self.stats.read_bytes +%= @intCast(count);
                break :blk .{ .bytes = count };
            },
            .end => .end,
            .failure => |raw| blk: {
                self.stats.failures +%= 1;
                break :blk .{ .failure = mapReadFailure(raw) };
            },
        };
    }

    fn write(context: ?*anyopaque, raw_path: []const u8, bytes: []const u8, append: bool) vm.FileWriteResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        self.stats.write_calls +%= 1;
        var path = r4os.AbsoluteFilePath.parse(raw_path) catch {
            self.stats.failures +%= 1;
            return .{ .failure = .path_error };
        };
        const result = if (append)
            self.files.append(path.asZ(), bytes)
        else
            self.files.write(path.asZ(), bytes);
        return switch (result) {
            .bytes => |count| if (count == bytes.len) blk: {
                self.stats.write_bytes +%= @intCast(count);
                break :blk .ok;
            } else blk: {
                self.stats.failures +%= 1;
                break :blk .{ .failure = .io_error };
            },
            .end => blk: {
                self.stats.failures +%= 1;
                break :blk .{ .failure = .io_error };
            },
            .failure => |raw| blk: {
                self.stats.failures +%= 1;
                break :blk .{ .failure = mapWriteFailure(raw) };
            },
        };
    }
};

fn mapReadFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        -1, -2, -4 => .path_error,
        -3 => .not_found,
        -5, -8 => .too_large,
        else => .io_error,
    };
}

fn mapWriteFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        -1, -2 => .path_error,
        -3 => .not_found,
        else => .io_error,
    };
}

test "R4SYS storage failures keep BASIC file categories visible" {
    const std = @import("std");
    try std.testing.expectEqual(vm.FileHostError.path_error, mapReadFailure(-1));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapReadFailure(-3));
    try std.testing.expectEqual(vm.FileHostError.too_large, mapReadFailure(-5));
    try std.testing.expectEqual(vm.FileHostError.io_error, mapReadFailure(-6));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapWriteFailure(-3));
}
