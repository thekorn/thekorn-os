const base = 0x0900_0000;
const data = base + 0x00;
const flags = base + 0x18;
const integer_baud_rate = base + 0x24;
const fractional_baud_rate = base + 0x28;
const line_control = base + 0x2c;
const control = base + 0x30;
const interrupt_clear = base + 0x44;

pub fn init() void {
    write(control, 0);
    write(interrupt_clear, 0x7ff);
    write(integer_baud_rate, 13);
    write(fractional_baud_rate, 1);
    write(line_control, 0b11 << 5);
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
