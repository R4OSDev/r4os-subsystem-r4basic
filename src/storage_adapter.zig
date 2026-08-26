const std = @import("std");
const r4os = @import("r4os");
const vm = @import("vm.zig");

const path_cache_entries: usize = 4;
const shell_argument_capacity: usize = 4096;
const terminal_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X";

const Operation = enum(u8) {
    read,
    write,
    append,
    write_at,
    create,
    info,
    lock,
    unlock,
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
    shell_process: ?r4os.ProcessHandle = null,
    shell_command: [shell_argument_capacity]u8 = undefined,
    shell_command_len: u16 = 0,

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
        services.file_write_at = writeAt;
        services.file_info = fileInfo;
        services.file_lock = fileLock;
        services.file_quiesce = quiesce;
        services.platform_context = self;
        services.path_info = pathInfo;
        services.path_delete = pathDelete;
        services.path_rename = pathRename;
        services.directory_create = directoryCreate;
        services.directory_delete = directoryDelete;
        services.directory_read = directoryRead;
        services.wall_clock = wallClock;
        services.wall_clock_set = wallClockSet;
        services.environment_set = environmentSet;
        services.shell = shell;
        services.platform_quiesce = platformQuiesce;
    }

    /// R4SYS requests are not cancellable. The VM-owned transfer buffer must
    /// remain alive until a terminal state releases the request binding.
    pub fn deinit(self: *Adapter) void {
        self.quiesceActive();
        self.quiesceShell();
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
            const transfer = operation == .read or operation == .write or operation == .append or operation == .write_at or operation == .create;
            if (transfer and count > requested_bytes) {
                self.stats.failures +%= 1;
                continue;
            }
            switch (operation) {
                .read => self.stats.read_bytes +|= @intCast(count),
                .write, .append, .write_at, .create => self.stats.write_bytes +|= @intCast(count),
                .info, .lock, .unlock => {},
            }
        }
    }

    fn platformQuiesce(context: ?*anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return));
        self.quiesceShell();
    }

    fn pathInfo(context: ?*anyopaque, raw_path: []const u8) vm.PathInfoResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        const files = r4os.Files{ .sys = self.resources.sys };
        return switch (files.info(self.cache_path[path_slot].asZ())) {
            .value => |info| .{ .info = if (info.is_dir != 0) .directory else .file },
            .missing => .missing,
            .failure => |raw| .{ .failure = mapPathFailure(raw) },
        };
    }

    fn pathDelete(context: ?*anyopaque, raw_path: []const u8) vm.PathOperationResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        const files = r4os.Files{ .sys = self.resources.sys };
        return mapPathOperation(files.delete(self.cache_path[path_slot].asZ()));
    }

    fn pathRename(context: ?*anyopaque, raw_source: []const u8, raw_target: []const u8) vm.PathOperationResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const source_slot = self.cachedPath(raw_source) orelse return .{ .failure = .path_error };
        const source = self.cache_path[source_slot];
        const target_slot = self.cachedPath(raw_target) orelse return .{ .failure = .path_error };
        const target = self.cache_path[target_slot];
        const files = r4os.Files{ .sys = self.resources.sys };
        return mapPathOperation(files.rename(source.asZ(), target.asZ()));
    }

    fn directoryCreate(context: ?*anyopaque, raw_path: []const u8) vm.PathOperationResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        const files = r4os.Files{ .sys = self.resources.sys };
        return mapPathOperation(files.createDirectory(self.cache_path[path_slot].asZ()));
    }

    fn directoryDelete(context: ?*anyopaque, raw_path: []const u8) vm.PathOperationResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        const files = r4os.Files{ .sys = self.resources.sys };
        return mapPathOperation(files.deleteDirectory(self.cache_path[path_slot].asZ()));
    }

    fn directoryRead(context: ?*anyopaque, raw_path: []const u8, index: u32, out: []u8) vm.DirectoryReadResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        const files = r4os.Files{ .sys = self.resources.sys };
        var iterator = files.iterate(self.cache_path[path_slot].asZ());
        iterator.index = index +| 2;
        return switch (iterator.next(out)) {
            .entry => |entry| .{ .entry = .{
                .kind = if (entry.kind == .directory) .directory else .file,
                .path_length = @intCast(entry.path.len),
            } },
            .end => .end,
            .failure => |raw| .{ .failure = mapPathFailure(raw) },
        };
    }

    fn wallClock(context: ?*anyopaque) vm.WallClockResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .failure));
        const state = self.resources.sys.timeState();
        if (state.valid == 0) return .failure;
        return .{ .value = .{
            .valid = true,
            .year = state.year,
            .month = state.month,
            .day = state.day,
            .weekday = state.weekday,
            .hour = state.hour,
            .minute = state.minute,
            .second = state.second,
        } };
    }

    fn wallClockSet(context: ?*anyopaque, clock: vm.WallClock) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        var state = self.resources.sys.timeState();
        state.valid = @intFromBool(clock.valid);
        state.year = clock.year;
        state.month = clock.month;
        state.day = clock.day;
        state.weekday = clock.weekday;
        state.hour = clock.hour;
        state.minute = clock.minute;
        state.second = clock.second;
        state.seconds_since_midnight = clock.secondsSinceMidnight();
        return self.resources.sys.timeSetState(&state) == 0;
    }

    fn environmentSet(context: ?*anyopaque, raw_name: []const u8, value: []const u8) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        if (raw_name.len == 0 or raw_name.len > vm.maximum_environment_name_bytes) return false;
        var name: [vm.maximum_environment_name_bytes + 1]u8 = .{0} ** (vm.maximum_environment_name_bytes + 1);
        @memcpy(name[0..raw_name.len], raw_name);
        return self.resources.sys.envSet(@ptrCast(&name), value) == 0;
    }

    fn shell(context: ?*anyopaque, command: []const u8) vm.ShellResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        if (std.mem.indexOfScalar(u8, command, 0) != null or command.len + 4 >= self.shell_command.len) {
            return .{ .failure = .path_error };
        }
        if (self.shell_process == null) {
            const prefix = if (command.len == 0) "" else "/C ";
            const argument_len = prefix.len + command.len;
            @memcpy(self.shell_command[0..prefix.len], prefix);
            @memcpy(self.shell_command[prefix.len..argument_len], command);
            self.shell_command[argument_len] = 0;
            self.shell_command_len = @intCast(argument_len);
            var path = r4os.AbsoluteFilePath.parse(terminal_path) catch return .{ .failure = .path_error };
            self.shell_process = switch (self.resources.spawnWithConsoleHost(
                path.asZ(),
                @ptrCast(&self.shell_command),
                .console,
                .terminal_window,
            )) {
                .process => |process| process,
                .failure => |raw| return .{ .failure = mapProcessFailure(raw) },
            };
            return .pending;
        }
        const expected_prefix = if (command.len == 0) "" else "/C ";
        if (self.shell_command_len != expected_prefix.len + command.len or
            !std.mem.eql(u8, self.shell_command[expected_prefix.len..self.shell_command_len], command))
        {
            return .{ .failure = .io_error };
        }
        var process = &self.shell_process.?;
        return switch (process.wait(r4os.time_contract.timeoutPoll())) {
            .exited => |code| blk: {
                self.shell_process = null;
                self.shell_command_len = 0;
                break :blk .{ .exited = code };
            },
            .would_block, .timed_out => .pending,
            .failure => |raw| blk: {
                self.quiesceShell();
                break :blk .{ .failure = mapProcessFailure(raw) };
            },
        };
    }

    fn quiesceShell(self: *Adapter) void {
        const process = if (self.shell_process) |*value| value else return;
        if (!process.valid()) {
            self.shell_process = null;
            self.shell_command_len = 0;
            return;
        }
        _ = process.requestClose();
        switch (process.wait(r4os.time_contract.timeoutFinite(.{ .nanoseconds = 250 * std.time.ns_per_ms }))) {
            .exited => {},
            else => {
                _ = process.kill();
                _ = process.wait(r4os.time_contract.timeoutForever());
            },
        }
        self.shell_process = null;
        self.shell_command_len = 0;
    }

    fn read(context: ?*anyopaque, raw_path: []const u8, offset: u32, out: []u8) vm.FileReadResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        if (self.active) |*active| {
            if (!matches(active, .read, path_slot, offset, if (out.len == 0) 0 else @intFromPtr(out.ptr), out.len)) return self.readFailure(.io_error);
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
        self.active = activeRequest(request, .read, path_slot, offset, if (out.len == 0) 0 else @intFromPtr(out.ptr), out.len);
        self.stats.read_calls +%= 1;
        self.noteSubmission(out.len);
        return .pending;
    }

    fn write(context: ?*anyopaque, raw_path: []const u8, bytes: []const u8, append: bool) vm.FileWriteResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const operation: Operation = if (append) .append else .write;
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        if (self.active) |*active| {
            if (!matches(active, operation, path_slot, 0, if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr), bytes.len)) return self.writeFailure(.io_error);
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
        self.active = activeRequest(request, operation, path_slot, 0, if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr), bytes.len);
        self.stats.write_calls +%= 1;
        self.noteSubmission(bytes.len);
        return .pending;
    }

    fn writeAt(context: ?*anyopaque, raw_path: []const u8, offset: u32, bytes: []const u8, create: bool) vm.FileWriteResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const operation: Operation = if (create) .create else .write_at;
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        const address = if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
        if (self.active) |*active| {
            if (!matches(active, operation, path_slot, offset, address, bytes.len)) return self.writeFailure(.io_error);
            return self.pollWrite(active);
        }

        const opened = if (create and offset == 0 and bytes.len == 0)
            self.resources.asyncWrite(self.cache_path[path_slot].asZ(), bytes, 0)
        else
            self.resources.asyncWriteAt(self.cache_path[path_slot].asZ(), offset, bytes, 0);
        const request = switch (opened) {
            .request => |value| value,
            .failure => |raw| if (isSubmissionBackpressure(raw)) return .pending else return self.writeFailure(mapSubmissionFailure(raw)),
        };
        self.active = activeRequest(request, operation, path_slot, offset, address, bytes.len);
        self.stats.write_calls +%= 1;
        self.noteSubmission(bytes.len);
        return .pending;
    }

    fn fileInfo(context: ?*anyopaque, raw_path: []const u8) vm.FileInfoResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        if (self.active) |*active| {
            if (!matches(active, .info, path_slot, 0, 0, 0)) return .{ .failure = .io_error };
            const terminal = self.pollTerminal(active) orelse return .pending;
            if (terminal == r4os.abi.io_error_not_found) return .missing;
            if (terminal < 0) return .{ .failure = mapInfoFailure(terminal) };
            return .{ .info = .{ .size = @intCast(terminal) } };
        }

        const request = switch (self.resources.asyncFileInfo(self.cache_path[path_slot].asZ(), 0)) {
            .request => |value| value,
            .failure => |raw| if (isSubmissionBackpressure(raw)) return .pending else return .{ .failure = mapSubmissionFailure(raw) },
        };
        self.active = activeRequest(request, .info, path_slot, 0, 0, 0);
        self.noteSubmission(0);
        return .pending;
    }

    fn fileLock(context: ?*anyopaque, raw_path: []const u8, offset: u32, length: u32, unlock: bool) vm.FileLockResult {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return .{ .failure = .unavailable }));
        if (length == 0) return .{ .failure = .path_error };
        const operation: Operation = if (unlock) .unlock else .lock;
        const path_slot = self.cachedPath(raw_path) orelse return .{ .failure = .path_error };
        if (self.active) |*active| {
            if (!matches(active, operation, path_slot, offset, 0, length)) return .{ .failure = .io_error };
            const terminal = self.pollTerminal(active) orelse return .pending;
            if (terminal < 0) return .{ .failure = mapLockFailure(terminal) };
            if (terminal != r4os.abi.io_ok) return .{ .failure = .io_error };
            return .success;
        }

        const flags: u32 = if (unlock) r4os.abi.io_file_lock_flag_unlock else 0;
        const request = switch (self.resources.asyncFileLock(self.cache_path[path_slot].asZ(), offset, length, flags)) {
            .request => |value| value,
            .failure => |raw| if (isSubmissionBackpressure(raw)) return .pending else return .{ .failure = mapSubmissionFailure(raw) },
        };
        self.active = activeRequest(request, operation, path_slot, offset, 0, length);
        self.noteSubmission(length);
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
    buffer_address: usize,
    requested_bytes: usize,
) ActiveRequest {
    return .{
        .request = request,
        .operation = operation,
        .path_slot = path_slot,
        .offset = offset,
        .buffer_address = buffer_address,
        .requested_bytes = requested_bytes,
    };
}

fn matches(
    active: *const ActiveRequest,
    operation: Operation,
    path_slot: u8,
    offset: u64,
    buffer_address: usize,
    requested_bytes: usize,
) bool {
    return active.operation == operation and
        active.path_slot == path_slot and
        active.offset == offset and
        active.requested_bytes == requested_bytes and
        active.buffer_address == buffer_address;
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
        -3, r4os.abi.io_error_not_found => .not_found,
        -10 => .too_large,
        else => .io_error,
    };
}

fn mapInfoFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        r4os.abi.io_error_not_found => .not_found,
        r4os.abi.io_error_invalid => .path_error,
        r4os.abi.io_error_too_large => .too_large,
        else => .io_error,
    };
}

fn mapLockFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        r4os.abi.io_error_lock_violation => .lock_violation,
        r4os.abi.io_error_not_found => .not_found,
        r4os.abi.io_error_invalid => .path_error,
        else => .io_error,
    };
}

fn isSubmissionBackpressure(raw: i32) bool {
    return raw == r4os.abi.io_error_busy or raw == r4os.abi.io_error_no_slots;
}

fn mapSubmissionFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        r4os.abi.io_error_invalid => .path_error,
        r4os.abi.io_error_not_found => .not_found,
        r4os.abi.io_error_lock_violation => .lock_violation,
        r4os.abi.io_error_too_large => .too_large,
        r4os.abi.io_error_no_instance, r4os.abi.io_error_unsupported => .unavailable,
        else => .io_error,
    };
}

fn mapPathOperation(result: r4os.app_storage.Operation) vm.PathOperationResult {
    return switch (result) {
        .ok => .success,
        .missing => .missing,
        .failure => |raw| .{ .failure = mapPathFailure(raw) },
    };
}

fn mapPathFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        -1, -3 => .path_error,
        -2 => .path_not_found,
        -4 => .path_not_found,
        -5, -7 => .permission_denied,
        -6, -8 => .io_error,
        -10 => .too_large,
        -11 => .permission_denied,
        else => .io_error,
    };
}

fn mapProcessFailure(raw: i32) vm.FileHostError {
    return switch (raw) {
        r4os.abi.program_handle_error_not_found => .not_found,
        r4os.abi.program_handle_error_no_memory => .too_many_files,
        r4os.abi.program_handle_error_invalid => .path_error,
        else => .io_error,
    };
}

test "R4SYS storage failures keep BASIC file categories visible" {
    try std.testing.expectEqual(vm.FileHostError.path_error, mapReadFailure(-1));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapReadFailure(-3));
    try std.testing.expectEqual(vm.FileHostError.too_large, mapReadFailure(-8));
    try std.testing.expectEqual(vm.FileHostError.io_error, mapReadFailure(-6));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapWriteFailure(-3));
    try std.testing.expectEqual(vm.FileHostError.not_found, mapInfoFailure(r4os.abi.io_error_not_found));
    try std.testing.expectEqual(vm.FileHostError.lock_violation, mapLockFailure(r4os.abi.io_error_lock_violation));
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
