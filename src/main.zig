const std = @import("std");
const builtin = @import("builtin");
const uart = @import("platform/qemu_virt/uart.zig");
const Console = @import("kernel/console.zig").Console;
const console = Console(uart.writeByte);

extern var __kernel_start: u8;
extern var __kernel_end: u8;

pub export fn kernelMain(dtb: usize, current_el: usize, mpidr: usize) callconv(.c) noreturn {
    uart.init();
    console.writeBootFacts(
        dtb,
        current_el,
        mpidr,
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_start),
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_end),
    );
    halt();
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    if (builtin.is_test) std.debug.defaultPanic(message, return_address);
    console.writePanic(message);
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("wfe");
}

var test_output: [512]u8 = undefined;
var test_output_len: usize = 0;

fn captureTestByte(byte: u8) void {
    test_output[test_output_len] = byte;
    test_output_len += 1;
}

fn resetTestOutput() void {
    test_output_len = 0;
}

test "panic output uses the serial CRLF convention" {
    resetTestOutput();

    Console(captureTestByte).writePanic("unexpected state");

    try std.testing.expectEqualStrings(
        "PANIC:unexpected state\r\n",
        test_output[0..test_output_len],
    );
}

test "boot facts include padded hexadecimal addresses and completion markers" {
    resetTestOutput();

    Console(captureTestByte).writeBootFacts(
        0x4000_0000,
        1,
        0x8000_0000,
        0x0008_0000,
        0x0009_1234,
    );

    try std.testing.expectEqualStrings(
        "BOOT:START\r\n" ++
            "BOOT:CURRENT_EL=1\r\n" ++
            "BOOT:MPIDR=0x0000000080000000\r\n" ++
            "BOOT:DTB=0x0000000040000000\r\n" ++
            "BOOT:KERNEL_START=0x0000000000080000\r\n" ++
            "BOOT:KERNEL_END=0x0000000000091234\r\n" ++
            "BOOT:OK\r\n" ++
            "PANIC:phase 1 deliberate panic\r\n",
        test_output[0..test_output_len],
    );
}
