const std = @import("std");

pub const columns: usize = 80;
pub const rows: usize = 25;
pub const maximum_rows: usize = 60;
pub const maximum_pages: usize = 8;
pub const print_zone_columns: usize = 14;

pub const Error = error{ IllegalFunctionCall, OutOfMemory };

pub const CellRect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

pub const max_dirty_regions: usize = 8;

pub const CellDamage = struct {
    regions: [max_dirty_regions]CellRect = .{CellRect{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** max_dirty_regions,
    count: usize = 0,

    fn full(width: usize, height: usize) CellDamage {
        var result = CellDamage{};
        result.regions[0] = .{ .x = 0, .y = 0, .w = width, .h = height };
        result.count = @intFromBool(width != 0 and height != 0);
        return result;
    }

    pub fn slice(self: *const CellDamage) []const CellRect {
        return self.regions[0..self.count];
    }

    fn note(self: *CellDamage, value: CellRect) void {
        if (value.w == 0 or value.h == 0) return;
        var merged = value;
        var index: usize = 0;
        while (index < self.count) {
            if (!cellRectsTouchOrOverlap(self.regions[index], merged)) {
                index += 1;
                continue;
            }
            merged = mergeCellRect(self.regions[index], merged);
            self.count -= 1;
            self.regions[index] = self.regions[self.count];
        }
        if (self.count < self.regions.len) {
            self.regions[self.count] = merged;
            self.count += 1;
            return;
        }
        var best_index: usize = 0;
        var best_growth: usize = std.math.maxInt(usize);
        for (self.regions[0..self.count], 0..) |existing, candidate| {
            const combined = mergeCellRect(existing, merged);
            const growth = combined.w * combined.h - existing.w * existing.h;
            if (growth < best_growth) {
                best_growth = growth;
                best_index = candidate;
            }
        }
        self.regions[best_index] = mergeCellRect(self.regions[best_index], merged);
    }
};

pub const Cell = struct {
    character: u8 = ' ',
    foreground: u8 = 7,
    background: u8 = 0,
};

const PageState = struct {
    cursor_row: usize = 0,
    cursor_column: usize = 0,
    cursor_visible: bool = true,
    cursor_start: u8 = 6,
    cursor_stop: u8 = 7,
    foreground: u8 = 7,
    background: u8 = 0,
    view_top: usize = 0,
    view_bottom: usize = rows - 1,
    revision: u64 = 1,
    dirty: bool = true,
};

pub const Screen = struct {
    cells: [columns * rows]Cell = [_]Cell{.{}} ** (columns * rows),
    extended_cells: ?[]Cell = null,
    active_columns: usize = columns,
    active_rows: usize = rows,
    page_count: usize = 1,
    active_page: usize = 0,
    visible_page: usize = 0,
    cursor_row: usize = 0,
    cursor_column: usize = 0,
    cursor_visible: bool = true,
    cursor_start: u8 = 6,
    cursor_stop: u8 = 7,
    foreground: u8 = 7,
    background: u8 = 0,
    view_top: usize = 0,
    view_bottom: usize = rows - 1,
    revision: u64 = 1,
    dirty: CellDamage = CellDamage.full(columns, rows),
    saved_pages: [maximum_pages]PageState = [_]PageState{.{}} ** maximum_pages,

    pub fn deinit(self: *Screen, allocator: std.mem.Allocator) void {
        if (self.extended_cells) |storage| allocator.free(storage);
        self.* = undefined;
    }

    pub fn reset(self: *Screen) void {
        std.debug.assert(self.extended_cells == null);
        self.* = .{};
    }

    pub fn resetAllocated(self: *Screen, allocator: std.mem.Allocator) void {
        if (self.extended_cells) |storage| allocator.free(storage);
        self.* = .{};
    }

    pub fn configure(self: *Screen, requested_columns: usize) Error!void {
        if (requested_columns != 40 and requested_columns != columns) return error.IllegalFunctionCall;
        if (self.extended_cells != null) return error.IllegalFunctionCall;
        self.* = .{
            .active_columns = requested_columns,
            .dirty = CellDamage.full(requested_columns, rows),
        };
    }

    pub fn configureMode(
        self: *Screen,
        allocator: std.mem.Allocator,
        requested_columns: usize,
        requested_rows: usize,
        requested_page_count: usize,
        requested_active_page: usize,
        requested_visible_page: usize,
    ) Error!void {
        if ((requested_columns != 40 and requested_columns != columns) or requested_rows == 0 or
            requested_rows > maximum_rows or requested_page_count == 0 or requested_page_count > maximum_pages or
            requested_active_page >= requested_page_count or requested_visible_page >= requested_page_count)
        {
            return error.IllegalFunctionCall;
        }
        const needs_extended = requested_page_count != 1 or requested_rows > rows;
        const cell_count = std.math.mul(usize, columns * requested_rows, requested_page_count) catch
            return error.OutOfMemory;
        const replacement = if (needs_extended) try allocator.alloc(Cell, cell_count) else null;
        if (replacement) |storage| @memset(storage, .{});
        if (self.extended_cells) |storage| allocator.free(storage);
        self.* = .{
            .extended_cells = replacement,
            .active_columns = requested_columns,
            .active_rows = requested_rows,
            .page_count = requested_page_count,
            .active_page = requested_active_page,
            .visible_page = requested_visible_page,
            .view_bottom = requested_rows - 1,
            .dirty = CellDamage.full(requested_columns, requested_rows),
        };
        for (self.saved_pages[0..requested_page_count]) |*page| {
            page.view_bottom = requested_rows - 1;
            page.dirty = true;
        }
    }

    pub fn ensurePages(self: *Screen, allocator: std.mem.Allocator, requested_page_count: usize) Error!void {
        if (requested_page_count == self.page_count) return;
        if (requested_page_count < self.page_count or requested_page_count > maximum_pages or
            self.active_page != 0 or self.visible_page != 0)
        {
            return error.IllegalFunctionCall;
        }
        const stride = columns * self.active_rows;
        const cell_count = std.math.mul(usize, stride, requested_page_count) catch return error.OutOfMemory;
        const replacement = try allocator.alloc(Cell, cell_count);
        errdefer allocator.free(replacement);
        @memset(replacement, .{});
        const current = self.activeCellsConst() orelse return error.IllegalFunctionCall;
        @memcpy(replacement[0..stride], current);
        if (self.extended_cells) |storage| allocator.free(storage);
        self.extended_cells = replacement;
        self.page_count = requested_page_count;
        for (self.saved_pages[1..requested_page_count]) |*page| {
            page.view_bottom = self.active_rows - 1;
            page.dirty = true;
        }
    }

    pub fn selectPages(self: *Screen, requested_active_page: usize, requested_visible_page: usize) Error!void {
        if (requested_active_page >= self.page_count or requested_visible_page >= self.page_count) {
            return error.IllegalFunctionCall;
        }
        self.saveActivePage();
        if (requested_active_page != self.active_page) {
            self.active_page = requested_active_page;
            self.loadActivePage();
        }
        self.visible_page = requested_visible_page;
    }

    pub fn copyPage(self: *Screen, source: usize, destination: usize) Error!void {
        if (source >= self.page_count or destination >= self.page_count) return error.IllegalFunctionCall;
        if (source == destination) return;
        self.saveActivePage();
        const source_cells = self.pageCellsConst(source) orelse return error.IllegalFunctionCall;
        const destination_cells = self.pageCells(destination) orelse return error.IllegalFunctionCall;
        @memcpy(destination_cells, source_cells);
        self.saved_pages[destination] = self.saved_pages[source];
        self.saved_pages[destination].revision +%= 1;
        self.saved_pages[destination].dirty = false;
        if (destination == self.active_page) self.loadActivePage();
    }

    pub fn setWidth(self: *Screen, requested_columns: i32, requested_rows: ?i32) Error!void {
        if (requested_columns != self.active_columns) return error.IllegalFunctionCall;
        if (requested_rows) |value| if (value != self.active_rows) return error.IllegalFunctionCall;
    }

    pub fn setColor(self: *Screen, requested_foreground: ?i32, requested_background: ?i32) Error!void {
        return self.setColorRange(requested_foreground, requested_background, 31, 7);
    }

    pub fn setColorRange(
        self: *Screen,
        requested_foreground: ?i32,
        requested_background: ?i32,
        maximum_foreground: i32,
        maximum_background: i32,
    ) Error!void {
        if (requested_foreground) |value| if (value < 0 or value > maximum_foreground) return error.IllegalFunctionCall;
        if (requested_background) |value| if (value < 0 or value > maximum_background) return error.IllegalFunctionCall;
        if (requested_foreground) |value| self.foreground = @intCast(value);
        if (requested_background) |value| self.background = @intCast(value);
        self.revision +%= 1;
    }

    pub fn clear(self: *Screen, requested_mode: ?i32) Error!void {
        const mode = requested_mode orelse 0;
        if (mode < 0 or mode > 2) return error.IllegalFunctionCall;
        const first = if (mode == 2) self.view_top else 0;
        const last = if (mode == 2)
            @min(self.view_bottom, self.active_rows -| 2)
        else
            self.active_rows - 1;
        if (first <= last) {
            var row = first;
            while (row <= last) : (row += 1) self.clearRow(row);
            self.markDirty(.{ .x = 0, .y = first, .w = self.active_columns, .h = last - first + 1 });
        }
        self.cursor_row = first;
        self.cursor_column = 0;
        self.revision +%= 1;
    }

    pub fn homeCursor(self: *Screen) void {
        self.cursor_row = self.view_top;
        self.cursor_column = 0;
        self.revision +%= 1;
    }

    pub fn locate(
        self: *Screen,
        requested_row: ?i32,
        requested_column: ?i32,
        requested_cursor: ?i32,
        requested_start: ?i32,
        requested_stop: ?i32,
    ) Error!void {
        if (requested_row) |value| if (value < 1 or value > self.active_rows) return error.IllegalFunctionCall;
        if (requested_column) |value| if (value < 1 or value > self.active_columns) return error.IllegalFunctionCall;
        if (requested_cursor) |value| if (value != 0 and value != 1) return error.IllegalFunctionCall;
        if (requested_stop != null and requested_start == null) return error.IllegalFunctionCall;
        if (requested_start) |value| if (value < 0 or value > 31) return error.IllegalFunctionCall;
        if (requested_stop) |value| if (value < 0 or value > 31) return error.IllegalFunctionCall;

        if (requested_row) |value| self.cursor_row = @intCast(value - 1);
        if (requested_column) |value| self.cursor_column = @intCast(value - 1);
        if (requested_cursor) |value| self.cursor_visible = value != 0;
        if (requested_start) |value| {
            self.cursor_start = @intCast(value);
            self.cursor_stop = @intCast(requested_stop orelse value);
        }
        if (requested_stop) |value| self.cursor_stop = @intCast(value);
        self.revision +%= 1;
    }

    pub fn setView(self: *Screen, requested_top: ?i32, requested_bottom: ?i32) Error!void {
        if (requested_top == null and requested_bottom == null) {
            self.view_top = 0;
            self.view_bottom = self.active_rows - 1;
            self.revision +%= 1;
            return;
        }
        const top = requested_top orelse return error.IllegalFunctionCall;
        const bottom = requested_bottom orelse return error.IllegalFunctionCall;
        if (top < 1 or bottom < top or bottom > self.active_rows) return error.IllegalFunctionCall;
        self.view_top = @intCast(top - 1);
        self.view_bottom = @intCast(bottom - 1);
        if (self.cursor_row < self.view_top or self.cursor_row > self.view_bottom) {
            self.cursor_row = self.view_top;
            self.cursor_column = 0;
        }
        self.revision +%= 1;
    }

    pub fn write(self: *Screen, bytes: []const u8) void {
        for (bytes) |byte| self.writeByte(byte);
    }

    pub fn writeByte(self: *Screen, byte: u8) void {
        switch (byte) {
            '\r' => {
                self.cursor_column = 0;
                self.revision +%= 1;
            },
            '\n' => self.newLine(),
            8 => self.erasePrevious(),
            0...7, 9, 11, 12, 14...31, 127 => {},
            else => {
                if (self.cursor_column >= self.active_columns) self.newLine();
                const index = self.cursor_row * columns + self.cursor_column;
                const active_cells = self.activeCells() orelse return;
                active_cells[index] = .{
                    .character = byte,
                    .foreground = self.foreground,
                    .background = self.background,
                };
                self.markDirty(.{ .x = self.cursor_column, .y = self.cursor_row, .w = 1, .h = 1 });
                self.cursor_column += 1;
                self.revision +%= 1;
            },
        }
    }

    pub fn newLine(self: *Screen) void {
        self.cursor_column = 0;
        if (self.cursor_row < self.view_top or self.cursor_row > self.view_bottom) {
            self.cursor_row = self.view_top;
            self.revision +%= 1;
            return;
        }
        if (self.cursor_row < self.view_bottom) {
            self.cursor_row += 1;
            self.revision +%= 1;
            return;
        }
        self.scrollView();
    }

    pub fn printComma(self: *Screen) void {
        const next = (self.cursor_column / print_zone_columns + 1) * print_zone_columns;
        if (next >= self.active_columns) {
            self.newLine();
        } else {
            self.cursor_column = next;
            self.revision +%= 1;
        }
    }

    pub fn printTab(self: *Screen, requested_column: i32) Error!void {
        if (requested_column < 1 or requested_column > 255) return error.IllegalFunctionCall;
        const target: usize = @intCast(@mod(requested_column - 1, @as(i32, @intCast(self.active_columns))));
        if (target < self.cursor_column) self.newLine();
        self.cursor_column = target;
        self.revision +%= 1;
    }

    pub fn erasePrevious(self: *Screen) void {
        if (self.cursor_column == 0) return;
        self.cursor_column -= 1;
        const index = self.cursor_row * columns + self.cursor_column;
        const active_cells = self.activeCells() orelse return;
        active_cells[index] = .{
            .character = ' ',
            .foreground = self.foreground,
            .background = self.background,
        };
        self.markDirty(.{ .x = self.cursor_column, .y = self.cursor_row, .w = 1, .h = 1 });
        self.revision +%= 1;
    }

    pub fn takeDirty(self: *Screen) CellDamage {
        const result = self.dirty;
        self.dirty = .{};
        return result;
    }

    pub fn takeDirtyPage(self: *Screen, page_index: usize) CellDamage {
        if (page_index >= self.page_count) return .{};
        if (page_index == self.active_page) return self.takeDirty();
        if (!self.saved_pages[page_index].dirty) return .{};
        self.saved_pages[page_index].dirty = false;
        return CellDamage.full(self.active_columns, self.active_rows);
    }

    pub fn cell(self: *const Screen, row: usize, column: usize) ?Cell {
        if (row >= self.active_rows or column >= self.active_columns) return null;
        const active_cells = self.activeCellsConst() orelse return null;
        return active_cells[row * columns + column];
    }

    pub fn cellOnPage(self: *const Screen, page_index: usize, row: usize, column: usize) ?Cell {
        if (page_index >= self.page_count or row >= self.active_rows or column >= self.active_columns) return null;
        const page_cells = self.pageCellsConst(page_index) orelse return null;
        return page_cells[row * columns + column];
    }

    pub fn cursorRow(self: *const Screen) i16 {
        return @intCast(self.cursor_row + 1);
    }

    pub fn cursorColumn(self: *const Screen) i16 {
        return @intCast(self.cursor_column + 1);
    }

    pub fn columnCount(self: *const Screen) usize {
        return self.active_columns;
    }

    pub fn rowCount(self: *const Screen) usize {
        return self.active_rows;
    }

    /// Replaces the visible function-key legend without moving the BASIC
    /// cursor or changing the configured print viewport.
    pub fn writeBottomLine(self: *Screen, bytes: []const u8) void {
        const row = self.active_rows - 1;
        const first = row * columns;
        const active_cells = self.activeCells() orelse return;
        for (active_cells[first .. first + self.active_columns], 0..) |*cell_value, column| {
            cell_value.* = .{
                .character = if (column < bytes.len) bytes[column] else ' ',
                .foreground = self.foreground,
                .background = self.background,
            };
        }
        self.markDirty(.{ .x = 0, .y = row, .w = self.active_columns, .h = 1 });
        self.revision +%= 1;
    }

    pub fn screenValue(self: *const Screen, requested_row: i32, requested_column: i32, color: bool) Error!i16 {
        if (requested_row < 1 or requested_row > self.active_rows or requested_column < 1 or requested_column > self.active_columns) {
            return error.IllegalFunctionCall;
        }
        const active_cells = self.activeCellsConst() orelse return error.IllegalFunctionCall;
        const value = active_cells[@as(usize, @intCast(requested_row - 1)) * columns + @as(usize, @intCast(requested_column - 1))];
        return if (color)
            @as(i16, value.foreground & 0x0f) | (@as(i16, value.background) << 4)
        else
            value.character;
    }

    pub fn copyRow(self: *const Screen, row: usize, out: *[columns]u8) bool {
        if (row >= self.active_rows) return false;
        const active_cells = self.activeCellsConst() orelse return false;
        for (0..columns) |column| out[column] = active_cells[row * columns + column].character;
        return true;
    }

    fn clearRow(self: *Screen, row: usize) void {
        const first = row * columns;
        const active_cells = self.activeCells() orelse return;
        for (active_cells[first .. first + self.active_columns]) |*cell_value| {
            cell_value.* = .{
                .character = ' ',
                .foreground = self.foreground,
                .background = self.background,
            };
        }
    }

    fn scrollView(self: *Screen) void {
        if (self.view_top < self.view_bottom) {
            const active_cells = self.activeCells() orelse return;
            var row = self.view_top;
            while (row < self.view_bottom) : (row += 1) {
                const target = row * columns;
                const source = (row + 1) * columns;
                std.mem.copyForwards(Cell, active_cells[target .. target + self.active_columns], active_cells[source .. source + self.active_columns]);
            }
        }
        self.clearRow(self.view_bottom);
        self.markDirty(.{ .x = 0, .y = self.view_top, .w = self.active_columns, .h = self.view_bottom - self.view_top + 1 });
        self.cursor_row = self.view_bottom;
        self.revision +%= 1;
    }

    fn markDirty(self: *Screen, value: CellRect) void {
        self.dirty.note(value);
    }

    fn pageCells(self: *Screen, page_index: usize) ?[]Cell {
        if (page_index >= self.page_count) return null;
        const stride = columns * self.active_rows;
        if (self.extended_cells) |storage| {
            const first = page_index * stride;
            return storage[first .. first + stride];
        }
        if (page_index != 0 or self.active_rows > rows) return null;
        return self.cells[0..stride];
    }

    fn pageCellsConst(self: *const Screen, page_index: usize) ?[]const Cell {
        if (page_index >= self.page_count) return null;
        const stride = columns * self.active_rows;
        if (self.extended_cells) |storage| {
            const first = page_index * stride;
            return storage[first .. first + stride];
        }
        if (page_index != 0 or self.active_rows > rows) return null;
        return self.cells[0..stride];
    }

    fn activeCells(self: *Screen) ?[]Cell {
        return self.pageCells(self.active_page);
    }

    fn activeCellsConst(self: *const Screen) ?[]const Cell {
        return self.pageCellsConst(self.active_page);
    }

    fn saveActivePage(self: *Screen) void {
        self.saved_pages[self.active_page] = .{
            .cursor_row = self.cursor_row,
            .cursor_column = self.cursor_column,
            .cursor_visible = self.cursor_visible,
            .cursor_start = self.cursor_start,
            .cursor_stop = self.cursor_stop,
            .foreground = self.foreground,
            .background = self.background,
            .view_top = self.view_top,
            .view_bottom = self.view_bottom,
            .revision = self.revision,
            .dirty = self.dirty.count != 0,
        };
    }

    fn loadActivePage(self: *Screen) void {
        var page = &self.saved_pages[self.active_page];
        self.cursor_row = page.cursor_row;
        self.cursor_column = page.cursor_column;
        self.cursor_visible = page.cursor_visible;
        self.cursor_start = page.cursor_start;
        self.cursor_stop = page.cursor_stop;
        self.foreground = page.foreground;
        self.background = page.background;
        self.view_top = page.view_top;
        self.view_bottom = page.view_bottom;
        self.revision = page.revision;
        self.dirty = if (page.dirty) CellDamage.full(self.active_columns, self.active_rows) else .{};
        page.dirty = false;
    }
};

fn mergeCellRect(a: CellRect, b: CellRect) CellRect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    const right = @max(a.x + a.w, b.x + b.w);
    const bottom = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
}

fn cellRectsTouchOrOverlap(a: CellRect, b: CellRect) bool {
    return a.x <= b.x + b.w and b.x <= a.x + a.w and
        a.y <= b.y + b.h and b.y <= a.y + a.h;
}

test "text screen scrolls only its active viewport" {
    var screen = Screen{};
    try screen.setView(2, 3);
    screen.cursor_row = 1;
    screen.write("first");
    screen.newLine();
    screen.write("second");
    screen.newLine();
    var line: [columns]u8 = undefined;
    try std.testing.expect(screen.copyRow(1, &line));
    try std.testing.expectEqualStrings("second", std.mem.trimRight(u8, &line, " "));
    try std.testing.expectEqual(@as(u8, ' '), screen.cell(0, 0).?.character);
}

test "invalid color and cursor updates are atomic" {
    var screen = Screen{};
    const original_revision = screen.revision;
    try std.testing.expectError(error.IllegalFunctionCall, screen.setColor(12, 9));
    try std.testing.expectEqual(@as(u8, 7), screen.foreground);
    try std.testing.expectEqual(@as(u8, 0), screen.background);
    try std.testing.expectEqual(original_revision, screen.revision);

    try std.testing.expectError(error.IllegalFunctionCall, screen.locate(5, 81, 0, null, null));
    try std.testing.expectEqual(@as(usize, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), screen.cursor_column);
    try std.testing.expect(screen.cursor_visible);
    try std.testing.expectEqual(original_revision, screen.revision);
}

test "CLS 2 clears the text viewport but preserves the physical bottom line" {
    var screen = Screen{};
    try screen.locate(24, 1, null, null, null);
    screen.write("body");
    try screen.locate(25, 1, null, null, null);
    screen.write("footer");
    try screen.clear(2);
    try std.testing.expectEqual(@as(u8, ' '), screen.cell(23, 0).?.character);
    try std.testing.expectEqual(@as(u8, 'f'), screen.cell(24, 0).?.character);
    try std.testing.expectEqual(@as(usize, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), screen.cursor_column);
}

test "40-column graphics text mode reports bounded dirty cells" {
    var screen = Screen{};
    _ = screen.takeDirty();
    try screen.configure(40);
    const configured = screen.takeDirty();
    try std.testing.expectEqual(@as(usize, 1), configured.count);
    try std.testing.expectEqual(CellRect{ .x = 0, .y = 0, .w = 40, .h = rows }, configured.regions[0]);
    try screen.setWidth(40, rows);
    try std.testing.expectError(error.IllegalFunctionCall, screen.setWidth(80, rows));

    try screen.locate(1, 40, null, null, null);
    screen.write("X");
    const changed = screen.takeDirty();
    try std.testing.expectEqual(@as(usize, 1), changed.count);
    try std.testing.expectEqual(CellRect{ .x = 39, .y = 0, .w = 1, .h = 1 }, changed.regions[0]);
    try std.testing.expectEqual(@as(u8, 'X'), screen.cell(0, 39).?.character);
}

test "sparse text writes remain separate dirty cell regions" {
    var screen = Screen{};
    _ = screen.takeDirty();
    try screen.locate(1, 1, null, null, null);
    screen.write("A");
    try screen.locate(25, 80, null, null, null);
    screen.write("Z");
    const dirty = screen.takeDirty();
    try std.testing.expectEqual(@as(usize, 2), dirty.count);
}

test "text pages allocate on demand and preserve isolated cells and copies" {
    var screen: Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.configureMode(std.testing.allocator, 40, 25, 8, 0, 0);
    try std.testing.expect(screen.extended_cells != null);
    screen.write("A");
    try screen.selectPages(1, 0);
    screen.write("B");
    try std.testing.expectEqual(@as(u8, 'A'), screen.cellOnPage(0, 0, 0).?.character);
    try std.testing.expectEqual(@as(u8, 'B'), screen.cellOnPage(1, 0, 0).?.character);
    try screen.copyPage(1, 2);
    try std.testing.expectEqual(@as(u8, 'B'), screen.cellOnPage(2, 0, 0).?.character);
    try screen.selectPages(2, 2);
    try std.testing.expectEqual(@as(u8, 'B'), screen.cell(0, 0).?.character);
}
