//! BCM2711 mailbox transport for firmware property-channel messages.

const mailbox_base = 0xfe00_b880;
const read_register = mailbox_base;
const read_status_register = mailbox_base + 0x18;
const write_register = mailbox_base + 0x20;
const write_status_register = mailbox_base + 0x38;
const status_full: u32 = 1 << 31;
const status_empty: u32 = 1 << 30;
const property_channel: u32 = 8;
const vc_address_alias: u32 = 0xc000_0000;
const poll_limit = 10_000_000;

pub const Error = error{ InvalidAddress, Timeout };

/// Submit one 16-byte-aligned property message. Firmware consumes a VC bus
/// address, while the CPU accesses the same storage through its Arm address.
pub fn property(message: []align(16) volatile u32) Error!void {
    const arm_address = @intFromPtr(message.ptr);
    if (arm_address > 0x3fff_fff0 or arm_address & 0xf != 0) return error.InvalidAddress;
    const request: u32 = @as(u32, @intCast(arm_address)) | vc_address_alias | property_channel;

    asm volatile ("dsb sy" ::: .{ .memory = true });
    var polls: usize = 0;
    while (read(write_status_register) & status_full != 0) : (polls += 1) {
        if (polls == poll_limit) return error.Timeout;
    }
    write(write_register, request);

    polls = 0;
    while (polls < poll_limit) : (polls += 1) {
        if (read(read_status_register) & status_empty != 0) continue;
        if (read(read_register) == request) {
            asm volatile ("dsb sy" ::: .{ .memory = true });
            return;
        }
    }
    return error.Timeout;
}

fn read(address: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn write(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}
