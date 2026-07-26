//! Modern virtio-MMIO discovery, feature negotiation, and split queues.

const std = @import("std");
const builtin = @import("builtin");

const transport_base = 0x0a00_0000;
const transport_count = 32;
const transport_stride = 0x200;
const magic_value = 0x7472_6976;
const modern_version = 2;

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

const status_acknowledge = 1;
const status_driver = 2;
const status_driver_ok = 4;
const status_features_ok = 8;
const feature_version_one: u64 = @as(u64, 1) << 32;
const available_no_interrupt = 1;

pub const block_device_id = 2;
pub const gpu_device_id = 16;
pub const descriptor_next = 1;
pub const descriptor_write = 2;

pub const Error = error{
    DeviceNotFound,
    FeatureNegotiationFailed,
    QueueUnavailable,
    InvalidDmaAddress,
    Timeout,
};

pub const Descriptor = extern struct {
    address: u64 = 0,
    length: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

pub const UsedElement = extern struct {
    identifier: u32 = 0,
    length: u32 = 0,
};

pub const Device = struct {
    base: usize,

    pub fn at(base: u64, identifier: u32) Error!Device {
        const transport_end = transport_base + transport_count * transport_stride;
        if (base < transport_base or base >= transport_end or
            (base - transport_base) % transport_stride != 0 or
            base > std.math.maxInt(usize))
        {
            return error.DeviceNotFound;
        }
        const candidate = Device{ .base = @intCast(base) };
        if (candidate.read(0) != magic_value or
            candidate.read(4) != modern_version or
            candidate.read(8) != identifier)
        {
            return error.DeviceNotFound;
        }
        return candidate;
    }

    pub fn find(identifier: u32) Error!Device {
        for (0..transport_count) |index| {
            return Device.at(transport_base + index * transport_stride, identifier) catch continue;
        }
        return error.DeviceNotFound;
    }

    pub fn negotiate(self: Device, required_features: u64) Error!void {
        self.write(device_status, 0);
        if (self.read(device_status) != 0) return error.FeatureNegotiationFailed;
        self.write(device_status, status_acknowledge);
        self.write(device_status, status_acknowledge | status_driver);

        const required = required_features | feature_version_one;
        if (self.features() & required != required) return error.FeatureNegotiationFailed;
        self.write(driver_features_select, 0);
        self.write(driver_features, @truncate(required));
        self.write(driver_features_select, 1);
        self.write(driver_features, @truncate(required >> 32));
        self.write(device_status, status_acknowledge | status_driver | status_features_ok);
        if (self.read(device_status) & status_features_ok == 0) {
            return error.FeatureNegotiationFailed;
        }
    }

    pub fn finish(self: Device) void {
        self.write(
            device_status,
            status_acknowledge | status_driver | status_features_ok | status_driver_ok,
        );
    }

    pub fn notify(self: Device, queue_index: u16) void {
        self.write(queue_notify, queue_index);
    }

    pub fn readConfig(self: Device, offset: usize) u32 {
        return self.read(0x100 + offset);
    }

    pub fn readTransport(self: Device, offset: usize) u32 {
        return self.read(offset);
    }

    fn features(self: Device) u64 {
        self.write(device_features_select, 0);
        const low = self.read(device_features);
        self.write(device_features_select, 1);
        return (@as(u64, self.read(device_features)) << 32) | low;
    }

    fn selectQueue(self: Device, index: u16, size: u16) Error!void {
        self.write(queue_select, index);
        if (self.read(queue_ready) != 0 or self.read(queue_size_maximum) < size) {
            return error.QueueUnavailable;
        }
        self.write(queue_size_register, size);
    }

    fn setQueueAddresses(self: Device, descriptors: anytype, driver: anytype, used: anytype) Error!void {
        try self.writeAddress(queue_descriptors_low, queue_descriptors_high, descriptors);
        try self.writeAddress(queue_driver_low, queue_driver_high, driver);
        try self.writeAddress(queue_device_low, queue_device_high, used);
        self.write(queue_ready, 1);
    }

    fn writeAddress(self: Device, low_register: usize, high_register: usize, pointer: anytype) Error!void {
        const address = try dmaAddress(pointer);
        self.write(low_register, @truncate(address));
        self.write(high_register, @truncate(address >> 32));
    }

    fn read(self: Device, offset: usize) u32 {
        return @as(*const volatile u32, @ptrFromInt(self.base + offset)).*;
    }

    fn write(self: Device, offset: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(self.base + offset)).* = value;
    }
};

pub fn Queue(comptime size: u16) type {
    if (size == 0) @compileError("a virtio queue cannot be empty");
    return struct {
        pub const Available = extern struct {
            flags: u16 = 0,
            index: u16 = 0,
            ring: [size]u16 = @splat(0),
            used_event: u16 = 0,
        };
        pub const Used = extern struct {
            flags: u16 = 0,
            index: u16 = 0,
            ring: [size]UsedElement = @splat(.{}),
            available_event: u16 = 0,
        };

        descriptors: [size]Descriptor align(16) = @splat(.{}),
        available: Available align(2) = .{},
        used: Used align(8) = .{},
        last_used: u16 = 0,

        const Self = @This();

        pub fn initialize(self: *Self, device: Device, index: u16) Error!void {
            self.* = .{};
            try device.selectQueue(index, size);
            try device.setQueueAddresses(&self.descriptors, &self.available, &self.used);
        }

        pub fn submit(self: *Self, device: Device, queue_index: u16, head: u16) void {
            const available_index = volatileRead(u16, &self.available.index);
            self.available.flags = available_no_interrupt;
            self.available.ring[available_index % size] = head;
            releaseBarrier();
            volatileWrite(u16, &self.available.index, available_index +% 1);
            releaseBarrier();
            device.notify(queue_index);
        }

        pub fn pollCompletion(self: *Self) ?UsedElement {
            if (self.usedIndex() == self.last_used) return null;
            acquireBarrier();
            const slot = &self.used.ring[self.last_used % size];
            var element: UsedElement align(8) = undefined;
            element.identifier = volatileReadU32(&slot.identifier);
            element.length = volatileReadU32(&slot.length);
            self.last_used +%= 1;
            return element;
        }

        pub fn wait(self: *Self, poll_limit: usize) Error!UsedElement {
            var polls: usize = 0;
            while (true) : (polls += 1) {
                if (self.usedIndex() != self.last_used) {
                    acquireBarrier();
                    const slot = &self.used.ring[self.last_used % size];
                    var completion: UsedElement align(8) = undefined;
                    completion.identifier = volatileReadU32(&slot.identifier);
                    completion.length = volatileReadU32(&slot.length);
                    self.last_used +%= 1;
                    return completion;
                }
                if (polls == poll_limit) return error.Timeout;
            }
        }

        fn usedIndex(self: *Self) u16 {
            return volatileReadU16(&self.used.index);
        }
    };
}

pub fn dmaAddress(pointer: anytype) Error!u64 {
    const address: u64 = @intCast(@intFromPtr(pointer));
    if (address >= 0x0001_0000_0000_0000) return error.InvalidDmaAddress;
    return address;
}

fn volatileRead(comptime T: type, pointer: *const T) T {
    return @as(*const volatile T, @ptrCast(pointer)).*;
}

fn volatileReadByte(pointer: *const u8) u8 {
    if (builtin.cpu.arch == .aarch64) {
        const value = asm volatile ("ldrb w8, [%[address]]"
            : [value] "={x8}" (-> u32),
            : [address] "r" (pointer),
            : .{ .memory = true });
        return @truncate(value);
    }
    return volatileRead(u8, pointer);
}

fn volatileWrite(comptime T: type, pointer: *T, value: T) void {
    @as(*volatile T, @ptrCast(pointer)).* = value;
}

fn volatileReadU16(pointer: *const u16) u16 {
    if (builtin.cpu.arch == .aarch64) {
        const value = asm volatile ("ldrh w8, [%[address]]"
            : [value] "={x8}" (-> u32),
            : [address] "r" (pointer),
            : .{ .memory = true });
        return @truncate(value);
    }
    return volatileRead(u16, pointer);
}

fn volatileReadU32(pointer: *const u32) u32 {
    const bytes: *const [4]u8 = @ptrCast(pointer);
    return @as(u32, volatileReadByte(&bytes[0])) |
        (@as(u32, volatileReadByte(&bytes[1])) << 8) |
        (@as(u32, volatileReadByte(&bytes[2])) << 16) |
        (@as(u32, volatileReadByte(&bytes[3])) << 24);
}

fn releaseBarrier() void {
    if (builtin.cpu.arch == .aarch64) {
        asm volatile ("dmb oshst" ::: .{ .memory = true });
    } else {
        asm volatile ("" ::: .{ .memory = true });
    }
}

fn acquireBarrier() void {
    if (builtin.cpu.arch == .aarch64) {
        asm volatile ("dmb osh" ::: .{ .memory = true });
    } else {
        asm volatile ("" ::: .{ .memory = true });
    }
}

test "split queue submits, completes, and reuses descriptors" {
    var registers: [0x108 / @sizeOf(u32)]u32 align(4) = @splat(0);
    const device = Device{ .base = @intFromPtr(&registers) };
    var queue: Queue(2) = .{};
    queue.descriptors[0] = .{ .address = 0x1000, .length = 16 };

    queue.submit(device, 3, 0);
    try std.testing.expectEqual(@as(u16, 1), queue.available.index);
    try std.testing.expectEqual(@as(u16, 0), queue.available.ring[0]);
    try std.testing.expectEqual(@as(u32, 3), registers[queue_notify / @sizeOf(u32)]);
    try std.testing.expectEqual(null, queue.pollCompletion());

    queue.used.ring[0] = .{ .identifier = 0, .length = 16 };
    queue.used.index = 1;
    try std.testing.expectEqual(UsedElement{ .identifier = 0, .length = 16 }, queue.pollCompletion().?);
    try std.testing.expectEqual(null, queue.pollCompletion());

    queue.submit(device, 3, 0);
    queue.used.ring[1] = .{ .identifier = 0, .length = 8 };
    queue.used.index = 2;
    try std.testing.expectEqual(@as(u32, 8), (try queue.wait(1)).length);
    try std.testing.expectEqual(@as(u16, 2), queue.last_used);
}

test "split queue wait is bounded" {
    var queue: Queue(2) = .{};
    try std.testing.expectError(error.Timeout, queue.wait(0));
}
