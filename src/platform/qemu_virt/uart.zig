//! Minimal driver for UART0 on the QEMU Arm `virt` machine.
//!
//! QEMU maps UART0 as an Arm PrimeCell PL011 device in the guest's physical
//! address space. QEMU chooses the `0x0900_0000` base address; the PL011
//! programmer's model defines the fixed register offsets added to that base.
//! The registers are 32-bit memory-mapped I/O, so accesses must be volatile.
//!
//! References:
//! - QEMU `virt` memory map and PL011 creation:
//!   https://github.com/qemu/qemu/blob/master/hw/arm/virt.c
//! - Arm PrimeCell UART (PL011) Technical Reference Manual, Programmer's Model:
//!   https://developer.arm.com/documentation/ddi0183/latest/

pub const supports_timer_interrupts = true;
pub const gic = @import("gic.zig");

// QEMU VIRT_UART0: guest physical address 0x0900_0000, region size 0x1000.
const base = 0x0900_0000;

// PL011 register addresses. Names in comments match the Arm manual.
// UARTDR: data written here is placed in the transmit FIFO.
const data = base + 0x00;
// UARTFR: status flags, including transmit FIFO full (TXFF, bit 5).
const flags = base + 0x18;
// UARTIBRD and UARTFBRD: integer and fractional baud-rate divisors.
const integer_baud_rate = base + 0x24;
const fractional_baud_rate = base + 0x28;
// UARTLCR_H: word length, FIFO, parity, and stop-bit configuration.
const line_control = base + 0x2c;
// UARTCR: enables the UART and its transmit/receive paths.
const control = base + 0x30;
// UARTICR: writing one to a bit clears the corresponding interrupt.
const interrupt_clear = base + 0x44;

pub fn init() void {
    // Disable the UART while changing its configuration.
    write(control, 0);
    // Clear all eleven PL011 interrupt sources.
    write(interrupt_clear, 0x7ff);
    // QEMU supplies a 24 MHz UART clock. Divisors 13 + 1/64 select a baud
    // rate close to 115200: baud = clock / (16 * divisor).
    write(integer_baud_rate, 13);
    write(fractional_baud_rate, 1);
    // WLEN (bits 6:5) = 0b11 selects eight data bits. Other fields remain
    // zero, selecting one stop bit, no parity, and disabled FIFOs (8N1).
    write(line_control, 0b11 << 5);
    // Enable receive (RXE, bit 9), transmit (TXE, bit 8), and the UART
    // peripheral itself (UARTEN, bit 0).
    write(control, (1 << 9) | (1 << 8) | 1);
}

pub fn writeByte(byte: u8) void {
    _ = read(flags);
    write(data, byte);
}

fn read(address: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn write(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}
