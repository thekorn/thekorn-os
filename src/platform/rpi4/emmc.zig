//! Polling, read-only SD card driver for BCM2711 EMMC2.
//!
//! The Pi 4 routes its onboard microSD slot through the SDHCI-compatible
//! EMMC2 controller. This driver deliberately stays at 3.3 V, one-bit bus
//! width, and default speed. It exposes the card image's second MBR partition,
//! which contains the deterministic FAT16 user-program filesystem.

const std = @import("std");

pub const base = 0xfe34_0000;
pub const sector_size = 512;
pub const ready_marker = "EMMC2:OK\n";
pub const ReadError = error{
    InvalidBuffer,
    OutOfBounds,
    IoFailure,
};

const mailbox_base = 0xfe00_b880;
const mailbox_read = mailbox_base + 0x00;
const mailbox_status = mailbox_base + 0x18;
const mailbox_write = mailbox_base + 0x20;
const mailbox_write_status = mailbox_base + 0x38;
const mailbox_empty: u32 = 1 << 30;
const mailbox_full: u32 = 1 << 31;
const property_channel: u32 = 8;
const get_clock_rate: u32 = 0x0003_0002;
const emmc2_clock_id: u32 = 12;

const block_size_count = 0x04;
const argument = 0x08;
const transfer_command = 0x0c;
const response_0 = 0x10;
const buffer_data = 0x20;
const present_state = 0x24;
const host_power_control = 0x28;
const clock_timeout_reset = 0x2c;
const interrupt_status = 0x30;
const interrupt_enable = 0x34;
const interrupt_signal_enable = 0x38;
const host_control_2 = 0x3c;

const command_inhibit: u32 = 1 << 0;
const data_inhibit: u32 = 1 << 1;
const clock_internal_enable: u32 = 1 << 0;
const clock_internal_stable: u32 = 1 << 1;
const clock_card_enable: u32 = 1 << 2;
const clock_divider_mask: u32 = 0xffc0;
const timeout_maximum: u32 = 0xe << 16;
const reset_all: u32 = 1 << 24;
const reset_command: u32 = 1 << 25;
const reset_data: u32 = 1 << 26;

const interrupt_command_complete: u32 = 1 << 0;
const interrupt_transfer_complete: u32 = 1 << 1;
const interrupt_buffer_read_ready: u32 = 1 << 5;
const interrupt_error: u32 = 1 << 15;
const interrupt_error_mask: u32 = 0xffff_0000 | interrupt_error;
const enabled_interrupts = interrupt_error_mask |
    interrupt_command_complete |
    interrupt_transfer_complete |
    interrupt_buffer_read_ready;

const transfer_block_count_enable: u16 = 1 << 1;
const transfer_read: u16 = 1 << 4;

const response_none: u16 = 0;
const response_long: u16 = 1;
const response_short: u16 = 2;
const response_short_busy: u16 = 3;
const command_crc_check: u16 = 1 << 3;
const command_index_check: u16 = 1 << 4;
const command_data_present: u16 = 1 << 5;

const ocr_ready: u32 = 1 << 31;
const ocr_high_capacity: u32 = 1 << 30;
const r1_application_command: u32 = 1 << 5;
const r1_error_mask: u32 = 0xfdff_e008;
const r6_error_mask: u32 = (1 << 15) | (1 << 14) | (1 << 13);
const card_state_mask: u32 = 0xf << 9;
const card_state_standby: u32 = 3 << 9;
const user_partition_type: u8 = 0x0e;

const DriverError = error{
    Timeout,
    MailboxFailure,
    UnsupportedCard,
    InvalidResponse,
    CommandFailure,
    DataFailure,
    UserPartitionNotFound,
};

const Partition = struct {
    start: u32,
    count: u32,
};

const State = struct {
    base_clock_hz: u32 = 0,
    relative_card_address: u16 = 0,
    partition: Partition = .{ .start = 0, .count = 0 },
    slow_clock: bool = true,
    control_1: u32 = 0,
};

const ClockMessage = extern struct {
    size: u32,
    code: u32,
    tag: u32,
    value_size: u32,
    value_length: u32,
    clock_id: u32,
    rate_hz: u32,
    end: u32,
};

var state: State = .{};
var clock_message: ClockMessage align(64) = undefined;

pub fn initialize() DriverError!void {
    state = .{};
    state.base_clock_hz = try queryBaseClock();

    writeRegister(interrupt_signal_enable, 0);
    try resetHost();

    // Clear 1.8 V signaling and enable 3.3 V SD bus power. BCM2711 EMMC2
    // requires 32-bit accesses even for packed byte and half-word registers.
    writeRegister(host_control_2, readRegister(host_control_2) & ~@as(u32, 1 << 19));
    writeRegister(host_power_control, 0x0000_0f00);
    writeRegister(interrupt_status, 0xffff_ffff);
    writeRegister(interrupt_enable, enabled_interrupts);
    try setClock(400_000);
    delayMicros(1_000);

    _ = try sendCommand(0, 0, response_none, false, 0);
    delayMicros(2_000);
    const interface_condition = try sendCommand(
        8,
        0x0000_01aa,
        response_short | command_crc_check | command_index_check,
        false,
        0,
    );
    if (interface_condition & 0xfff != 0x1aa) return error.UnsupportedCard;

    const negotiation_start = counter();
    var operating_conditions: u32 = 0;
    while (true) {
        const application = try sendCommand(
            55,
            0,
            response_short | command_crc_check | command_index_check,
            false,
            0,
        );
        if (application & r1_application_command == 0 or application & r1_error_mask != 0) {
            return error.InvalidResponse;
        }
        operating_conditions = try sendCommand(
            41,
            0x40ff_8000,
            response_short,
            false,
            0,
        );
        if (operating_conditions & ocr_ready != 0) break;
        if (timedOut(negotiation_start, 2_000)) return error.Timeout;
        delayMicros(10_000);
    }
    if (operating_conditions & ocr_high_capacity == 0) return error.UnsupportedCard;

    _ = try sendCommand(2, 0, response_long | command_crc_check, false, 0);
    const relative_address = try sendCommand(
        3,
        0,
        response_short | command_crc_check | command_index_check,
        false,
        0,
    );
    if (relative_address & r6_error_mask != 0 or
        relative_address & card_state_mask != card_state_standby)
    {
        return error.InvalidResponse;
    }
    state.relative_card_address = @truncate(relative_address >> 16);
    if (state.relative_card_address == 0) return error.InvalidResponse;

    const selected = try sendCommand(
        7,
        @as(u32, state.relative_card_address) << 16,
        response_short_busy | command_crc_check | command_index_check,
        false,
        0,
    );
    if (selected & r1_error_mask != 0) return error.InvalidResponse;
    try setClock(25_000_000);

    var master_boot_record: [sector_size]u8 = undefined;
    try readRawSector(0, &master_boot_record);
    state.partition = try findUserPartition(&master_boot_record);
}

pub fn context() *anyopaque {
    return &state;
}

pub fn blockCount() u64 {
    return state.partition.count;
}

pub fn readBlocks(
    context_pointer: *anyopaque,
    first_block: u64,
    destination: []u8,
) ReadError!void {
    const device: *State = @ptrCast(@alignCast(context_pointer));
    var offset: usize = 0;
    var logical_block = first_block;
    while (offset < destination.len) : ({
        offset += sector_size;
        logical_block += 1;
    }) {
        const physical = std.math.add(u64, device.partition.start, logical_block) catch {
            return error.OutOfBounds;
        };
        if (physical > std.math.maxInt(u32)) return error.OutOfBounds;
        readRawSector(@intCast(physical), destination[offset..][0..sector_size]) catch {
            return error.IoFailure;
        };
    }
}

fn resetHost() DriverError!void {
    writeRegister(clock_timeout_reset, reset_all);
    const start = counter();
    while (readRegister(clock_timeout_reset) & reset_all != 0) {
        if (timedOut(start, 100)) return error.Timeout;
    }
    state.control_1 = timeout_maximum;
    writeRegister(clock_timeout_reset, state.control_1);
}

fn setClock(target_hz: u32) DriverError!void {
    state.control_1 &= ~(clock_internal_enable | clock_card_enable | clock_divider_mask);
    writeRegister(clock_timeout_reset, state.control_1);

    state.control_1 |= encodeDivider(state.base_clock_hz, target_hz) |
        clock_internal_enable;
    writeRegister(clock_timeout_reset, state.control_1);
    const start = counter();
    while (readRegister(clock_timeout_reset) & clock_internal_stable == 0) {
        if (timedOut(start, 100)) return error.Timeout;
    }
    state.control_1 |= clock_card_enable;
    writeRegister(clock_timeout_reset, state.control_1);
    state.slow_clock = target_hz <= 400_000;
}

fn encodeDivider(base_hz: u32, target_hz: u32) u32 {
    const denominator = @as(u64, target_hz) * 2;
    const rounded = (@as(u64, base_hz) + denominator - 1) / denominator;
    const divisor: u32 = @intCast(@min(@max(rounded, 1), 0x3ff));
    return ((divisor & 0xff) << 8) | ((divisor & 0x300) >> 2);
}

fn sendCommand(
    index: u6,
    command_argument: u32,
    flags: u16,
    data_command: bool,
    transfer_mode: u16,
) DriverError!u32 {
    try waitForInhibit(data_command);
    writeRegister(interrupt_status, 0xffff_ffff);
    writeRegister(argument, command_argument);
    const command: u16 = (@as(u16, index) << 8) | flags |
        (if (data_command) command_data_present else 0);
    writeRegister(transfer_command, @as(u32, transfer_mode) | (@as(u32, command) << 16));

    const start = counter();
    while (true) {
        const status = readRegister(interrupt_status);
        if (status & interrupt_error_mask != 0) {
            writeRegister(interrupt_status, status & (interrupt_error_mask | interrupt_command_complete));
            resetLines(reset_command | if (data_command) reset_data else 0) catch {};
            return error.CommandFailure;
        }
        if (status & interrupt_command_complete != 0) break;
        if (timedOut(start, 500)) {
            resetLines(reset_command | if (data_command) reset_data else 0) catch {};
            return error.Timeout;
        }
    }
    writeRegister(interrupt_status, interrupt_command_complete);
    const response = readRegister(response_0);
    if (flags & 0b11 == response_short_busy) try waitForBusy();
    return response;
}

fn waitForInhibit(data_command: bool) DriverError!void {
    const wanted = command_inhibit | if (data_command) data_inhibit else 0;
    const start = counter();
    while (readRegister(present_state) & wanted != 0) {
        if (timedOut(start, 500)) return error.Timeout;
    }
}

fn waitForBusy() DriverError!void {
    const start = counter();
    while (readRegister(present_state) & data_inhibit != 0) {
        const status = readRegister(interrupt_status);
        if (status & interrupt_error_mask != 0) return error.CommandFailure;
        if (timedOut(start, 500)) return error.Timeout;
    }
}

fn resetLines(lines: u32) DriverError!void {
    state.control_1 |= lines;
    writeRegister(clock_timeout_reset, state.control_1);
    const start = counter();
    while (readRegister(clock_timeout_reset) & lines != 0) {
        if (timedOut(start, 100)) return error.Timeout;
    }
    state.control_1 &= ~lines;
}

fn readRawSector(sector: u32, destination: *[sector_size]u8) DriverError!void {
    writeRegister(block_size_count, 0x0001_0200);
    const response = try sendCommand(
        17,
        sector,
        response_short | command_crc_check | command_index_check,
        true,
        transfer_block_count_enable | transfer_read,
    );
    if (response & r1_error_mask != 0) return error.InvalidResponse;

    const ready_start = counter();
    while (true) {
        const status = readRegister(interrupt_status);
        if (status & interrupt_error_mask != 0) {
            resetLines(reset_data) catch {};
            return error.DataFailure;
        }
        if (status & interrupt_buffer_read_ready != 0) break;
        if (timedOut(ready_start, 500)) return error.Timeout;
    }

    for (0..sector_size / 4) |word_index| {
        const word = readRegister(buffer_data);
        const byte_index = word_index * 4;
        destination[byte_index] = @truncate(word);
        destination[byte_index + 1] = @truncate(word >> 8);
        destination[byte_index + 2] = @truncate(word >> 16);
        destination[byte_index + 3] = @truncate(word >> 24);
    }
    writeRegister(interrupt_status, interrupt_buffer_read_ready);

    const complete_start = counter();
    while (true) {
        const status = readRegister(interrupt_status);
        if (status & interrupt_error_mask != 0) {
            resetLines(reset_data) catch {};
            return error.DataFailure;
        }
        if (status & interrupt_transfer_complete != 0) break;
        if (timedOut(complete_start, 500)) return error.Timeout;
    }
    writeRegister(interrupt_status, interrupt_transfer_complete);
}

fn findUserPartition(master_boot_record: *const [sector_size]u8) DriverError!Partition {
    if (master_boot_record[510] != 0x55 or master_boot_record[511] != 0xaa) {
        return error.UserPartitionNotFound;
    }
    for (0..4) |index| {
        const offset = 446 + index * 16;
        if (master_boot_record[offset + 4] != user_partition_type) continue;
        const start = little32(master_boot_record[offset + 8 ..][0..4]);
        const count = little32(master_boot_record[offset + 12 ..][0..4]);
        if (start == 0 or count == 0) return error.UserPartitionNotFound;
        _ = std.math.add(u32, start, count) catch return error.UserPartitionNotFound;
        return .{ .start = start, .count = count };
    }
    return error.UserPartitionNotFound;
}

fn queryBaseClock() DriverError!u32 {
    clock_message = .{
        .size = @sizeOf(ClockMessage),
        .code = 0,
        .tag = get_clock_rate,
        .value_size = 8,
        .value_length = 4,
        .clock_id = emmc2_clock_id,
        .rate_hz = 0,
        .end = 0,
    };
    const physical = @intFromPtr(&clock_message);
    if (physical >= 0x4000_0000 or physical & 0xf != 0) return error.MailboxFailure;
    const bus_address: u32 = @intCast(physical | 0xc000_0000);
    cacheClean(@intFromPtr(&clock_message));
    asm volatile ("dsb sy" ::: .{ .memory = true });

    var start = counter();
    while (readMmio(mailbox_write_status) & mailbox_full != 0) {
        if (timedOut(start, 100)) return error.Timeout;
    }
    writeMmio(mailbox_write, bus_address | property_channel);

    start = counter();
    while (true) {
        while (readMmio(mailbox_status) & mailbox_empty != 0) {
            if (timedOut(start, 100)) return error.Timeout;
        }
        const response = readMmio(mailbox_read);
        if (response == (bus_address | property_channel)) break;
        if (timedOut(start, 100)) return error.Timeout;
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });
    cacheInvalidate(@intFromPtr(&clock_message));
    asm volatile ("dsb sy" ::: .{ .memory = true });
    if (clock_message.code != 0x8000_0000 or
        clock_message.tag != get_clock_rate or
        clock_message.value_length & 0x8000_0000 == 0 or
        clock_message.value_length & 0x7fff_ffff < 8 or
        clock_message.clock_id != emmc2_clock_id or
        clock_message.rate_hz == 0)
    {
        return error.MailboxFailure;
    }
    return clock_message.rate_hz;
}

fn writeRegister(offset: usize, value: u32) void {
    writeMmio(base + offset, value);
    asm volatile ("dsb sy" ::: .{ .memory = true });
    if (state.slow_clock) delayMicros(10);
}

fn readRegister(offset: usize) u32 {
    return readMmio(base + offset);
}

fn readMmio(address: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn writeMmio(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

fn counter() u64 {
    return asm volatile ("mrs %[value], CNTPCT_EL0"
        : [value] "=r" (-> u64),
    );
}

fn counterFrequency() u64 {
    return asm volatile ("mrs %[value], CNTFRQ_EL0"
        : [value] "=r" (-> u64),
    );
}

fn timedOut(start: u64, milliseconds: u64) bool {
    const ticks = (counterFrequency() * milliseconds + 999) / 1_000;
    return counter() -% start >= ticks;
}

fn delayMicros(microseconds: u64) void {
    const start = counter();
    const ticks = (counterFrequency() * microseconds + 999_999) / 1_000_000;
    while (counter() -% start < ticks) asm volatile ("yield");
}

fn cacheClean(address: usize) void {
    asm volatile ("dc cvac, %[address]"
        :
        : [address] "r" (address),
        : .{ .memory = true });
}

fn cacheInvalidate(address: usize) void {
    asm volatile ("dc ivac, %[address]"
        :
        : [address] "r" (address),
        : .{ .memory = true });
}

fn little32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

test "divider encoding rounds down the resulting card clock" {
    try std.testing.expectEqual(@as(u32, 0x7d00), encodeDivider(100_000_000, 400_000));
    try std.testing.expectEqual(@as(u32, 0x0200), encodeDivider(100_000_000, 25_000_000));
    try std.testing.expectEqual(@as(u32, 0xffc0), encodeDivider(1_000_000_000, 100_000));
}

test "user partition parser accepts only a bounded FAT16 LBA entry" {
    var record: [sector_size]u8 = @splat(0);
    record[510] = 0x55;
    record[511] = 0xaa;
    record[446 + 16 + 4] = user_partition_type;
    record[446 + 16 + 8] = 0x00;
    record[446 + 16 + 9] = 0xe0;
    record[446 + 16 + 10] = 0x01;
    record[446 + 16 + 12] = 0x00;
    record[446 + 16 + 13] = 0x20;

    try std.testing.expectEqual(
        Partition{ .start = 122_880, .count = 8_192 },
        try findUserPartition(&record),
    );
    record[511] = 0;
    try std.testing.expectError(error.UserPartitionNotFound, findUserPartition(&record));
}
