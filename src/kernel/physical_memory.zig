const std = @import("std");
const fdt = @import("../formats/fdt.zig");

pub const page_size: u64 = 4096;

pub const FreeError = error{
    UnalignedAddress,
    AddressOutOfRange,
    NotRam,
    Reserved,
    DoubleFree,
};

pub const Allocator = struct {
    bitmap: []u8,
    base: u64,
    frame_count: usize,
    next: usize = 0,
    ram: [fdt.max_ranges]fdt.Range = undefined,
    ram_count: usize = 0,
    reservations: [64]fdt.Range = undefined,
    reservation_count: usize = 0,

    pub fn init(storage: []u8, ram: []const fdt.Range) error{ NoRam, Overflow, TooManyRanges, InsufficientBitmap }!Allocator {
        if (ram.len == 0) return error.NoRam;
        if (ram.len > fdt.max_ranges) return error.TooManyRanges;
        var base: u64 = std.math.maxInt(u64);
        var end: u64 = 0;
        for (ram) |range| {
            if (range.address > std.math.maxInt(u64) - range.size) return error.Overflow;
            base = @min(base, range.address & ~(page_size - 1));
            const range_end = range.address + range.size;
            if (range_end > std.math.maxInt(u64) - (page_size - 1)) return error.Overflow;
            end = @max(end, std.mem.alignForward(u64, range_end, page_size));
        }
        const frames64 = (end - base) / page_size;
        if (frames64 > @as(u64, storage.len) * 8 or frames64 > std.math.maxInt(usize)) return error.InsufficientBitmap;
        const frames: usize = @intCast(frames64);
        @memset(storage, 0xff);
        var allocator = Allocator{ .bitmap = storage, .base = base, .frame_count = frames };
        for (ram) |range| {
            allocator.ram[allocator.ram_count] = range;
            allocator.ram_count += 1;
            const first = std.mem.alignForward(u64, range.address, page_size);
            const raw_end = range.address + range.size;
            const last = raw_end & ~(page_size - 1);
            var address = first;
            while (address < last) : (address += page_size) allocator.set(@intCast((address - base) / page_size), false);
        }
        return allocator;
    }

    pub fn reserve(self: *Allocator, range: fdt.Range) error{ Overflow, TooManyReservations }!void {
        if (range.size == 0) return;
        if (range.address > std.math.maxInt(u64) - range.size or range.address + range.size > std.math.maxInt(u64) - (page_size - 1)) return error.Overflow;
        if (self.reservation_count == self.reservations.len) return error.TooManyReservations;
        self.reservations[self.reservation_count] = range;
        self.reservation_count += 1;
        const first = range.address & ~(page_size - 1);
        const last = std.mem.alignForward(u64, range.address + range.size, page_size);
        var address = @max(first, self.base);
        const allocator_end = self.base + @as(u64, self.frame_count) * page_size;
        while (address < @min(last, allocator_end)) : (address += page_size) self.set(@intCast((address - self.base) / page_size), true);
    }

    pub fn allocate(self: *Allocator) ?u64 {
        var scanned: usize = 0;
        while (scanned < self.frame_count) : (scanned += 1) {
            const index = (self.next + scanned) % self.frame_count;
            if (!self.get(index)) {
                self.set(index, true);
                self.next = (index + 1) % self.frame_count;
                return self.base + @as(u64, index) * page_size;
            }
        }
        return null;
    }

    pub fn free(self: *Allocator, address: u64) FreeError!void {
        if (address % page_size != 0) return error.UnalignedAddress;
        if (address < self.base) return error.AddressOutOfRange;
        const index64 = (address - self.base) / page_size;
        if (index64 >= self.frame_count) return error.AddressOutOfRange;
        var belongs_to_ram = false;
        for (self.ram[0..self.ram_count]) |range| {
            if (address >= range.address and address + page_size <= range.address + range.size) {
                belongs_to_ram = true;
                break;
            }
        }
        if (!belongs_to_ram) return error.NotRam;
        for (self.reservations[0..self.reservation_count]) |range| {
            if (address + page_size > range.address and address < range.address + range.size) return error.Reserved;
        }
        const index: usize = @intCast(index64);
        if (!self.get(index)) return error.DoubleFree;
        self.set(index, false);
    }

    fn get(self: *const Allocator, index: usize) bool {
        return self.bitmap[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }
    fn set(self: *Allocator, index: usize, value: bool) void {
        const mask = @as(u8, 1) << @intCast(index % 8);
        if (value) self.bitmap[index / 8] |= mask else self.bitmap[index / 8] &= ~mask;
    }
};

test "allocator respects RAM holes and reservations under stress" {
    var bitmap: [4]u8 = undefined;
    const ram = [_]fdt.Range{ .{ .address = 0x1000, .size = 0x3000 }, .{ .address = 0x6000, .size = 0x2000 } };
    var allocator = try Allocator.init(&bitmap, &ram);
    try allocator.reserve(.{ .address = 0x1800, .size = 1 });
    const expected = [_]u64{ 0x2000, 0x3000, 0x6000, 0x7000 };
    for (expected) |address| try std.testing.expectEqual(address, allocator.allocate().?);
    try std.testing.expectEqual(null, allocator.allocate());
    try allocator.free(0x6000);
    try std.testing.expectEqual(@as(u64, 0x6000), allocator.allocate().?);
}

test "allocator rejects invalid frees without releasing their frames" {
    var bitmap: [2]u8 = undefined;
    const ram = [_]fdt.Range{ .{ .address = 0x1000, .size = 0x2000 }, .{ .address = 0x4000, .size = 0x1000 } };
    var allocator = try Allocator.init(&bitmap, &ram);
    try allocator.reserve(.{ .address = 0x1000, .size = page_size });
    try std.testing.expectError(error.Reserved, allocator.free(0x1000));
    try std.testing.expectError(error.NotRam, allocator.free(0x3000));
    try std.testing.expectEqual(@as(u64, 0x2000), allocator.allocate().?);
    try allocator.free(0x2000);
    try std.testing.expectError(error.DoubleFree, allocator.free(0x2000));
}

test "allocator rejects spans larger than its bitmap" {
    var bitmap: [1]u8 = undefined;
    const ram = [_]fdt.Range{.{ .address = 0x4000_0000, .size = 9 * page_size }};
    try std.testing.expectError(error.InsufficientBitmap, Allocator.init(&bitmap, &ram));
}

test "allocator rejects more RAM ranges than it can retain for free validation" {
    var bitmap: [1]u8 = undefined;
    var ram: [fdt.max_ranges + 1]fdt.Range = undefined;
    try std.testing.expectError(error.TooManyRanges, Allocator.init(&bitmap, &ram));
}
