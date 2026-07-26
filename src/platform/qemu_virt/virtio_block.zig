//! Polling virtio-mmio block driver for the QEMU Arm `virt` machine.

const transport_base = 0x0a00_0000;
const transport_count = 32;
const transport_stride = 0x200;
const magic_value = 0x7472_6976;
const modern_version = 2;
const block_device_id = 2;
pub const sector_size = 512;
pub const ready_marker = "VIRTIO_BLK:OK\n";
const queue_size = 8;
const poll_limit = 10_000_000;

const device_features = 0x010;
const device_features_select = 0x014;
const driver_features = 0x020;
const driver_features_select = 0x024;
const queue_select = 0x030;
const queue_size_maximum = 0x034;
const queue_size_register = 0x038;
const queue_ready = 0x044;
const queue_notify = 0x050;
const device_status = 0x070;
const queue_descriptors_low = 0x080;
const queue_descriptors_high = 0x084;
const queue_driver_low = 0x090;
const queue_driver_high = 0x094;
const queue_device_low = 0x0a0;
const queue_device_high = 0x0a4;
const config_generation = 0x0fc;
const config_capacity_low = 0x100;
const config_capacity_high = 0x104;

const status_acknowledge = 1;
const status_driver = 2;
const status_driver_ok = 4;
const status_features_ok = 8;
const feature_version_one: u32 = 1;
const descriptor_next = 1;
const descriptor_write = 2;
const available_no_interrupt = 1;

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

const Descriptor = extern struct {
    address: u64 = 0,
    length: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

const Available = extern struct {
    flags: u16 = 0,
    index: u16 = 0,
    ring: [queue_size]u16 = @splat(0),
    used_event: u16 = 0,
};

const UsedElement = extern struct {
    identifier: u32 = 0,
    length: u32 = 0,
};

const Used = extern struct {
    flags: u16 = 0,
    index: u16 = 0,
    ring: [queue_size]UsedElement = @splat(.{}),
    available_event: u16 = 0,
};

const RequestHeader = extern struct {
    request_type: u32 = 0,
    reserved: u32 = 0,
    sector: u64 = 0,
};

const State = struct {
    base: usize = 0,
    capacity: u64 = 0,
    last_used: u16 = 0,
    descriptors: [queue_size]Descriptor align(16) = @splat(.{}),
    available: Available align(2) = .{},
    used: Used align(4) = .{},
    request: RequestHeader align(16) = .{},
    request_status: u8 = 0xff,
    sector: [sector_size]u8 align(16) = undefined,
};

var state: State = .{};

pub fn initialize() InitError!void {
    state = .{};
    state.base = findDevice() orelse return error.DeviceNotFound;

    writeRegister(device_status, 0);
    if (readRegister(device_status) != 0) return error.FeatureNegotiationFailed;
    writeRegister(device_status, status_acknowledge);
    writeRegister(device_status, status_acknowledge | status_driver);

    writeRegister(device_features_select, 1);
    if (readRegister(device_features) & feature_version_one == 0) {
        return error.FeatureNegotiationFailed;
    }
    writeRegister(driver_features_select, 0);
    writeRegister(driver_features, 0);
    writeRegister(driver_features_select, 1);
    writeRegister(driver_features, feature_version_one);
    writeRegister(device_status, status_acknowledge | status_driver | status_features_ok);
    if (readRegister(device_status) & status_features_ok == 0) {
        return error.FeatureNegotiationFailed;
    }

    writeRegister(queue_select, 0);
    if (readRegister(queue_ready) != 0 or readRegister(queue_size_maximum) < queue_size) {
        return error.QueueUnavailable;
    }
    writeRegister(queue_size_register, queue_size);
    try writeAddress(queue_descriptors_low, queue_descriptors_high, &state.descriptors);
    try writeAddress(queue_driver_low, queue_driver_high, &state.available);
    try writeAddress(queue_device_low, queue_device_high, &state.used);
    writeRegister(queue_ready, 1);
    writeRegister(
        device_status,
        status_acknowledge | status_driver | status_features_ok | status_driver_ok,
    );
    state.capacity = readCapacity();
    if (state.capacity == 0) return error.InvalidCapacity;
}

pub fn context() *anyopaque {
    return &state;
}

pub fn blockCount() u64 {
    return state.capacity;
}

fn findDevice() ?usize {
    for (0..transport_count) |index| {
        const base = transport_base + index * transport_stride;
        if (readMmio(base) == magic_value and
            readMmio(base + 4) == modern_version and
            readMmio(base + 8) == block_device_id)
        {
            return base;
        }
    }
    return null;
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
    device.descriptors[0] = .{
        .address = try dmaAddress(&device.request),
        .length = @sizeOf(RequestHeader),
        .flags = descriptor_next,
        .next = 1,
    };
    device.descriptors[1] = .{
        .address = try dmaAddress(&device.sector),
        .length = sector_size,
        .flags = descriptor_next | descriptor_write,
        .next = 2,
    };
    device.descriptors[2] = .{
        .address = try dmaAddress(&device.request_status),
        .length = 1,
        .flags = descriptor_write,
    };

    const available_index = volatileRead(u16, &device.available.index);
    device.available.flags = available_no_interrupt;
    device.available.ring[available_index % queue_size] = 0;
    asm volatile ("dmb oshst" ::: .{ .memory = true });
    volatileWrite(u16, &device.available.index, available_index +% 1);
    asm volatile ("dmb oshst" ::: .{ .memory = true });
    writeRegister(queue_notify, 0);

    var polls: usize = 0;
    while (volatileRead(u16, &device.used.index) == device.last_used) : (polls += 1) {
        if (polls == poll_limit) return error.Timeout;
    }
    asm volatile ("dmb osh" ::: .{ .memory = true });
    const completion_id = volatileRead(
        u32,
        &device.used.ring[device.last_used % queue_size].identifier,
    );
    device.last_used +%= 1;
    if (completion_id != 0) return error.InvalidCompletion;
    if (volatileRead(u8, &device.request_status) != 0) return error.DeviceError;
    for (destination, device.sector) |*output, byte| output.* = byte;
}

fn readCapacity() u64 {
    while (true) {
        const before = readRegister(config_generation);
        const low = readRegister(config_capacity_low);
        const high = readRegister(config_capacity_high);
        if (before == readRegister(config_generation)) return (@as(u64, high) << 32) | low;
    }
}

fn dmaAddress(pointer: anytype) error{InvalidDmaAddress}!u64 {
    const address: u64 = @intCast(@intFromPtr(pointer));
    if (address >= 0x0001_0000_0000_0000) return error.InvalidDmaAddress;
    return address;
}

fn writeAddress(low_register: usize, high_register: usize, pointer: anytype) error{InvalidDmaAddress}!void {
    const address = try dmaAddress(pointer);
    writeRegister(low_register, @truncate(address));
    writeRegister(high_register, @truncate(address >> 32));
}

fn readRegister(offset: usize) u32 {
    return readMmio(state.base + offset);
}

fn writeRegister(offset: usize, value: u32) void {
    writeMmio(state.base + offset, value);
}

fn readMmio(address: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(address)).*;
}

fn writeMmio(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

fn volatileRead(comptime T: type, pointer: *const T) T {
    return @as(*const volatile T, @ptrCast(pointer)).*;
}

fn volatileWrite(comptime T: type, pointer: *T, value: T) void {
    @as(*volatile T, @ptrCast(pointer)).* = value;
}
