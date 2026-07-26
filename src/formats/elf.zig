const std = @import("std");

pub const load_segment = 1;
pub const flag_execute = 1;
pub const flag_write = 2;
pub const flag_read = 4;
pub const max_program_headers = 8;

pub const ParseError = error{
    Truncated,
    BadMagic,
    UnsupportedClass,
    UnsupportedEncoding,
    UnsupportedType,
    UnsupportedMachine,
    BadHeader,
    BadProgramHeader,
    TooManyProgramHeaders,
    Overflow,
};

pub const Segment = struct {
    segment_type: u32,
    flags: u32,
    file_offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,
};

pub const Image = struct {
    bytes: []const u8,
    entry: u64,
    program_header_offset: usize,
    program_header_count: usize,
    program_header_size: usize,

    pub fn segment(self: Image, index: usize) ParseError!Segment {
        if (index >= self.program_header_count) return error.BadProgramHeader;
        const offset = self.program_header_offset + index * self.program_header_size;
        const result = Segment{
            .segment_type = try le32(self.bytes, offset),
            .flags = try le32(self.bytes, offset + 4),
            .file_offset = try le64(self.bytes, offset + 8),
            .virtual_address = try le64(self.bytes, offset + 16),
            .file_size = try le64(self.bytes, offset + 32),
            .memory_size = try le64(self.bytes, offset + 40),
            .alignment = try le64(self.bytes, offset + 48),
        };
        if (result.file_size > result.memory_size or
            result.file_offset > std.math.maxInt(u64) - result.file_size or
            result.file_offset + result.file_size > self.bytes.len or
            result.virtual_address > std.math.maxInt(u64) - result.memory_size)
        {
            return error.BadProgramHeader;
        }
        return result;
    }
};

pub fn parse(bytes: []const u8) ParseError!Image {
    if (bytes.len < 64) return error.Truncated;
    if (bytes[0] != 0x7f or bytes[1] != 'E' or bytes[2] != 'L' or bytes[3] != 'F') return error.BadMagic;
    if (bytes[4] != 2) return error.UnsupportedClass;
    if (bytes[5] != 1 or bytes[6] != 1) return error.UnsupportedEncoding;
    if (try le16(bytes, 16) != 2) return error.UnsupportedType;
    if (try le16(bytes, 18) != 183) return error.UnsupportedMachine;
    if (try le32(bytes, 20) != 1 or try le16(bytes, 52) != 64) return error.BadHeader;

    const program_header_offset64 = try le64(bytes, 32);
    const program_header_size: usize = try le16(bytes, 54);
    const program_header_count: usize = try le16(bytes, 56);
    if (program_header_size != 56 or program_header_count == 0) return error.BadHeader;
    if (program_header_count > max_program_headers) return error.TooManyProgramHeaders;
    if (program_header_offset64 > std.math.maxInt(usize)) return error.Overflow;
    const program_header_offset: usize = @intCast(program_header_offset64);
    if (program_header_offset > bytes.len or
        program_header_count > (bytes.len - program_header_offset) / program_header_size)
    {
        return error.Truncated;
    }
    return .{
        .bytes = bytes,
        .entry = try le64(bytes, 24),
        .program_header_offset = program_header_offset,
        .program_header_count = program_header_count,
        .program_header_size = program_header_size,
    };
}

fn le16(bytes: []const u8, offset: usize) ParseError!u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return error.Truncated;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn le32(bytes: []const u8, offset: usize) ParseError!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.Truncated;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn le64(bytes: []const u8, offset: usize) ParseError!u64 {
    if (offset > bytes.len or bytes.len - offset < 8) return error.Truncated;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn fixture() [120]u8 {
    var bytes: [120]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    std.mem.writeInt(u16, bytes[16..18], 2, .little);
    std.mem.writeInt(u16, bytes[18..20], 183, .little);
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    std.mem.writeInt(u64, bytes[24..32], 0x0040_0000, .little);
    std.mem.writeInt(u64, bytes[32..40], 64, .little);
    std.mem.writeInt(u16, bytes[52..54], 64, .little);
    std.mem.writeInt(u16, bytes[54..56], 56, .little);
    std.mem.writeInt(u16, bytes[56..58], 1, .little);
    std.mem.writeInt(u32, bytes[64..68], load_segment, .little);
    std.mem.writeInt(u32, bytes[68..72], flag_read | flag_execute, .little);
    std.mem.writeInt(u64, bytes[72..80], 112, .little);
    std.mem.writeInt(u64, bytes[80..88], 0x0040_0000, .little);
    std.mem.writeInt(u64, bytes[96..104], 8, .little);
    std.mem.writeInt(u64, bytes[104..112], 8, .little);
    std.mem.writeInt(u64, bytes[112..120], 4096, .little);
    return bytes;
}

test "parses a little-endian AArch64 load segment" {
    const bytes = fixture();
    const image = try parse(&bytes);
    const segment = try image.segment(0);
    try std.testing.expectEqual(@as(u64, 0x0040_0000), image.entry);
    try std.testing.expectEqual(@as(u32, flag_read | flag_execute), segment.flags);
    try std.testing.expectEqual(@as(u64, 8), segment.file_size);
}

test "rejects malformed and out-of-bounds images" {
    var bytes = fixture();
    bytes[4] = 1;
    try std.testing.expectError(error.UnsupportedClass, parse(&bytes));
    bytes = fixture();
    std.mem.writeInt(u64, bytes[96..104], 9, .little);
    try std.testing.expectError(error.BadProgramHeader, (try parse(&bytes)).segment(0));
}

test "rejects overflowing segment ranges" {
    var bytes = fixture();
    std.mem.writeInt(u64, bytes[72..80], std.math.maxInt(u64) - 4, .little);
    try std.testing.expectError(error.BadProgramHeader, (try parse(&bytes)).segment(0));

    bytes = fixture();
    std.mem.writeInt(u64, bytes[80..88], std.math.maxInt(u64) - 4, .little);
    try std.testing.expectError(error.BadProgramHeader, (try parse(&bytes)).segment(0));
}
