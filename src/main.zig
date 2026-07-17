pub export var boot_dtb: usize = 0;

pub export fn kernelMain(dtb: usize) callconv(.c) noreturn {
    boot_dtb = dtb;
    halt();
}

pub fn panic(_: []const u8, _: ?*anyopaque, _: ?usize) noreturn {
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("wfe");
}
