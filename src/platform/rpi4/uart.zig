//! Polled PL011 console for Raspberry Pi 4 GPIO pins 14 and 15.
//!
//! BCM2711 maps peripherals at `0xfe00_0000`. GPIO alternate function zero
//! connects pins 14 and 15 to PL011 transmit and receive. Raspberry Pi firmware
//! supplies the PL011 with the 48 MHz clock requested by `config.txt`.

const peripheral_base = 0xfe00_0000;
const gpio_base = peripheral_base + 0x20_0000;
const uart_base = peripheral_base + 0x20_1000;

const gpio_function_select_1 = gpio_base + 0x04;
const gpio_pull_up_down_0 = gpio_base + 0xe4;

const data = uart_base + 0x00;
const flags = uart_base + 0x18;
const integer_baud_rate = uart_base + 0x24;
const fractional_baud_rate = uart_base + 0x28;
const line_control = uart_base + 0x2c;
const control = uart_base + 0x30;
const interrupt_mask = uart_base + 0x38;
const interrupt_clear = uart_base + 0x44;

const busy = 1 << 3;
const transmit_fifo_full = 1 << 5;

pub fn init() void {
    // Firmware may still be transmitting second-stage diagnostics. Drain it
    // before disabling PL011, then clear its FIFO configuration before
    // changing the baud rate and line format.
    while (read(flags) & busy != 0) {}
    write(control, 0);
    write(line_control, 0);

    // GPFSEL1 assigns three bits per pin. ALT0 is 0b100 for both GPIO14
    // (PL011 TX) and GPIO15 (PL011 RX).
    var functions = read(gpio_function_select_1);
    functions &= ~@as(u32, (0b111 << 12) | (0b111 << 15));
    functions |= (0b100 << 12) | (0b100 << 15);
    write(gpio_function_select_1, functions);

    // BCM2711 uses GPPUPPDN registers rather than the earlier GPIO pull
    // control sequence. Zero disables pulls for the two UART pins.
    var pulls = read(gpio_pull_up_down_0);
    pulls &= ~@as(u32, (0b11 << 28) | (0b11 << 30));
    write(gpio_pull_up_down_0, pulls);

    write(interrupt_mask, 0);
    write(interrupt_clear, 0x7ff);
    // 48 MHz / (16 * 115200) = 26 + 3/64 after rounding.
    write(integer_baud_rate, 26);
    write(fractional_baud_rate, 3);
    write(line_control, 0b11 << 5);
    write(control, (1 << 9) | (1 << 8) | 1);
}

pub fn writeByte(byte: u8) void {
    while (read(flags) & transmit_fifo_full != 0) {}
    write(data, byte);
}

fn read(address: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn write(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}
