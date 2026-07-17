const std = @import("std");
const uart = @import("platform/qemu_virt/uart.zig");
const console = @import("kernel/console.zig").Console(uart.writeByte);

extern var __kernel_start: u8;
extern var __kernel_end: u8;

pub export fn kernelMain(dtb: usize, current_el: usize, mpidr: usize) callconv(.c) noreturn {
    uart.init();
    console.writeBootFacts(
        dtb,
        current_el,
        mpidr,
        @intFromPtr(&__kernel_start),
        @intFromPtr(&__kernel_end),
    );
    halt();
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    console.writePanic(message);
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("wfe");
}
