const std = @import("std");

pub const columns: usize = 80;
pub const rows: usize = 25;
pub const print_zone_columns: usize = 14;

pub const Error = error{IllegalFunctionCall};

pub const Cell = struct {
    character: u8 = ' ',
    foreground: u8 = 7,
    background: u8 = 0,
};

pub const Screen = struct {
    cells: [columns * rows]Cell = [_]Cell{.{}} ** (columns * rows),
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

    pub fn reset(self: *Screen) void {
        self.* = .{};
    }

    pub fn setWidth(self: *Screen, requested_columns: i32, requested_rows: ?i32) Error!void {
        _ = self;
        if (requested_columns != columns) return error.IllegalFunctionCall;
        if (requested_rows) |value| if (value != rows) return error.IllegalFunctionCall;
    }

    pub fn setColor(self: *Screen, requested_foreground: ?i32, requested_background: ?i32) Error!void {
        if (requested_foreground) |value| if (value < 0 or value > 31) return error.IllegalFunctionCall;
        if (requested_background) |value| if (value < 0 or value > 7) return error.IllegalFunctionCall;
        if (requested_foreground) |value| self.foreground = @intCast(value);
        if (requested_background) |value| self.background = @intCast(value);
        self.revision +%= 1;
    }

    pub fn clear(self: *Screen, requested_mode: ?i32) Error!void {
        const mode = requested_mode orelse 0;
        if (mode < 0 or mode > 2) return error.IllegalFunctionCall;
        const first = if (mode == 2) self.view_top else 0;
        const last = if (mode == 2) self.view_bottom else rows - 1;
        var row = first;
        while (row <= last) : (row += 1) self.clearRow(row);
        self.cursor_row = first;
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
        if (requested_row) |value| if (value < 1 or value > rows) return error.IllegalFunctionCall;
        if (requested_column) |value| if (value < 1 or value > columns) return error.IllegalFunctionCall;
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
            self.view_bottom = rows - 1;
            self.revision +%= 1;
            return;
        }
        const top = requested_top orelse return error.IllegalFunctionCall;
        const bottom = requested_bottom orelse return error.IllegalFunctionCall;
        if (top < 1 or bottom < top or bottom > rows) return error.IllegalFunctionCall;
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
                if (self.cursor_column >= columns) self.newLine();
                const index = self.cursor_row * columns + self.cursor_column;
                self.cells[index] = .{
                    .character = byte,
                    .foreground = self.foreground,
                    .background = self.background,
                };
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
        if (next >= columns) {
            self.newLine();
        } else {
            self.cursor_column = next;
            self.revision +%= 1;
        }
    }

    pub fn printTab(self: *Screen, requested_column: i32) Error!void {
        if (requested_column < 1 or requested_column > 255) return error.IllegalFunctionCall;
        const target: usize = @intCast(@mod(requested_column - 1, @as(i32, columns)));
        if (target < self.cursor_column) self.newLine();
        self.cursor_column = target;
        self.revision +%= 1;
    }

    pub fn erasePrevious(self: *Screen) void {
        if (self.cursor_column == 0) return;
        self.cursor_column -= 1;
        const index = self.cursor_row * columns + self.cursor_column;
        self.cells[index] = .{
            .character = ' ',
            .foreground = self.foreground,
            .background = self.background,
        };
        self.revision +%= 1;
    }

    pub fn cell(self: *const Screen, row: usize, column: usize) ?Cell {
        if (row >= rows or column >= columns) return null;
        return self.cells[row * columns + column];
    }

    pub fn copyRow(self: *const Screen, row: usize, out: *[columns]u8) bool {
        if (row >= rows) return false;
        for (0..columns) |column| out[column] = self.cells[row * columns + column].character;
        return true;
    }

    fn clearRow(self: *Screen, row: usize) void {
        const first = row * columns;
        for (self.cells[first .. first + columns]) |*cell_value| {
            cell_value.* = .{
                .character = ' ',
                .foreground = self.foreground,
                .background = self.background,
            };
        }
    }

    fn scrollView(self: *Screen) void {
        if (self.view_top < self.view_bottom) {
            var row = self.view_top;
            while (row < self.view_bottom) : (row += 1) {
                const target = row * columns;
                const source = (row + 1) * columns;
                std.mem.copyForwards(Cell, self.cells[target .. target + columns], self.cells[source .. source + columns]);
            }
        }
        self.clearRow(self.view_bottom);
        self.cursor_row = self.view_bottom;
        self.revision +%= 1;
    }
};

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
