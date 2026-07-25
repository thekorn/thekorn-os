//! AArch64 EL1 stage-1 translation support for a 4 KiB granule.
//!
//! Reference: Arm Architecture Reference Manual for A-profile architecture,
//! DDI 0487, "VMSAv8-64 translation table format descriptors."

const std = @import("std");

pub const page_size: usize = 4096;
pub const entries_per_table: usize = page_size / @sizeOf(u64);

pub const Table = struct {
    entries: [entries_per_table]u64 align(page_size) = @splat(0),
};

pub const Mapping = enum {
    normal_read_execute,
    normal_read_only,
    normal_read_write,
    device_read_write,
};

pub const DescriptorError = error{
    UnalignedAddress,
    AddressOutOfRange,
};

pub const MapError = DescriptorError || error{
    EmptyRange,
    TableCapacityExceeded,
    ConflictingMapping,
};

// Attr0 is Device-nGnRnE. Attr1 is normal, inner/outer write-back,
// non-transient, read-allocate, and write-allocate memory.
pub const mair_el1: u64 = @as(u64, 0xff) << 8;
const sctlr_enable_value: u64 = 0x30d0_0800 |
    (1 << 0) | // M: MMU enable.
    (1 << 2) | // C: data and unified cache enable.
    (1 << 3) | // SA: EL1 stack alignment check.
    (1 << 4) | // SA0: EL0 stack alignment check.
    (1 << 12) | // I: instruction cache enable.
    (1 << 19); // WXN: writable mappings cannot execute.

const descriptor_valid: u64 = 1 << 0;
const descriptor_table_or_page: u64 = 1 << 1;
const descriptor_type: u64 = descriptor_valid | descriptor_table_or_page;
const attribute_index_shift = 2;
const normal_attribute_index: u64 = 1 << attribute_index_shift;
const access_read_only: u64 = 0b10 << 6;
const outer_shareable: u64 = 0b10 << 8;
const inner_shareable: u64 = 0b11 << 8;
const access_flag: u64 = 1 << 10;
const privileged_execute_never: u64 = 1 << 53;
const unprivileged_execute_never: u64 = 1 << 54;
const output_address_mask: u64 = 0x0000_ffff_ffff_f000;
const page_offset_mask: u64 = page_size - 1;
const level_zero_shift = 39;
const level_one_shift = 30;
const level_two_shift = 21;
const level_three_shift = 12;
const max_level_two_tables = 4;
const max_level_three_tables = 16;
const table_index_mask = entries_per_table - 1;

const LevelThreeParent = struct {
    level_two_table: usize,
    entry: usize,
};

pub const IdentityMap = struct {
    root: Table = .{},
    level_one: Table = .{},
    level_two: [max_level_two_tables]Table = @splat(.{}),
    level_three: [max_level_three_tables]Table = @splat(.{}),
    root_entry: ?usize = null,
    level_two_entries: [max_level_two_tables]usize = undefined,
    level_two_count: usize = 0,
    level_three_parents: [max_level_three_tables]LevelThreeParent = undefined,
    level_three_count: usize = 0,

    pub fn map(self: *IdentityMap, start: u64, end: u64, mapping: Mapping) MapError!void {
        if (start == end) return error.EmptyRange;
        if (start > end) return error.AddressOutOfRange;
        if (start & page_offset_mask != 0 or end & page_offset_mask != 0) return error.UnalignedAddress;

        var address = start;
        while (address < end) : (address += page_size) try self.mapPage(address, mapping);
    }

    pub fn rootAddress(self: *const IdentityMap) u64 {
        return @intCast(@intFromPtr(&self.root));
    }

    pub fn descriptor(self: *const IdentityMap, address: u64) ?u64 {
        if (self.root_entry != tableIndex(address, level_zero_shift)) return null;
        const level_one_index = tableIndex(address, level_one_shift);
        const level_two_table = self.findLevelTwo(level_one_index) orelse return null;
        const level_two_entry = tableIndex(address, level_two_shift);
        const level_three_table = self.findLevelThree(level_two_table, level_two_entry) orelse return null;
        const descriptor_value = self.level_three[level_three_table].entries[tableIndex(address, level_three_shift)];
        return if (descriptor_value == 0) null else descriptor_value;
    }

    fn mapPage(self: *IdentityMap, address: u64, mapping: Mapping) MapError!void {
        _ = try encodeOutputAddress(address);
        try self.installLevelOne(tableIndex(address, level_zero_shift));
        const level_two_table = try self.getOrCreateLevelTwo(tableIndex(address, level_one_shift));
        const level_three_table = try self.getOrCreateLevelThree(
            level_two_table,
            tableIndex(address, level_two_shift),
        );
        const entry = &self.level_three[level_three_table].entries[tableIndex(address, level_three_shift)];
        const descriptor_value = try pageDescriptor(address, mapping);
        if (entry.* != 0 and entry.* != descriptor_value) return error.ConflictingMapping;
        entry.* = descriptor_value;
    }

    fn installLevelOne(self: *IdentityMap, entry: usize) MapError!void {
        if (self.root_entry) |existing| {
            if (existing != entry) return error.TableCapacityExceeded;
            return;
        }
        self.root.entries[entry] = try tableDescriptor(@intFromPtr(&self.level_one));
        self.root_entry = entry;
    }

    fn getOrCreateLevelTwo(self: *IdentityMap, entry: usize) MapError!usize {
        if (self.findLevelTwo(entry)) |index| return index;
        if (self.level_two_count == self.level_two.len) return error.TableCapacityExceeded;

        const index = self.level_two_count;
        self.level_two_entries[index] = entry;
        self.level_one.entries[entry] = try tableDescriptor(@intFromPtr(&self.level_two[index]));
        self.level_two_count += 1;
        return index;
    }

    fn getOrCreateLevelThree(
        self: *IdentityMap,
        level_two_table: usize,
        entry: usize,
    ) MapError!usize {
        if (self.findLevelThree(level_two_table, entry)) |index| return index;
        if (self.level_three_count == self.level_three.len) return error.TableCapacityExceeded;

        const index = self.level_three_count;
        self.level_three_parents[index] = .{ .level_two_table = level_two_table, .entry = entry };
        self.level_two[level_two_table].entries[entry] = try tableDescriptor(@intFromPtr(&self.level_three[index]));
        self.level_three_count += 1;
        return index;
    }

    fn findLevelTwo(self: *const IdentityMap, entry: usize) ?usize {
        for (self.level_two_entries[0..self.level_two_count], 0..) |candidate, index| {
            if (candidate == entry) return index;
        }
        return null;
    }

    fn findLevelThree(self: *const IdentityMap, level_two_table: usize, entry: usize) ?usize {
        for (self.level_three_parents[0..self.level_three_count], 0..) |candidate, index| {
            if (candidate.level_two_table == level_two_table and candidate.entry == entry) return index;
        }
        return null;
    }
};

pub fn tableDescriptor(next_table_address: u64) DescriptorError!u64 {
    return try encodeOutputAddress(next_table_address) | descriptor_type;
}

pub fn pageDescriptor(output_address: u64, mapping: Mapping) DescriptorError!u64 {
    const attributes: u64 = switch (mapping) {
        .normal_read_execute => normal_attribute_index |
            inner_shareable |
            access_read_only |
            unprivileged_execute_never,
        .normal_read_only => normal_attribute_index |
            inner_shareable |
            access_read_only |
            privileged_execute_never |
            unprivileged_execute_never,
        .normal_read_write => normal_attribute_index |
            inner_shareable |
            privileged_execute_never |
            unprivileged_execute_never,
        .device_read_write => outer_shareable |
            privileged_execute_never |
            unprivileged_execute_never,
    };
    return try encodeOutputAddress(output_address) |
        descriptor_type |
        access_flag |
        attributes;
}

pub fn enable(root_address: u64) void {
    const physical_address_range = asm volatile ("mrs %[value], ID_AA64MMFR0_EL1"
        : [value] "=r" (-> u64),
    ) & 0xf;
    const tcr_el1 = translationControl(@intCast(@min(physical_address_range, 5)));

    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("msr MAIR_EL1, %[value]"
        :
        : [value] "r" (mair_el1),
        : .{ .memory = true });
    asm volatile ("msr TCR_EL1, %[value]"
        :
        : [value] "r" (tcr_el1),
        : .{ .memory = true });
    asm volatile ("msr TTBR0_EL1, %[value]"
        :
        : [value] "r" (root_address),
        : .{ .memory = true });
    asm volatile ("isb");
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb");
    asm volatile ("ic iallu" ::: .{ .memory = true });
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb");

    asm volatile ("msr SCTLR_EL1, %[value]"
        :
        : [value] "r" (sctlr_enable_value),
        : .{ .memory = true });
    asm volatile ("isb");
}

pub fn isEnabled() bool {
    const sctlr_el1 = asm volatile ("mrs %[value], SCTLR_EL1"
        : [value] "=r" (-> u64),
    );
    return sctlr_el1 & 1 != 0;
}

fn translationControl(physical_address_range: u3) u64 {
    const t0sz_48_bit = 16;
    const inner_write_back = @as(u64, 0b01) << 8;
    const outer_write_back = @as(u64, 0b01) << 10;
    const inner_shareable_walk = @as(u64, 0b11) << 12;
    const disable_ttbr1_walks = @as(u64, 1) << 23;
    const intermediate_physical_size = @as(u64, physical_address_range) << 32;
    return t0sz_48_bit |
        inner_write_back |
        outer_write_back |
        inner_shareable_walk |
        disable_ttbr1_walks |
        intermediate_physical_size;
}

fn encodeOutputAddress(address: u64) DescriptorError!u64 {
    if (address & page_offset_mask != 0) return error.UnalignedAddress;
    if (address & ~output_address_mask != 0) return error.AddressOutOfRange;
    return address;
}

fn tableIndex(address: u64, shift: comptime_int) usize {
    return @intCast((address >> shift) & table_index_mask);
}

test "translation tables occupy one aligned page" {
    const table: Table = .{};

    try std.testing.expectEqual(page_size, @sizeOf(Table));
    try std.testing.expectEqual(page_size, @alignOf(Table));
    for (table.entries) |entry| try std.testing.expectEqual(@as(u64, 0), entry);
}

test "table descriptors encode aligned next-level addresses" {
    try std.testing.expectEqual(
        @as(u64, 0x0000_0000_1234_5003),
        try tableDescriptor(0x0000_0000_1234_5000),
    );
    try std.testing.expectError(error.UnalignedAddress, tableDescriptor(0x1234_5001));
    try std.testing.expectError(error.AddressOutOfRange, tableDescriptor(0x0001_0000_0000_0000));
}

test "page descriptors enforce the kernel W xor X policy" {
    try std.testing.expectEqual(
        @as(u64, 0x0040_0000_4000_0787),
        try pageDescriptor(0x4000_0000, .normal_read_execute),
    );
    try std.testing.expectEqual(
        @as(u64, 0x0060_0000_4000_0787),
        try pageDescriptor(0x4000_0000, .normal_read_only),
    );
    try std.testing.expectEqual(
        @as(u64, 0x0060_0000_4000_0707),
        try pageDescriptor(0x4000_0000, .normal_read_write),
    );
}

test "device mappings use Attr0 and cannot execute" {
    try std.testing.expectEqual(@as(u64, 0xff00), mair_el1);
    try std.testing.expectEqual(
        @as(u64, 0x0060_0000_0900_0603),
        try pageDescriptor(0x0900_0000, .device_read_write),
    );
}

test "page descriptors reject addresses outside their output width" {
    try std.testing.expectError(error.UnalignedAddress, pageDescriptor(1, .normal_read_only));
    try std.testing.expectError(
        error.AddressOutOfRange,
        pageDescriptor(0x0001_0000_0000_0000, .normal_read_only),
    );
}

test "identity map builds sparse four-level page tables" {
    var identity: IdentityMap = .{};

    try identity.map(0x4008_0000, 0x4008_2000, .normal_read_execute);
    try identity.map(0x4008_2000, 0x4008_3000, .normal_read_only);
    try identity.map(0x0900_0000, 0x0900_1000, .device_read_write);

    try std.testing.expectEqual(
        try pageDescriptor(0x4008_0000, .normal_read_execute),
        identity.descriptor(0x4008_0000).?,
    );
    try std.testing.expectEqual(
        try pageDescriptor(0x4008_2000, .normal_read_only),
        identity.descriptor(0x4008_2000).?,
    );
    try std.testing.expectEqual(
        try pageDescriptor(0x0900_0000, .device_read_write),
        identity.descriptor(0x0900_0000).?,
    );
    try std.testing.expectEqual(null, identity.descriptor(0));
    try std.testing.expectEqual(null, identity.descriptor((@as(u64, 1) << level_zero_shift) | 0x4008_0000));
    try std.testing.expectEqual(@as(usize, 2), identity.level_two_count);
    try std.testing.expectEqual(@as(usize, 2), identity.level_three_count);
}

test "identity map rejects invalid and conflicting ranges" {
    var identity: IdentityMap = .{};

    try std.testing.expectError(error.EmptyRange, identity.map(0x1000, 0x1000, .normal_read_write));
    try std.testing.expectError(error.UnalignedAddress, identity.map(1, 0x1000, .normal_read_write));
    try identity.map(0x1000, 0x2000, .normal_read_write);
    try std.testing.expectError(
        error.ConflictingMapping,
        identity.map(0x1000, 0x2000, .normal_read_only),
    );
}

test "translation control configures cacheable 48-bit TTBR0 walks" {
    try std.testing.expectEqual(@as(u64, 0x0000_0002_0080_3510), translationControl(2));
    try std.testing.expectEqual(@as(u64, 0x0000_0005_0080_3510), translationControl(5));
    try std.testing.expectEqual(@as(u64, 0x30d8_181d), sctlr_enable_value);
}
