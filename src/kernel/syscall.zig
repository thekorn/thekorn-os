const std = @import("std");

pub const abi_version: u64 = 1;
const version_shift = 8;

pub const Number = enum(u64) {
    write = abi_version << version_shift,
    yield,
    exit,
    grow,
};

pub const ErrorCode = enum(i64) {
    invalid_syscall = 1,
    invalid_address = 2,
    out_of_memory = 3,
    invalid_argument = 4,
};

pub fn decode(raw_number: u64) ?Number {
    if (raw_number < @intFromEnum(Number.write) or raw_number > @intFromEnum(Number.grow)) return null;
    return @enumFromInt(raw_number);
}

pub fn errorResult(code: ErrorCode) u64 {
    return @bitCast(-@intFromEnum(code));
}

test "ABI version is encoded in every syscall number" {
    const version_mask = @as(u64, 0xff) << version_shift;
    for (std.enums.values(Number)) |number| {
        try std.testing.expectEqual(abi_version << version_shift, @intFromEnum(number) & version_mask);
    }
}

test "syscall decoding rejects unknown versions and operations" {
    try std.testing.expectEqual(Number.write, decode(0x100).?);
    try std.testing.expectEqual(Number.grow, decode(0x103).?);
    try std.testing.expectEqual(null, decode(0x003));
    try std.testing.expectEqual(null, decode(0x200));
    try std.testing.expectEqual(null, decode(0x104));
}

test "errors use negative result values" {
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(errorResult(.invalid_syscall))));
    try std.testing.expectEqual(@as(i64, -4), @as(i64, @bitCast(errorResult(.invalid_argument))));
}
