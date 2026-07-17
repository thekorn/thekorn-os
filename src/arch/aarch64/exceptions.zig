const std = @import("std");

pub const breakpoint_class = 0x3c;

pub const Frame = extern struct {
    registers: [31]u64,
    elr: u64,
    spsr: u64,
    esr: u64,
    far: u64,
};

pub fn class(esr: u64) u64 {
    return (esr >> 26) & 0x3f;
}

test "exception class is decoded from ESR bits 31 through 26" {
    try std.testing.expectEqual(breakpoint_class, class(breakpoint_class << 26));
}

test "exception frame layout matches the vector assembly" {
    try std.testing.expectEqual(280, @sizeOf(Frame));
    try std.testing.expectEqual(248, @offsetOf(Frame, "elr"));
    try std.testing.expectEqual(272, @offsetOf(Frame, "far"));
}
