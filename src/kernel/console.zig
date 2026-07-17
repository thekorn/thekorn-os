pub fn Console(comptime write_byte: fn (u8) void) type {
    return struct {
        inline fn write(bytes: []const u8) void {
            for (bytes) |byte| {
                if (byte == '\n') write_byte('\r');
                write_byte(byte);
            }
        }

        inline fn writeHex(prefix: []const u8, value: usize) void {
            const digits = "0123456789abcdef";
            for (prefix) |byte| write_byte(byte);
            write_byte('0');
            write_byte('x');
            var shift: usize = @bitSizeOf(usize) - 4;
            while (true) {
                write_byte(digits[(value >> @intCast(shift)) & 0xf]);
                if (shift == 0) break;
                shift -= 4;
            }
            write_byte('\r');
            write_byte('\n');
        }

        inline fn writeValue(prefix: []const u8, value: usize) void {
            for (prefix) |byte| write_byte(byte);
            if (value >= 10) write_byte('0' + @as(u8, @intCast(value / 10)));
            write_byte('0' + @as(u8, @intCast(value % 10)));
            write_byte('\r');
            write_byte('\n');
        }

        pub fn writeBootFacts(
            dtb: usize,
            current_el: usize,
            mpidr: usize,
            kernel_start: usize,
            kernel_end: usize,
        ) void {
            write("BOOT:START\n");
            writeValue("BOOT:CURRENT_EL=", current_el);
            writeHex("BOOT:MPIDR=", mpidr);
            writeHex("BOOT:DTB=", dtb);
            writeHex("BOOT:KERNEL_START=", kernel_start);
            writeHex("BOOT:KERNEL_END=", kernel_end);
            write("BOOT:OK\n");
            writePanic("phase 1 deliberate panic");
        }

        pub inline fn writePanic(message: []const u8) void {
            write("PANIC:");
            write(message);
            write("\n");
        }
    };
}
