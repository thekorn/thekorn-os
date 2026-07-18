const std = @import("std");

pub const magic = 0xd00dfeed;
pub const max_ranges = 32;

pub const Range = struct { address: u64, size: u64 };
pub const Info = struct {
    total_size: usize,
    ram: [max_ranges]Range = undefined,
    ram_count: usize = 0,
    reservations: [max_ranges]Range = undefined,
    reservation_count: usize = 0,
};

pub const ParseError = error{
    Truncated,
    BadMagic,
    BadVersion,
    BadOffset,
    BadToken,
    BadString,
    BadCells,
    BadProperty,
    TooManyRanges,
    Overflow,
};

fn be32(bytes: []const u8, offset: usize) ParseError!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.Truncated;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

pub fn blobSize(header: []const u8) ParseError!usize {
    if (header.len < 8) return error.Truncated;
    if (try be32(header, 0) != magic) return error.BadMagic;
    const size: usize = try be32(header, 4);
    if (size < 40) return error.Truncated;
    return size;
}

fn appendRange(array: *[max_ranges]Range, count: *usize, address: u64, size: u64) ParseError!void {
    if (size == 0) return;
    if (address > std.math.maxInt(u64) - size) return error.Overflow;
    if (count.* == array.len) return error.TooManyRanges;
    array[count.*] = .{ .address = address, .size = size };
    count.* += 1;
}

fn cellsValue(data: []const u8, cells: u32) ParseError!u64 {
    if (cells < 1 or cells > 2 or data.len != cells * 4) return error.BadCells;
    var value: u64 = 0;
    var offset: usize = 0;
    while (offset < data.len) : (offset += 4) value = (value << 32) | try be32(data, offset);
    return value;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    if (bytes.len < prefix.len) return false;
    for (prefix, bytes[0..prefix.len]) |a, b| if (a != b) return false;
    return true;
}

pub fn parse(bytes: []const u8) ParseError!Info {
    if (bytes.len < 40) return error.Truncated;
    if (try be32(bytes, 0) != magic) return error.BadMagic;
    const total: usize = try be32(bytes, 4);
    if (total < 40 or total > bytes.len) return error.Truncated;
    const structure: usize = try be32(bytes, 8);
    const strings: usize = try be32(bytes, 12);
    const reservations: usize = try be32(bytes, 16);
    const version = try be32(bytes, 20);
    if (version < 17 or try be32(bytes, 24) > 17) return error.BadVersion;
    const strings_size: usize = try be32(bytes, 32);
    const structure_size: usize = try be32(bytes, 36);
    if (structure > total or structure_size > total - structure or
        strings > total or strings_size > total - strings or reservations > total)
        return error.BadOffset;

    var result = Info{ .total_size = total };
    var reservation_offset = reservations;
    while (true) {
        if (reservation_offset > total or total - reservation_offset < 16) return error.Truncated;
        const address = std.mem.readInt(u64, bytes[reservation_offset..][0..8], .big);
        const size = std.mem.readInt(u64, bytes[reservation_offset + 8 ..][0..8], .big);
        reservation_offset += 16;
        if (address == 0 and size == 0) break;
        try appendRange(&result.reservations, &result.reservation_count, address, size);
    }

    const Node = struct {
        reg_address_cells: u32,
        reg_size_cells: u32,
        child_address_cells: u32,
        child_size_cells: u32,
        memory: u32,
        reserved_child: u32,
        reserved_parent: u32,
        padding: u32,
    };
    var stack: [32]Node align(8) = undefined;
    var depth: usize = 0;
    var off = structure;
    const structure_end = structure + structure_size;
    while (off < structure_end) {
        const token = try be32(bytes[0..structure_end], off);
        off += 4;
        switch (token) {
            1 => {
                if (depth == stack.len) return error.BadToken;
                const name_start = off;
                while (off < structure_end and bytes[off] != 0) : (off += 1) {}
                if (off == structure_end) return error.Truncated;
                const name = bytes[name_start..off];
                off = std.mem.alignForward(usize, off + 1, 4);
                const reg_address_cells: u32 = if (depth == 0) 2 else stack[depth - 1].child_address_cells;
                const reg_size_cells: u32 = if (depth == 0) 1 else stack[depth - 1].child_size_cells;
                const reserved_child = depth != 0 and stack[depth - 1].reserved_parent != 0;
                stack[depth] = .{
                    .reg_address_cells = reg_address_cells,
                    .reg_size_cells = reg_size_cells,
                    .child_address_cells = 2,
                    .child_size_cells = 1,
                    .memory = @intFromBool(equal(name, "memory") or startsWith(name, "memory@")),
                    .reserved_child = @intFromBool(reserved_child),
                    .reserved_parent = @intFromBool(depth == 1 and equal(name, "reserved-memory")),
                    .padding = 0,
                };
                depth += 1;
            },
            2 => if (depth == 0) return error.BadToken else {
                depth -= 1;
            },
            3 => {
                if (depth == 0 or off + 8 > structure_end) return error.BadToken;
                const len: usize = try be32(bytes, off);
                const name_off: usize = try be32(bytes, off + 4);
                off += 8;
                if (len > structure_end - off or name_off >= strings_size) return error.BadProperty;
                const data = bytes[off .. off + len];
                off = std.mem.alignForward(usize, off + len, 4);
                var name_end = strings + name_off;
                while (name_end < strings + strings_size and bytes[name_end] != 0) : (name_end += 1) {}
                if (name_end == strings + strings_size) return error.BadString;
                const name = bytes[strings + name_off .. name_end];
                var node = &stack[depth - 1];
                if (equal(name, "#address-cells")) node.child_address_cells = @intCast(try cellsValue(data, 1));
                if (equal(name, "#size-cells")) node.child_size_cells = @intCast(try cellsValue(data, 1));
                if (equal(name, "device_type") and startsWith(data, "memory")) node.memory = 1;
                if (equal(name, "reg") and (node.memory != 0 or node.reserved_child != 0)) {
                    if (node.reg_address_cells < 1 or node.reg_address_cells > 2 or node.reg_size_cells < 1 or node.reg_size_cells > 2) return error.BadCells;
                    const tuple_cells = node.reg_address_cells + node.reg_size_cells;
                    if (data.len % (tuple_cells * 4) != 0) return error.BadCells;
                    var pos: usize = 0;
                    while (pos < data.len) : (pos += tuple_cells * 4) {
                        const address = try cellsValue(data[pos..][0 .. node.reg_address_cells * 4], node.reg_address_cells);
                        const size_start = pos + node.reg_address_cells * 4;
                        const size = try cellsValue(data[size_start..][0 .. node.reg_size_cells * 4], node.reg_size_cells);
                        if (node.memory != 0) try appendRange(&result.ram, &result.ram_count, address, size) else try appendRange(&result.reservations, &result.reservation_count, address, size);
                    }
                }
            },
            4 => {},
            9 => {
                if (depth != 0) return error.BadToken;
                return result;
            },
            else => return error.BadToken,
        }
    }
    return error.Truncated;
}

test "rejects malformed FDT headers" {
    try std.testing.expectError(error.Truncated, parse("short"));
    var header: [40]u8 = undefined;
    @memset(&header, 0);
    try std.testing.expectError(error.BadMagic, parse(&header));
}

test "discovers RAM and both reservation forms" {
    const blob = [_]u8{
        0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x01, 0x6e, 0x00, 0x00, 0x00, 0x48,
        0x00, 0x00, 0x01, 0x3c, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11,
        0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32,
        0x00, 0x00, 0x00, 0xf4, 0x00, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x0f,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x6d, 0x65, 0x6d, 0x6f,
        0x72, 0x79, 0x40, 0x34, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x00,
        0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x1b,
        0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x72, 0x65, 0x73, 0x65,
        0x72, 0x76, 0x65, 0x64, 0x2d, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x00,
        0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00, 0x01,
        0x63, 0x61, 0x72, 0x76, 0x65, 0x6f, 0x75, 0x74, 0x40, 0x34, 0x31, 0x30,
        0x30, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00,
        0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x09, 0x23, 0x61, 0x64, 0x64, 0x72, 0x65, 0x73, 0x73,
        0x2d, 0x63, 0x65, 0x6c, 0x6c, 0x73, 0x00, 0x23, 0x73, 0x69, 0x7a, 0x65,
        0x2d, 0x63, 0x65, 0x6c, 0x6c, 0x73, 0x00, 0x64, 0x65, 0x76, 0x69, 0x63,
        0x65, 0x5f, 0x74, 0x79, 0x70, 0x65, 0x00, 0x72, 0x65, 0x67, 0x00, 0x72,
        0x61, 0x6e, 0x67, 0x65, 0x73, 0x00,
    };

    const info = try parse(&blob);
    try std.testing.expectEqual(blob.len, try blobSize(blob[0..40]));
    try std.testing.expectEqual(@as(usize, 1), info.ram_count);
    try std.testing.expectEqualDeep(Range{ .address = 0x4000_0000, .size = 0x0800_0000 }, info.ram[0]);
    try std.testing.expectEqual(@as(usize, 2), info.reservation_count);
    try std.testing.expectEqualDeep(Range{ .address = 0x4200_0000, .size = 0x1000 }, info.reservations[0]);
    try std.testing.expectEqualDeep(Range{ .address = 0x4100_0000, .size = 0x2000 }, info.reservations[1]);

    const memory_reg_offset = 152;
    var own_cells_blob: [blob.len + 16]u8 = undefined;
    @memcpy(own_cells_blob[0..memory_reg_offset], blob[0..memory_reg_offset]);
    std.mem.writeInt(u32, own_cells_blob[memory_reg_offset..][0..4], 3, .big);
    std.mem.writeInt(u32, own_cells_blob[memory_reg_offset + 4 ..][0..4], 4, .big);
    std.mem.writeInt(u32, own_cells_blob[memory_reg_offset + 8 ..][0..4], 0, .big);
    std.mem.writeInt(u32, own_cells_blob[memory_reg_offset + 12 ..][0..4], 1, .big);
    @memcpy(own_cells_blob[memory_reg_offset + 16 ..], blob[memory_reg_offset..]);
    std.mem.writeInt(u32, own_cells_blob[4..8], own_cells_blob.len, .big);
    std.mem.writeInt(u32, own_cells_blob[12..16], 0x13c + 16, .big);
    std.mem.writeInt(u32, own_cells_blob[36..40], 0xf4 + 16, .big);
    const own_cells_info = try parse(&own_cells_blob);
    try std.testing.expectEqualDeep(info.ram[0], own_cells_info.ram[0]);

    var invalid_cells_blob = blob;
    @memset(invalid_cells_blob[92..96], 0xff);
    try std.testing.expectError(error.BadCells, parse(&invalid_cells_blob));
}
