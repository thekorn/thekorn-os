const std = @import("std");

pub const preferred_width: u32 = 800;
pub const preferred_height: u32 = 600;

pub const PixelFormat = enum {
    /// One little-endian u32 per pixel: blue at byte 0, green at byte 1,
    /// red at byte 2, and the unused X byte at byte 3.
    xrgb8888,
    unsupported,
};

pub const Framebuffer = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    pitch: u32,
    format: PixelFormat,
};

pub const Rectangle = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const DrawRectangle = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Error = error{
    DisplayUnavailable,
    InvalidDimensions,
    UnsupportedFormat,
    AllocationFailed,
    TransportFailed,
};

/// A platform-owned display surface. Portable code may mutate the framebuffer,
/// then asks the backend to publish a clipped dirty rectangle.
pub const Display = struct {
    context: *anyopaque,
    framebuffer: Framebuffer,
    presentFn: *const fn (context: *anyopaque, dirty: Rectangle) Error!void,

    pub fn present(self: Display, dirty: Rectangle) Error!void {
        return self.presentFn(self.context, dirty);
    }
};

pub const Renderer = struct {
    framebuffer: Framebuffer,

    pub fn init(framebuffer: Framebuffer) Error!Renderer {
        if (framebuffer.format != .xrgb8888) return error.UnsupportedFormat;
        const row_bytes = std.math.mul(usize, framebuffer.width, @sizeOf(u32)) catch return error.InvalidDimensions;
        if (framebuffer.pitch < row_bytes) return error.InvalidDimensions;
        if (framebuffer.width > std.math.maxInt(i32) or framebuffer.height > std.math.maxInt(i32)) {
            return error.InvalidDimensions;
        }
        const required = requiredByteLength(framebuffer, row_bytes) catch return error.InvalidDimensions;
        if (framebuffer.bytes.len < required) return error.InvalidDimensions;
        return .{ .framebuffer = framebuffer };
    }

    pub fn clear(self: Renderer, color: u32) void {
        self.fill(.{
            .x = 0,
            .y = 0,
            .width = self.framebuffer.width,
            .height = self.framebuffer.height,
        }, color);
    }

    pub fn pixel(self: Renderer, point: Point, color: u32) void {
        if (point.x < 0 or point.y < 0) return;
        const x: u32 = @intCast(point.x);
        const y: u32 = @intCast(point.y);
        if (x >= self.framebuffer.width or y >= self.framebuffer.height) return;
        self.writePixel(x, y, color);
    }

    pub fn fill(self: Renderer, rectangle: DrawRectangle, color: u32) void {
        const left = @max(@as(i64, rectangle.x), 0);
        const top = @max(@as(i64, rectangle.y), 0);
        const right = @min(
            @as(i64, rectangle.x) + rectangle.width,
            self.framebuffer.width,
        );
        const bottom = @min(
            @as(i64, rectangle.y) + rectangle.height,
            self.framebuffer.height,
        );
        if (left >= right or top >= bottom) return;

        for (@intCast(top)..@intCast(bottom)) |y| {
            for (@intCast(left)..@intCast(right)) |x| self.writePixel(@intCast(x), @intCast(y), color);
        }
    }

    pub fn line(self: Renderer, start: Point, end: Point, color: u32) void {
        var x: i64 = start.x;
        var y: i64 = start.y;
        const end_x: i64 = end.x;
        const end_y: i64 = end.y;
        const delta_x: i64 = @intCast(@abs(end_x - x));
        const step_x: i64 = if (x < end_x) 1 else -1;
        const delta_y: i64 = -@as(i64, @intCast(@abs(end_y - y)));
        const step_y: i64 = if (y < end_y) 1 else -1;
        var difference = delta_x + delta_y;

        while (true) {
            if (x >= std.math.minInt(i32) and x <= std.math.maxInt(i32) and
                y >= std.math.minInt(i32) and y <= std.math.maxInt(i32))
            {
                self.pixel(.{ .x = @intCast(x), .y = @intCast(y) }, color);
            }
            if (x == end_x and y == end_y) break;
            const doubled = difference * 2;
            if (doubled >= delta_y) {
                difference += delta_y;
                x += step_x;
            }
            if (doubled <= delta_x) {
                difference += delta_x;
                y += step_y;
            }
        }
    }

    pub fn glyph(self: Renderer, origin: Point, bitmap: [8]u8, color: u32) void {
        for (bitmap, 0..) |row, y| {
            for (0..8) |x| {
                const shift: u3 = @intCast(7 - x);
                if (row & (@as(u8, 1) << shift) == 0) continue;
                self.pixel(.{
                    .x = origin.x +| @as(i32, @intCast(x)),
                    .y = origin.y +| @as(i32, @intCast(y)),
                }, color);
            }
        }
    }

    pub fn text(self: Renderer, origin: Point, bytes: []const u8, color: u32) void {
        var x = origin.x;
        for (bytes) |byte| {
            self.glyph(.{ .x = x, .y = origin.y }, glyphBitmap(byte), color);
            x +|= 8;
        }
    }

    fn writePixel(self: Renderer, x: u32, y: u32, color: u32) void {
        const offset = @as(usize, y) * self.framebuffer.pitch + @as(usize, x) * @sizeOf(u32);
        self.framebuffer.bytes[offset] = @truncate(color);
        self.framebuffer.bytes[offset + 1] = @truncate(color >> 8);
        self.framebuffer.bytes[offset + 2] = @truncate(color >> 16);
        self.framebuffer.bytes[offset + 3] = 0;
    }
};

fn requiredByteLength(framebuffer: Framebuffer, row_bytes: usize) !usize {
    if (framebuffer.height == 0 or framebuffer.width == 0) return 0;
    const preceding_rows = try std.math.mul(usize, framebuffer.height - 1, framebuffer.pitch);
    return std.math.add(usize, preceding_rows, row_bytes);
}

fn glyphBitmap(byte: u8) [8]u8 {
    return switch (byte) {
        'A' => glyph_a,
        'E' => glyph_e,
        'H' => glyph_h,
        'K' => glyph_k,
        'N' => glyph_n,
        'O' => glyph_o,
        'R' => glyph_r,
        'S' => glyph_s,
        'T' => glyph_t,
        ' ' => @splat(0),
        else => .{ 0x7e, 0x42, 0x0c, 0x18, 0x18, 0x00, 0x18, 0x00 },
    };
}

const glyph_a: [8]u8 align(16) = .{ 0x18, 0x24, 0x42, 0x7e, 0x42, 0x42, 0x42, 0x00 };
const glyph_e: [8]u8 align(16) = .{ 0x7e, 0x40, 0x40, 0x7c, 0x40, 0x40, 0x7e, 0x00 };
const glyph_h: [8]u8 align(16) = .{ 0x42, 0x42, 0x42, 0x7e, 0x42, 0x42, 0x42, 0x00 };
const glyph_k: [8]u8 align(16) = .{ 0x42, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42, 0x00 };
const glyph_n: [8]u8 align(16) = .{ 0x42, 0x62, 0x52, 0x4a, 0x46, 0x42, 0x42, 0x00 };
const glyph_o: [8]u8 align(16) = .{ 0x3c, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3c, 0x00 };
const glyph_r: [8]u8 align(16) = .{ 0x7c, 0x42, 0x42, 0x7c, 0x48, 0x44, 0x42, 0x00 };
const glyph_s: [8]u8 align(16) = .{ 0x3c, 0x42, 0x40, 0x3c, 0x02, 0x42, 0x3c, 0x00 };
const glyph_t: [8]u8 align(16) = .{ 0x7f, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x00 };

test "graphics contract fixes the preferred format and byte order" {
    try std.testing.expectEqual(@as(u32, 800), preferred_width);
    try std.testing.expectEqual(@as(u32, 600), preferred_height);
    try std.testing.expectEqual(PixelFormat.xrgb8888, .xrgb8888);

    const red: u32 = 0x00ff_0000;
    const bytes: [4]u8 = @bitCast(red);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xff, 0x00 }, &bytes);
}

test "Display forwards presentation to its platform backend" {
    const Mock = struct {
        presented: ?Rectangle = null,

        fn present(context: *anyopaque, dirty: Rectangle) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.presented = dirty;
        }
    };

    var mock = Mock{};
    var bytes: [4]u8 = @splat(0);
    const display = Display{
        .context = &mock,
        .framebuffer = .{
            .bytes = &bytes,
            .width = 1,
            .height = 1,
            .pitch = 4,
            .format = .xrgb8888,
        },
        .presentFn = Mock.present,
    };
    const dirty = Rectangle{ .x = 0, .y = 0, .width = 1, .height = 1 };

    try display.present(dirty);
    try std.testing.expectEqual(dirty, mock.presented.?);
}

test "Renderer honors padded pitch and XRGB8888 byte order" {
    var bytes: [24]u8 = @splat(0xa5);
    const renderer = try Renderer.init(.{
        .bytes = &bytes,
        .width = 2,
        .height = 2,
        .pitch = 12,
        .format = .xrgb8888,
    });
    renderer.clear(0x0012_3456);

    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0, 0x56, 0x34, 0x12, 0 }, bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, bytes[8..12]);
    try std.testing.expectEqualSlices(u8, bytes[0..8], bytes[12..20]);
}

test "Renderer clips rectangles, lines, glyphs, and empty surfaces" {
    var bytes: [64]u8 = @splat(0);
    const renderer = try Renderer.init(.{
        .bytes = &bytes,
        .width = 4,
        .height = 4,
        .pitch = 16,
        .format = .xrgb8888,
    });
    renderer.fill(.{ .x = -2, .y = -1, .width = 4, .height = 3 }, 0x00ff_0000);
    renderer.line(.{ .x = -1, .y = 3 }, .{ .x = 4, .y = 3 }, 0x0000_ff00);
    renderer.glyph(.{ .x = 3, .y = -4 }, glyphBitmap('T'), 0x0000_00ff);

    try std.testing.expectEqual(@as(u8, 0xff), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0), bytes[10]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0, 0 }, bytes[48..52]);

    const empty = try Renderer.init(.{
        .bytes = &.{},
        .width = 0,
        .height = 0,
        .pitch = 0,
        .format = .xrgb8888,
    });
    empty.clear(0xffff_ffff);
    empty.pixel(.{ .x = 0, .y = 0 }, 0xffff_ffff);
}

test "Renderer rejects malformed framebuffer layouts" {
    var bytes: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidDimensions, Renderer.init(.{
        .bytes = &bytes,
        .width = 3,
        .height = 1,
        .pitch = 8,
        .format = .xrgb8888,
    }));
    try std.testing.expectError(error.InvalidDimensions, Renderer.init(.{
        .bytes = &bytes,
        .width = 2,
        .height = 2,
        .pitch = 8,
        .format = .xrgb8888,
    }));
    try std.testing.expectError(error.UnsupportedFormat, Renderer.init(.{
        .bytes = &.{},
        .width = 0,
        .height = 0,
        .pitch = 0,
        .format = .unsupported,
    }));
}
