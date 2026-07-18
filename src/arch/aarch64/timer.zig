const std = @import("std");

var tick_count: usize = 0;
var tick_limit: usize = 0;
var interval: u32 = 0;

pub fn init(limit: usize) void {
    const frequency = counterFrequency();
    interval = @intCast(@max(frequency / 1_000, 1));
    tick_limit = limit;
    @atomicStore(usize, &tick_count, 0, .release);
    writeTimerValue(interval);
    writeTimerControl(1);
    instructionSynchronize();
}

pub fn handleInterrupt() void {
    const next = @atomicRmw(usize, &tick_count, .Add, 1, .acq_rel) + 1;
    if (next < tick_limit) {
        writeTimerValue(interval);
    } else {
        writeTimerControl(0);
    }
    instructionSynchronize();
}

pub fn ticks() usize {
    return @atomicLoad(usize, &tick_count, .acquire);
}

fn counterFrequency() u64 {
    return asm volatile ("mrs %[frequency], CNTFRQ_EL0"
        : [frequency] "=r" (-> u64),
    );
}

fn writeTimerValue(value: u32) void {
    asm volatile ("msr CNTP_TVAL_EL0, %[value]"
        :
        : [value] "r" (@as(u64, value)),
    );
}

fn writeTimerControl(value: u64) void {
    asm volatile ("msr CNTP_CTL_EL0, %[value]"
        :
        : [value] "r" (value),
    );
}

fn instructionSynchronize() void {
    asm volatile ("isb");
}

test "tick count reads monotonically" {
    tick_limit = 3;
    @atomicStore(usize, &tick_count, 0, .release);

    const first = ticks();
    _ = @atomicRmw(usize, &tick_count, .Add, 1, .acq_rel);
    const second = ticks();

    try std.testing.expect(second > first);
    try std.testing.expectEqual(1, second);
}
