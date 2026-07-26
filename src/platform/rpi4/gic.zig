//! GIC-400 interrupt controller for the Raspberry Pi 4 BCM2711.
//!
//! BCM2711 places the GIC-400 distributor at hexadecimal FF841000 and its CPU
//! interface at hexadecimal FF842000. The Arm generic physical timer uses
//! PPI 30.

pub const distributor_base = 0xff84_1000;
pub const cpu_interface_base = 0xff84_2000;

const distributor_control = distributor_base + 0x000;
const interrupt_set_enable = distributor_base + 0x100;
const interrupt_clear_enable = distributor_base + 0x180;
const interrupt_clear_pending = distributor_base + 0x280;
const interrupt_priority = distributor_base + 0x400;
const interrupt_target = distributor_base + 0x800;
const interrupt_configuration = distributor_base + 0xc00;

const cpu_control = cpu_interface_base + 0x000;
const priority_mask = cpu_interface_base + 0x004;
const interrupt_acknowledge = cpu_interface_base + 0x00c;
const end_of_interrupt = cpu_interface_base + 0x010;

pub const physical_timer_interrupt = 30;
pub const first_special_interrupt = 1020;

pub fn init() void {
    write32(distributor_control, 0);
    configure(physical_timer_interrupt);
    write32(distributor_control, 1);

    write32(priority_mask, 0xff);
    write32(cpu_control, 1);
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb");
}

pub fn enable(interrupt_id: u32) void {
    const bank = interrupt_id / 32;
    const bit = @as(u32, 1) << @intCast(interrupt_id % 32);
    write32(interrupt_clear_enable + 4 * bank, bit);
    asm volatile ("dsb sy" ::: .{ .memory = true });
    const configuration_address = interrupt_configuration + 4 * (interrupt_id / 16);
    const edge_bit = @as(u32, 1) << @intCast((interrupt_id % 16) * 2 + 1);
    write32(configuration_address, read32(configuration_address) & ~edge_bit);
    write8(interrupt_priority + interrupt_id, 0x80);
    write8(interrupt_target + interrupt_id, 1);
    write32(interrupt_clear_pending + 4 * bank, bit);
    write32(interrupt_set_enable + 4 * bank, bit);
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn configure(interrupt_id: u32) void {
    const bank = interrupt_id / 32;
    const bit = @as(u32, 1) << @intCast(interrupt_id % 32);
    write8(interrupt_priority + interrupt_id, 0x80);
    if (interrupt_id >= 32) write8(interrupt_target + interrupt_id, 1);
    write32(interrupt_clear_pending + 4 * bank, bit);
    write32(interrupt_set_enable + 4 * bank, bit);
}

pub fn acknowledge() u32 {
    return read32(interrupt_acknowledge);
}

pub fn interruptId(acknowledgement: u32) u32 {
    return acknowledgement & 0x3ff;
}

pub fn end(acknowledgement: u32) void {
    write32(end_of_interrupt, acknowledgement);
}

fn read32(address: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn write32(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

fn write8(address: usize, value: u8) void {
    @as(*volatile u8, @ptrFromInt(address)).* = value;
}
