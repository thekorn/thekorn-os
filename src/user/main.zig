const std = @import("std");
const options = @import("options");
const syscall = @import("syscall");

const user_data_address = 0x0042_0000;
const user_heap_address = 0x0043_0000;
const uart_address = 0x0900_0000;
const kernel_physical_address = 0x4008_0000;
const progress_target = 10_000;
const tick_target = 100;
const heap_page_limit = 4;

// zlinter-disable-next-line function_naming - linker ABI entry symbol
pub export fn _start() callconv(.c) noreturn {
    const hello = if (options.process_id == 1) "PROCESS1:HELLO\n" else "PROCESS2:HELLO\n";
    const stack_ok = if (options.process_id == 1) "PROCESS1:STACK_OK\n" else "PROCESS2:STACK_OK\n";
    const done = if (options.process_id == 1) "PROCESS1:OK\n" else "PROCESS2:OK\n";
    if (invoke(.write, @intFromPtr(hello.ptr), hello.len) != hello.len) fail();
    if (invoke(.write, kernel_physical_address, 8) != syscall.errorResult(.invalid_address)) fail();
    if (invokeRaw(0, 0, 0) != syscall.errorResult(.invalid_syscall)) fail();

    const heap = invoke(.grow, 1, 0);
    if (heap != user_heap_address) fail();
    if (invoke(.grow, heap_page_limit, 0) != syscall.errorResult(.out_of_memory)) fail();
    const heap_identity: *volatile u64 = @ptrFromInt(heap);
    heap_identity.* = options.process_id;

    if (!yieldWithStackCanary()) fail();
    if (invoke(.write, @intFromPtr(stack_ok.ptr), stack_ok.len) != stack_ok.len) fail();

    const progress: *volatile usize = @ptrFromInt(user_data_address);
    const ticks: *volatile usize = @ptrFromInt(user_data_address + @sizeOf(usize));
    const identity: *volatile usize = @ptrFromInt(user_data_address + 2 * @sizeOf(usize));
    identity.* = options.process_id;
    while (progress.* < progress_target) progress.* += 1;
    while (ticks.* < tick_target) asm volatile ("" ::: .{ .memory = true });

    const uart: *const volatile u32 = @ptrFromInt(uart_address);
    _ = uart.*;
    const kernel: *const volatile u64 = @ptrFromInt(kernel_physical_address);
    _ = kernel.*;

    if (invoke(.write, @intFromPtr(done.ptr), done.len) != done.len) fail();
    exit(0);
}

fn invoke(number: syscall.Number, argument0: u64, argument1: u64) u64 {
    return invokeRaw(@intFromEnum(number), argument0, argument1);
}

fn invokeRaw(number: u64, argument0: u64, argument1: u64) u64 {
    return asm volatile ("svc #0"
        : [result] "={x0}" (-> u64),
        : [number] "{x8}" (number),
          [argument0] "{x0}" (argument0),
          [argument1] "{x1}" (argument1),
        : .{ .memory = true });
}

noinline fn yieldWithStackCanary() bool {
    var canary: [32]u64 = undefined;
    for (&canary, 0..) |*value, index| value.* = 0xa5a5_0000_0000_0000 | index;
    asm volatile (""
        :
        : [canary] "r" (&canary),
        : .{ .memory = true });
    if (invoke(.yield, 0, 0) != 0) return false;
    asm volatile ("" ::: .{ .memory = true });
    for (canary, 0..) |value, index| {
        if (value != 0xa5a5_0000_0000_0000 | index) return false;
    }
    return true;
}

fn exit(status: u64) noreturn {
    _ = invoke(.exit, status, 0);
    while (true) asm volatile ("wfe");
}

fn fail() noreturn {
    exit(1);
}

pub fn panic(_: []const u8, _: ?*std.lang.StackTrace, _: ?usize) noreturn {
    exit(1);
}
