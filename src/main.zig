const std = @import("std");
const builtin = @import("builtin");
const uart = @import("platform");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("arch/aarch64/mmu.zig");
const timer = @import("arch/aarch64/timer.zig");
const fdt = @import("formats/fdt.zig");
const physical_memory = @import("kernel/physical_memory.zig");
const Console = @import("kernel/console.zig").Console;
const KernelConsole = Console(uart.writeByte);

const timer_tick_limit = 1_000;
const max_dtb_size = 2 * 1024 * 1024;
const instruction_abort_current_el = 0x21;
const data_abort_current_el = 0x25;
const write_not_read: u64 = 1 << 6;
const fault_status_mask = 0x3f;
const translation_fault_first = 0x04;
const translation_fault_last = 0x07;
const permission_fault_level_three = 0x0f;

const MmuProbe = enum {
    none,
    text_write,
    low_alias_write,
    rodata_execute,
    data_execute,
    unmapped_write,
};

var unexpected_interrupts: usize = 0;
var frame_bitmap: [256 * 1024]u8 = undefined;
var identity_map: mmu.IdentityMap = .{};
var high_half_map: mmu.IdentityMap = .{};
var expected_mmu_probe: MmuProbe = .none;
var completed_mmu_probe: MmuProbe = .none;

extern var __kernel_start: u8;
extern var __kernel_end: u8;
extern var __text_start: u8;
extern var __text_end: u8;
extern var __rodata_start: u8;
extern var __rodata_end: u8;
extern var __data_start: u8;
extern var __stack_top: u8;
extern const __exception_vectors: u8;
extern const __rodata_execute_probe: u32;
extern var __data_execute_probe: u32;
extern fn mmuProbeExecute(address: usize) callconv(.c) void;
extern fn mmuProbeWrite(address: usize) callconv(.c) void;
extern fn mmuEnterHighHalf(continuation: u64, vector_base: u64, stack_top: u64) callconv(.c) noreturn;

pub export fn kernelMain(dtb: usize, entry_el: usize, mpidr: usize) callconv(.c) noreturn {
    uart.init();
    KernelConsole.writeBootFacts(
        dtb,
        entry_el,
        mpidr,
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_start),
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_end),
    );
    initializeMemory(dtb);
    if (builtin.cpu.arch == .aarch64) initializeMmu();
    continueBoot();
}

fn continueBoot() noreturn {
    if (builtin.cpu.arch == .aarch64) {
        asm volatile ("brk #0");
    } else {
        @trap();
    }
    KernelConsole.write("EXCEPTION:RETURNED\n");

    if (builtin.cpu.arch == .aarch64 and uart.supports_timer_interrupts) {
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

fn initializeMemory(dtb_address: usize) void {
    if (dtb_address == 0 or dtb_address % 8 != 0 or dtb_address > std.math.maxInt(usize) - 40) memoryFailed();
    const header: [*]const u8 = @ptrFromInt(dtb_address);
    const total_size = fdt.blobSize(header[0..40]) catch memoryFailed();
    if (total_size > max_dtb_size or dtb_address > std.math.maxInt(usize) - total_size) memoryFailed();
    const info = fdt.parse(header[0..total_size]) catch memoryFailed();
    var allocator = physical_memory.Allocator.init(&frame_bitmap, info.ram[0..info.ram_count]) catch memoryFailed();
    for (info.reservations[0..info.reservation_count]) |range| allocator.reserve(range) catch memoryFailed();
    allocator.reserve(.{ .address = dtb_address, .size = total_size }) catch memoryFailed();
    const kernel_start = if (builtin.is_test) 0 else @intFromPtr(&__kernel_start);
    const kernel_end = if (builtin.is_test) 0 else @intFromPtr(&__kernel_end);
    allocator.reserve(.{ .address = kernel_start, .size = kernel_end - kernel_start }) catch memoryFailed();

    KernelConsole.writeHex("MEMORY:DTB_SIZE=", total_size);
    KernelConsole.writeHex("MEMORY:RAM_RANGES=", info.ram_count);
    KernelConsole.writeHex("MEMORY:FRAMES=", allocator.frame_count);
    var allocated: usize = 0;
    while (allocator.allocate()) |frame| {
        for (allocator.reservations[0..allocator.reservation_count]) |range| {
            if (frame < range.address + range.size and frame + physical_memory.page_size > range.address) memoryFailed();
        }
        allocated += 1;
    }
    if (allocated == 0) memoryFailed();
    KernelConsole.writeHex("MEMORY:ALLOCATED=", allocated);
    KernelConsole.write("MEMORY:OK\n");
}

fn initializeMmu() noreturn {
    const text_start: u64 = @intFromPtr(&__text_start);
    const text_end: u64 = @intFromPtr(&__text_end);
    const rodata_start: u64 = @intFromPtr(&__rodata_start);
    const rodata_end: u64 = @intFromPtr(&__rodata_end);
    const data_start: u64 = @intFromPtr(&__data_start);
    const kernel_end: u64 = @intFromPtr(&__kernel_end);

    identity_map.map(text_start, text_end, .normal_read_execute) catch mmuFailed();
    identity_map.map(rodata_start, rodata_end, .normal_read_only) catch mmuFailed();
    identity_map.map(data_start, kernel_end, .normal_read_write) catch mmuFailed();
    for (uart.mmio_regions) |region| {
        identity_map.map(region.start, region.end, .device_read_write) catch mmuFailed();
    }
    mapHighHalf(text_start, text_end, .normal_read_execute);
    mapHighHalf(rodata_start, rodata_end, .normal_read_only);
    mapHighHalf(data_start, kernel_end, .normal_read_write);

    mmu.enable(identity_map.rootAddress());
    if (!mmu.isEnabled()) mmuFailed();
    KernelConsole.write("MMU:ENABLED\n");

    mmu.enableHighHalf(high_half_map.rootAddress());
    const continuation = mmu.highAddress(@intFromPtr(&kernelHighMain)) catch mmuFailed();
    const vector_base = mmu.highAddress(@intFromPtr(&__exception_vectors)) catch mmuFailed();
    const stack_top = mmu.highAddress(@intFromPtr(&__stack_top)) catch mmuFailed();
    mmuEnterHighHalf(continuation, vector_base, stack_top);
}

fn mapHighHalf(physical_start: u64, physical_end: u64, mapping: mmu.Mapping) void {
    const virtual_start = mmu.highAddress(physical_start) catch mmuFailed();
    high_half_map.mapAt(
        virtual_start,
        physical_start,
        physical_end - physical_start,
        mapping,
    ) catch mmuFailed();
}

fn kernelHighMain() callconv(.c) noreturn {
    const program_counter = mmu.currentProgramCounter();
    const stack_pointer = mmu.currentStackPointer();
    const vector_base = mmu.vectorBase();
    // Linker boundary symbols may be materialized as either their physical
    // value or a PC-relative high alias, depending on the generated access.
    const physical_start = physicalMappedAddress(@intFromPtr(&__kernel_start));
    const physical_end = physicalMappedAddress(@intFromPtr(&__kernel_end));
    const virtual_start = highMappedAddress(physical_start);

    KernelConsole.writeHex("MMU:HIGH_PC=", program_counter);
    KernelConsole.writeHex("MMU:HIGH_SP=", stack_pointer);
    KernelConsole.writeHex("MMU:HIGH_VBAR=", vector_base);
    if (!mmu.isHighAddress(program_counter) or
        !mmu.isHighAddress(stack_pointer) or
        !mmu.isHighAddress(vector_base))
    {
        mmuFailed();
    }
    if (vector_base != highMappedAddress(@intFromPtr(&__exception_vectors))) mmuFailed();
    if (high_half_map.descriptor(virtual_start) == null) mmuFailed();

    identity_map.unmap(physical_start, physical_end) catch mmuFailed();
    mmu.invalidateAll();
    if (identity_map.descriptor(physical_start) != null) mmuFailed();
    for (uart.mmio_regions) |region| {
        if (identity_map.descriptor(region.start) == null) mmuFailed();
    }

    KernelConsole.write("MMU:HIGH_HALF\n");
    verifyMmuProtection();
    KernelConsole.write("MMU:OK\n");
    continueBoot();
}

fn highMappedAddress(address: u64) u64 {
    if (mmu.isHighAddress(address)) return address;
    return mmu.highAddress(address) catch mmuFailed();
}

fn physicalMappedAddress(address: u64) u64 {
    if (mmu.isHighAddress(address)) return mmu.physicalAddress(address) catch mmuFailed();
    _ = mmu.highAddress(address) catch mmuFailed();
    return address;
}

fn verifyMmuProtection() void {
    expected_mmu_probe = .low_alias_write;
    mmuProbeWrite(@intCast(physicalMappedAddress(@intFromPtr(&__kernel_start))));
    finishMmuProbe(.low_alias_write);
    KernelConsole.write("MMU:LOW_ALIAS_UNMAPPED\n");

    expected_mmu_probe = .text_write;
    mmuProbeWrite(@intCast(highMappedAddress(@intFromPtr(&__text_start))));
    finishMmuProbe(.text_write);
    KernelConsole.write("MMU:TEXT_RO\n");

    expected_mmu_probe = .rodata_execute;
    mmuProbeExecute(@intCast(highMappedAddress(@intFromPtr(&__rodata_execute_probe))));
    finishMmuProbe(.rodata_execute);
    KernelConsole.write("MMU:RODATA_NX\n");

    expected_mmu_probe = .data_execute;
    mmuProbeExecute(@intCast(highMappedAddress(@intFromPtr(&__data_execute_probe))));
    finishMmuProbe(.data_execute);
    KernelConsole.write("MMU:DATA_NX\n");

    expected_mmu_probe = .unmapped_write;
    mmuProbeWrite(0);
    finishMmuProbe(.unmapped_write);
    KernelConsole.write("MMU:UNMAPPED\n");
}

fn finishMmuProbe(probe: MmuProbe) void {
    if (expected_mmu_probe != .none or completed_mmu_probe != probe) mmuFailed();
    completed_mmu_probe = .none;
}

fn memoryFailed() noreturn {
    KernelConsole.write("MEMORY:FAILED\n");
    halt();
}

fn mmuFailed() noreturn {
    KernelConsole.write("MMU:FAILED\n");
    halt();
}

pub export fn exceptionHandler(vector: usize, frame: *exceptions.Frame) callconv(.c) void {
    if (builtin.cpu.arch == .aarch64 and uart.supports_timer_interrupts and vector == 5) {
        handleIrq();
        return;
    }
    if (handleMmuProbe(vector, frame)) return;

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

fn handleMmuProbe(vector: usize, frame: *exceptions.Frame) bool {
    const probe = expected_mmu_probe;
    if (probe == .none or vector != 4) return false;

    const expected_address: usize = switch (probe) {
        .none => unreachable,
        .text_write => @intCast(highMappedAddress(@intFromPtr(&__text_start))),
        .low_alias_write => @intCast(physicalMappedAddress(@intFromPtr(&__kernel_start))),
        .rodata_execute => @intCast(highMappedAddress(@intFromPtr(&__rodata_execute_probe))),
        .data_execute => @intCast(highMappedAddress(@intFromPtr(&__data_execute_probe))),
        .unmapped_write => 0,
    };
    if (!matchesMmuProbe(probe, frame.esr, frame.far, expected_address)) return false;

    switch (probe) {
        .none => unreachable,
        .text_write, .low_alias_write, .unmapped_write => frame.elr += 4,
        .rodata_execute, .data_execute => frame.elr = frame.registers[1],
    }
    expected_mmu_probe = .none;
    completed_mmu_probe = probe;
    return true;
}

fn matchesMmuProbe(probe: MmuProbe, esr: u64, far: u64, expected_address: usize) bool {
    if (far != expected_address) return false;
    const exception_class = exceptions.class(esr);
    const fault_status = esr & fault_status_mask;
    return switch (probe) {
        .none => false,
        .text_write => exception_class == data_abort_current_el and
            esr & write_not_read != 0 and
            fault_status == permission_fault_level_three,
        .low_alias_write => exception_class == data_abort_current_el and
            esr & write_not_read != 0 and
            fault_status >= translation_fault_first and
            fault_status <= translation_fault_last,
        .rodata_execute, .data_execute => exception_class == instruction_abort_current_el and
            fault_status == permission_fault_level_three,
        .unmapped_write => exception_class == data_abort_current_el and
            esr & write_not_read != 0 and
            fault_status >= translation_fault_first and
            fault_status <= translation_fault_last,
    };
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

test {
    _ = mmu;
}

test "panic output uses the serial CRLF convention" {
    resetTestOutput();

    Console(captureTestByte).writePanic("unexpected state");

    try std.testing.expectEqualStrings(
        "PANIC:unexpected state\r\n",
        test_output[0..test_output_len],
    );
}

test "console translates every newline to CRLF" {
    resetTestOutput();

    Console(captureTestByte).write("first\n\nlast\n");

    try std.testing.expectEqualStrings(
        "first\r\n\r\nlast\r\n",
        test_output[0..test_output_len],
    );
}

test "console writes hexadecimal boundary values with full width" {
    resetTestOutput();

    Console(captureTestByte).writeHex("ZERO=", 0);
    try std.testing.expectEqualStrings(
        "ZERO=0x0000000000000000\r\n",
        test_output[0..test_output_len],
    );

    resetTestOutput();
    Console(captureTestByte).writeHex("MAX=", std.math.maxInt(usize));
    try std.testing.expectEqual("MAX=0x".len + @bitSizeOf(usize) / 4 + 2, test_output_len);
    try std.testing.expect(std.mem.startsWith(u8, test_output[0..test_output_len], "MAX=0x"));
    for (test_output["MAX=0x".len .. test_output_len - 2]) |digit| {
        try std.testing.expectEqual('f', digit);
    }
    try std.testing.expectEqualStrings("\r\n", test_output[test_output_len - 2 .. test_output_len]);
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

test "GIC acknowledgement decoding preserves interrupt ID boundaries" {
    try std.testing.expectEqual(@as(u32, 0), uart.gic.interruptId(0));
    try std.testing.expectEqual(
        uart.gic.first_special_interrupt - 1,
        uart.gic.interruptId(uart.gic.first_special_interrupt - 1),
    );
    try std.testing.expectEqual(
        uart.gic.first_special_interrupt,
        uart.gic.interruptId(uart.gic.first_special_interrupt),
    );
    try std.testing.expectEqual(@as(u32, 0x3ff), uart.gic.interruptId(std.math.maxInt(u32)));
}

test "MMU probes classify permission and translation faults" {
    const address = 0x4008_0000;
    try std.testing.expect(matchesMmuProbe(
        .text_write,
        (@as(u64, data_abort_current_el) << 26) | write_not_read | permission_fault_level_three,
        address,
        address,
    ));
    try std.testing.expect(matchesMmuProbe(
        .low_alias_write,
        (@as(u64, data_abort_current_el) << 26) | write_not_read | translation_fault_last,
        address,
        address,
    ));
    try std.testing.expect(matchesMmuProbe(
        .rodata_execute,
        (@as(u64, instruction_abort_current_el) << 26) | permission_fault_level_three,
        address,
        address,
    ));
    try std.testing.expect(matchesMmuProbe(
        .unmapped_write,
        (@as(u64, data_abort_current_el) << 26) | write_not_read | translation_fault_last,
        0,
        0,
    ));
    try std.testing.expect(!matchesMmuProbe(
        .data_execute,
        (@as(u64, data_abort_current_el) << 26) | write_not_read | permission_fault_level_three,
        address,
        address,
    ));
}
