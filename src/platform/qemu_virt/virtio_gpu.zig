//! Polling virtio-gpu 2D backend for the QEMU Arm `virt` machine.

const std = @import("std");
const virtio = @import("virtio.zig");

const queue_size = 8;
const poll_limit = 10_000_000;
const resource_id = 1;
const response_ok_nodata = 0x1100;
const response_ok_display_info = 0x1101;
const command_get_display_info = 0x0100;
const command_resource_create_2d = 0x0101;
const command_set_scanout = 0x0103;
const command_resource_flush = 0x0104;
const command_transfer_to_host_2d = 0x0105;
const command_attach_backing = 0x0106;
const format_b8g8r8x8_unorm = 2;
pub const width: u32 = 800;
pub const height: u32 = 600;
const page_size = 4096;
const backing_bytes = width * height * @sizeOf(u32);
const backing_frames = std.mem.alignForward(usize, backing_bytes, page_size) / page_size;

pub const Error = error{ DisplayUnavailable, InvalidDimensions, AllocationFailed, TransportFailed, InvalidResponse, InvalidCompletion };
pub const Surface = struct { bytes: []u8, presentFn: *const fn (x: u32, y: u32, rectangle_width: u32, rectangle_height: u32) Error!void };

const Header = extern struct { command_type: u32 = 0, flags: u32 = 0, fence_id: u64 = 0, context_id: u32 = 0, padding: u32 = 0 };
const Rectangle = extern struct { x: u32 = 0, y: u32 = 0, width: u32 = 0, height: u32 = 0 };
const Display = extern struct { rectangle: Rectangle = .{}, enabled: u32 = 0, flags: u32 = 0 };
const DisplayInfo = extern struct { header: Header = .{}, displays: [16]Display = @splat(.{}) };
const Create2d = extern struct { header: Header, resource: u32, format: u32, width: u32, height: u32 };
const ResourceRectangle = extern struct { header: Header, rectangle: Rectangle, scanout: u32, resource: u32 };
const Flush = extern struct { header: Header, rectangle: Rectangle, resource: u32, padding: u32 = 0 };
const Transfer = extern struct { header: Header, rectangle: Rectangle, offset: u64, resource: u32, padding: u32 = 0 };
const Backing = extern struct { header: Header, resource: u32, entries: u32, address: u64, length: u32, padding: u32 = 0 };

const State = struct {
    device: virtio.Device = .{ .base = 0 },
    queue: virtio.Queue(queue_size) = .{},
    command: [@sizeOf(Transfer)]u8 align(16) = @splat(0),
    response: DisplayInfo align(16) = .{},
    backing_address: u64 = 0,
};
var state: State = .{};

pub fn initialize(allocator: anytype, transport_bases: []const u64) Error!Surface {
    state = .{};
    state.device = findDevice(transport_bases) catch return error.TransportFailed;
    state.device.negotiate(0) catch return error.TransportFailed;
    state.queue.initialize(state.device, 0) catch return error.TransportFailed;
    state.device.finish();

    var header = Header{ .command_type = command_get_display_info };
    try request(std.mem.asBytes(&header), response_ok_display_info, @sizeOf(DisplayInfo));
    const mode = state.response.displays[0];
    if (mode.enabled == 0) return error.DisplayUnavailable;
    if (mode.rectangle.width < width or mode.rectangle.height < height) return error.InvalidDimensions;

    state.backing_address = allocator.allocateContiguous(backing_frames) orelse return error.AllocationFailed;
    const rectangle = Rectangle{ .width = width, .height = height };
    var create = Create2d{ .header = .{ .command_type = command_resource_create_2d }, .resource = resource_id, .format = format_b8g8r8x8_unorm, .width = rectangle.width, .height = rectangle.height };
    try request(std.mem.asBytes(&create), response_ok_nodata, @sizeOf(Header));
    var backing = Backing{ .header = .{ .command_type = command_attach_backing }, .resource = resource_id, .entries = 1, .address = state.backing_address, .length = backing_bytes };
    try request(std.mem.asBytes(&backing), response_ok_nodata, @sizeOf(Header));
    var scanout = ResourceRectangle{ .header = .{ .command_type = command_set_scanout }, .rectangle = rectangle, .scanout = 0, .resource = resource_id };
    try request(std.mem.asBytes(&scanout), response_ok_nodata, @sizeOf(Header));

    const bytes: [*]u8 = @ptrFromInt(state.backing_address);
    return .{ .bytes = bytes[0..backing_bytes], .presentFn = present };
}

fn findDevice(transport_bases: []const u64) virtio.Error!virtio.Device {
    for (transport_bases) |base| {
        return virtio.Device.at(base, virtio.gpu_device_id) catch continue;
    }
    return error.DeviceNotFound;
}

fn present(x: u32, y: u32, rectangle_width: u32, rectangle_height: u32) Error!void {
    if (x > width or y > height or rectangle_width > width - x or rectangle_height > height - y) return error.InvalidDimensions;
    const rectangle = Rectangle{ .x = x, .y = y, .width = rectangle_width, .height = rectangle_height };
    var transfer = Transfer{ .header = .{ .command_type = command_transfer_to_host_2d }, .rectangle = rectangle, .offset = (@as(u64, y) * width + x) * 4, .resource = resource_id };
    try request(std.mem.asBytes(&transfer), response_ok_nodata, @sizeOf(Header));
    var flush = Flush{ .header = .{ .command_type = command_resource_flush }, .rectangle = rectangle, .resource = resource_id };
    try request(std.mem.asBytes(&flush), response_ok_nodata, @sizeOf(Header));
}

fn request(command: []const u8, expected_type: u32, minimum_response: u32) Error!void {
    if (command.len > state.command.len) return error.TransportFailed;
    @memcpy(state.command[0..command.len], command);
    @memset(std.mem.asBytes(&state.response), 0);
    state.queue.descriptors[0] = .{ .address = virtio.dmaAddress(&state.command) catch return error.TransportFailed, .length = @intCast(command.len), .flags = virtio.descriptor_next, .next = 1 };
    state.queue.descriptors[1] = .{ .address = virtio.dmaAddress(&state.response) catch return error.TransportFailed, .length = @sizeOf(DisplayInfo), .flags = virtio.descriptor_write };
    state.queue.submit(state.device, 0, 0);
    const completion = state.queue.wait(poll_limit) catch return error.TransportFailed;
    try validateCompletion(completion.identifier, completion.length, minimum_response);
    const response_type = @as(*const volatile u32, @ptrCast(&state.response.header.command_type)).*;
    return validateResponse(response_type, expected_type);
}

fn validateCompletion(identifier: u32, length: u32, minimum: u32) error{InvalidCompletion}!void {
    if (identifier != 0 or length < minimum or length > @sizeOf(DisplayInfo)) {
        return error.InvalidCompletion;
    }
}

pub fn validateResponse(actual: u32, expected: u32) error{InvalidResponse}!void {
    if (actual != expected) return error.InvalidResponse;
}

test "GPU responses require the exact command completion type" {
    try validateResponse(response_ok_display_info, response_ok_display_info);
    try std.testing.expectError(error.InvalidResponse, validateResponse(response_ok_nodata, response_ok_display_info));
    try std.testing.expectError(error.InvalidResponse, validateResponse(0x1200, response_ok_nodata));
}

test "GPU completions require the submitted head and full response" {
    try validateCompletion(0, @sizeOf(DisplayInfo), @sizeOf(DisplayInfo));
    try std.testing.expectError(error.InvalidCompletion, validateCompletion(1, @sizeOf(Header), @sizeOf(Header)));
    try std.testing.expectError(error.InvalidCompletion, validateCompletion(0, @sizeOf(Header) - 1, @sizeOf(Header)));
    try std.testing.expectError(error.InvalidCompletion, validateCompletion(0, @sizeOf(DisplayInfo) + 1, @sizeOf(Header)));
}
