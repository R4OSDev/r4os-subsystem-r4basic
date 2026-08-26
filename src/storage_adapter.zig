const std = @import("std");
const r4os = @import("r4os");
const vm = @import("vm.zig");

const path_cache_entries: usize = 4;

const Operation = enum(u8) {
    read,
    write,
    append,
};

const ActiveRequest = struct {
    request: r4os.IoRequest,
    operation: Operation,
    path_slot: u8,
    offset: u64,
    buffer_address: usize,
    requested_bytes: usize,
};

pub const Adapter = struct {
    resources: r4os.Resources,
    stats: Stats = .{},
    active: ?ActiveRequest = null,
    cache_valid: [path_cache_entries]bool = .{false} ** path_cache_entries,
    cache_raw: [path_cache_entries][r4os.path.file_path_max + 1]u8 = undefined,
    cache_raw_len: [path_cache_entries]u16 = .{0} ** path_cache_entries,
    cache_path: [path_cache_entries]r4os.AbsoluteFilePath = undefined,
    cache_next: usize = 0,

    pub const Stats = struct {
        read_calls: u64 = 0,
        read_bytes: u64 = 0,
        write_calls: u64 = 0,
        write_bytes: u64 = 0,
        failures: u64 = 0,
        status_polls: u64 = 0,
        pending_polls: u64 = 0,
        completions: u64 = 0,
        path_normalizations: u64 = 0,
        path_cache_hits: u64 = 0,
        maximum_request_bytes: u64 = 0,
        maximum_active_requests: u64 = 0,
    };

    pub fn init(resources: r4os.Resources) Adapter {
        return .{ .resources = resources };
    }

    pub fn install(self: *Adapter, services: *vm.HostServices) void {
        services.file_context = self;
        services.file_read = read;
        services.file_write = write;
        services.file_quiesce = quiesce;
    }

    /// R4SYS requests are not cancellable. The VM-owned transfer buffer must
    /// remain alive until a terminal state releases the request binding.
    pub fn deinit(self: *Adapter) void {
        self.quiesceActive();
        self.* = undefined;
    }

    fn quiesce(context: ?*anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return));
        self.quiesceActive();
    }

    fn quiesceActive(self: *Adapter) void {
        while (self.active) |*active| {
            const operation = active.operation;
            const requested_bytes = active.requested_bytes;
            if (!active.request.valid()) {
                self.active = null;
                self.stats.completions +%= 1;
                self.stats.failures +%= 1;
                break;
            }
            _ = active.request.wait(r4os.time_contract.timeoutForever());
            const terminal = self.pollTerminal(active) orelse continue;
            if (terminal < 0) {
                self.stats.failures +%= 1;
                continue;
            }
            const count: usize = @intCast(terminal);
            if (count > requested_bytes) {
                self.stats.failures +%= 1;
                continue;
            }
            switch (operation) {
                .read => self.stats.read_bytes +|= @intCast(count),
                .write, .append => self.stats.write_bytes +|= @intCast(count),
            }
        }
    }

    fn read(context: ?*anyopaque, raw_path: []const u8, offset: u32, out: []u8) vm.FileReadResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        if (self.active) |*active| {
            if (!matches(active, .read, path_slot, offset, out.ptr, out.len)) return self.readFailure(.io_error);
            return self.pollRead(active);
        }

        const request = switch (self.resources.asyncReadAt(
            self.cache_path[path_slot].asZ(),
            offset,
            out,
            0,
        )) {
            .request => |value| value,
            .failure => |raw| if (isSubmissionBackpressure(raw)) return .pending else return self.readFailure(mapSubmissionFailure(raw)),
        };
        self.active = activeRequest(request, .read, path_slot, offset, out.ptr, out.len);
        self.stats.read_calls +%= 1;
        self.noteSubmission(out.len);
        return .pending;
    }

    fn write(context: ?*anyopaque, raw_path: []const u8, bytes: []const u8, append: bool) vm.FileWriteResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const operation: Operation = if (append) .append else .write;
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        if (self.active) |*active| {
            if (!matches(active, operation, path_slot, 0, bytes.ptr, bytes.len)) return self.writeFailure(.io_error);
            return self.pollWrite(active);
        }

        const opened = if (append)
            self.resources.asyncAppend(self.cache_path[path_slot].asZ(), bytes, 0)
        else
            self.resources.asyncWrite(self.cache_path[path_slot].asZ(), bytes, 0);
        const request = switch (opened) {
            .request => |value| value,
            .failure => |raw| if (isSubmissionBackpressure(raw)) return .pending else return self.writeFailure(mapSubmissionFailure(raw)),
        };
        self.active = activeRequest(request, operation, path_slot, 0, bytes.ptr, bytes.len);
        self.stats.write_calls +%= 1;
        self.noteSubmission(bytes.len);
        return .pending;
    }

    fn pollRead(self: *Adapter, active: *ActiveRequest) vm.FileReadResult {
        const requested_bytes = active.requested_bytes;
        const terminal = self.pollTerminal(active) orelse return .pending;
        if (terminal < 0) return self.readFailure(mapReadFailure(terminal));
        const count: usize = @intCast(terminal);
        if (count > requested_bytes) return self.readFailure(.io_error);
        self.stats.read_bytes +|= @intCast(count);
        return if (count == 0) .end else .{ .bytes = @intCast(count) };
    }

    fn pollWrite(self: *Adapter, active: *ActiveRequest) vm.FileWriteResult {
        const requested_bytes = active.requested_bytes;
        const terminal = self.pollTerminal(active) orelse return .pending;
        if (terminal < 0) return self.writeFailure(mapWriteFailure(terminal));
        const count: usize = @intCast(terminal);
        if (count > requested_bytes) return self.writeFailure(.io_error);
        self.stats.write_bytes +|= @intCast(count);
        return .{ .bytes = @intCast(count) };
    }

    fn pollTerminal(self: *Adapter, active: *ActiveRequest) ?i32 {
        self.stats.status_polls +%= 1;
        const info = switch (active.request.status()) {
            .value => |value| value,
            .failure => |raw| {
                const closed = active.request.close();
                if (closed != r4os.abi.io_ok and closed != r4os.abi.err_closed) {
                    self.stats.pending_polls +%= 1;
                    return null;
                }
                self.active = null;
                self.stats.completions +%= 1;
                return raw;
            },
        };
        const invalid_state = switch (info.state) {
            r4os.abi.io_state_pending, r4os.abi.io_state_running => {
                self.stats.pending_polls +%= 1;
                return null;
            },
            r4os.abi.io_state_completed, r4os.abi.io_state_failed => false,
            else => true,
        };
        const close_result = active.request.close();
        if (close_result == r4os.abi.io_error_busy) {
            self.stats.pending_polls +%= 1;
            return null;
        }
        if (close_result != r4os.abi.io_ok and close_result != r4os.abi.err_closed) {
            self.stats.failures +%= 1;
            return null;
        }
        const result = if (invalid_state)
            r4os.abi.io_error_invalid
        else if (info.result < 0)
            info.result
        else if (info.status < 0)
            info.status
        else if (info.state == r4os.abi.io_state_failed)
            r4os.abi.io_error_invalid
        else
            info.result;
        self.active = null;
        self.stats.completions +%= 1;
        return result;
    }

    fn cachedPath(self: *Adapter, raw_path: []const u8) ?u8 {
        if (raw_path.len > r4os.path.file_path_max) {
            self.stats.failures +%= 1;
            return null;
        }
        for (0..path_cache_entries) |slot| {
            if (!self.cache_valid[slot]) continue;
            const len: usize = self.cache_raw_len[slot];
            if (std.mem.eql(u8, raw_path, self.cache_raw[slot][0..len])) {
                self.stats.path_cache_hits +%= 1;
                return @intCast(slot);
            }
        }

        const normalized = r4os.AbsoluteFilePath.parse(raw_path) catch {
            self.stats.failures +%= 1;
            return null;
        };
        const slot = self.cache_next;
        self.cache_next = (slot + 1) % path_cache_entries;
        @memcpy(self.cache_raw[slot][0..raw_path.len], raw_path);
        self.cache_raw_len[slot] = @intCast(raw_path.len);
        self.cache_path[slot] = normalized;
        self.cache_valid[slot] = true;
        self.stats.path_normalizations +%= 1;
        return @intCast(slot);
    }

    fn noteSubmission(self: *Adapter, requested_bytes: usize) void {
        self.stats.maximum_request_bytes = @max(self.stats.maximum_request_bytes, @as(u64, @intCast(requested_bytes)));
        self.stats.maximum_active_requests = 1;
    }

    fn readFailure(self: *Adapter, failure: vm.FileHostError) vm.FileReadResult {
        self.stats.failures +%= 1;
        return .{ .failure = failure };
    }

    fn writeFailure(self: *Adapter, failure: vm.FileHostError) vm.FileWriteResult {
        self.stats.failures +%= 1;
        return .{ .failure = failure };
    }
};

fn activeRequest(
    request: r4os.IoRequest,
    operation: Operation,
    path_slot: u8,
    offset: u64,
    pointer: anytype,
    requested_bytes: usize,
) ActiveRequest {
    return .{
        .request = request,
        .operation = operation,
        .path_slot = path_slot,
        .offset = offset,
        .buffer_address = if (requested_bytes == 0) 0 else @intFromPtr(pointer),
        .requested_bytes = requested_bytes,
    };
}

fn matches(
    active: *const ActiveRequest,
    operation: Operation,
    path_slot: u8,
    offset: u64,
    pointer: anytype,
    requested_bytes: usize,
) bool {
    return active.operation == operation and
        active.path_slot == path_slot and
        active.offset == offset and
        active.requested_bytes == requested_bytes and
        (requested_bytes == 0 or active.buffer_address == @intFromPtr(pointer));
}

fn mapReadFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        -1, -2, -4 => .path_error,
        -3 => .not_found,
        -5, -8, -10 => .too_large,
        else => .io_error,
    };
}

fn mapWriteFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        -1, -2 => .path_error,
        -3 => .not_found,
        -10 => .too_large,
        else => .io_error,
    };
}

fn isSubmissionBackpressure(raw: i32) bool {
    return raw == r4os.abi.io_error_busy or raw == r4os.abi.io_error_no_slots;
}

fn mapSubmissionFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        r4os.abi.io_error_invalid => .path_error,
        r4os.abi.io_error_too_large => .too_large,
        r4os.abi.io_error_no_instance, r4os.abi.io_error_unsupported => .unavailable,
        else => .io_error,
    };
}

test "R4SYS storage failures keep BASIC file categories visible" {
    try std.testing.expectEqual(vm.FileHostError.path_error, mapReadFailure(-1));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapReadFailure(-3));
    try std.testing.expectEqual(vm.FileHostError.too_large, mapReadFailure(-8));
    try std.testing.expectEqual(vm.FileHostError.io_error, mapReadFailure(-6));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapWriteFailure(-3));
    try std.testing.expect(isSubmissionBackpressure(r4os.abi.io_error_busy));
    try std.testing.expect(isSubmissionBackpressure(r4os.abi.io_error_no_slots));
    try std.testing.expectEqual(vm.FileHostError.path_error, mapSubmissionFailure(r4os.abi.io_error_invalid));
    try std.testing.expectEqual(vm.FileHostError.unavailable, mapSubmissionFailure(r4os.abi.io_error_no_instance));
    try std.testing.expectEqual(vm.FileHostError.too_large, mapSubmissionFailure(r4os.abi.io_error_too_large));

    var adapter = Adapter.init(undefined);
    const first = adapter.cachedPath("c:/GAMES/./DATA/../INPUT.TXT") orelse return error.PathCacheMiss;
    const second = adapter.cachedPath("c:/GAMES/./DATA/../INPUT.TXT") orelse return error.PathCacheMiss;
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("C:\\GAMES\\INPUT.TXT", adapter.cache_path[first].bytes());
    try std.testing.expectEqual(@as(u64, 1), adapter.stats.path_normalizations);
    try std.testing.expectEqual(@as(u64, 1), adapter.stats.path_cache_hits);
}
