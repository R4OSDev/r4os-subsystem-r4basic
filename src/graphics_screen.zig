const std = @import("std");
const basic_font = @import("basic_font.zig");
const bytecode = @import("bytecode.zig");
const text_screen = @import("text_screen.zig");

pub const Error = error{
    OutOfMemory,
    IllegalFunctionCall,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const View = struct {
    pixels: []u8,
    palette: []u32,
    width: u32,
    height: u32,
    mode_revision: u64,
    content_revision: u64,
};

const mode_1_width: u32 = 320;
const mode_1_height: u32 = 200;
const mode_9_width: u32 = 640;
const mode_9_height: u32 = 350;
const mode_0_width: u32 = 640;
const mode_0_height: u32 = 400;
const text_columns_mode_1: usize = 40;
const text_columns_mode_9: usize = 80;
const text_rows: usize = 25;
const text_cell_width: usize = 8;
const text_cell_height_mode_1: usize = 8;
const text_cell_height_mode_9: usize = 14;
const text_cell_height_mode_0: usize = 16;
const image_header_bytes: usize = 4;
const maximum_circle_segments: usize = 16_384;

const ega_16_codes = [_]u8{ 0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63 };
const screen_1_defaults = [_]u8{ 0, 11, 13, 15 };

pub const Screen = struct {
    pixels: ?[]u8 = null,
    palette: [256]u32 = [_]u32{0} ** 256,
    width: u32 = 0,
    height: u32 = 0,
    mode: i32 = 0,
    current: Point = .{ .x = 0, .y = 0 },
    mode_revision: u64 = 1,
    content_revision: u64 = 1,
    damage: ?Rect = null,

    pub fn deinit(self: *Screen, allocator: std.mem.Allocator) void {
        if (self.pixels) |pixels| allocator.free(pixels);
        self.* = .{};
    }

    pub fn reset(self: *Screen, allocator: std.mem.Allocator) void {
        if (self.pixels) |pixels| allocator.free(pixels);
        const next_mode_revision = self.mode_revision +% 1;
        const next_content_revision = self.content_revision +% 1;
        self.* = .{
            .mode_revision = next_mode_revision,
            .content_revision = next_content_revision,
        };
    }

    pub fn setMode(self: *Screen, allocator: std.mem.Allocator, mode: i32) Error!void {
        const width: u32 = switch (mode) {
            0 => mode_0_width,
            1 => mode_1_width,
            9 => mode_9_width,
            else => return error.IllegalFunctionCall,
        };
        const height: u32 = switch (mode) {
            0 => mode_0_height,
            1 => mode_1_height,
            9 => mode_9_height,
            else => unreachable,
        };
        const count = std.math.mul(usize, width, height) catch return error.OutOfMemory;
        const replacement = try allocator.alloc(u8, count);
        @memset(replacement, 0);

        if (self.pixels) |pixels| allocator.free(pixels);
        self.pixels = replacement;
        self.width = width;
        self.height = height;
        self.mode = mode;
        self.current = .{ .x = 0, .y = 0 };
        self.resetPalette();
        self.damage = .{ .x = 0, .y = 0, .w = width, .h = height };
        self.mode_revision +%= 1;
        self.content_revision +%= 1;
    }

    pub fn view(self: *Screen) ?View {
        const pixels = self.pixels orelse return null;
        return .{
            .pixels = pixels,
            .palette = self.palette[0..],
            .width = self.width,
            .height = self.height,
            .mode_revision = self.mode_revision,
            .content_revision = self.content_revision,
        };
    }

    pub fn takeDamage(self: *Screen) ?Rect {
        const result = self.damage;
        self.damage = null;
        return result;
    }

    pub fn maximumAttribute(self: *const Screen) u8 {
        return if (self.mode == 1) 3 else if (self.mode == 0 or self.mode == 9) 15 else 0;
    }

    pub fn setPalette(self: *Screen, requested_attribute: i32, display_color: i32) Error!void {
        if (self.mode == 0) return error.IllegalFunctionCall;
        if (requested_attribute < 0 or requested_attribute > self.maximumAttribute()) return error.IllegalFunctionCall;
        const hardware_code: u8 = switch (self.mode) {
            1 => if (display_color >= 0 and display_color < ega_16_codes.len)
                ega_16_codes[@intCast(display_color)]
            else
                return error.IllegalFunctionCall,
            9 => if (display_color >= 0 and display_color <= 63)
                @intCast(display_color)
            else
                return error.IllegalFunctionCall,
            else => return error.IllegalFunctionCall,
        };
        const index: usize = @intCast(requested_attribute);
        const rgb = egaRgb(hardware_code);
        if (self.palette[index] == rgb) return;
        self.palette[index] = rgb;
        self.markFull();
    }

    pub fn clear(self: *Screen, requested_attribute: i32) Error!void {
        const color = try self.attribute(requested_attribute);
        const pixels = self.pixels orelse return error.IllegalFunctionCall;
        for (pixels) |existing| if (existing != color) {
            @memset(pixels, color);
            self.markFull();
            return;
        };
    }

    pub fn resolvePoint(self: *const Screen, x: i32, y: i32, relative: bool) Point {
        if (!relative) return .{ .x = x, .y = y };
        return .{
            .x = saturatingAdd(self.current.x, x),
            .y = saturatingAdd(self.current.y, y),
        };
    }

    pub fn pset(self: *Screen, target: Point, requested_color: i32) Error!void {
        const color = try self.attribute(requested_color);
        self.current = target;
        self.setPixel(target.x, target.y, color);
    }

    pub fn point(self: *const Screen, point_value: Point) Error!i32 {
        if (self.mode == 0) return error.IllegalFunctionCall;
        const pixels = self.pixels orelse return error.IllegalFunctionCall;
        if (!self.contains(point_value.x, point_value.y)) return -1;
        return pixels[self.pixelIndex(point_value.x, point_value.y)];
    }

    pub fn line(
        self: *Screen,
        first: Point,
        second: Point,
        requested_color: i32,
        box_mode: bytecode.GraphicsBoxMode,
    ) Error!void {
        const color = try self.attribute(requested_color);
        self.current = second;
        switch (box_mode) {
            .line => self.drawLine(first, second, color),
            .box => {
                self.drawLine(first, .{ .x = second.x, .y = first.y }, color);
                self.drawLine(.{ .x = second.x, .y = first.y }, second, color);
                self.drawLine(second, .{ .x = first.x, .y = second.y }, color);
                self.drawLine(.{ .x = first.x, .y = second.y }, first, color);
            },
            .filled_box => self.fillBox(first, second, color),
        }
    }

    pub fn circle(
        self: *Screen,
        center: Point,
        radius: f64,
        requested_color: i32,
        requested_start: ?f64,
        requested_end: ?f64,
        requested_aspect: ?f64,
    ) Error!void {
        if (self.pixels == null or !std.math.isFinite(radius) or radius < 0) return error.IllegalFunctionCall;
        const color = try self.attribute(requested_color);
        const aspect_raw = requested_aspect orelse defaultAspect(self.mode);
        if (!std.math.isFinite(aspect_raw) or aspect_raw == 0) return error.IllegalFunctionCall;
        const aspect = @abs(aspect_raw);
        const radius_x = if (aspect < 1) radius else radius / aspect;
        const radius_y = if (aspect < 1) radius * aspect else radius;
        if (!std.math.isFinite(radius_x) or !std.math.isFinite(radius_y)) return error.IllegalFunctionCall;

        const tau = 2.0 * std.math.pi;
        const radial_start = if (requested_start) |value| value < 0 else false;
        const radial_end = if (requested_end) |value| value < 0 else false;
        const start = @abs(requested_start orelse 0);
        var end = @abs(requested_end orelse tau);
        if (!std.math.isFinite(start) or !std.math.isFinite(end) or start > tau or end > tau) {
            return error.IllegalFunctionCall;
        }
        const full_circle = requested_start == null and requested_end == null;
        if (!full_circle and end <= start) end += tau;
        const sweep = if (full_circle) tau else end - start;
        const circumference_hint = @max(radius_x, radius_y) * sweep;
        const segment_float = @ceil(@max(16.0, circumference_hint * 2.0));
        const segments: usize = @intFromFloat(@min(@as(f64, @floatFromInt(maximum_circle_segments)), segment_float));

        var previous = ellipsePoint(center, radius_x, radius_y, start);
        if (radial_start) self.drawLine(center, previous, color);
        var step: usize = 1;
        while (step <= segments) : (step += 1) {
            const ratio = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(segments));
            const next = ellipsePoint(center, radius_x, radius_y, start + sweep * ratio);
            self.drawLine(previous, next, color);
            previous = next;
        }
        if (radial_end) self.drawLine(center, previous, color);
    }

    pub fn paint(
        self: *Screen,
        allocator: std.mem.Allocator,
        start: Point,
        requested_fill: i32,
        requested_border: i32,
    ) Error!void {
        const fill_color = try self.attribute(requested_fill);
        const border_color = try self.attribute(requested_border);
        const pixels = self.pixels orelse return error.IllegalFunctionCall;
        if (!self.contains(start.x, start.y)) return;
        const initial_index = self.pixelIndex(start.x, start.y);
        const target = pixels[initial_index];
        if (target == fill_color or target == border_color) return;

        var pending: std.ArrayList(u32) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, @intCast(initial_index));
        while (pending.pop()) |raw_index| {
            const index: usize = raw_index;
            if (pixels[index] != target or pixels[index] == border_color) continue;
            const x: u32 = @intCast(index % self.width);
            const y: u32 = @intCast(index / self.width);
            self.setPixel(@intCast(x), @intCast(y), fill_color);
            if (x != 0) try pending.append(allocator, raw_index - 1);
            if (x + 1 < self.width) try pending.append(allocator, raw_index + 1);
            if (y != 0) try pending.append(allocator, raw_index - self.width);
            if (y + 1 < self.height) try pending.append(allocator, raw_index + self.width);
        }
    }

    pub fn capture(self: *const Screen, allocator: std.mem.Allocator, first: Point, second: Point) Error![]u8 {
        if (self.mode == 0) return error.IllegalFunctionCall;
        const pixels = self.pixels orelse return error.IllegalFunctionCall;
        const left = @min(first.x, second.x);
        const right = @max(first.x, second.x);
        const top = @min(first.y, second.y);
        const bottom = @max(first.y, second.y);
        if (!self.contains(left, top) or !self.contains(right, bottom)) return error.IllegalFunctionCall;
        const image_width: usize = @intCast(right - left + 1);
        const image_height: usize = @intCast(bottom - top + 1);
        const width_bits: usize = if (self.mode == 1) image_width * 2 else image_width;
        const row_bytes = (width_bits + 7) / 8;
        const planes: usize = if (self.mode == 1) 1 else 4;
        const payload = std.math.mul(usize, row_bytes * planes, image_height) catch return error.OutOfMemory;
        const result = try allocator.alloc(u8, image_header_bytes + payload);
        @memset(result, 0);
        std.mem.writeInt(u16, result[0..2], @intCast(width_bits), .little);
        std.mem.writeInt(u16, result[2..4], @intCast(image_height), .little);

        var y: usize = 0;
        while (y < image_height) : (y += 1) {
            var x: usize = 0;
            while (x < image_width) : (x += 1) {
                const source_x: usize = @intCast(left + @as(i32, @intCast(x)));
                const source_y: usize = @intCast(top + @as(i32, @intCast(y)));
                const color = pixels[source_y * self.width + source_x];
                if (self.mode == 1) {
                    const bit = x * 2;
                    const shift: u3 = @intCast(6 - (bit & 7));
                    result[image_header_bytes + y * row_bytes + bit / 8] |= (color & 3) << shift;
                } else {
                    var plane: usize = 0;
                    while (plane < 4) : (plane += 1) {
                        if ((color & (@as(u8, 1) << @intCast(plane))) == 0) continue;
                        const offset = image_header_bytes + y * row_bytes * 4 + plane * row_bytes + x / 8;
                        result[offset] |= @as(u8, 0x80) >> @intCast(x & 7);
                    }
                }
            }
        }
        return result;
    }

    pub fn put(self: *Screen, origin: Point, bytes: []const u8, action: bytecode.GraphicsPutAction) Error!void {
        if (self.mode == 0) return error.IllegalFunctionCall;
        if (self.pixels == null or bytes.len < image_header_bytes) return error.IllegalFunctionCall;
        const width_bits: usize = std.mem.readInt(u16, bytes[0..2], .little);
        const image_height: usize = std.mem.readInt(u16, bytes[2..4], .little);
        if (width_bits == 0 or image_height == 0) return error.IllegalFunctionCall;
        const image_width: usize = if (self.mode == 1) blk: {
            if ((width_bits & 1) != 0) return error.IllegalFunctionCall;
            break :blk width_bits / 2;
        } else if (self.mode == 9)
            width_bits
        else
            return error.IllegalFunctionCall;
        const row_bytes = (width_bits + 7) / 8;
        const planes: usize = if (self.mode == 1) 1 else 4;
        const payload = std.math.mul(usize, row_bytes * planes, image_height) catch return error.IllegalFunctionCall;
        if (bytes.len < image_header_bytes + payload or image_width == 0) return error.IllegalFunctionCall;
        const far_x = @as(i64, origin.x) + @as(i64, @intCast(image_width)) - 1;
        const far_y = @as(i64, origin.y) + @as(i64, @intCast(image_height)) - 1;
        if (origin.x < 0 or origin.y < 0 or far_x >= self.width or far_y >= self.height) {
            return error.IllegalFunctionCall;
        }

        var y: usize = 0;
        while (y < image_height) : (y += 1) {
            var x: usize = 0;
            while (x < image_width) : (x += 1) {
                var color: u8 = 0;
                if (self.mode == 1) {
                    const bit = x * 2;
                    const shift: u3 = @intCast(6 - (bit & 7));
                    color = (bytes[image_header_bytes + y * row_bytes + bit / 8] >> shift) & 3;
                } else {
                    var plane: usize = 0;
                    while (plane < 4) : (plane += 1) {
                        const offset = image_header_bytes + y * row_bytes * 4 + plane * row_bytes + x / 8;
                        if ((bytes[offset] & (@as(u8, 0x80) >> @intCast(x & 7))) != 0) {
                            color |= @as(u8, 1) << @intCast(plane);
                        }
                    }
                }
                const target_x: i32 = origin.x + @as(i32, @intCast(x));
                const target_y: i32 = origin.y + @as(i32, @intCast(y));
                if (action == .xor) color ^= self.pixel(target_x, target_y);
                self.setPixel(target_x, target_y, color);
            }
        }
    }

    pub fn renderText(self: *Screen, text: *const text_screen.Screen, cells: text_screen.CellRect) void {
        if (self.pixels == null) return;
        const columns = if (self.mode == 1) text_columns_mode_1 else text_columns_mode_9;
        const cell_height = switch (self.mode) {
            0 => text_cell_height_mode_0,
            1 => text_cell_height_mode_1,
            9 => text_cell_height_mode_9,
            else => return,
        };
        const first_x = @min(cells.x, columns);
        const first_y = @min(cells.y, text_rows);
        const last_x = @min(columns, cells.x +| cells.w);
        const last_y = @min(text_rows, cells.y +| cells.h);
        var cell_y = first_y;
        while (cell_y < last_y) : (cell_y += 1) {
            var cell_x = first_x;
            while (cell_x < last_x) : (cell_x += 1) {
                const cell = text.cell(cell_y, cell_x) orelse continue;
                const glyph = basic_font.glyph(cell.character);
                var row: usize = 0;
                while (row < cell_height) : (row += 1) {
                    const glyph_row = glyph[(row * glyph.len) / cell_height];
                    var column: usize = 0;
                    while (column < text_cell_width) : (column += 1) {
                        const bit = (@as(u8, 0x80) >> @intCast(column));
                        const color = if ((glyph_row & bit) != 0) cell.foreground else cell.background;
                        const x: i32 = @intCast(cell_x * text_cell_width + column);
                        const y: i32 = @intCast(cell_y * cell_height + row);
                        self.setPixel(x, y, color & self.maximumAttribute());
                    }
                }
            }
        }
    }

    fn resetPalette(self: *Screen) void {
        @memset(self.palette[0..], 0);
        if (self.mode == 1) {
            for (screen_1_defaults, 0..) |logical_color, palette_index| {
                self.palette[palette_index] = egaRgb(ega_16_codes[logical_color]);
            }
        } else if (self.mode == 0 or self.mode == 9) {
            for (ega_16_codes, 0..) |hardware_code, palette_index| {
                self.palette[palette_index] = egaRgb(hardware_code);
            }
        }
    }

    fn attribute(self: *const Screen, requested: i32) Error!u8 {
        if (self.mode == 0 or self.pixels == null or requested < 0 or requested > self.maximumAttribute()) {
            return error.IllegalFunctionCall;
        }
        return @intCast(requested);
    }

    fn contains(self: *const Screen, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height;
    }

    fn pixelIndex(self: *const Screen, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
    }

    fn pixel(self: *const Screen, x: i32, y: i32) u8 {
        return self.pixels.?[self.pixelIndex(x, y)];
    }

    fn setPixel(self: *Screen, x: i32, y: i32, color: u8) void {
        if (!self.contains(x, y)) return;
        const pixels = self.pixels.?;
        const index = self.pixelIndex(x, y);
        if (pixels[index] == color) return;
        pixels[index] = color;
        self.mark(.{ .x = @intCast(x), .y = @intCast(y), .w = 1, .h = 1 });
    }

    fn drawLine(self: *Screen, requested_first: Point, requested_second: Point, color: u8) void {
        var first = requested_first;
        var second = requested_second;
        if (!self.clipLine(&first, &second)) return;
        var x = first.x;
        var y = first.y;
        const dx: i32 = @intCast(@abs(second.x - first.x));
        const sx: i32 = if (first.x < second.x) 1 else -1;
        const dy: i32 = -@as(i32, @intCast(@abs(second.y - first.y)));
        const sy: i32 = if (first.y < second.y) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.setPixel(x, y, color);
            if (x == second.x and y == second.y) break;
            const twice = err * 2;
            if (twice >= dy) {
                err += dy;
                x += sx;
            }
            if (twice <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    fn fillBox(self: *Screen, first: Point, second: Point, color: u8) void {
        const left = @max(@as(i32, 0), @min(first.x, second.x));
        const right = @min(@as(i32, @intCast(self.width - 1)), @max(first.x, second.x));
        const top = @max(@as(i32, 0), @min(first.y, second.y));
        const bottom = @min(@as(i32, @intCast(self.height - 1)), @max(first.y, second.y));
        if (left > right or top > bottom) return;
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) self.setPixel(x, y, color);
        }
    }

    fn clipLine(self: *const Screen, first: *Point, second: *Point) bool {
        if (self.width == 0 or self.height == 0) return false;
        const max_x: f64 = @floatFromInt(self.width - 1);
        const max_y: f64 = @floatFromInt(self.height - 1);
        var x0: f64 = @floatFromInt(first.x);
        var y0: f64 = @floatFromInt(first.y);
        var x1: f64 = @floatFromInt(second.x);
        var y1: f64 = @floatFromInt(second.y);
        var code0 = outCode(x0, y0, max_x, max_y);
        var code1 = outCode(x1, y1, max_x, max_y);
        var iterations: usize = 0;
        while (iterations < 16) : (iterations += 1) {
            if ((code0 | code1) == 0) {
                first.* = .{ .x = roundClipCoordinate(x0, self.width), .y = roundClipCoordinate(y0, self.height) };
                second.* = .{ .x = roundClipCoordinate(x1, self.width), .y = roundClipCoordinate(y1, self.height) };
                return true;
            }
            if ((code0 & code1) != 0) return false;
            const code = if (code0 != 0) code0 else code1;
            var x: f64 = 0;
            var y: f64 = 0;
            if ((code & 8) != 0) {
                if (y1 == y0) return false;
                y = max_y;
                x = x0 + (x1 - x0) * (max_y - y0) / (y1 - y0);
            } else if ((code & 4) != 0) {
                if (y1 == y0) return false;
                y = 0;
                x = x0 + (x1 - x0) * (0 - y0) / (y1 - y0);
            } else if ((code & 2) != 0) {
                if (x1 == x0) return false;
                x = max_x;
                y = y0 + (y1 - y0) * (max_x - x0) / (x1 - x0);
            } else {
                if (x1 == x0) return false;
                x = 0;
                y = y0 + (y1 - y0) * (0 - x0) / (x1 - x0);
            }
            if (code == code0) {
                x0 = x;
                y0 = y;
                code0 = outCode(x0, y0, max_x, max_y);
            } else {
                x1 = x;
                y1 = y;
                code1 = outCode(x1, y1, max_x, max_y);
            }
        }
        return false;
    }

    fn markFull(self: *Screen) void {
        if (self.width == 0 or self.height == 0) return;
        self.damage = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        self.content_revision +%= 1;
    }

    fn mark(self: *Screen, requested: Rect) void {
        if (requested.w == 0 or requested.h == 0) return;
        if (self.damage) |current| {
            const x = @min(current.x, requested.x);
            const y = @min(current.y, requested.y);
            const right = @max(current.x + current.w, requested.x + requested.w);
            const bottom = @max(current.y + current.h, requested.y + requested.h);
            self.damage = .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
        } else {
            self.damage = requested;
        }
        self.content_revision +%= 1;
    }
};

fn saturatingAdd(first: i32, second: i32) i32 {
    const result = @as(i64, first) + second;
    return @intCast(std.math.clamp(result, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn defaultAspect(mode: i32) f64 {
    return switch (mode) {
        1 => 4.0 * (@as(f64, mode_1_height) / @as(f64, mode_1_width)) / 3.0,
        9 => 4.0 * (@as(f64, mode_9_height) / @as(f64, mode_9_width)) / 3.0,
        else => 1.0,
    };
}

fn ellipsePoint(center: Point, radius_x: f64, radius_y: f64, angle: f64) Point {
    return .{
        .x = roundedPointCoordinate(@as(f64, @floatFromInt(center.x)) + @cos(angle) * radius_x),
        .y = roundedPointCoordinate(@as(f64, @floatFromInt(center.y)) - @sin(angle) * radius_y),
    };
}

fn roundedPointCoordinate(value: f64) i32 {
    const rounded = if (value >= 0) @floor(value + 0.5) else @ceil(value - 0.5);
    return @intFromFloat(std.math.clamp(rounded, @as(f64, std.math.minInt(i32)), @as(f64, std.math.maxInt(i32))));
}

fn outCode(x: f64, y: f64, max_x: f64, max_y: f64) u4 {
    var code: u4 = 0;
    if (x < 0) code |= 1 else if (x > max_x) code |= 2;
    if (y < 0) code |= 4 else if (y > max_y) code |= 8;
    return code;
}

fn roundClipCoordinate(value: f64, limit: u32) i32 {
    const rounded = if (value >= 0) @floor(value + 0.5) else @ceil(value - 0.5);
    return @intFromFloat(std.math.clamp(rounded, 0, @as(f64, @floatFromInt(limit - 1))));
}

fn egaRgb(code: u8) u32 {
    const blue: u32 = (if ((code & 0x01) != 0) @as(u32, 170) else 0) + (if ((code & 0x08) != 0) @as(u32, 85) else 0);
    const green: u32 = (if ((code & 0x02) != 0) @as(u32, 170) else 0) + (if ((code & 0x10) != 0) @as(u32, 85) else 0);
    const red: u32 = (if ((code & 0x04) != 0) @as(u32, 170) else 0) + (if ((code & 0x20) != 0) @as(u32, 85) else 0);
    return (red << 16) | (green << 8) | blue;
}

test "SCREEN 9 palette and reversible packed XOR" {
    var screen: Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 9);
    try std.testing.expectEqual(@as(u32, 640), screen.width);
    try std.testing.expectEqual(@as(u32, 350), screen.height);
    try screen.setPalette(1, 46);
    try std.testing.expectEqual(@as(u32, 0x00ffaa55), screen.palette[1]);

    try screen.line(.{ .x = 2, .y = 2 }, .{ .x = 7, .y = 8 }, 9, .filled_box);
    const image = try screen.capture(std.testing.allocator, .{ .x = 2, .y = 2 }, .{ .x = 7, .y = 8 });
    defer std.testing.allocator.free(image);
    try screen.clear(0);
    try screen.put(.{ .x = 10, .y = 10 }, image, .xor);
    try std.testing.expectEqual(@as(i32, 9), try screen.point(.{ .x = 10, .y = 10 }));
    try screen.put(.{ .x = 10, .y = 10 }, image, .xor);
    try std.testing.expectEqual(@as(i32, 0), try screen.point(.{ .x = 10, .y = 10 }));
}

test "SCREEN 1 GET header uses two packed bits per pixel" {
    var screen: Screen = .{};
    defer screen.deinit(std.testing.allocator);
    try screen.setMode(std.testing.allocator, 1);
    try screen.pset(.{ .x = 0, .y = 0 }, 3);
    try screen.pset(.{ .x = 1, .y = 0 }, 2);
    const image = try screen.capture(std.testing.allocator, .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 4 });
    defer std.testing.allocator.free(image);
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, image[0..2], .little));
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, image[2..4], .little));
    try std.testing.expectEqual(@as(u8, 0xe0), image[4]);
}
