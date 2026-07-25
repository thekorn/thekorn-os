const std = @import("std");
const exceptions = @import("../arch/aarch64/exceptions.zig");

pub const task_count = 3;
pub const stack_size = 16 * 1024;

pub const Reason = enum {
    cooperative,
    preemptive,
};

pub const DispatchError = error{
    NotRunning,
    NoRunnableTask,
};

const task_stack = [stack_size]u8;

pub const Scheduler = struct {
    stacks: [task_count]task_stack align(16) = undefined,
    frames: [task_count]*exceptions.Frame = undefined,
    current: ?usize = null,
    cooperative_switch_count: usize = 0,
    preemption_count: usize = 0,
    preemptive_dispatch_counts: [task_count]usize = @splat(0),
    runnable: [task_count]bool = @splat(true),

    pub fn init(self: *Scheduler, entry: u64, spsr: u64) void {
        self.current = null;
        self.cooperative_switch_count = 0;
        self.preemption_count = 0;
        self.preemptive_dispatch_counts = @splat(0);
        self.runnable = @splat(true);

        for (&self.stacks, 0..) |*stack, index| {
            const stack_top = @intFromPtr(stack) + stack_size;
            const frame: *exceptions.Frame = @ptrFromInt(stack_top - exceptions.stack_frame_size);
            frame.* = std.mem.zeroes(exceptions.Frame);
            frame.registers[0] = index;
            frame.elr = entry;
            frame.spsr = spsr;
            self.frames[index] = frame;
        }
    }

    pub fn dispatch(
        self: *Scheduler,
        current_frame: *exceptions.Frame,
        reason: Reason,
    ) DispatchError!*exceptions.Frame {
        const current = self.current orelse {
            if (reason == .preemptive) return error.NotRunning;
            self.current = 0;
            return self.frames[0];
        };

        self.frames[current] = current_frame;
        const next = self.nextRunnable(current) orelse return error.NoRunnableTask;
        self.current = next;
        switch (reason) {
            .cooperative => self.cooperative_switch_count += 1,
            .preemptive => {
                self.preemption_count += 1;
                self.preemptive_dispatch_counts[next] += 1;
            },
        }
        return self.frames[next];
    }

    pub fn blockCurrent(
        self: *Scheduler,
        current_frame: *exceptions.Frame,
    ) DispatchError!*exceptions.Frame {
        const current = self.current orelse return error.NotRunning;
        self.frames[current] = current_frame;
        self.runnable[current] = false;
        const next = self.nextRunnable(current) orelse return error.NoRunnableTask;
        self.current = next;
        return self.frames[next];
    }

    pub fn currentTask(self: *const Scheduler) ?usize {
        return self.current;
    }

    pub fn cooperativeSwitches(self: *const Scheduler) usize {
        return self.cooperative_switch_count;
    }

    pub fn preemptions(self: *const Scheduler) usize {
        return self.preemption_count;
    }

    pub fn preemptiveDispatches(self: *const Scheduler, task: usize) usize {
        return self.preemptive_dispatch_counts[task];
    }

    fn nextRunnable(self: *const Scheduler, current: usize) ?usize {
        for (1..task_count + 1) |distance| {
            const candidate = (current + distance) % task_count;
            if (self.runnable[candidate]) return candidate;
        }
        return null;
    }
};

test "scheduler initializes separate aligned task stacks" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1234_5000, 0x345);

    for (scheduler.frames, 0..) |frame, index| {
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(frame) % 16);
        try std.testing.expectEqual(@as(u64, index), frame.registers[0]);
        try std.testing.expectEqual(@as(u64, 0x1234_5000), frame.elr);
        try std.testing.expectEqual(@as(u64, 0x345), frame.spsr);
        if (index != 0) {
            const previous = @intFromPtr(scheduler.frames[index - 1]);
            try std.testing.expectEqual(@as(usize, stack_size), @intFromPtr(frame) - previous);
        }
    }
}

test "scheduler rotates cooperatively and preemptively" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x345);
    var boot_frame = std.mem.zeroes(exceptions.Frame);

    const first = try scheduler.dispatch(&boot_frame, .cooperative);
    try std.testing.expectEqual(@as(u64, 0), first.registers[0]);
    const second = try scheduler.dispatch(first, .cooperative);
    try std.testing.expectEqual(@as(u64, 1), second.registers[0]);
    const third = try scheduler.dispatch(second, .cooperative);
    try std.testing.expectEqual(@as(u64, 2), third.registers[0]);
    const first_again = try scheduler.dispatch(third, .preemptive);

    try std.testing.expectEqual(first, first_again);
    try std.testing.expectEqual(@as(usize, 2), scheduler.cooperativeSwitches());
    try std.testing.expectEqual(@as(usize, 1), scheduler.preemptions());
    try std.testing.expectEqual(@as(usize, 1), scheduler.preemptiveDispatches(0));
}

test "scheduler rejects preemption before its first dispatch" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x345);
    var frame = std.mem.zeroes(exceptions.Frame);

    try std.testing.expectError(error.NotRunning, scheduler.dispatch(&frame, .preemptive));
}

test "blocked tasks are skipped by subsequent dispatches" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x345);
    var boot_frame = std.mem.zeroes(exceptions.Frame);

    const first = try scheduler.dispatch(&boot_frame, .cooperative);
    const second = try scheduler.dispatch(first, .cooperative);
    const third = try scheduler.dispatch(second, .cooperative);
    const first_after_block = try scheduler.blockCurrent(third);
    const second_again = try scheduler.dispatch(first_after_block, .preemptive);

    try std.testing.expectEqual(@as(u64, 0), first_after_block.registers[0]);
    try std.testing.expectEqual(@as(u64, 1), second_again.registers[0]);
    try std.testing.expectEqual(@as(usize, 1), scheduler.preemptions());
}
