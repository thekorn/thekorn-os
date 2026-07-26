const std = @import("std");
const Rectangle = @import("framebuffer.zig").Rectangle;

pub const label = "THEKORN OS";
pub const background: u32 = 0x0012_1820;
pub const panel: u32 = 0x0024_3448;
pub const accent: u32 = 0x00e0_9f3e;
pub const foreground: u32 = 0x00f4_f1e8;
pub const panel_rectangle = Rectangle{ .x = 80, .y = 120, .width = 640, .height = 360 };
pub const accent_rectangle = Rectangle{ .x = 80, .y = 120, .width = 640, .height = 16 };
pub const line_start = .{ .x = 112, .y = 416 };
pub const line_end = .{ .x = 688, .y = 184 };
pub const label_origin = .{ .x = 112, .y = 160 };

pub const markers = struct {
    pub const init = "GRAPHICS:INIT";
    pub const qemu_ok = "GRAPHICS:QEMU_OK";
    pub const rpi4_ok = "GRAPHICS:RPI4_OK";
    pub const failed = "GRAPHICS:FAILED";
};

pub const qemu_marker_sequence = [_][]const u8{ markers.init, markers.qemu_ok };
pub const rpi4_marker_sequence = [_][]const u8{ markers.init, markers.rpi4_ok };
pub const failure_marker_sequence = [_][]const u8{ markers.init, markers.failed };

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
