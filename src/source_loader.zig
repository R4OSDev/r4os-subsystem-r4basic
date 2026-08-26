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

pub const maximum_source_files: usize = 64;
pub const maximum_include_depth: usize = 16;
pub const maximum_guest_path_bytes: usize = 1023;
pub const maximum_graph_diagnostics: usize = 128;

pub const Graph = struct {
    source: []u8,
    file_names: [][]u8,
    line_origins: []frontend.LineOrigin,
    diagnostics: []frontend.Diagnostic,
    diagnostics_truncated: bool,
    stats: Stats,

    pub fn ok(self: Graph) bool {
        return self.diagnostics.len == 0 and !self.diagnostics_truncated;
    }

    pub fn takeSource(self: *Graph) []u8 {
        const source = self.source;
        self.source = &.{};
        return source;
    }

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        if (self.source.len != 0) allocator.free(self.source);
        for (self.file_names) |file_name| allocator.free(file_name);
        if (self.file_names.len != 0) allocator.free(self.file_names);
        if (self.line_origins.len != 0) allocator.free(self.line_origins);
        if (self.diagnostics.len != 0) allocator.free(self.diagnostics);
        self.* = undefined;
    }
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

const FileRecord = struct {
    path: []u8,
    bytes: []u8,
};

const EnsureResult = union(enum) {
    index: u16,
    missing,
    directory,
    read_failure,
    too_large,
    too_many,
};

const GraphState = struct {
    allocator: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    line_origins: std.ArrayList(frontend.LineOrigin) = .empty,
    diagnostics: std.ArrayList(frontend.Diagnostic) = .empty,
    files: std.ArrayList(FileRecord) = .empty,
    active: [maximum_source_files]u16 = undefined,
    active_len: usize = 0,
    stats: Stats = .{},
    stopped: bool = false,
    diagnostics_truncated: bool = false,

    fn deinit(self: *GraphState) void {
        for (self.files.items) |file| {
            if (file.path.len != 0) self.allocator.free(file.path);
            if (file.bytes.len != 0) self.allocator.free(file.bytes);
        }
        self.files.deinit(self.allocator);
        self.source.deinit(self.allocator);
        self.line_origins.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    fn loadUnique(self: *GraphState, reader: anytype, path: []const u8) Error!EnsureResult {
        for (self.files.items, 0..) |file, index| {
            if (std.ascii.eqlIgnoreCase(file.path, path)) return .{ .index = @intCast(index) };
        }
        if (self.files.items.len >= maximum_source_files) return .too_many;

        const sentinel_path = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(sentinel_path);
        self.stats.info_calls +|= 1;
        const loaded = load(self.allocator, reader, sentinel_path) catch |fault| switch (fault) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return .too_large,
            error.Missing => return .missing,
            error.Directory => return .directory,
            error.ReadFailure, error.ShortRead => return .read_failure,
        };
        errdefer self.allocator.free(loaded.bytes);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.files.append(self.allocator, .{ .path = owned_path, .bytes = loaded.bytes });
        self.stats.read_calls +|= loaded.stats.read_calls;
        self.stats.read_bytes +|= loaded.stats.read_bytes;
        return .{ .index = @intCast(self.files.items.len - 1) };
    }

    fn addDiagnostic(self: *GraphState, code: frontend.DiagnosticCode, span: frontend.Span) !void {
        if (self.diagnostics.items.len >= maximum_graph_diagnostics) {
            self.diagnostics_truncated = true;
            return;
        }
        const file_name = if (@as(usize, span.file_id) < self.files.items.len)
            self.files.items[span.file_id].path
        else
            self.files.items[0].path;
        try self.diagnostics.append(self.allocator, .{ .code = code, .span = span, .file_name = file_name });
    }

    fn isActive(self: *const GraphState, file_index: u16) bool {
        for (self.active[0..self.active_len]) |active| if (active == file_index) return true;
        return false;
    }

    fn appendBytes(self: *GraphState, bytes: []const u8, span: frontend.Span) !bool {
        if (bytes.len > frontend.maximum_source_bytes - self.source.items.len) {
            try self.addDiagnostic(.include_graph_too_large, span);
            self.stopped = true;
            return false;
        }
        try self.source.appendSlice(self.allocator, bytes);
        return true;
    }

    fn ensureLineBreak(self: *GraphState, span: frontend.Span) !bool {
        if (self.source.items.len == 0) return true;
        const last = self.source.items[self.source.items.len - 1];
        if (last == '\r' or last == '\n') return true;
        return self.appendBytes("\n", span);
    }

    fn expandFile(self: *GraphState, reader: anytype, file_index: u16, depth: usize) Error!void {
        if (self.stopped) return;
        self.active[self.active_len] = file_index;
        self.active_len += 1;
        defer self.active_len -= 1;

        const bytes = self.files.items[file_index].bytes;
        const path = self.files.items[file_index].path;
        var offset: usize = 0;
        var source_line: u32 = 1;
        while (offset < bytes.len and !self.stopped) : (source_line += 1) {
            var content_end = offset;
            while (content_end < bytes.len and bytes[content_end] != '\r' and bytes[content_end] != '\n') content_end += 1;
            var line_end = content_end;
            if (line_end < bytes.len) {
                if (bytes[line_end] == '\r' and line_end + 1 < bytes.len and bytes[line_end + 1] == '\n') {
                    line_end += 2;
                } else {
                    line_end += 1;
                }
            }
            const line_start: u32 = @intCast(self.source.items.len);
            const line_span = frontend.Span{
                .start = line_start,
                .end = line_start,
                .line = source_line,
                .column = 1,
                .file_id = file_index,
            };
            if (!try self.appendBytes(bytes[offset..line_end], line_span)) return;
            try self.line_origins.append(self.allocator, .{ .file_id = file_index, .line = source_line });
            try self.expandLineIncludes(reader, path, file_index, depth, source_line, line_start, bytes[offset..content_end]);
            offset = line_end;
        }
    }

    fn expandLineIncludes(
        self: *GraphState,
        reader: anytype,
        parent_path: []const u8,
        file_index: u16,
        depth: usize,
        source_line: u32,
        composite_line_start: u32,
        line: []const u8,
    ) Error!void {
        var cursor = commentPayloadStart(line) orelse return;
        while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
        if (cursor >= line.len or line[cursor] != '$') return;

        while (cursor < line.len and line[cursor] == '$' and !self.stopped) {
            const command_start = cursor;
            cursor += 1;
            const name_start = cursor;
            while (cursor < line.len and std.ascii.isAlphabetic(line[cursor])) cursor += 1;
            const is_include = std.ascii.eqlIgnoreCase(line[name_start..cursor], "INCLUDE");
            if (is_include) {
                while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
                if (cursor >= line.len or line[cursor] != ':') return;
                cursor += 1;
                while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
                if (cursor >= line.len or line[cursor] != '\'') return;
                cursor += 1;
                const argument_start = cursor;
                while (cursor < line.len and line[cursor] != '\'') cursor += 1;
                if (cursor >= line.len or cursor == argument_start) return;
                const argument = line[argument_start..cursor];
                cursor += 1;
                const span = frontend.Span{
                    .start = composite_line_start + @as(u32, @intCast(command_start)),
                    .end = composite_line_start + @as(u32, @intCast(cursor)),
                    .line = source_line,
                    .column = @intCast(command_start + 1),
                    .file_id = file_index,
                };
                try self.expandInclude(reader, parent_path, argument, depth, span);
            }
            while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
            if (cursor >= line.len or line[cursor] != '$') return;
        }
    }

    fn expandInclude(
        self: *GraphState,
        reader: anytype,
        parent_path: []const u8,
        argument: []const u8,
        depth: usize,
        span: frontend.Span,
    ) Error!void {
        if (depth + 1 > maximum_include_depth) {
            try self.addDiagnostic(.include_depth_exceeded, span);
            return;
        }
        const resolved = (try resolveRelativePath(self.allocator, parent_path, argument)) orelse {
            try self.addDiagnostic(.invalid_include, span);
            return;
        };
        defer self.allocator.free(resolved);
        const ensured = try self.loadUnique(reader, resolved);
        const include_index = switch (ensured) {
            .index => |value| value,
            .missing, .directory, .read_failure => {
                try self.addDiagnostic(.include_missing, span);
                return;
            },
            .too_large => {
                try self.addDiagnostic(.include_graph_too_large, span);
                return;
            },
            .too_many => {
                try self.addDiagnostic(.include_graph_too_large, span);
                return;
            },
        };
        if (self.isActive(include_index)) {
            try self.addDiagnostic(.include_cycle, span);
            return;
        }
        if (!try self.ensureLineBreak(span)) return;
        try self.expandFile(reader, include_index, depth + 1);
        _ = try self.ensureLineBreak(span);
    }
};

/// Loads a bounded, cycle-checked `$INCLUDE` graph. Every physical source is
/// read once; repeated includes reuse that owned source while preserving BASIC's
/// textual inclusion order in the composite program.
pub fn loadGraph(allocator: std.mem.Allocator, reader: anytype, root_path: []const u8) Error!Graph {
    var state = GraphState{ .allocator = allocator };
    defer state.deinit();

    const normalized_root = (try normalizeGuestPath(allocator, root_path)) orelse return error.ReadFailure;
    defer allocator.free(normalized_root);
    const root = try state.loadUnique(reader, normalized_root);
    const root_index = switch (root) {
        .index => |value| value,
        .missing => return error.Missing,
        .directory => return error.Directory,
        .read_failure => return error.ReadFailure,
        .too_large => return error.TooLarge,
        .too_many => unreachable,
    };
    try state.expandFile(reader, root_index, 0);

    const source = try state.source.toOwnedSlice(allocator);
    errdefer allocator.free(source);
    const origins = try state.line_origins.toOwnedSlice(allocator);
    errdefer allocator.free(origins);
    const diagnostics = try state.diagnostics.toOwnedSlice(allocator);
    errdefer allocator.free(diagnostics);
    const file_names = try allocator.alloc([]u8, state.files.items.len);
    errdefer allocator.free(file_names);
    for (state.files.items, 0..) |*file, index| {
        file_names[index] = file.path;
        file.path = &.{};
        allocator.free(file.bytes);
        file.bytes = &.{};
    }
    return .{
        .source = source,
        .file_names = file_names,
        .line_origins = origins,
        .diagnostics = diagnostics,
        .diagnostics_truncated = state.diagnostics_truncated,
        .stats = state.stats,
    };
}

/// R4Basic's interpreted CHAIN extension applies a requested DELETE range to
/// the fully loaded target graph before compilation. This keeps the switch
/// atomic and gives numbered source lines one unambiguous meaning even when
/// the target uses textual includes.
pub fn deleteNumberedLines(
    allocator: std.mem.Allocator,
    graph: *Graph,
    first: u16,
    last: u16,
) std.mem.Allocator.Error!usize {
    std.debug.assert(first <= last);
    var replacement_source: std.ArrayList(u8) = .empty;
    errdefer replacement_source.deinit(allocator);
    try replacement_source.ensureTotalCapacityPrecise(allocator, graph.source.len);
    var replacement_origins: std.ArrayList(frontend.LineOrigin) = .empty;
    errdefer replacement_origins.deinit(allocator);
    try replacement_origins.ensureTotalCapacityPrecise(allocator, graph.line_origins.len);

    var offset: usize = 0;
    var origin_index: usize = 0;
    var deleted: usize = 0;
    while (offset < graph.source.len) : (origin_index += 1) {
        var content_end = offset;
        while (content_end < graph.source.len and graph.source[content_end] != '\r' and graph.source[content_end] != '\n') content_end += 1;
        var line_end = content_end;
        if (line_end < graph.source.len) {
            if (graph.source[line_end] == '\r' and line_end + 1 < graph.source.len and graph.source[line_end + 1] == '\n') {
                line_end += 2;
            } else {
                line_end += 1;
            }
        }
        const number = numberedLine(graph.source[offset..content_end]);
        const remove = if (number) |value| value >= first and value <= last else false;
        if (remove) {
            deleted += 1;
        } else {
            try replacement_source.appendSlice(allocator, graph.source[offset..line_end]);
            if (origin_index < graph.line_origins.len) try replacement_origins.append(allocator, graph.line_origins[origin_index]);
        }
        offset = line_end;
    }
    while (origin_index < graph.line_origins.len) : (origin_index += 1) {
        try replacement_origins.append(allocator, graph.line_origins[origin_index]);
    }

    const source = try replacement_source.toOwnedSlice(allocator);
    errdefer allocator.free(source);
    const origins = try replacement_origins.toOwnedSlice(allocator);
    allocator.free(graph.source);
    if (graph.line_origins.len != 0) allocator.free(graph.line_origins);
    graph.source = source;
    graph.line_origins = origins;
    return deleted;
}

fn numberedLine(line: []const u8) ?u16 {
    var cursor: usize = 0;
    while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
    const start = cursor;
    var value: u32 = 0;
    while (cursor < line.len and std.ascii.isDigit(line[cursor])) : (cursor += 1) {
        value = value * 10 + line[cursor] - '0';
        if (value > 65_529) return null;
    }
    if (cursor == start) return null;
    return @intCast(value);
}

fn commentPayloadStart(line: []const u8) ?usize {
    var index: usize = 0;
    var statement_start = true;
    var first_segment = true;
    var in_string = false;
    while (index < line.len) {
        const byte = line[index];
        if (in_string) {
            if (byte == '"') in_string = false;
            index += 1;
            continue;
        }
        if (byte == '"') {
            in_string = true;
            statement_start = false;
            index += 1;
            continue;
        }
        if (byte == '\'') return index + 1;
        if (byte == ':') {
            statement_start = true;
            first_segment = false;
            index += 1;
            continue;
        }
        if (statement_start and (byte == ' ' or byte == '\t')) {
            index += 1;
            continue;
        }
        if (statement_start and first_segment and std.ascii.isDigit(byte)) {
            while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
            first_segment = false;
            continue;
        }
        if (statement_start and index + 3 <= line.len and std.ascii.eqlIgnoreCase(line[index .. index + 3], "REM") and
            (index + 3 == line.len or !std.ascii.isAlphanumeric(line[index + 3])))
        {
            return index + 3;
        }
        statement_start = false;
        index += 1;
    }
    return null;
}

fn resolveRelativePath(allocator: std.mem.Allocator, parent_path: []const u8, argument: []const u8) !?[]u8 {
    if (argument.len == 0 or argument.len > maximum_guest_path_bytes) return null;
    if (argument[0] == '\\' or argument[0] == '/' or std.mem.indexOfScalar(u8, argument, ':') != null) return null;
    const separator = lastPathSeparator(parent_path);
    const base_end = if (separator) |index| index + 1 else 0;
    if (base_end + argument.len > maximum_guest_path_bytes) return null;
    const combined = try allocator.alloc(u8, base_end + argument.len);
    defer allocator.free(combined);
    @memcpy(combined[0..base_end], parent_path[0..base_end]);
    @memcpy(combined[base_end..], argument);
    return normalizeGuestPath(allocator, combined);
}

fn normalizeGuestPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0 or path.len > maximum_guest_path_bytes) return null;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var segment_starts: [160]usize = undefined;
    var segment_count: usize = 0;
    var cursor: usize = 0;
    if (path.len >= 2 and path[1] == ':') {
        if (!std.ascii.isAlphabetic(path[0])) return null;
        try output.append(allocator, std.ascii.toUpper(path[0]));
        try output.appendSlice(allocator, ":\\");
        cursor = 2;
        while (cursor < path.len and (path[cursor] == '\\' or path[cursor] == '/')) cursor += 1;
    }
    while (cursor < path.len) {
        while (cursor < path.len and (path[cursor] == '\\' or path[cursor] == '/')) cursor += 1;
        if (cursor == path.len) break;
        const start = cursor;
        while (cursor < path.len and path[cursor] != '\\' and path[cursor] != '/') cursor += 1;
        const segment = path[start..cursor];
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segment_count == 0) return null;
            segment_count -= 1;
            output.items.len = segment_starts[segment_count];
            continue;
        }
        if (segment.len == 0 or segment_count >= segment_starts.len) return null;
        segment_starts[segment_count] = output.items.len;
        segment_count += 1;
        if (output.items.len != 0 and output.items[output.items.len - 1] != '\\') try output.append(allocator, '\\');
        try output.appendSlice(allocator, segment);
    }
    if (output.items.len == 0 or output.items.len > maximum_guest_path_bytes) return null;
    return try output.toOwnedSlice(allocator);
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index != 0) {
        index -= 1;
        if (path[index] == '\\' or path[index] == '/') return index;
    }
    return null;
}
