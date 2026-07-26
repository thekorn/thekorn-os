const std = @import("std");

pub const Error = error{
    InvalidMagic,
    InvalidHeader,
    InvalidHex,
    InvalidName,
    Truncated,
    Overflow,
    MissingTrailer,
};

pub const Archive = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Archive {
        return .{ .bytes = bytes };
    }

    pub fn find(self: Archive, wanted: []const u8) Error!?[]const u8 {
        var offset: usize = 0;
        while (offset < self.bytes.len) {
            const header_end = add(offset, 110) catch return error.Overflow;
            if (header_end > self.bytes.len) return error.Truncated;
            const header = self.bytes[offset..header_end];
            if (!equalBytes(header[0..6], "070701")) return error.InvalidMagic;

            // Validate every fixed-width field, not only the fields used here.
            var fields: [13]u32 = undefined;
            for (0..13) |i| fields[i] = try hex(header[6 + i * 8 .. 14 + i * 8]);
            const file_size: usize = fields[6];
            const name_size: usize = fields[11];
            if (name_size == 0) return error.InvalidName;

            const name_end = add(header_end, name_size) catch return error.Overflow;
            if (name_end > self.bytes.len) return error.Truncated;
            const stored_name = self.bytes[header_end..name_end];
            if (stored_name[name_size - 1] != 0) return error.InvalidName;
            const name = stored_name[0 .. name_size - 1];
            for (name) |byte| {
                if (byte == 0) return error.InvalidName;
            }

            const data_start = try align4(name_end);
            const data_end = add(data_start, file_size) catch return error.Overflow;
            if (data_start > self.bytes.len or data_end > self.bytes.len) return error.Truncated;

            if (equalBytes(name, "TRAILER!!!")) {
                if (file_size != 0) return error.InvalidHeader;
                return null;
            }
            if (equalBytes(name, wanted)) return self.bytes[data_start..data_end];
            offset = try align4(data_end);
            if (offset > self.bytes.len) return error.Truncated;
        }
        return error.MissingTrailer;
    }
};

fn equalBytes(first: []const u8, second: []const u8) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn add(a: usize, b: usize) error{Overflow}!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

fn align4(value: usize) Error!usize {
    const bumped = add(value, 3) catch return error.Overflow;
    return bumped & ~@as(usize, 3);
}

fn hex(bytes: []const u8) Error!u32 {
    if (bytes.len != 8) return error.InvalidHeader;
    var value: u32 = 0;
    for (bytes) |byte| {
        const digit: u32 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidHex,
        };
        value = std.math.mul(u32, value, 16) catch return error.Overflow;
        value = std.math.add(u32, value, digit) catch return error.Overflow;
    }
    return value;
}

fn appendEntry(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
    var header: [110]u8 = undefined;
    @memset(&header, '0');
    @memcpy(header[0..6], "070701");
    const sizes = [_]struct { offset: usize, value: usize }{
        .{ .offset = 54, .value = data.len },
        .{ .offset = 94, .value = name.len + 1 },
    };
    for (sizes) |item| {
        var value = item.value;
        var i: usize = item.offset + 8;
        while (i > item.offset) {
            i -= 1;
            header[i] = "0123456789abcdef"[value & 15];
            value >>= 4;
        }
    }
    try list.appendSlice(allocator, &header);
    try list.appendSlice(allocator, name);
    try list.append(allocator, 0);
    while (list.items.len % 4 != 0) try list.append(allocator, 0);
    try list.appendSlice(allocator, data);
    while (list.items.len % 4 != 0) try list.append(allocator, 0);
}

test "newc finds aligned files and reports absence at trailer" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendEntry(&bytes, std.testing.allocator, "a", "x");
    try appendEntry(&bytes, std.testing.allocator, "USER1.ELF", "payload");
    try appendEntry(&bytes, std.testing.allocator, "TRAILER!!!", "");
    const archive = Archive.init(bytes.items);
    try std.testing.expectEqualStrings("payload", (try archive.find("USER1.ELF")).?);
    try std.testing.expect((try archive.find("missing")) == null);
}

test "newc rejects malformed and truncated archives" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendEntry(&bytes, std.testing.allocator, "x", "abc");
    try std.testing.expectError(error.MissingTrailer, Archive.init(bytes.items).find("z"));
    try std.testing.expectError(error.Truncated, Archive.init(bytes.items[0..109]).find("z"));
    bytes.items[0] = '1';
    try std.testing.expectError(error.InvalidMagic, Archive.init(bytes.items).find("z"));
    bytes.items[0] = '0';
    bytes.items[6] = 'z';
    try std.testing.expectError(error.InvalidHex, Archive.init(bytes.items).find("z"));
}
