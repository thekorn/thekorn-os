//! Raspberry Pi firmware-property framebuffer backend.

const std = @import("std");
const builtin = @import("builtin");
const mailbox = @import("mailbox.zig");

const requested_width: u32 = 800;
const requested_height: u32 = 600;
const request_code: u32 = 0;
const response_success: u32 = 0x8000_0000;
const response_bit: u32 = 0x8000_0000;
const tag_physical_size: u32 = 0x0004_8003;
const tag_virtual_size: u32 = 0x0004_8004;
const tag_depth: u32 = 0x0004_8005;
const tag_pixel_order: u32 = 0x0004_8006;
const tag_allocate: u32 = 0x0004_0001;
const tag_pitch: u32 = 0x0004_0008;
const rgb_order: u32 = 1;
const vc_bus_address_mask: u32 = 0x3fff_ffff;

pub const Error = error{ DisplayUnavailable, InvalidDimensions, AllocationFailed, TransportFailed, InvalidResponse };
pub const Surface = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    pitch: u32,
    presentFn: *const fn (x: u32, y: u32, width: u32, height: u32) Error!void,
};

var message: [30]u32 align(16) = undefined;
const request_message: [30]u32 align(16) = .{
    120,               request_code,
    tag_physical_size, 8,
    8,                 requested_width,
    requested_height,  tag_virtual_size,
    8,                 8,
    requested_width,   requested_height,
    tag_depth,         4,
    4,                 32,
    tag_pixel_order,   4,
    4,                 rgb_order,
    tag_allocate,      8,
    4,                 4096,
    0,                 tag_pitch,
    4,                 0,
    0,                 0,
};

pub fn initialize(_: anytype, _: []const u64) Error!Surface {
    for (request_message, 0..) |value, index| {
        @as(*volatile u32, @ptrCast(&message[index])).* = value;
    }
    mailbox.property(&message) catch return error.TransportFailed;
    return parseResponse(&message);
}

pub fn parseResponse(words: *const [30]u32) Error!Surface {
    if (words[0] != @sizeOf(@TypeOf(words.*)) or words[1] != response_success or words[29] != 0) return error.InvalidResponse;
    try tag(words, 2, tag_physical_size, 8);
    try tag(words, 7, tag_virtual_size, 8);
    try tag(words, 12, tag_depth, 4);
    try tag(words, 16, tag_pixel_order, 4);
    try tag(words, 20, tag_allocate, 8);
    try tag(words, 25, tag_pitch, 4);
    if (words[15] != 32 or words[19] != rgb_order) return error.InvalidResponse;

    const width = words[10];
    const height = words[11];
    const bus_address = words[23];
    const allocation_size = words[24];
    const pitch = words[28];
    if (words[5] == 0 or words[6] == 0 or width == 0 or height == 0 or bus_address == 0 or allocation_size == 0) return error.DisplayUnavailable;
    const row_bytes = std.math.mul(usize, width, 4) catch return error.InvalidDimensions;
    if (pitch < row_bytes) return error.InvalidDimensions;
    const preceding = std.math.mul(usize, height - 1, pitch) catch return error.InvalidDimensions;
    const required = std.math.add(usize, preceding, row_bytes) catch return error.InvalidDimensions;
    if (required > allocation_size) return error.AllocationFailed;
    const arm_address = bus_address & vc_bus_address_mask;
    if (arm_address == 0) return error.DisplayUnavailable;
    const bytes: [*]u8 = @ptrFromInt(arm_address);
    return .{ .bytes = bytes[0..allocation_size], .width = width, .height = height, .pitch = pitch, .presentFn = present };
}

fn tag(words: *const [30]u32, index: usize, identifier: u32, length: u32) Error!void {
    if (words[index] != identifier or words[index + 1] != length or words[index + 2] != response_bit | length) return error.InvalidResponse;
}

fn present(_: u32, _: u32, _: u32, _: u32) Error!void {
    if (builtin.cpu.arch == .aarch64) asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn validResponse() [30]u32 {
    var result = request_message;
    result[1] = response_success;
    result[4] = response_bit | 8;
    result[9] = response_bit | 8;
    result[14] = response_bit | 4;
    result[18] = response_bit | 4;
    result[22] = response_bit | 8;
    result[23] = 0xc100_0000;
    result[24] = requested_width * requested_height * 4;
    result[27] = response_bit | 4;
    result[28] = requested_width * 4;
    return result;
}

test "property request encodes allocation input and response sizes" {
    const request = request_message;
    try std.testing.expectEqual(tag_allocate, request[20]);
    try std.testing.expectEqual(@as(u32, 8), request[21]);
    try std.testing.expectEqual(@as(u32, 4), request[22]);
    try std.testing.expectEqual(@as(u32, 4096), request[23]);
}

test "valid property response returns authoritative surface" {
    var response = validResponse();
    response[10] = 640;
    response[11] = 480;
    response[28] = 2688;
    response[24] = 2688 * 480;
    const surface = try parseResponse(&response);
    try std.testing.expectEqual(@as(u32, 640), surface.width);
    try std.testing.expectEqual(@as(u32, 480), surface.height);
    try std.testing.expectEqual(@as(u32, 2688), surface.pitch);
    try std.testing.expectEqual(@as(usize, 2688 * 480), surface.bytes.len);
    try std.testing.expectEqual(@as(usize, 0x0100_0000), @intFromPtr(surface.bytes.ptr));
}

test "property parser rejects malformed response fields" {
    const cases = [_]struct { index: usize, value: u32 }{
        .{ .index = 1, .value = 0x8000_0001 }, .{ .index = 2, .value = 0 },
        .{ .index = 4, .value = 8 },           .{ .index = 15, .value = 24 },
        .{ .index = 19, .value = 0 },          .{ .index = 23, .value = 0 },
    };
    for (cases) |case| {
        var response = validResponse();
        response[case.index] = case.value;
        try std.testing.expectError(if (case.index == 23) error.DisplayUnavailable else error.InvalidResponse, parseResponse(&response));
    }
}

test "property parser rejects pitch allocation and arithmetic overflow" {
    var short_pitch = validResponse();
    short_pitch[28] = requested_width * 4 - 1;
    try std.testing.expectError(error.InvalidDimensions, parseResponse(&short_pitch));
    var short_allocation = validResponse();
    short_allocation[24] -= 1;
    try std.testing.expectError(error.AllocationFailed, parseResponse(&short_allocation));
    var overflow = validResponse();
    overflow[10] = std.math.maxInt(u32);
    overflow[11] = std.math.maxInt(u32);
    overflow[28] = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidDimensions, parseResponse(&overflow));
}
