const std = @import("std");

pub const breakpoint_class = 0x3c;
pub const fp_access_trap_class = 0x07;
pub const supervisor_call_class = 0x15;
pub const stack_frame_size = 288;

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

pub fn disableFloatingPoint() void {
    const cpacr_el1 = asm volatile ("mrs %[value], CPACR_EL1"
        : [value] "=r" (-> u64),
    );
    asm volatile ("msr CPACR_EL1, %[value]"
        :
        : [value] "r" (cpacr_el1 & ~(@as(u64, 0b11) << 20)),
        : .{ .memory = true });
    asm volatile ("isb");
}

pub fn setUserStackPointer(address: u64) void {
    asm volatile ("msr SP_EL0, %[value]"
        :
        : [value] "r" (address),
        : .{ .memory = true });
}

test "exception class is decoded from ESR bits 31 through 26" {
    try std.testing.expectEqual(breakpoint_class, class(breakpoint_class << 26));
}

test "exception class ignores bits outside the class field" {
    try std.testing.expectEqual(0, class(0));
    try std.testing.expectEqual(@as(u64, 0x3f), class(~@as(u64, 0)));
    try std.testing.expectEqual(
        breakpoint_class,
        class((breakpoint_class << 26) | 0x03ff_ffff | (@as(u64, 0xffff_ffff) << 32)),
    );
}

test "exception frame layout matches the vector assembly" {
    try std.testing.expectEqual(280, @sizeOf(Frame));
    try std.testing.expectEqual(0, stack_frame_size % 16);
    try std.testing.expect(stack_frame_size >= @sizeOf(Frame));
    try std.testing.expectEqual(248, @offsetOf(Frame, "elr"));
    try std.testing.expectEqual(272, @offsetOf(Frame, "far"));
}
