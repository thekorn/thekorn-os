pub fn Console(comptime writeByte: fn (u8) void) type {
    return struct {
        pub inline fn write(bytes: []const u8) void {
            for (bytes) |byte| {
                if (byte == '\n') writeByte('\r');
                writeByte(byte);
            }
        }

        pub inline fn writeHex(prefix: []const u8, value: usize) void {
            const digits = "0123456789abcdef";
            for (prefix) |byte| writeByte(byte);
            writeByte('0');
            writeByte('x');
            var shift: usize = @bitSizeOf(usize) - 4;
            while (true) {
                writeByte(digits[(value >> @intCast(shift)) & 0xf]);
                if (shift == 0) break;
                shift -= 4;
            }
            writeByte('\r');
            writeByte('\n');
        }

        inline fn writeValue(prefix: []const u8, value: usize) void {
            for (prefix) |byte| writeByte(byte);
            if (value >= 10) writeByte('0' + @as(u8, @intCast(value / 10)));
            writeByte('0' + @as(u8, @intCast(value % 10)));
            writeByte('\r');
            writeByte('\n');
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
        }

        pub inline fn writePanic(message: []const u8) void {
            write("PANIC:");
            write(message);
            write("\n");
        }
    };
}
