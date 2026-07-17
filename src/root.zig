const std = @import("std");

pub const stack_size = 64 * 1024;

test "boot stack preserves the AArch64 ABI alignment" {
    try std.testing.expectEqual(0, stack_size % 16);
}
