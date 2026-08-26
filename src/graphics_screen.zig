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

pub const max_damage_regions: usize = 8;

pub const Damage = struct {
    regions: [max_damage_regions]Rect = .{Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** max_damage_regions,
    count: usize = 0,
    merges: u32 = 0,
    overflow_merges: u32 = 0,

    pub fn slice(self: *const Damage) []const Rect {
        return self.regions[0..self.count];
    }

    fn clear(self: *Damage) void {
        self.* = .{};
    }

    fn full(self: *Damage, width: u32, height: u32) void {
        self.* = .{};
        if (width == 0 or height == 0) return;
        self.regions[0] = .{ .x = 0, .y = 0, .w = width, .h = height };
        self.count = 1;
    }

    fn note(self: *Damage, requested: Rect) void {
        if (requested.w == 0 or requested.h == 0) return;
        var merged = requested;
        var index: usize = 0;
        while (index < self.count) {
            if (!rectsTouchOrOverlap(self.regions[index], merged)) {
                index += 1;
                continue;
            }
            merged = mergeRect(self.regions[index], merged);
            self.count -= 1;
            self.regions[index] = self.regions[self.count];
            self.merges +|= 1;
        }
        if (self.count < self.regions.len) {
            self.regions[self.count] = merged;
            self.count += 1;
            return;
        }

        var best_index: usize = 0;
        var best_growth: u64 = std.math.maxInt(u64);
        for (self.regions[0..self.count], 0..) |existing, candidate| {
            const combined = mergeRect(existing, merged);
            const growth = rectArea(combined) - rectArea(existing);
            if (growth < best_growth) {
                best_growth = growth;
                best_index = candidate;
            }
        }
        self.regions[best_index] = mergeRect(self.regions[best_index], merged);
        self.merges +|= 1;
        self.overflow_merges +|= 1;
    }
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

pub const PerformanceStats = struct {
    mode_allocations: u64 = 0,
    mode_reuses: u64 = 0,
    mode_clear_bytes: u64 = 0,
    pixel_probes: u64 = 0,
    pixel_changes: u64 = 0,
    span_operations: u64 = 0,
    span_pixels: u64 = 0,
    damage_commits: u64 = 0,
    damage_regions: u64 = 0,
    damage_merges: u64 = 0,
    damage_overflow_merges: u64 = 0,
    full_damage_commits: u64 = 0,
    text_cells: u64 = 0,
    text_rows: u64 = 0,
    line_segments: u64 = 0,
    line_pixels: u64 = 0,
    fill_spans: u64 = 0,
    paint_spans: u64 = 0,
    paint_pixels: u64 = 0,
    paint_pixel_probes: u64 = 0,
    paint_queue_pushes: u64 = 0,
    paint_queue_pops: u64 = 0,
    paint_duplicate_pops: u64 = 0,
    paint_queue_grows: u64 = 0,
    maximum_paint_queue: u64 = 0,
    circle_requested_segments: u64 = 0,
    circle_segments: u64 = 0,
    circle_skipped_segments: u64 = 0,
    capture_calls: u64 = 0,
    capture_pixels: u64 = 0,
    capture_bytes: u64 = 0,
    put_calls: u64 = 0,
    put_pixels: u64 = 0,
    put_bytes: u64 = 0,
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

const Mutation = struct {
    damage: Damage = .{},

    fn notePoint(self: *Mutation, x: u32, y: u32) void {
        self.noteRect(.{ .x = x, .y = y, .w = 1, .h = 1 });
    }

    fn noteSpan(self: *Mutation, x: u32, y: u32, width: u32) void {
        self.noteRect(.{ .x = x, .y = y, .w = width, .h = 1 });
    }

    fn noteRect(self: *Mutation, requested: Rect) void {
        self.damage.note(requested);
    }
};

const ImageLayout = struct {
    left: i32,
    top: i32,
    width: usize,
    height: usize,
    width_bits: usize,
    row_bytes: usize,
    planes: usize,
    byte_count: usize,
};

pub const Screen = struct {
    pixels: ?[]u8 = null,
    palette: [256]u32 = [_]u32{0} ** 256,
    width: u32 = 0,
    height: u32 = 0,
    mode: i32 = 0,
    current: Point = .{ .x = 0, .y = 0 },
    mode_revision: u64 = 1,
    content_revision: u64 = 1,
    damage: Damage = .{},
    stats: PerformanceStats = .{},

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
        if (self.pixels != null and self.pixels.?.len == count) {
            @memset(self.pixels.?, 0);
            self.stats.mode_reuses +%= 1;
        } else {
            const replacement = try allocator.alloc(u8, count);
            @memset(replacement, 0);
            if (self.pixels) |pixels| allocator.free(pixels);
            self.pixels = replacement;
            self.stats.mode_allocations +%= 1;
        }
        self.stats.mode_clear_bytes +%= count;
        self.width = width;
        self.height = height;
        self.mode = mode;
        self.current = .{ .x = 0, .y = 0 };
        self.resetPalette();
        self.damage.full(width, height);
        self.stats.damage_commits +%= 1;
        self.stats.damage_regions +%= 1;
        self.stats.full_damage_commits +%= 1;
        self.mode_revision +%= 1;
        self.content_revision +%= 1;
    }

    pub fn performanceStats(self: *const Screen) PerformanceStats {
        return self.stats;
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

    pub fn takeDamage(self: *Screen) Damage {
        const result = self.damage;
        self.damage.clear();
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
        const unchanged = std.mem.count(u8, pixels, &[_]u8{color});
        self.stats.pixel_probes +%= pixels.len;
        if (unchanged == pixels.len) return;
        @memset(pixels, color);
        self.stats.pixel_changes +%= pixels.len - unchanged;
        self.stats.span_operations +%= self.height;
        self.stats.span_pixels +%= pixels.len;
        self.markFull();
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
        var mutation: Mutation = .{};
        self.writePixelChecked(&mutation, target.x, target.y, color);
        self.commitMutation(mutation);
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
        var mutation: Mutation = .{};
        switch (box_mode) {
            .line => self.drawLine(&mutation, first, second, color),
            .box => {
                self.drawLine(&mutation, first, .{ .x = second.x, .y = first.y }, color);
                self.drawLine(&mutation, .{ .x = second.x, .y = first.y }, second, color);
                self.drawLine(&mutation, second, .{ .x = first.x, .y = second.y }, color);
                self.drawLine(&mutation, .{ .x = first.x, .y = second.y }, first, color);
            },
            .filled_box => self.fillBox(&mutation, first, second, color),
        }
        self.commitMutation(mutation);
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
        self.stats.circle_requested_segments +%= segments;
        if (full_circle and !radial_start and !radial_end and !self.ellipsePolygonMayTouchScreen(center, radius_x, radius_y, segments)) {
            self.stats.circle_skipped_segments +%= segments;
            return;
        }
        self.stats.circle_segments +%= segments;

        var mutation: Mutation = .{};
        var previous = ellipsePoint(center, radius_x, radius_y, start);
        if (radial_start) self.drawLine(&mutation, center, previous, color);
        var step: usize = 1;
        while (step <= segments) : (step += 1) {
            const ratio = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(segments));
            const next = ellipsePoint(center, radius_x, radius_y, start + sweep * ratio);
            self.drawLine(&mutation, previous, next, color);
            previous = next;
        }
        if (radial_end) self.drawLine(&mutation, center, previous, color);
        self.commitMutation(mutation);
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
        try self.appendPaintSeed(&pending, allocator, @intCast(initial_index));
        var mutation: Mutation = .{};
        errdefer self.commitMutation(mutation);
        while (pending.pop()) |raw_index| {
            self.stats.paint_queue_pops +%= 1;
            const index: usize = raw_index;
            self.stats.paint_pixel_probes +%= 1;
            if (pixels[index] != target) {
                self.stats.paint_duplicate_pops +%= 1;
                continue;
            }
            const row_width: usize = self.width;
            const y: usize = index / row_width;
            const row_start = y * row_width;
            var left = index - row_start;
            var right = left;
            while (left != 0) {
                self.stats.paint_pixel_probes +%= 1;
                if (pixels[row_start + left - 1] != target) break;
                left -= 1;
            }
            while (right + 1 < row_width) {
                self.stats.paint_pixel_probes +%= 1;
                if (pixels[row_start + right + 1] != target) break;
                right += 1;
            }

            const span = pixels[row_start + left .. row_start + right + 1];
            @memset(span, fill_color);
            self.stats.pixel_changes +%= span.len;
            self.stats.span_operations +%= 1;
            self.stats.span_pixels +%= span.len;
            self.stats.paint_spans +%= 1;
            self.stats.paint_pixels +%= span.len;
            mutation.noteSpan(@intCast(left), @intCast(y), @intCast(span.len));

            if (y != 0) try self.appendPaintRuns(&pending, allocator, pixels, row_start - row_width, left, right, target);
            if (y + 1 < self.height) try self.appendPaintRuns(&pending, allocator, pixels, row_start + row_width, left, right, target);
        }
        self.commitMutation(mutation);
    }

    pub fn capture(self: *Screen, allocator: std.mem.Allocator, first: Point, second: Point) Error![]u8 {
        const layout = try self.imageLayout(first, second);
        const result = try allocator.alloc(u8, layout.byte_count);
        errdefer allocator.free(result);
        self.captureLayoutInto(layout, result);
        return result;
    }

    pub fn captureInto(self: *Screen, first: Point, second: Point, out: []u8) Error!usize {
        const layout = try self.imageLayout(first, second);
        if (out.len < layout.byte_count) return error.IllegalFunctionCall;
        self.captureLayoutInto(layout, out[0..layout.byte_count]);
        return layout.byte_count;
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

        self.stats.put_calls +%= 1;
        self.stats.put_pixels +%= image_width * image_height;
        self.stats.put_bytes +%= image_header_bytes + payload;
        var mutation: Mutation = .{};
        const pixels = self.pixels.?;
        var y: usize = 0;
        while (y < image_height) : (y += 1) {
            const target_y: u32 = @intCast(origin.y + @as(i32, @intCast(y)));
            const row_start = @as(usize, target_y) * self.width + @as(usize, @intCast(origin.x));
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
                const target_index = row_start + x;
                if (action == .xor) color ^= pixels[target_index];
                self.writePixelAt(&mutation, target_index, @intCast(origin.x + @as(i32, @intCast(x))), target_y, color);
            }
        }
        self.commitMutation(mutation);
    }

    pub fn renderText(self: *Screen, text: *const text_screen.Screen, cells: text_screen.CellRect) void {
        const pixels = self.pixels orelse return;
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
        const maximum_attribute = self.maximumAttribute();
        var mutation: Mutation = .{};
        var cell_y = first_y;
        while (cell_y < last_y) : (cell_y += 1) {
            const cell_count = last_x - first_x;
            var cached_cells: [text_columns_mode_9]text_screen.Cell = undefined;
            var cached_glyphs: [text_columns_mode_9][8]u8 = undefined;
            for (0..cell_count) |index| {
                const cell = text.cell(cell_y, first_x + index) orelse unreachable;
                cached_cells[index] = cell;
                cached_glyphs[index] = basic_font.glyph(cell.character);
                self.stats.text_cells +%= 1;
            }

            const raster_x = first_x * text_cell_width;
            const raster_width = cell_count * text_cell_width;
            var row: usize = 0;
            while (row < cell_height) : (row += 1) {
                var raster_row: [mode_0_width]u8 = undefined;
                for (0..cell_count) |cell_index| {
                    const cell = cached_cells[cell_index];
                    const glyph_row = cached_glyphs[cell_index][(row * 8) / cell_height];
                    const cell_offset = cell_index * text_cell_width;
                    var column: usize = 0;
                    while (column < text_cell_width) : (column += 1) {
                        const bit = (@as(u8, 0x80) >> @intCast(column));
                        raster_row[cell_offset + column] = (if ((glyph_row & bit) != 0) cell.foreground else cell.background) & maximum_attribute;
                    }
                }
                const raster_y = cell_y * cell_height + row;
                const offset = raster_y * self.width + raster_x;
                const destination = pixels[offset .. offset + raster_width];
                const replacement = raster_row[0..raster_width];
                self.stats.text_rows +%= 1;
                self.stats.span_operations +%= 1;
                self.stats.span_pixels +%= raster_width;
                self.stats.pixel_probes +%= raster_width;
                if (std.mem.eql(u8, destination, replacement)) continue;
                for (destination, replacement) |existing, next| {
                    if (existing != next) self.stats.pixel_changes +%= 1;
                }
                @memcpy(destination, replacement);
                mutation.noteSpan(@intCast(raster_x), @intCast(raster_y), @intCast(raster_width));
            }
        }
        self.commitMutation(mutation);
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

    fn writePixelChecked(self: *Screen, mutation: *Mutation, x: i32, y: i32, color: u8) void {
        if (!self.contains(x, y)) return;
        const index = self.pixelIndex(x, y);
        self.writePixelAt(mutation, index, @intCast(x), @intCast(y), color);
    }

    fn writePixelAt(self: *Screen, mutation: *Mutation, index: usize, x: u32, y: u32, color: u8) void {
        const pixels = self.pixels.?;
        self.stats.pixel_probes +%= 1;
        if (pixels[index] == color) return;
        pixels[index] = color;
        self.stats.pixel_changes +%= 1;
        mutation.notePoint(x, y);
    }

    fn writeSolidSpan(self: *Screen, mutation: *Mutation, y: usize, left: usize, right: usize, color: u8) void {
        const row_start = y * self.width;
        const destination = self.pixels.?[row_start + left .. row_start + right + 1];
        self.stats.span_operations +%= 1;
        self.stats.span_pixels +%= destination.len;
        const unchanged = std.mem.count(u8, destination, &[_]u8{color});
        self.stats.pixel_probes +%= destination.len;
        if (unchanged == destination.len) return;
        @memset(destination, color);
        self.stats.pixel_changes +%= destination.len - unchanged;
        mutation.noteSpan(@intCast(left), @intCast(y), @intCast(destination.len));
    }

    fn drawLine(self: *Screen, mutation: *Mutation, requested_first: Point, requested_second: Point, color: u8) void {
        var first = requested_first;
        var second = requested_second;
        if (!self.clipLine(&first, &second)) return;
        self.stats.line_segments +%= 1;
        var x = first.x;
        var y = first.y;
        var pixel_index: i64 = @intCast(self.pixelIndex(x, y));
        const row_stride: i64 = self.width;
        const dx: i32 = @intCast(@abs(second.x - first.x));
        const sx: i32 = if (first.x < second.x) 1 else -1;
        const dy: i32 = -@as(i32, @intCast(@abs(second.y - first.y)));
        const sy: i32 = if (first.y < second.y) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.stats.line_pixels +%= 1;
            self.writePixelAt(mutation, @intCast(pixel_index), @intCast(x), @intCast(y), color);
            if (x == second.x and y == second.y) break;
            const twice = err * 2;
            if (twice >= dy) {
                err += dy;
                x += sx;
                pixel_index += sx;
            }
            if (twice <= dx) {
                err += dx;
                y += sy;
                pixel_index += @as(i64, sy) * row_stride;
            }
        }
    }

    fn fillBox(self: *Screen, mutation: *Mutation, first: Point, second: Point, color: u8) void {
        const left = @max(@as(i32, 0), @min(first.x, second.x));
        const right = @min(@as(i32, @intCast(self.width - 1)), @max(first.x, second.x));
        const top = @max(@as(i32, 0), @min(first.y, second.y));
        const bottom = @min(@as(i32, @intCast(self.height - 1)), @max(first.y, second.y));
        if (left > right or top > bottom) return;
        var y = top;
        while (y <= bottom) : (y += 1) {
            self.stats.fill_spans +%= 1;
            self.writeSolidSpan(mutation, @intCast(y), @intCast(left), @intCast(right), color);
        }
    }

    fn appendPaintSeed(self: *Screen, pending: *std.ArrayList(u32), allocator: std.mem.Allocator, index: u32) Error!void {
        const previous_capacity = pending.capacity;
        try pending.append(allocator, index);
        self.stats.paint_queue_pushes +%= 1;
        if (pending.capacity != previous_capacity) self.stats.paint_queue_grows +%= 1;
        self.stats.maximum_paint_queue = @max(self.stats.maximum_paint_queue, pending.items.len);
    }

    fn appendPaintRuns(
        self: *Screen,
        pending: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
        pixels: []const u8,
        row_start: usize,
        left: usize,
        right: usize,
        target: u8,
    ) Error!void {
        var x = left;
        while (x <= right) {
            self.stats.paint_pixel_probes +%= 1;
            if (pixels[row_start + x] != target) {
                x += 1;
                continue;
            }
            try self.appendPaintSeed(pending, allocator, @intCast(row_start + x));
            x += 1;
            while (x <= right) : (x += 1) {
                self.stats.paint_pixel_probes +%= 1;
                if (pixels[row_start + x] != target) break;
            }
        }
    }

    fn imageLayout(self: *const Screen, first: Point, second: Point) Error!ImageLayout {
        if (self.mode == 0 or self.pixels == null) return error.IllegalFunctionCall;
        const left = @min(first.x, second.x);
        const right = @max(first.x, second.x);
        const top = @min(first.y, second.y);
        const bottom = @max(first.y, second.y);
        if (!self.contains(left, top) or !self.contains(right, bottom)) return error.IllegalFunctionCall;
        const width: usize = @intCast(right - left + 1);
        const height: usize = @intCast(bottom - top + 1);
        const width_bits = std.math.mul(usize, width, if (self.mode == 1) 2 else 1) catch return error.OutOfMemory;
        if (width_bits > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return error.IllegalFunctionCall;
        const row_bytes = (width_bits + 7) / 8;
        const planes: usize = if (self.mode == 1) 1 else 4;
        const row_plane_bytes = std.math.mul(usize, row_bytes, planes) catch return error.OutOfMemory;
        const payload = std.math.mul(usize, row_plane_bytes, height) catch return error.OutOfMemory;
        const byte_count = std.math.add(usize, image_header_bytes, payload) catch return error.OutOfMemory;
        return .{
            .left = left,
            .top = top,
            .width = width,
            .height = height,
            .width_bits = width_bits,
            .row_bytes = row_bytes,
            .planes = planes,
            .byte_count = byte_count,
        };
    }

    fn captureLayoutInto(self: *Screen, layout: ImageLayout, out: []u8) void {
        @memset(out, 0);
        std.mem.writeInt(u16, out[0..2], @intCast(layout.width_bits), .little);
        std.mem.writeInt(u16, out[2..4], @intCast(layout.height), .little);
        const pixels = self.pixels.?;
        const source_left: usize = @intCast(layout.left);
        const source_top: usize = @intCast(layout.top);
        var y: usize = 0;
        while (y < layout.height) : (y += 1) {
            const source = pixels[(source_top + y) * self.width + source_left ..][0..layout.width];
            const output_row = image_header_bytes + y * layout.row_bytes * layout.planes;
            if (self.mode == 1) {
                var x: usize = 0;
                while (x < layout.width) : (x += 1) {
                    const bit = x * 2;
                    const shift: u3 = @intCast(6 - (bit & 7));
                    out[output_row + bit / 8] |= (source[x] & 3) << shift;
                }
            } else {
                var plane: usize = 0;
                while (plane < 4) : (plane += 1) {
                    const plane_mask = @as(u8, 1) << @intCast(plane);
                    const plane_start = output_row + plane * layout.row_bytes;
                    var x: usize = 0;
                    while (x < layout.width) : (x += 1) {
                        if ((source[x] & plane_mask) != 0) out[plane_start + x / 8] |= @as(u8, 0x80) >> @intCast(x & 7);
                    }
                }
            }
        }
        self.stats.capture_calls +%= 1;
        self.stats.capture_pixels +%= layout.width * layout.height;
        self.stats.capture_bytes +%= layout.byte_count;
    }

    fn ellipsePolygonMayTouchScreen(self: *const Screen, center: Point, radius_x: f64, radius_y: f64, segments: usize) bool {
        if (self.width == 0 or self.height == 0) return false;

        // Expand by two pixels to cover endpoint rounding and Bresenham's
        // one-pixel raster envelope. Only provably invisible full polygons
        // are rejected, so visible CIRCLE output stays byte-identical.
        const margin = 2.0;
        const minimum_x = -margin;
        const minimum_y = -margin;
        const maximum_x = @as(f64, @floatFromInt(self.width - 1)) + margin;
        const maximum_y = @as(f64, @floatFromInt(self.height - 1)) + margin;
        const center_x: f64 = @floatFromInt(center.x);
        const center_y: f64 = @floatFromInt(center.y);
        if (radius_x == 0 and radius_y == 0) {
            return center_x >= minimum_x and center_x <= maximum_x and center_y >= minimum_y and center_y <= maximum_y;
        }
        if (radius_x == 0) {
            return center_x >= minimum_x and center_x <= maximum_x and
                center_y + radius_y >= minimum_y and center_y - radius_y <= maximum_y;
        }
        if (radius_y == 0) {
            return center_y >= minimum_y and center_y <= maximum_y and
                center_x + radius_x >= minimum_x and center_x - radius_x <= maximum_x;
        }
        const closest_x = std.math.clamp(center_x, minimum_x, maximum_x);
        const closest_y = std.math.clamp(center_y, minimum_y, maximum_y);
        const minimum_normalized = normalizedEllipseDistance(closest_x, closest_y, center_x, center_y, radius_x, radius_y);
        if (minimum_normalized > 1.0) return false;

        const farthest_dx = @max(@abs(minimum_x - center_x), @abs(maximum_x - center_x));
        const farthest_dy = @max(@abs(minimum_y - center_y), @abs(maximum_y - center_y));
        const maximum_normalized = (farthest_dx / radius_x) * (farthest_dx / radius_x) +
            (farthest_dy / radius_y) * (farthest_dy / radius_y);
        const half_step = std.math.pi / @as(f64, @floatFromInt(segments));
        const polygon_inner_radius = @cos(half_step);
        return maximum_normalized >= polygon_inner_radius * polygon_inner_radius;
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
        self.damage.full(self.width, self.height);
        self.stats.damage_commits +%= 1;
        self.stats.damage_regions +%= 1;
        self.stats.full_damage_commits +%= 1;
        self.content_revision +%= 1;
    }

    fn commitMutation(self: *Screen, mutation: Mutation) void {
        if (mutation.damage.count == 0) return;
        self.stats.damage_merges +%= mutation.damage.merges;
        self.stats.damage_overflow_merges +%= mutation.damage.overflow_merges;
        for (mutation.damage.slice()) |damage| self.mark(damage);
        self.stats.damage_commits +%= 1;
        self.stats.damage_regions +%= mutation.damage.count;
        self.content_revision +%= 1;
    }

    fn mark(self: *Screen, requested: Rect) void {
        if (requested.w == 0 or requested.h == 0) return;
        const before_merges = self.damage.merges;
        const before_overflow = self.damage.overflow_merges;
        self.damage.note(requested);
        self.stats.damage_merges +%= self.damage.merges - before_merges;
        self.stats.damage_overflow_merges +%= self.damage.overflow_merges - before_overflow;
    }
};

fn mergeRect(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    const right = @max(@as(u64, a.x) + a.w, @as(u64, b.x) + b.w);
    const bottom = @max(@as(u64, a.y) + a.h, @as(u64, b.y) + b.h);
    return .{ .x = x, .y = y, .w = @intCast(right - x), .h = @intCast(bottom - y) };
}

fn rectArea(value: Rect) u64 {
    return @as(u64, value.w) * value.h;
}

fn rectsTouchOrOverlap(a: Rect, b: Rect) bool {
    const a_right = @as(u64, a.x) + a.w;
    const a_bottom = @as(u64, a.y) + a.h;
    const b_right = @as(u64, b.x) + b.w;
    const b_bottom = @as(u64, b.y) + b.h;
    return @as(u64, a.x) <= b_right and @as(u64, b.x) <= a_right and
        @as(u64, a.y) <= b_bottom and @as(u64, b.y) <= a_bottom;
}

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

fn normalizedEllipseDistance(x: f64, y: f64, center_x: f64, center_y: f64, radius_x: f64, radius_y: f64) f64 {
    const normalized_x = (x - center_x) / radius_x;
    const normalized_y = (y - center_y) / radius_y;
    return normalized_x * normalized_x + normalized_y * normalized_y;
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
