//! Polling virtio-MMIO block driver for the QEMU Arm `virt` machine.

const virtio = @import("virtio.zig");

pub const sector_size = 512;
pub const ready_marker = "VIRTIO_BLK:OK\n";
const queue_size = 8;
const poll_limit = 10_000_000;
const queue_index = 0;
const config_generation = 0x0fc;
const config_capacity_low = 0;
const config_capacity_high = 4;

pub const InitError = error{
    DeviceNotFound,
    FeatureNegotiationFailed,
    QueueUnavailable,
    InvalidDmaAddress,
    InvalidCapacity,
};

pub const ReadError = error{
    InvalidBuffer,
    OutOfBounds,
    IoFailure,
};

const RequestHeader = extern struct {
    request_type: u32 = 0,
    reserved: u32 = 0,
    sector: u64 = 0,
};

const State = struct {
    device: virtio.Device = .{ .base = 0 },
    capacity: u64 = 0,
    queue: virtio.Queue(queue_size) = .{},
    request: RequestHeader align(16) = .{},
    request_status: u8 = 0xff,
    sector: [sector_size]u8 align(16) = undefined,
};

var state: State = .{};

pub fn initialize() InitError!void {
    state = .{};
    state.device = virtio.Device.find(virtio.block_device_id) catch |err| return mapInitError(err);
    state.device.negotiate(0) catch |err| return mapInitError(err);
    state.queue.initialize(state.device, queue_index) catch |err| return mapInitError(err);
    state.device.finish();
    state.capacity = readCapacity();
    if (state.capacity == 0) return error.InvalidCapacity;
}

pub fn context() *anyopaque {
    return &state;
}

pub fn blockCount() u64 {
    return state.capacity;
}

pub fn readBlocks(context_pointer: *anyopaque, first_block: u64, destination: []u8) ReadError!void {
    const device: *State = @ptrCast(@alignCast(context_pointer));
    var offset: usize = 0;
    var sector = first_block;
    while (offset < destination.len) : ({
        offset += sector_size;
        sector += 1;
    }) {
        readSector(device, sector, destination[offset..][0..sector_size]) catch return error.IoFailure;
    }
}

const RequestError = error{ InvalidDmaAddress, Timeout, InvalidCompletion, DeviceError };

fn readSector(device: *State, sector: u64, destination: *[sector_size]u8) RequestError!void {
    device.request = .{ .sector = sector };
    volatileWrite(u8, &device.request_status, 0xff);
    device.queue.descriptors[0] = .{
        .address = virtio.dmaAddress(&device.request) catch return error.InvalidDmaAddress,
        .length = @sizeOf(RequestHeader),
        .flags = virtio.descriptor_next,
        .next = 1,
    };
    device.queue.descriptors[1] = .{
        .address = virtio.dmaAddress(&device.sector) catch return error.InvalidDmaAddress,
        .length = sector_size,
        .flags = virtio.descriptor_next | virtio.descriptor_write,
        .next = 2,
    };
    device.queue.descriptors[2] = .{
        .address = virtio.dmaAddress(&device.request_status) catch return error.InvalidDmaAddress,
        .length = 1,
        .flags = virtio.descriptor_write,
    };

    device.queue.submit(device.device, queue_index, 0);
    const completion = device.queue.wait(poll_limit) catch return error.Timeout;
    if (completion.identifier != 0) return error.InvalidCompletion;
    if (volatileRead(u8, &device.request_status) != 0) return error.DeviceError;
    for (destination, device.sector) |*output, byte| output.* = byte;
}

fn readCapacity() u64 {
    while (true) {
        const before = state.device.readTransport(config_generation);
        const low = state.device.readConfig(config_capacity_low);
        const high = state.device.readConfig(config_capacity_high);
        if (before == state.device.readTransport(config_generation)) return (@as(u64, high) << 32) | low;
    }
}

fn mapInitError(err: virtio.Error) InitError {
    return switch (err) {
        error.DeviceNotFound => error.DeviceNotFound,
        error.FeatureNegotiationFailed => error.FeatureNegotiationFailed,
        error.QueueUnavailable => error.QueueUnavailable,
        error.InvalidDmaAddress => error.InvalidDmaAddress,
        error.Timeout => unreachable,
    };
}

fn volatileRead(comptime T: type, pointer: *const T) T {
    return @as(*const volatile T, @ptrCast(pointer)).*;
}

fn volatileWrite(comptime T: type, pointer: *T, value: T) void {
    @as(*volatile T, @ptrCast(pointer)).* = value;
}
