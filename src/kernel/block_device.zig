const std = @import("std");

pub const Error = error{
    InvalidBuffer,
    OutOfBounds,
    IoFailure,
};

/// A borrowed, read-only block device. The callback receives an already
/// validated whole-block request; drivers may still report transport I/O.
pub const BlockDevice = struct {
    context: *anyopaque,
    readBlocks: *const fn (context: *anyopaque, first_block: u64, destination: []u8) Error!void,
    block_size: u32,
    block_count: u64,

    pub fn read(self: BlockDevice, first_block: u64, destination: []u8) Error!void {
        if (self.block_size == 0) return error.InvalidBuffer;
        if (destination.len % self.block_size != 0) return error.InvalidBuffer;

        const requested: u64 = @intCast(destination.len / self.block_size);
        if (first_block > self.block_count) return error.OutOfBounds;
        if (requested > self.block_count - first_block) return error.OutOfBounds;
        if (requested == 0) return;

        return self.readBlocks(self.context, first_block, destination);
    }
};

const Mock = struct {
    calls: usize = 0,
    first: u64 = 0,

    fn read(context: *anyopaque, first: u64, destination: []u8) Error!void {
        const self: *Mock = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.first = first;
        @memset(destination, 0xa5);
    }

    fn device(self: *Mock) BlockDevice {
        return .{ .context = self, .readBlocks = read, .block_size = 512, .block_count = 4 };
    }
};

test "BlockDevice validates requests and dispatches" {
    var mock = Mock{};
    const device = mock.device();
    var sector: [512]u8 = undefined;
    try device.read(2, &sector);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqual(@as(u64, 2), mock.first);
    try std.testing.expectEqual(@as(u8, 0xa5), sector[0]);

    try std.testing.expectError(error.InvalidBuffer, device.read(0, sector[0..511]));
    try std.testing.expectError(error.OutOfBounds, device.read(4, &sector));
    try std.testing.expectError(error.OutOfBounds, device.read(std.math.maxInt(u64), &sector));
    try device.read(4, sector[0..0]);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

test "BlockDevice rejects a zero block size" {
    var mock = Mock{};
    var device = mock.device();
    device.block_size = 0;
    try std.testing.expectError(error.InvalidBuffer, device.read(0, &.{}));
}
