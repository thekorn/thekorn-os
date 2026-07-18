const std = @import("std");
const builtin = @import("builtin");
const uart = @import("platform");
const exceptions = @import("arch/aarch64/exceptions.zig");
const timer = @import("arch/aarch64/timer.zig");
const Console = @import("kernel/console.zig").Console;
const KernelConsole = Console(uart.writeByte);

const timer_tick_limit = 1_000;
var unexpected_interrupts: usize = 0;

extern var __kernel_start: u8;
extern var __kernel_end: u8;

pub export fn kernelMain(dtb: usize, entry_el: usize, mpidr: usize) callconv(.c) noreturn {
    uart.init();
    KernelConsole.writeBootFacts(
        dtb,
        entry_el,
        mpidr,
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_start),
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_end),
    );
    if (builtin.cpu.arch == .aarch64) {
        asm volatile ("brk #0");
    } else {
        @trap();
    }
    KernelConsole.write("EXCEPTION:RETURNED\n");

    if (uart.supports_timer_interrupts) {
        uart.gic.init();
        timer.init(timer_tick_limit);
        enableInterrupts();

        var previous_ticks: usize = 0;
        while (timer.ticks() < timer_tick_limit) {
            const current_ticks = timer.ticks();
            if (current_ticks < previous_ticks) {
                KernelConsole.write("TIMER:NON_MONOTONIC\n");
                halt();
            }
            previous_ticks = current_ticks;
        }
        disableInterrupts();

        if (unexpected_interrupts != 0 or timer.ticks() != timer_tick_limit) {
            KernelConsole.write("IRQ:FAILED\n");
            halt();
        }
        KernelConsole.writeHex("TIMER:TICKS=", timer.ticks());
        KernelConsole.write("TIMER:MONOTONIC\n");
        KernelConsole.write("IRQ:OK\n");
    }
    KernelConsole.write("BOOT:OK\n");
    halt();
}

pub export fn exceptionHandler(vector: usize, frame: *exceptions.Frame) callconv(.c) void {
    if (uart.supports_timer_interrupts and vector == 5) {
        handleIrq();
        return;
    }

    KernelConsole.writeHex("EXCEPTION:VECTOR=", vector);
    KernelConsole.writeHex("EXCEPTION:ESR=", frame.esr);
    KernelConsole.writeHex("EXCEPTION:EC=", exceptions.class(frame.esr));
    KernelConsole.writeHex("EXCEPTION:ELR=", frame.elr);
    KernelConsole.writeHex("EXCEPTION:SPSR=", frame.spsr);
    KernelConsole.writeHex("EXCEPTION:FAR=", frame.far);

    if (vector == 4 and exceptions.class(frame.esr) == exceptions.breakpoint_class) {
        KernelConsole.write("EXCEPTION:BRK\n");
        frame.elr += 4;
        return;
    }

    KernelConsole.write("EXCEPTION:UNHANDLED\n");
    halt();
}

fn handleIrq() void {
    const acknowledgement = uart.gic.acknowledge();
    const interrupt_id = uart.gic.interruptId(acknowledgement);
    if (interrupt_id == uart.gic.physical_timer_interrupt) {
        timer.handleInterrupt();
        uart.gic.end(acknowledgement);
    } else if (interrupt_id < uart.gic.first_special_interrupt) {
        _ = @atomicRmw(usize, &unexpected_interrupts, .Add, 1, .monotonic);
        uart.gic.end(acknowledgement);
    }
}

fn enableInterrupts() void {
    asm volatile ("msr DAIFClr, #2" ::: .{ .memory = true });
}

fn disableInterrupts() void {
    asm volatile ("msr DAIFSet, #2" ::: .{ .memory = true });
}

pub fn panic(message: []const u8, _: ?*std.lang.StackTrace, return_address: ?usize) noreturn {
    if (builtin.is_test) std.debug.defaultPanic(message, return_address);
    KernelConsole.writePanic(message);
    halt();
}

fn halt() noreturn {
    if (builtin.cpu.arch != .aarch64) @trap();
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
            "BOOT:KERNEL_END=0x0000000000091234\r\n",
        test_output[0..test_output_len],
    );
}

test "GIC acknowledgement decoding excludes CPU ID bits" {
    try std.testing.expectEqual(
        @as(u32, 30),
        uart.gic.interruptId((5 << 10) | 30),
    );
}
