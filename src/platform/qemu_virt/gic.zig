//! GICv2 interrupt controller for the QEMU Arm `virt` machine.

const distributor_base = 0x0800_0000;
const cpu_interface_base = 0x0801_0000;

const distributor_control = distributor_base + 0x000;
const interrupt_set_enable = distributor_base + 0x100;
const interrupt_clear_pending = distributor_base + 0x280;
const interrupt_priority = distributor_base + 0x400;

const cpu_control = cpu_interface_base + 0x000;
const priority_mask = cpu_interface_base + 0x004;
const interrupt_acknowledge = cpu_interface_base + 0x00c;
const end_of_interrupt = cpu_interface_base + 0x010;

pub const physical_timer_interrupt = 30;
pub const first_special_interrupt = 1020;

pub fn init() void {
    write32(distributor_control, 0);
    write8(interrupt_priority + physical_timer_interrupt, 0x80);
    write32(interrupt_clear_pending, @as(u32, 1) << physical_timer_interrupt);
    write32(interrupt_set_enable, @as(u32, 1) << physical_timer_interrupt);
    write32(distributor_control, 1);

    write32(priority_mask, 0xff);
    write32(cpu_control, 1);
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb");
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
