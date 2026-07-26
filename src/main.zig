const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const uart = @import("platform");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("arch/aarch64/mmu.zig");
const timer = @import("arch/aarch64/timer.zig");
const embedded_users = @import("embedded_users");
const cpio = @import("formats/cpio.zig");
const elf = @import("formats/elf.zig");
const fat = @import("formats/fat.zig");
const fdt = @import("formats/fdt.zig");
const block_device = @import("kernel/block_device.zig");
const boot_scene = @import("kernel/boot_scene.zig");
const framebuffer = @import("kernel/framebuffer.zig");
const physical_memory = @import("kernel/physical_memory.zig");
const process = @import("kernel/process.zig");
const scheduler = @import("kernel/scheduler.zig");
const syscall = @import("kernel/syscall.zig");
const Console = @import("kernel/console.zig").Console;
const KernelConsole = Console(uart.writeByte);

const timer_tick_limit = 1_000;
const cooperative_progress_limit = 32;
const preemptive_progress_limit = 10_000;
const user_tick_target = 100;
const cooperative_phase: u8 = 0;
const preemptive_phase: u8 = 1;
const max_user_write = 256;
// EL1h with debug, SError, and FIQ masked. IRQ remains enabled.
const scheduler_initial_spsr: u64 = 0x345;
// EL0t with debug, SError, IRQ, and FIQ enabled.
const user_initial_spsr: u64 = 0;
const max_dtb_size = 2 * 1024 * 1024;
const instruction_abort_current_el = 0x21;
const data_abort_lower_el = 0x24;
const data_abort_current_el = 0x25;
const write_not_read: u64 = 1 << 6;
const fault_status_mask = 0x3f;
const translation_fault_first = 0x04;
const translation_fault_last = 0x07;
const permission_fault_level_three = 0x0f;
const user_image_names = [process.count][]const u8{ "USER1.ELF", "USER2.ELF" };

comptime {
    _ = boot_scene;
    _ = framebuffer;
}

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
var physical_allocator: physical_memory.Allocator = undefined;
var virtio_mmio_bases: [fdt.max_ranges]u64 = undefined;
var virtio_mmio_count: usize = 0;
var identity_map: mmu.IdentityMap = .{};
var high_half_map: mmu.IdentityMap = .{};
var expected_mmu_probe: MmuProbe = .none;
var completed_mmu_probe: MmuProbe = .none;
var floating_point_probe_expected = false;
var floating_point_probe_completed = false;
var kernel_scheduler: scheduler.Scheduler = .{};
var scheduling_enabled = false;
var scheduling_phase: u8 = cooperative_phase;
var cooperative_progress: [scheduler.task_count]usize = @splat(0);
var preemptive_progress: [scheduler.task_count]usize = @splat(0);
var processes: [process.count]process.Process align(mmu.page_size) linksection(if (builtin.target.ofmt == .macho) "__DATA,__process_bss" else ".process.bss") = @splat(.{});
var storage_file_buffer: [process.image_size]u8 align(mmu.page_size) = undefined;

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
extern fn floatingPointProbe() callconv(.c) void;
extern fn mmuEnterHighHalf(continuation: u64, vector_base: u64, stack_top: u64) callconv(.c) noreturn;

comptime {
    if (!builtin.is_test) {
        @export(&kernelMain, .{ .name = "kernelMain" });
        @export(&exceptionHandler, .{ .name = "exceptionHandler" });
    }
}

fn kernelMain(dtb: usize, entry_el: usize, mpidr: usize) callconv(.c) noreturn {
    uart.init();
    KernelConsole.writeBootFacts(
        dtb,
        entry_el,
        mpidr,
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_start),
        if (builtin.is_test) 0 else @intFromPtr(&__kernel_end),
    );
    initializeMemory(dtb);
    if (comptime build_options.graphics_enabled) initializeGraphics();
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

    if (builtin.cpu.arch == .aarch64) verifyFloatingPointTrap();
    if (builtin.cpu.arch == .aarch64 and uart.supports_timer_interrupts) {
        runScheduler();
    }
    KernelConsole.write("BOOT:OK\n");
    halt();
}

fn verifyFloatingPointTrap() void {
    exceptions.disableFloatingPoint();
    floating_point_probe_expected = true;
    floating_point_probe_completed = false;
    floatingPointProbe();
    if (floating_point_probe_expected or !floating_point_probe_completed) schedulerFailed();
    KernelConsole.write("FP:TRAP\n");
}

fn runScheduler() noreturn {
    cooperative_progress = @splat(0);
    preemptive_progress = @splat(0);
    for (&processes) |*item| {
        @atomicStore(usize, item.progressPointer(), 0, .release);
        @atomicStore(usize, item.ticksPointer(), 0, .release);
        @atomicStore(usize, item.identityPointer(), 0, .release);
        item.started = 0;
        item.exited = 0;
        item.exit_status = 0;
        item.heap_pages_committed = 0;
        item.preemptions = 0;
        item.expected_fault = .none;
        item.stack_pointer = process.stack_address + process.stack_pages * mmu.page_size;
    }
    @atomicStore(u8, &scheduling_phase, cooperative_phase, .release);
    kernel_scheduler.init(
        highMappedAddress(@intFromPtr(&schedulerTask)),
        scheduler_initial_spsr,
    );
    uart.gic.init();
    scheduling_enabled = true;
    KernelConsole.writeHex("USER:ABI_VERSION=", syscall.abi_version);
    KernelConsole.write("SCHED:START\n");
    asm volatile ("svc #0" ::: .{ .memory = true });
    schedulerFailed();
}

fn schedulerTask(task_id: usize) callconv(.c) noreturn {
    if (task_id >= scheduler.task_count) schedulerFailed();

    while (@atomicLoad(u8, &scheduling_phase, .acquire) == cooperative_phase) {
        _ = @atomicRmw(usize, &cooperative_progress[task_id], .Add, 1, .acq_rel);
        if (cooperativeProgressComplete()) {
            const expected_switches = cooperative_progress_limit * scheduler.task_count - 1;
            if (kernel_scheduler.cooperativeSwitches() != expected_switches) schedulerFailed();
            KernelConsole.writeHex("SCHED:COOPERATIVE_SWITCHES=", expected_switches);
            KernelConsole.write("SCHED:COOPERATIVE_OK\n");
            @atomicStore(u8, &scheduling_phase, preemptive_phase, .release);
            timer.init(timer_tick_limit);
            break;
        }
        schedulerYield();
    }

    if (task_id >= process.first_task) enterUserMode();

    var previous_ticks = timer.ticks();
    while (true) {
        const progress = @atomicLoad(usize, &preemptive_progress[task_id], .acquire);
        if (progress < preemptive_progress_limit) {
            _ = @atomicRmw(usize, &preemptive_progress[task_id], .Add, 1, .acq_rel);
        }
        const current_ticks = timer.ticks();
        if (current_ticks < previous_ticks) schedulerFailed();
        previous_ticks = current_ticks;
        if (current_ticks >= timer_tick_limit) {
            if (preemptiveProgressComplete()) finishScheduler();
            schedulerFailed();
        }
    }
}

fn schedulerYield() void {
    asm volatile ("svc #0" ::: .{ .memory = true });
}

fn enterUserMode() noreturn {
    asm volatile ("svc #1" ::: .{ .memory = true });
    schedulerFailed();
}

fn currentProcessIndex() ?usize {
    const task = kernel_scheduler.currentTask() orelse return null;
    if (task < process.first_task or task >= process.first_task + process.count) return null;
    return task - process.first_task;
}

fn currentProcess() ?*process.Process {
    const index = currentProcessIndex() orelse return null;
    return &processes[index];
}

fn dispatchTask(frame: *exceptions.Frame, reason: scheduler.Reason) *exceptions.Frame {
    saveCurrentUserStack();
    const next = kernel_scheduler.dispatch(frame, reason) catch schedulerFailed();
    switchToCurrentTask();
    return next;
}

fn blockCurrentTask(frame: *exceptions.Frame) *exceptions.Frame {
    saveCurrentUserStack();
    const next = kernel_scheduler.blockCurrent(frame) catch schedulerFailed();
    switchToCurrentTask();
    return next;
}

fn switchToCurrentTask() void {
    if (currentProcess()) |item| {
        mmu.switchLowRoot(item.root_physical);
        exceptions.setUserStackPointer(item.stack_pointer);
    } else {
        mmu.switchLowRoot(physicalMappedAddress(identity_map.rootAddress()));
    }
}

fn saveCurrentUserStack() void {
    if (currentProcess()) |item| {
        if (item.started != 0 and item.exited == 0) item.stack_pointer = exceptions.userStackPointer();
    }
}

fn cooperativeProgressComplete() bool {
    for (&cooperative_progress) |*progress| {
        if (@atomicLoad(usize, progress, .acquire) < cooperative_progress_limit) return false;
    }
    return true;
}

fn preemptiveProgressComplete() bool {
    for (0..process.first_task) |task| {
        if (@atomicLoad(usize, &preemptive_progress[task], .acquire) < preemptive_progress_limit) return false;
    }
    for (&processes) |*item| {
        if (item.exited == 0 or
            @atomicLoad(usize, item.progressPointer(), .acquire) != preemptive_progress_limit)
        {
            return false;
        }
    }
    return true;
}

fn finishScheduler() noreturn {
    disableInterrupts();
    if (unexpected_interrupts != 0 or
        timer.ticks() != timer_tick_limit or
        kernel_scheduler.preemptions() != timer_tick_limit)
    {
        schedulerFailed();
    }
    for (0..process.first_task) |task| {
        if (@atomicLoad(usize, &preemptive_progress[task], .acquire) != preemptive_progress_limit or
            kernel_scheduler.preemptiveDispatches(task) == 0)
        {
            schedulerFailed();
        }
    }
    for (&processes, 0..) |*item, index| {
        const task = process.first_task + index;
        if (item.started == 0 or
            item.exited == 0 or
            item.exit_status != 0 or
            item.heap_pages_committed != 1 or
            item.preemptions == 0 or
            item.expected_fault != .none or
            @atomicLoad(usize, item.progressPointer(), .acquire) != preemptive_progress_limit or
            @atomicLoad(usize, item.ticksPointer(), .acquire) < user_tick_target or
            @atomicLoad(usize, item.identityPointer(), .acquire) != index + 1 or
            item.heapIdentityPointer().* != index + 1 or
            kernel_scheduler.preemptiveDispatches(task) == 0)
        {
            schedulerFailed();
        }
    }

    KernelConsole.writeHex("TIMER:TICKS=", timer.ticks());
    KernelConsole.write("TIMER:MONOTONIC\n");
    KernelConsole.write("IRQ:OK\n");
    KernelConsole.writeHex("SCHED:TASK0_PROGRESS=", preemptive_progress[0]);
    KernelConsole.writeHex("SCHED:TASK1_PROGRESS=", @atomicLoad(usize, processes[0].progressPointer(), .acquire));
    KernelConsole.writeHex("SCHED:TASK2_PROGRESS=", @atomicLoad(usize, processes[1].progressPointer(), .acquire));
    KernelConsole.writeHex("PROCESS1:PREEMPTIONS=", processes[0].preemptions);
    KernelConsole.writeHex("PROCESS2:PREEMPTIONS=", processes[1].preemptions);
    KernelConsole.writeHex("SCHED:PREEMPTIONS=", kernel_scheduler.preemptions());
    KernelConsole.write("SCHED:PREEMPTIVE_OK\n");
    KernelConsole.write("PROCESS:ISOLATION_OK\n");
    KernelConsole.write("ELF:OK\n");
    KernelConsole.write("USER:SYSCALLS_OK\n");
    KernelConsole.write("USER:OK\n");
    KernelConsole.write("SCHED:OK\n");
    KernelConsole.write("PHASE9:OK\n");
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

    // Restore the same reserved state after preserving the exhaustive sweep
    // evidence, so early device drivers can retain page-backed DMA memory.
    physical_allocator = physical_memory.Allocator.init(&frame_bitmap, info.ram[0..info.ram_count]) catch memoryFailed();
    for (info.reservations[0..info.reservation_count]) |range| physical_allocator.reserve(range) catch memoryFailed();
    physical_allocator.reserve(.{ .address = dtb_address, .size = total_size }) catch memoryFailed();
    physical_allocator.reserve(.{ .address = kernel_start, .size = kernel_end - kernel_start }) catch memoryFailed();
    virtio_mmio_count = info.virtio_mmio_count;
    for (info.virtio_mmio[0..info.virtio_mmio_count], 0..) |range, index| {
        virtio_mmio_bases[index] = range.address;
    }
}

fn initializeGraphics() void {
    KernelConsole.write(boot_scene.markers.init ++ "\n");
    const surface = uart.gpu.initialize(&physical_allocator, virtio_mmio_bases[0..virtio_mmio_count]) catch {
        KernelConsole.write(boot_scene.markers.failed ++ "\n");
        return;
    };
    const display = framebuffer.Framebuffer{ .bytes = surface.bytes, .width = framebuffer.preferred_width, .height = framebuffer.preferred_height, .pitch = framebuffer.preferred_width * 4, .format = .xrgb8888 };
    const renderer = framebuffer.Renderer.init(display) catch {
        KernelConsole.write(boot_scene.markers.failed ++ "\n");
        return;
    };
    boot_scene.render(renderer);
    surface.presentFn(0, 0, display.width, display.height) catch {
        KernelConsole.write(boot_scene.markers.failed ++ "\n");
        return;
    };
    KernelConsole.write(boot_scene.markers.qemu_ok ++ "\n");
}

fn initializeMmu() noreturn {
    const text_start: u64 = @intFromPtr(&__text_start);
    const text_end: u64 = @intFromPtr(&__text_end);
    const rodata_start: u64 = @intFromPtr(&__rodata_start);
    const rodata_end: u64 = @intFromPtr(&__rodata_end);
    const data_start: u64 = @intFromPtr(&__data_start);
    const kernel_end: u64 = @intFromPtr(&__kernel_end);

    loadProcessesFromInitramfs();
    if (uart.supports_block_device) loadProcessesFromFat();
    for (&processes) |*item| {
        for (uart.mmio_regions) |region| {
            item.address_space.map(region.start, region.end, .device_read_write) catch mmuFailed();
        }
    }

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

fn loadProcessesFromInitramfs() void {
    const archive = cpio.Archive.init(&embedded_users.initramfs);
    if ((archive.find("MISSING") catch storageFailed()) != null) storageFailed();
    for (&processes, user_image_names) |*item, name| {
        const bytes = (archive.find(name) catch storageFailed()) orelse storageFailed();
        item.load(bytes) catch storageFailed();
    }
    KernelConsole.writeHex("INITRAMFS:FILES=", process.count);
    KernelConsole.write("INITRAMFS:OK\n");
}

fn loadProcessesFromFat() void {
    uart.block.initialize() catch storageFailed();
    const device: block_device.BlockDevice = .{
        .context = uart.block.context(),
        .readBlocks = uart.block.readBlocks,
        .block_size = uart.block.sector_size,
        .block_count = uart.block.blockCount(),
    };
    const file_system = fat.FileSystem.mount(device) catch storageFailed();
    if (file_system.fat_type != .fat16) storageFailed();
    const archive = cpio.Archive.init(&embedded_users.initramfs);

    KernelConsole.writeHex("BLOCK:SECTORS=", device.block_count);
    KernelConsole.write(uart.block.ready_marker);
    for (&processes, user_image_names) |*item, name| {
        const bytes = file_system.readFile(name, &storage_file_buffer) catch storageFailed();
        const initramfs_bytes = (archive.find(name) catch storageFailed()) orelse storageFailed();
        if (!equalStorageBytes(bytes, initramfs_bytes)) storageFailed();
        item.load(bytes) catch storageFailed();
    }
    KernelConsole.writeHex("FAT:FILES=", process.count);
    KernelConsole.write("FAT:IMAGES_MATCH\n");
    KernelConsole.write("FAT:OK\n");
}

fn equalStorageBytes(first: []const u8, second: []const u8) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (left != right) return false;
    }
    return true;
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
    if (identity_map.descriptor(process.image_address) != null or
        processes[0].entry != process.image_address or
        processes[1].entry != process.image_address or
        processes[0].root_physical == processes[1].root_physical or
        @intFromPtr(&processes[0].memory) == @intFromPtr(&processes[1].memory) or
        processes[0].address_space.descriptor(process.image_address) == null or
        processes[1].address_space.descriptor(process.image_address) == null or
        processes[0].address_space.descriptor(process.data_address) == null or
        processes[1].address_space.descriptor(process.data_address) == null or
        processes[0].address_space.descriptor(process.data_address) ==
            processes[1].address_space.descriptor(process.data_address) or
        processes[0].address_space.descriptor(process.heap_address) != null or
        processes[1].address_space.descriptor(process.heap_address) != null)
    {
        mmuFailed();
    }

    KernelConsole.write("ELF:LOADED\n");
    KernelConsole.writeHex("ELF:IMAGES=", process.count);
    KernelConsole.writeHex("PROCESS:VIRTUAL_ENTRY=", process.image_address);
    KernelConsole.writeHex("PROCESS:VIRTUAL_DATA=", process.data_address);
    KernelConsole.write("PROCESS:DISTINCT_ROOTS\n");
    KernelConsole.write("PROCESS:DISTINCT_BACKING\n");
    KernelConsole.write("PROCESS:ADDRESS_SPACES_OK\n");
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

fn storageFailed() noreturn {
    KernelConsole.write("STORAGE:FAILED\n");
    halt();
}

fn mmuFailed() noreturn {
    KernelConsole.write("MMU:FAILED\n");
    halt();
}

fn schedulerFailed() noreturn {
    if (builtin.cpu.arch == .aarch64) disableInterrupts();
    KernelConsole.write("SCHED:FAILED\n");
    halt();
}

fn exceptionHandler(
    vector: usize,
    frame: *exceptions.Frame,
) callconv(.c) *exceptions.Frame {
    if (builtin.cpu.arch == .aarch64 and uart.supports_timer_interrupts and (vector == 5 or vector == 9)) {
        return handleIrq(vector, frame);
    }
    if (handleMmuProbe(vector, frame)) return frame;
    if (handleFloatingPointProbe(vector, frame)) return frame;
    if (handleUserFault(vector, frame)) return frame;
    if (builtin.cpu.arch == .aarch64 and
        uart.supports_timer_interrupts and
        scheduling_enabled and
        exceptions.class(frame.esr) == exceptions.supervisor_call_class)
    {
        if (vector == 4) return handleKernelSupervisorCall(frame);
        if (vector == 8) return handleUserSyscall(frame);
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
        return frame;
    }

    KernelConsole.write("EXCEPTION:UNHANDLED\n");
    halt();
}

fn handleKernelSupervisorCall(frame: *exceptions.Frame) *exceptions.Frame {
    const immediate = frame.esr & 0xffff;
    if (immediate == 0) {
        return dispatchTask(frame, .cooperative);
    }
    const item = currentProcess() orelse schedulerFailed();
    if (immediate != 1 or
        @atomicLoad(u8, &scheduling_phase, .acquire) != preemptive_phase or
        item.started != 0)
    {
        schedulerFailed();
    }

    exceptions.setUserStackPointer(item.stack_pointer);
    frame.registers = @splat(0);
    frame.elr = item.entry;
    frame.spsr = user_initial_spsr;
    frame.esr = 0;
    frame.far = 0;
    item.started = 1;
    item.expected_fault = .uart;
    KernelConsole.writeHex("PROCESS:ENTER_EL0=", currentProcessIndex().? + 1);
    return frame;
}

fn handleUserSyscall(frame: *exceptions.Frame) *exceptions.Frame {
    const item = currentProcess() orelse schedulerFailed();
    if (item.started == 0 or item.exited != 0) schedulerFailed();
    const number = if (frame.esr & 0xffff == 0) syscall.decode(frame.registers[8]) else null;
    const decoded = number orelse {
        frame.registers[0] = syscall.errorResult(.invalid_syscall);
        KernelConsole.writeHex("PROCESS:BAD_SYSCALL_REJECTED=", currentProcessIndex().? + 1);
        return frame;
    };
    switch (decoded) {
        .write => {
            const address = frame.registers[0];
            const length = frame.registers[1];
            if (length == 0) {
                frame.registers[0] = 0;
                return frame;
            }
            if (length > max_user_write or !isUserReadable(item, address, length)) {
                frame.registers[0] = syscall.errorResult(.invalid_address);
                KernelConsole.writeHex("PROCESS:BAD_POINTER_REJECTED=", currentProcessIndex().? + 1);
                return frame;
            }
            const bytes: [*]const u8 = @ptrFromInt(address);
            KernelConsole.write(bytes[0..@intCast(length)]);
            frame.registers[0] = length;
            return frame;
        },
        .yield => {
            frame.registers[0] = 0;
            KernelConsole.writeHex("PROCESS:YIELD=", currentProcessIndex().? + 1);
            return dispatchTask(frame, .cooperative);
        },
        .exit => {
            item.exit_status = frame.registers[0];
            item.exited = 1;
            KernelConsole.writeHex("PROCESS:EXIT=", currentProcessIndex().? + 1);
            return blockCurrentTask(frame);
        },
        .grow => {
            const requested_pages = frame.registers[0];
            if (heapGrowthError(item.heap_pages_committed, requested_pages)) |growth_error| {
                frame.registers[0] = syscall.errorResult(growth_error);
                if (growth_error == .out_of_memory) {
                    KernelConsole.writeHex("PROCESS:HEAP_LIMIT_ENFORCED=", currentProcessIndex().? + 1);
                }
                return frame;
            }
            const previous_break = process.heap_address + item.heap_pages_committed * mmu.page_size;
            const physical_heap = physicalMappedAddress(@intFromPtr(&item.memory.heap)) +
                item.heap_pages_committed * mmu.page_size;
            item.address_space.mapAt(
                previous_break,
                physical_heap,
                requested_pages * mmu.page_size,
                .user_read_write,
            ) catch schedulerFailed();
            item.heap_pages_committed += @intCast(requested_pages);
            mmu.invalidateAll();
            frame.registers[0] = previous_break;
            KernelConsole.writeHex("PROCESS:HEAP_PAGES=", item.heap_pages_committed);
            KernelConsole.writeHex("PROCESS:GROW=", currentProcessIndex().? + 1);
            return frame;
        },
    }
}

fn heapGrowthError(committed_pages: usize, requested_pages: u64) ?syscall.ErrorCode {
    if (requested_pages == 0) return .invalid_argument;
    if (committed_pages > process.heap_pages or requested_pages > process.heap_pages - committed_pages) {
        return .out_of_memory;
    }
    return null;
}

fn isUserReadable(item: *const process.Process, address: u64, length: u64) bool {
    if (length == 0) return true;
    if (address > std.math.maxInt(u64) - length) return false;
    const end = address + length;
    const allowed = rangeContains(process.image_address, process.image_size, address, end) or
        rangeContains(process.data_address, process.data_pages * mmu.page_size, address, end) or
        rangeContains(process.stack_address, process.stack_pages * mmu.page_size, address, end) or
        rangeContains(
            process.heap_address,
            item.heap_pages_committed * mmu.page_size,
            address,
            end,
        );
    if (!allowed) return false;
    var page = address & ~@as(u64, mmu.page_size - 1);
    while (page < end) : (page += mmu.page_size) {
        if (item.address_space.descriptor(page) == null) return false;
    }
    return true;
}

fn rangeContains(base: u64, size: u64, start: u64, end: u64) bool {
    return start >= base and end <= base + size;
}

fn handleUserFault(vector: usize, frame: *exceptions.Frame) bool {
    const item = currentProcess() orelse return false;
    if (item.started == 0 or
        item.exited != 0 or
        vector != 8 or
        exceptions.class(frame.esr) != data_abort_lower_el or
        frame.esr & write_not_read != 0)
    {
        return false;
    }

    const fault_status = frame.esr & fault_status_mask;
    switch (item.expected_fault) {
        .none => return false,
        .uart => {
            if (frame.far != 0x0900_0000 or fault_status != permission_fault_level_three) return false;
            item.expected_fault = .kernel;
            KernelConsole.writeHex("PROCESS:UART_DENIED=", currentProcessIndex().? + 1);
        },
        .kernel => {
            if (frame.far != physicalMappedAddress(@intFromPtr(&__kernel_start)) or
                fault_status < translation_fault_first or
                fault_status > translation_fault_last)
            {
                return false;
            }
            item.expected_fault = .none;
            KernelConsole.writeHex("PROCESS:KERNEL_DENIED=", currentProcessIndex().? + 1);
        },
    }
    frame.elr += 4;
    return true;
}

fn handleFloatingPointProbe(vector: usize, frame: *exceptions.Frame) bool {
    if (!floating_point_probe_expected or
        vector != 4 or
        exceptions.class(frame.esr) != exceptions.fp_access_trap_class)
    {
        return false;
    }
    frame.elr += 4;
    floating_point_probe_expected = false;
    floating_point_probe_completed = true;
    return true;
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

fn handleIrq(vector: usize, frame: *exceptions.Frame) *exceptions.Frame {
    const acknowledgement = uart.gic.acknowledge();
    const interrupt_id = uart.gic.interruptId(acknowledgement);
    if (interrupt_id == uart.gic.physical_timer_interrupt) {
        timer.handleInterrupt();
        if (vector == 9) {
            const item = currentProcess() orelse schedulerFailed();
            item.preemptions += 1;
        }
        for (&processes) |*item| {
            if (item.started != 0 and item.exited == 0) {
                @atomicStore(usize, item.ticksPointer(), timer.ticks(), .release);
            }
        }
        uart.gic.end(acknowledgement);
        if (scheduling_enabled) {
            return dispatchTask(frame, .preemptive);
        }
    } else if (interrupt_id < uart.gic.first_special_interrupt) {
        _ = @atomicRmw(usize, &unexpected_interrupts, .Add, 1, .monotonic);
        uart.gic.end(acknowledgement);
    }
    return frame;
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
    _ = block_device;
    _ = cpio;
    _ = exceptions;
    _ = elf;
    _ = fat;
    _ = fdt;
    _ = mmu;
    _ = physical_memory;
    _ = process;
    _ = scheduler;
    _ = syscall;
    _ = timer;
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

test "user-readable ranges reject overflow and uncommitted heap pages" {
    const item = &processes[0];
    item.address_space = .{};
    item.heap_pages_committed = 1;
    defer {
        item.address_space = .{};
        item.heap_pages_committed = 0;
    }
    try item.address_space.mapAt(process.image_address, 0x1000, mmu.page_size, .user_read_execute);
    try item.address_space.mapAt(process.heap_address, 0x2000, mmu.page_size, .user_read_write);

    try std.testing.expect(isUserReadable(item, process.image_address, mmu.page_size));
    try std.testing.expect(isUserReadable(item, process.heap_address, mmu.page_size));
    try std.testing.expect(!isUserReadable(item, process.image_address + mmu.page_size - 1, 2));
    try std.testing.expect(!isUserReadable(item, process.heap_address + mmu.page_size, 1));
    try std.testing.expect(!isUserReadable(item, std.math.maxInt(u64), 2));
}

test "heap growth is nonzero and bounded by its fixed window" {
    try std.testing.expectEqual(syscall.ErrorCode.invalid_argument, heapGrowthError(0, 0).?);
    try std.testing.expectEqual(null, heapGrowthError(0, process.heap_pages));
    try std.testing.expectEqual(syscall.ErrorCode.out_of_memory, heapGrowthError(1, process.heap_pages).?);
    try std.testing.expectEqual(syscall.ErrorCode.out_of_memory, heapGrowthError(process.heap_pages + 1, 1).?);
}

test "embedded user programs are loadable AArch64 ELF images" {
    for ([_][]const u8{ &embedded_users.one, &embedded_users.two }) |bytes| {
        const image = try elf.parse(bytes);
        try std.testing.expectEqual(process.image_address, image.entry);
        try std.testing.expect(image.program_header_count >= 2);
    }
}

test "generated initramfs contains both embedded user programs" {
    const archive = cpio.Archive.init(&embedded_users.initramfs);
    try std.testing.expect((try archive.find("MISSING")) == null);
    try std.testing.expectEqualSlices(u8, &embedded_users.one, (try archive.find("USER1.ELF")).?);
    try std.testing.expectEqualSlices(u8, &embedded_users.two, (try archive.find("USER2.ELF")).?);
}

test "embedded user programs load into independent address spaces" {
    const first = &processes[0];
    const second = &processes[1];
    defer {
        first.address_space = .{};
        second.address_space = .{};
    }

    try first.load(&embedded_users.one);
    try second.load(&embedded_users.two);

    try std.testing.expectEqual(process.image_address, first.entry);
    try std.testing.expectEqual(first.entry, second.entry);
    try std.testing.expect(first.root_physical != second.root_physical);
    try std.testing.expect(@intFromPtr(&first.memory) != @intFromPtr(&second.memory));
    try std.testing.expect(
        first.address_space.descriptor(process.data_address) !=
            second.address_space.descriptor(process.data_address),
    );
}

test "process loader rejects unsupported permissions, windows, and overlaps" {
    const image = try elf.parse(&embedded_users.one);
    const program_header = image.program_header_offset;
    const first_segment = try image.segment(0);
    try std.testing.expectEqual(elf.load_segment, first_segment.segment_type);
    defer processes[0].address_space = .{};

    var unsupported_permissions = embedded_users.one;
    std.mem.writeInt(
        u32,
        unsupported_permissions[program_header + 4 ..][0..4],
        elf.flag_read | elf.flag_write | elf.flag_execute,
        .little,
    );
    try std.testing.expectError(
        error.UnsupportedPermissions,
        processes[0].load(&unsupported_permissions),
    );

    var outside_window = embedded_users.one;
    std.mem.writeInt(
        u64,
        outside_window[program_header + 16 ..][0..8],
        process.image_address - first_segment.alignment,
        .little,
    );
    try std.testing.expectError(
        error.SegmentOutsideWindow,
        processes[0].load(&outside_window),
    );

    const second_program_header = program_header + image.program_header_size;
    var overlapping_segments = embedded_users.one;
    std.mem.writeInt(
        u64,
        overlapping_segments[second_program_header + 8 ..][0..8],
        first_segment.file_offset,
        .little,
    );
    std.mem.writeInt(
        u64,
        overlapping_segments[second_program_header + 16 ..][0..8],
        first_segment.virtual_address,
        .little,
    );
    try std.testing.expectError(
        error.InvalidSegment,
        processes[0].load(&overlapping_segments),
    );
}
