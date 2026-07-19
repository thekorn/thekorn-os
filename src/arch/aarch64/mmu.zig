//! AArch64 stage-1 translation descriptor primitives for a 4 KiB granule.
//!
//! This module only constructs translation-table data. Enabling the MMU and
//! ordering system-register writes remain a separate, observable boot step.
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

// Attr0 is Device-nGnRnE. Attr1 is normal, inner/outer write-back,
// non-transient, read-allocate, and write-allocate memory.
pub const mair_el1: u64 = @as(u64, 0xff) << 8;

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

fn encodeOutputAddress(address: u64) DescriptorError!u64 {
    if (address & page_offset_mask != 0) return error.UnalignedAddress;
    if (address & ~output_address_mask != 0) return error.AddressOutOfRange;
    return address;
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
