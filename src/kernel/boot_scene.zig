const std = @import("std");
const framebuffer = @import("framebuffer.zig");
const Point = framebuffer.Point;
const Rectangle = framebuffer.Rectangle;

pub const label = "THEKORN OS";
pub const background: u32 = 0x0012_1820;
pub const panel: u32 = 0x0024_3448;
pub const accent: u32 = 0x00e0_9f3e;
pub const foreground: u32 = 0x00f4_f1e8;
pub const panel_rectangle = Rectangle{ .x = 80, .y = 120, .width = 640, .height = 360 };
pub const accent_rectangle = Rectangle{ .x = 80, .y = 120, .width = 640, .height = 16 };
pub const line_start = Point{ .x = 112, .y = 416 };
pub const line_end = Point{ .x = 688, .y = 184 };
pub const label_origin = Point{ .x = 112, .y = 160 };

pub const markers = struct {
    pub const init = "GRAPHICS:INIT";
    pub const qemu_ok = "GRAPHICS:QEMU_OK";
    pub const rpi4_ok = "GRAPHICS:RPI4_OK";
    pub const failed = "GRAPHICS:FAILED";
};

pub const qemu_marker_sequence = [_][]const u8{ markers.init, markers.qemu_ok };
pub const rpi4_marker_sequence = [_][]const u8{ markers.init, markers.rpi4_ok };
pub const failure_marker_sequence = [_][]const u8{ markers.init, markers.failed };

pub fn render(renderer: framebuffer.Renderer) void {
    renderer.clear(background);
    renderer.fill(.{
        .x = panel_rectangle.x,
        .y = panel_rectangle.y,
        .width = panel_rectangle.width,
        .height = panel_rectangle.height,
    }, panel);
    renderer.fill(.{
        .x = accent_rectangle.x,
        .y = accent_rectangle.y,
        .width = accent_rectangle.width,
        .height = accent_rectangle.height,
    }, accent);
    renderer.line(line_start, line_end, accent);
    renderer.text(label_origin, label, foreground);
}

test "graphics outcomes have one ordered terminal marker" {
    try std.testing.expectEqualSlices([]const u8, &.{ "GRAPHICS:INIT", "GRAPHICS:QEMU_OK" }, &qemu_marker_sequence);
    try std.testing.expectEqualSlices([]const u8, &.{ "GRAPHICS:INIT", "GRAPHICS:RPI4_OK" }, &rpi4_marker_sequence);
    try std.testing.expectEqualSlices([]const u8, &.{ "GRAPHICS:INIT", "GRAPHICS:FAILED" }, &failure_marker_sequence);
}

test "boot scene palette is XRGB8888" {
    inline for (&.{ background, panel, accent, foreground }) |color| {
        try std.testing.expectEqual(@as(u32, 0), color & 0xff00_0000);
    }
}

test "boot scene geometry is fixed inside the preferred surface" {
    try std.testing.expectEqual(Rectangle{ .x = 80, .y = 120, .width = 640, .height = 360 }, panel_rectangle);
    try std.testing.expectEqual(Rectangle{ .x = 80, .y = 120, .width = 640, .height = 16 }, accent_rectangle);
    try std.testing.expectEqual(@as(u32, 112), label_origin.x);
    try std.testing.expectEqual(@as(u32, 160), label_origin.y);
    try std.testing.expect(line_start.x < line_end.x and line_start.y > line_end.y);
}

test "complete boot scene has deterministic pixels" {
    const byte_length = framebuffer.preferred_width * framebuffer.preferred_height * @sizeOf(u32);
    const bytes = try std.testing.allocator.alloc(u8, byte_length);
    defer std.testing.allocator.free(bytes);
    const renderer = try framebuffer.Renderer.init(.{
        .bytes = bytes,
        .width = framebuffer.preferred_width,
        .height = framebuffer.preferred_height,
        .pitch = framebuffer.preferred_width * @sizeOf(u32),
        .format = .xrgb8888,
    });

    render(renderer);

    try std.testing.expectEqual(@as(u64, 0x0a5a_7437_28f2_dbd7), std.hash.Wyhash.hash(0, bytes));
}
