const std = @import("std");

pub const preferred_width: u32 = 800;
pub const preferred_height: u32 = 600;

pub const PixelFormat = enum {
    /// One little-endian u32 per pixel: blue at byte 0, green at byte 1,
    /// red at byte 2, and the unused X byte at byte 3.
    xrgb8888,
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
