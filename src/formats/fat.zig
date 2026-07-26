const std = @import("std");
const block = @import("../kernel/block_device.zig");

pub const Error = block.Error || error{
    InvalidBpb,
    UnsupportedFat12,
    InvalidName,
    NotFound,
    BufferTooSmall,
    CorruptChain,
    BadCluster,
    ReservedCluster,
    ClusterOutOfRange,
    ChainLoop,
    TruncatedChain,
    Overflow,
};

pub const FatType = enum { fat16, fat32 };

pub const FileSystem = struct {
    device: block.BlockDevice,
    fat_type: FatType,
    sectors_per_cluster: u8,
    fat_start: u64,
    data_start: u64,
    root_start: u64,
    root_sectors: u32,
    root_cluster: u32,
    cluster_count: u32,

    pub const Entry = struct {
        name: [12]u8 = @splat(0),
        name_len: u8,
        is_directory: bool,
        size: u32,

        pub fn nameSlice(self: *const Entry) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    pub fn mount(device: block.BlockDevice) Error!FileSystem {
        if (device.block_size != 512) return error.InvalidBpb;
        var sector: [512]u8 = undefined;
        try device.read(0, &sector);
        if (sector[510] != 0x55 or sector[511] != 0xaa) return error.InvalidBpb;
        const bytes_per_sector = le16(sector[11..13]);
        const sectors_per_cluster = sector[13];
        const reserved = le16(sector[14..16]);
        const fats = sector[16];
        const root_entries = le16(sector[17..19]);
        const total16 = le16(sector[19..21]);
        const fat16_size = le16(sector[22..24]);
        const total32 = le32(sector[32..36]);
        const fat32_size = le32(sector[36..40]);
        if (bytes_per_sector != 512 or sectors_per_cluster == 0 or !std.math.isPowerOfTwo(sectors_per_cluster) or reserved == 0 or fats == 0) return error.InvalidBpb;

        const total: u64 = if (total16 != 0) total16 else total32;
        const fat_size: u64 = if (fat16_size != 0) fat16_size else fat32_size;
        if (total == 0 or fat_size == 0 or total > device.block_count) return error.InvalidBpb;
        const root_bytes = std.math.mul(u64, root_entries, 32) catch return error.Overflow;
        const root_sectors: u64 = (root_bytes + 511) / 512;
        const fats_sectors = std.math.mul(u64, fats, fat_size) catch return error.Overflow;
        const fat_start: u64 = reserved;
        const root_start = std.math.add(u64, fat_start, fats_sectors) catch return error.Overflow;
        const data_start = std.math.add(u64, root_start, root_sectors) catch return error.Overflow;
        if (data_start >= total) return error.InvalidBpb;
        const clusters64 = (total - data_start) / sectors_per_cluster;
        if (clusters64 < 4085) return error.UnsupportedFat12;
        if (clusters64 > std.math.maxInt(u32) - 2) return error.InvalidBpb;
        const fat_type: FatType = if (clusters64 < 65525) .fat16 else .fat32;
        if (fat_type == .fat16 and (root_entries == 0 or fat16_size == 0)) return error.InvalidBpb;
        if (fat_type == .fat32 and (root_entries != 0 or fat16_size != 0 or fat32_size == 0)) return error.InvalidBpb;
        const root_cluster = if (fat_type == .fat32) le32(sector[44..48]) & 0x0fffffff else 0;
        if (fat_type == .fat32 and (root_cluster < 2 or root_cluster >= clusters64 + 2)) return error.InvalidBpb;

        // The FAT must contain an entry for every data cluster.
        const entry_size: u64 = if (fat_type == .fat16) 2 else 4;
        if (fat_size * 512 / entry_size < clusters64 + 2) return error.InvalidBpb;
        return .{
            .device = device,
            .fat_type = fat_type,
            .sectors_per_cluster = sectors_per_cluster,
            .fat_start = fat_start,
            .data_start = data_start,
            .root_start = root_start,
            .root_sectors = @intCast(root_sectors),
            .root_cluster = root_cluster,
            .cluster_count = @intCast(clusters64),
        };
    }

    pub fn readFile(self: FileSystem, name: []const u8, destination: []u8) Error![]u8 {
        const entry = try self.find(name);
        const size: usize = entry.size;
        if (destination.len < size) return error.BufferTooSmall;
        const amount = try self.readAtEntry(entry, 0, destination[0..size]);
        if (amount != size) return error.TruncatedChain;
        return destination[0..size];
    }

    pub fn stat(self: FileSystem, name: []const u8) Error!Entry {
        return self.find(name);
    }

    /// Reads only sectors intersecting the requested range. FAT links are
    /// followed while skipping preceding clusters, so fragmented files and
    /// large offsets do not require a whole-file buffer.
    pub fn readAt(self: FileSystem, name: []const u8, offset: u64, destination: []u8) Error!usize {
        return self.readAtEntry(try self.find(name), offset, destination);
    }

    pub fn rootEntry(self: FileSystem, wanted_index: usize) Error!?Entry {
        var iterator = RootIterator{ .file_system = self };
        var index: usize = 0;
        while (try iterator.next()) |raw| {
            if (index == wanted_index) return publicEntry(raw);
            index += 1;
        }
        return null;
    }

    const RawEntry = struct { short_name: [11]u8, cluster: u32, size: u32, is_directory: bool };

    fn find(self: FileSystem, name: []const u8) Error!RawEntry {
        var short: [11]u8 = undefined;
        try shortName(name, &short);
        var iterator = RootIterator{ .file_system = self };
        while (try iterator.next()) |entry| {
            if (equalShortName(&entry.short_name, &short)) return entry;
        }
        return error.NotFound;
    }

    fn readAtEntry(self: FileSystem, entry: RawEntry, offset: u64, destination: []u8) Error!usize {
        if (entry.is_directory) return error.InvalidName;
        if (offset >= entry.size or destination.len == 0) return 0;
        if (entry.cluster < 2) return error.CorruptChain;
        const available: usize = @intCast(@as(u64, entry.size) - offset);
        const wanted = @min(destination.len, available);
        const cluster_bytes: u64 = @as(u64, self.sectors_per_cluster) * 512;

        var cluster = entry.cluster;
        var skip_clusters = offset / cluster_bytes;
        var visited: u32 = 0;
        while (skip_clusters > 0) : (skip_clusters -= 1) {
            try self.validateCluster(cluster);
            if (visited >= self.cluster_count) return error.ChainLoop;
            visited += 1;
            const next = try self.nextCluster(cluster);
            if (next == cluster) return error.ChainLoop;
            cluster = next;
        }

        var within_cluster: usize = @intCast(offset % cluster_bytes);
        var copied: usize = 0;
        var sector: [512]u8 = undefined;
        while (copied < wanted) {
            try self.validateCluster(cluster);
            if (visited >= self.cluster_count) return error.ChainLoop;
            visited += 1;
            const first = try self.clusterSector(cluster);
            var sector_index = within_cluster / 512;
            var within_sector = within_cluster % 512;
            while (sector_index < self.sectors_per_cluster and copied < wanted) : (sector_index += 1) {
                try self.device.read(first + sector_index, &sector);
                const amount = @min(wanted - copied, 512 - within_sector);
                @memcpy(destination[copied .. copied + amount], sector[within_sector .. within_sector + amount]);
                copied += amount;
                within_sector = 0;
            }
            if (copied == wanted) return copied;
            const next = try self.nextCluster(cluster);
            if (next == cluster) return error.ChainLoop;
            cluster = next;
            within_cluster = 0;
        }
        unreachable;
    }

    const RootIterator = struct {
        file_system: FileSystem,
        sector_index: u32 = 0,
        entry_index: u8 = 0,
        cluster: u32 = 0,
        visited: u32 = 0,
        sector: [512]u8 = undefined,
        loaded: bool = false,
        done: bool = false,

        fn next(self: *RootIterator) Error!?RawEntry {
            while (!self.done) {
                if (!self.loaded) try self.loadSector();
                if (self.done) return null;
                const item = self.sector[@as(usize, self.entry_index) * 32 ..][0..32];
                self.entry_index += 1;
                if (self.entry_index == 16) {
                    self.entry_index = 0;
                    self.loaded = false;
                    self.sector_index += 1;
                }
                if (item[0] == 0) {
                    self.done = true;
                    return null;
                }
                const attributes = item[11];
                if (item[0] == 0xe5 or attributes == 0x0f or (attributes & 0x08) != 0) continue;
                var name: [11]u8 = undefined;
                @memcpy(&name, item[0..11]);
                return .{
                    .short_name = name,
                    .cluster = (@as(u32, le16(item[20..22])) << 16) | le16(item[26..28]),
                    .size = le32(item[28..32]),
                    .is_directory = attributes & 0x10 != 0,
                };
            }
            return null;
        }

        fn loadSector(self: *RootIterator) Error!void {
            if (self.file_system.fat_type == .fat16) {
                if (self.sector_index >= self.file_system.root_sectors) {
                    self.done = true;
                    return;
                }
                try self.file_system.device.read(self.file_system.root_start + self.sector_index, &self.sector);
            } else {
                if (self.cluster == 0) self.cluster = self.file_system.root_cluster;
                if (self.sector_index >= self.file_system.sectors_per_cluster) {
                    if (self.visited >= self.file_system.cluster_count) return error.ChainLoop;
                    self.visited += 1;
                    self.cluster = self.file_system.nextCluster(self.cluster) catch |err| switch (err) {
                        error.TruncatedChain => {
                            self.done = true;
                            return;
                        },
                        else => return err,
                    };
                    self.sector_index = 0;
                }
                try self.file_system.validateCluster(self.cluster);
                try self.file_system.device.read(try self.file_system.clusterSector(self.cluster) + self.sector_index, &self.sector);
            }
            self.loaded = true;
        }
    };

    fn clusterSector(self: FileSystem, cluster: u32) Error!u64 {
        const relative = std.math.mul(u64, cluster - 2, self.sectors_per_cluster) catch return error.Overflow;
        const sector = std.math.add(u64, self.data_start, relative) catch return error.Overflow;
        if (sector >= self.device.block_count or self.sectors_per_cluster > self.device.block_count - sector) return error.ClusterOutOfRange;
        return sector;
    }

    fn validateCluster(self: FileSystem, cluster: u32) Error!void {
        if (cluster < 2 or cluster >= self.cluster_count + 2) return error.ClusterOutOfRange;
    }

    fn nextCluster(self: FileSystem, cluster: u32) Error!u32 {
        const width: u64 = if (self.fat_type == .fat16) 2 else 4;
        const byte_offset = std.math.mul(u64, cluster, width) catch return error.Overflow;
        const lba = self.fat_start + byte_offset / 512;
        var sector: [512]u8 = undefined;
        try self.device.read(lba, &sector);
        const entry_offset: usize = @intCast(byte_offset % 512);
        const value: u32 = if (self.fat_type == .fat16) le16(sector[entry_offset..][0..2]) else le32(sector[entry_offset..][0..4]) & 0x0fffffff;
        if (self.fat_type == .fat16) {
            if (value >= 0xfff8) return error.TruncatedChain;
            if (value == 0xfff7) return error.BadCluster;
            if (value >= 0xfff0) return error.ReservedCluster;
        } else {
            if (value >= 0x0ffffff8) return error.TruncatedChain;
            if (value == 0x0ffffff7) return error.BadCluster;
            if (value >= 0x0ffffff0) return error.ReservedCluster;
        }
        if (value < 2 or value >= self.cluster_count + 2) return error.ClusterOutOfRange;
        return value;
    }
};

fn publicEntry(raw: FileSystem.RawEntry) FileSystem.Entry {
    var result = FileSystem.Entry{
        .name_len = 0,
        .is_directory = raw.is_directory,
        .size = raw.size,
    };
    var length: usize = 8;
    while (length > 0 and raw.short_name[length - 1] == ' ') length -= 1;
    @memcpy(result.name[0..length], raw.short_name[0..length]);
    var extension_length: usize = 3;
    while (extension_length > 0 and raw.short_name[8 + extension_length - 1] == ' ') extension_length -= 1;
    if (extension_length > 0) {
        result.name[length] = '.';
        @memcpy(result.name[length + 1 ..][0..extension_length], raw.short_name[8..][0..extension_length]);
        length += extension_length + 1;
    }
    result.name_len = @intCast(length);
    return result;
}

fn equalShortName(first: *const [11]u8, second: *const [11]u8) bool {
    // Disk structures are byte-aligned, and EL1 enables alignment checks.
    const first_bytes: *const volatile [11]u8 = first;
    const second_bytes: *const volatile [11]u8 = second;
    for (0..11) |index| {
        if (first_bytes[index] != second_bytes[index]) return false;
    }
    return true;
}

fn shortName(name: []const u8, result: *[11]u8) Error!void {
    if (name.len == 0) return error.InvalidName;
    const dot = std.mem.findScalarLast(u8, name, '.');
    const base_len = dot orelse name.len;
    const ext_start = if (dot) |at| at + 1 else name.len;
    const ext_len = name.len - ext_start;
    if (base_len == 0 or base_len > 8 or ext_len > 3 or (dot != null and ext_len == 0)) return error.InvalidName;
    const output: *volatile [11]u8 = result;
    for (0..result.len) |index| output[index] = ' ';
    for (name[0..base_len], 0..) |byte, i| result[i] = try shortChar(byte);
    for (name[ext_start..], 0..) |byte, i| result[8 + i] = try shortChar(byte);
}

fn shortChar(byte: u8) Error!u8 {
    const upper = if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
    if ((upper >= 'A' and upper <= 'Z') or (upper >= '0' and upper <= '9') or std.mem.findScalar(u8, "$%'-_@~`!(){}^#&", upper) != null) return upper;
    return error.InvalidName;
}

fn le16(bytes: *const [2]u8) u16 {
    // Volatile byte reads prevent optimized unaligned integer accesses.
    const input: *const volatile [2]u8 = bytes;
    return @as(u16, input[0]) | @as(u16, input[1]) << 8;
}

fn le32(bytes: *const [4]u8) u32 {
    const input: *const volatile [4]u8 = bytes;
    return @as(u32, input[0]) |
        @as(u32, input[1]) << 8 |
        @as(u32, input[2]) << 16 |
        @as(u32, input[3]) << 24;
}

const MemoryDevice = struct {
    bytes: []u8,
    fn read(context: *anyopaque, first: u64, destination: []u8) block.Error!void {
        const self: *MemoryDevice = @ptrCast(@alignCast(context));
        const start = first * 512;
        @memcpy(destination, self.bytes[@intCast(start)..][0..destination.len]);
    }
    fn device(self: *MemoryDevice) block.BlockDevice {
        return .{ .context = self, .readBlocks = read, .block_size = 512, .block_count = self.bytes.len / 512 };
    }
};

fn put16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}
fn put32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

fn makeImage(allocator: std.mem.Allocator, kind: FatType) ![]u8 {
    const clusters: u32 = if (kind == .fat16) 4085 else 65525;
    const fat_sectors: u32 = if (kind == .fat16) 16 else 512;
    const reserved: u32 = if (kind == .fat16) 1 else 32;
    const root_sectors: u32 = if (kind == .fat16) 2 else 0;
    const total = reserved + fat_sectors + root_sectors + clusters;
    const image = try allocator.alloc(u8, @as(usize, total) * 512);
    @memset(image, 0);
    put16(image[11..13], 512);
    image[13] = 1;
    put16(image[14..16], @intCast(reserved));
    image[16] = 1;
    put16(image[17..19], if (kind == .fat16) 32 else 0);
    if (kind == .fat16) {
        put16(image[19..21], @intCast(total));
        put16(image[22..24], @intCast(fat_sectors));
    } else {
        put32(image[32..36], total);
        put32(image[36..40], fat_sectors);
        put32(image[44..48], 2);
    }
    image[510] = 0x55;
    image[511] = 0xaa;
    const fat = image[@as(usize, reserved) * 512 ..];
    const data_sector = reserved + fat_sectors + root_sectors;
    const root = if (kind == .fat16) image[@as(usize, reserved + fat_sectors) * 512 ..] else image[@as(usize, data_sector) * 512 ..];
    @memcpy(root[0..11], "USER1   ELF");
    root[11] = 0x20;
    const first_cluster: u32 = if (kind == .fat16) 2 else 5;
    put16(root[26..28], @truncate(first_cluster));
    put16(root[20..22], @truncate(first_cluster >> 16));
    put32(root[28..32], 700);
    const second_cluster: u32 = if (kind == .fat16) 4 else 7;
    if (kind == .fat16) {
        put16(fat[first_cluster * 2 ..][0..2], @intCast(second_cluster));
        put16(fat[second_cluster * 2 ..][0..2], 0xffff);
    } else {
        put32(fat[2 * 4 ..][0..4], 0x0fffffff);
        put32(fat[first_cluster * 4 ..][0..4], second_cluster);
        put32(fat[second_cluster * 4 ..][0..4], 0xafffffff); // high nibble must be masked
    }
    @memset(image[@as(usize, data_sector + first_cluster - 2) * 512 ..][0..512], 'A');
    @memset(image[@as(usize, data_sector + second_cluster - 2) * 512 ..][0..512], 'B');
    return image;
}

test "FAT16 and FAT32 read a fragmented short-name file" {
    for ([_]FatType{ .fat16, .fat32 }) |kind| {
        const image = try makeImage(std.testing.allocator, kind);
        defer std.testing.allocator.free(image);
        var memory = MemoryDevice{ .bytes = image };
        const file_system = try FileSystem.mount(memory.device());
        try std.testing.expectEqual(kind, file_system.fat_type);
        var output: [700]u8 = undefined;
        const contents = try file_system.readFile("user1.elf", &output);
        try std.testing.expectEqual(@as(usize, 700), contents.len);
        for (contents[0..512]) |byte| try std.testing.expectEqual(@as(u8, 'A'), byte);
        for (contents[512..]) |byte| try std.testing.expectEqual(@as(u8, 'B'), byte);
        const root_entry = (try file_system.rootEntry(0)).?;
        try std.testing.expectEqualStrings("USER1.ELF", root_entry.nameSlice());
        try std.testing.expectEqual(@as(u32, 700), root_entry.size);
        try std.testing.expect((try file_system.rootEntry(1)) == null);
        var partial: [32]u8 = undefined;
        try std.testing.expectEqual(@as(usize, partial.len), try file_system.readAt("USER1.ELF", 500, &partial));
        for (partial[0..12]) |byte| try std.testing.expectEqual(@as(u8, 'A'), byte);
        for (partial[12..]) |byte| try std.testing.expectEqual(@as(u8, 'B'), byte);
        try std.testing.expectEqual(@as(usize, 0), try file_system.readAt("USER1.ELF", 700, &partial));
        try std.testing.expectError(error.BufferTooSmall, file_system.readFile("USER1.ELF", output[0..699]));
        try std.testing.expectError(error.InvalidName, file_system.readFile("TOO-LONG-NAME.ELF", &output));
    }
}

test "FAT rejects malformed BPBs and broken chains" {
    const image = try makeImage(std.testing.allocator, .fat16);
    defer std.testing.allocator.free(image);
    var memory = MemoryDevice{ .bytes = image };
    var file_system = try FileSystem.mount(memory.device());
    const fat = image[512..];
    put16(fat[4..6], 2);
    var output: [700]u8 = undefined;
    try std.testing.expectError(error.ChainLoop, file_system.readFile("USER1.ELF", &output));
    put16(image[11..13], 0);
    try std.testing.expectError(error.InvalidBpb, FileSystem.mount(memory.device()));
}

test "FAT16 scans every root sector and reports a truncated file chain" {
    const image = try makeImage(std.testing.allocator, .fat16);
    defer std.testing.allocator.free(image);
    var memory = MemoryDevice{ .bytes = image };
    const file_system = try FileSystem.mount(memory.device());
    const root_offset: usize = @intCast(file_system.root_start * 512);
    var entry: [32]u8 = undefined;
    @memcpy(&entry, image[root_offset..][0..32]);
    for (0..16) |index| image[root_offset + index * 32] = 0xe5;
    @memcpy(image[root_offset + 512 ..][0..32], &entry);

    var output: [700]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 700), (try file_system.readFile("USER1.ELF", &output)).len);

    const fat_offset: usize = @intCast(file_system.fat_start * 512);
    put16(image[fat_offset + 4 ..][0..2], 0xffff);
    try std.testing.expectError(error.TruncatedChain, file_system.readFile("USER1.ELF", &output));
    try std.testing.expectError(error.InvalidName, file_system.readFile("USER?.ELF", &output));
}

test "FAT32 follows chained root directories and terminates missing searches" {
    const image = try makeImage(std.testing.allocator, .fat32);
    defer std.testing.allocator.free(image);
    var memory = MemoryDevice{ .bytes = image };
    const file_system = try FileSystem.mount(memory.device());
    const fat_offset: usize = @intCast(file_system.fat_start * 512);
    const first_root_offset: usize = @intCast(file_system.data_start * 512);
    const second_root_offset = first_root_offset + 512;
    var entry: [32]u8 = undefined;
    @memcpy(&entry, image[first_root_offset..][0..32]);
    for (0..16) |index| image[first_root_offset + index * 32] = 0xe5;
    @memcpy(image[second_root_offset..][0..32], &entry);
    put32(image[fat_offset + 2 * 4 ..][0..4], 3);
    put32(image[fat_offset + 3 * 4 ..][0..4], 0x0fff_ffff);

    var output: [700]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 700), (try file_system.readFile("USER1.ELF", &output)).len);

    for (0..16) |index| image[second_root_offset + index * 32] = 0xe5;
    try std.testing.expectError(error.NotFound, file_system.readFile("USER1.ELF", &output));
}
