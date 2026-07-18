//! Raspberry Pi 4 UART0 (PL011) console on GPIO 14 and GPIO 15.
//!
//! BCM2711 maps peripherals at `0xfe00_0000`. The boot configuration fixes
//! UART0's input clock at 48 MHz, so divisors 26 + 3/64 select 115200 baud.

pub const supports_timer_interrupts = false;

const gpio_base = 0xfe20_0000;
const uart_base = 0xfe20_1000;

const gpio_function_select_1 = gpio_base + 0x04;
const gpio_pull_control_0 = gpio_base + 0xe4;

const data = uart_base + 0x00;
const flags = uart_base + 0x18;
const integer_baud_rate = uart_base + 0x24;
const fractional_baud_rate = uart_base + 0x28;
const line_control = uart_base + 0x2c;
const control = uart_base + 0x30;
const interrupt_mask = uart_base + 0x38;
const interrupt_clear = uart_base + 0x44;
const dma_control = uart_base + 0x48;

pub fn init() void {
    write(control, 0);
    while (read(flags) & (1 << 3) != 0) {}

    var functions = read(gpio_function_select_1);
    functions &= ~@as(u32, (0b111 << 12) | (0b111 << 15));
    functions |= (0b100 << 12) | (0b100 << 15);
    write(gpio_function_select_1, functions);

    var pulls = read(gpio_pull_control_0);
    pulls &= ~@as(u32, 0xf000_0000);
    write(gpio_pull_control_0, pulls);
    asm volatile ("dsb sy" ::: .{ .memory = true });

    write(interrupt_clear, 0x7ff);
    write(interrupt_mask, 0);
    write(dma_control, 0);
    write(integer_baud_rate, 26);
    write(fractional_baud_rate, 3);
    write(line_control, (0b11 << 5) | (1 << 4));
    write(control, (1 << 9) | (1 << 8) | 1);
}

pub fn writeByte(byte: u8) void {
    while (read(flags) & (1 << 5) != 0) {}
    write(data, byte);
}

fn read(address: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn write(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}
