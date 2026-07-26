const std = @import("std");
const builtin = @import("builtin");
const exceptions = @import("../arch/aarch64/exceptions.zig");

pub const task_count = 3;
pub const stack_size = 16 * 1024;
const idle_task = task_count;
const slot_count = task_count + 1;

pub const State = enum {
    free,
    runnable,
    running,
    blocked,
    sleeping,
};

pub const Reason = enum {
    cooperative,
    preemptive,
};

pub const DispatchError = error{
    NotRunning,
    NoRunnableTask,
    AlreadyWaiting,
    QueueFull,
};

const task_stack = [stack_size]u8;

pub const WaitQueue = struct {
    tasks: [task_count]usize = undefined,
    count: usize = 0,
    pending_wake: bool = false,

    fn remove(self: *WaitQueue, task: usize) bool {
        for (self.tasks[0..self.count], 0..) |queued, index| {
            if (queued != task) continue;
            for (index + 1..self.count) |source| self.tasks[source - 1] = self.tasks[source];
            self.count -= 1;
            return true;
        }
        return false;
    }
};

pub const Scheduler = struct {
    stacks: [slot_count]task_stack align(16) = undefined,
    frames: [slot_count]*exceptions.Frame = undefined,
    current: ?usize = null,
    cooperative_switch_count: usize = 0,
    preemption_count: usize = 0,
    preemptive_dispatch_counts: [task_count]usize = @splat(0),
    states: [slot_count]State = @splat(.free),
    wait_queues: [task_count]?*WaitQueue = @splat(null),
    deadlines: [task_count]usize = @splat(0),
    round_robin_cursor: usize = task_count - 1,

    pub fn init(self: *Scheduler, entry: u64, idle_entry: u64, spsr: u64) void {
        self.current = null;
        self.cooperative_switch_count = 0;
        self.preemption_count = 0;
        self.preemptive_dispatch_counts = @splat(0);
        self.states = @splat(.runnable);
        self.wait_queues = @splat(null);
        self.deadlines = @splat(0);
        self.round_robin_cursor = task_count - 1;

        for (&self.stacks, 0..) |*stack, index| {
            const stack_top = @intFromPtr(stack) + stack_size;
            const frame: *exceptions.Frame = @ptrFromInt(stack_top - exceptions.stack_frame_size);
            frame.* = std.mem.zeroes(exceptions.Frame);
            frame.registers[0] = index;
            frame.elr = if (index == idle_task) idle_entry else entry;
            frame.spsr = spsr;
            self.frames[index] = frame;
        }
    }

    pub fn dispatch(
        self: *Scheduler,
        current_frame: *exceptions.Frame,
        reason: Reason,
    ) DispatchError!*exceptions.Frame {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        const current = self.current orelse {
            if (reason == .preemptive) return error.NotRunning;
            self.current = 0;
            self.states[0] = .running;
            self.round_robin_cursor = 0;
            return self.frames[0];
        };

        self.frames[current] = current_frame;
        if (self.states[current] == .running) self.states[current] = .runnable;
        const next = self.nextRunnable(current) orelse return error.NoRunnableTask;
        self.current = next;
        self.states[next] = .running;
        if (next < task_count) self.round_robin_cursor = next;
        switch (reason) {
            .cooperative => self.cooperative_switch_count += 1,
            .preemptive => {
                self.preemption_count += 1;
                if (next < task_count) self.preemptive_dispatch_counts[next] += 1;
            },
        }
        return self.frames[next];
    }

    pub fn blockCurrent(
        self: *Scheduler,
        current_frame: *exceptions.Frame,
    ) DispatchError!*exceptions.Frame {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        const current = self.current orelse return error.NotRunning;
        self.frames[current] = current_frame;
        self.states[current] = .blocked;
        const next = self.nextRunnable(current) orelse return error.NoRunnableTask;
        self.current = next;
        self.states[next] = .running;
        if (next < task_count) self.round_robin_cursor = next;
        return self.frames[next];
    }

    pub fn blockCurrentOn(
        self: *Scheduler,
        queue: *WaitQueue,
        current_frame: *exceptions.Frame,
    ) DispatchError!*exceptions.Frame {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        const current = self.current orelse return error.NotRunning;
        if (current == idle_task or self.wait_queues[current] != null) return error.AlreadyWaiting;
        if (queue.pending_wake) {
            queue.pending_wake = false;
            return current_frame;
        }
        if (queue.count == queue.tasks.len) return error.QueueFull;
        queue.tasks[queue.count] = current;
        queue.count += 1;
        self.wait_queues[current] = queue;
        self.frames[current] = current_frame;
        self.states[current] = .blocked;
        const next = self.nextRunnable(current) orelse return error.NoRunnableTask;
        self.current = next;
        self.states[next] = .running;
        if (next < task_count) self.round_robin_cursor = next;
        return self.frames[next];
    }

    pub fn wakeOne(self: *Scheduler, queue: *WaitQueue) void {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        if (queue.count == 0) {
            queue.pending_wake = true;
            return;
        }
        const task = queue.tasks[0];
        _ = queue.remove(task);
        self.wait_queues[task] = null;
        if (self.states[task] == .blocked) self.states[task] = .runnable;
    }

    pub fn wakeAll(self: *Scheduler, queue: *WaitQueue) void {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        if (queue.count == 0) {
            queue.pending_wake = true;
            return;
        }
        while (queue.count != 0) self.wakeOne(queue);
    }

    pub fn cancel(self: *Scheduler, task: usize) void {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        if (task >= task_count) return;
        if (self.wait_queues[task]) |queue| {
            _ = queue.remove(task);
            self.wait_queues[task] = null;
        }
        self.states[task] = .free;
    }

    pub fn sleepCurrent(
        self: *Scheduler,
        current_frame: *exceptions.Frame,
        deadline: usize,
        now: usize,
    ) DispatchError!*exceptions.Frame {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        if (deadlineReached(now, deadline)) return current_frame;
        const current = self.current orelse return error.NotRunning;
        if (current == idle_task or self.wait_queues[current] != null) return error.AlreadyWaiting;
        self.frames[current] = current_frame;
        self.deadlines[current] = deadline;
        self.states[current] = .sleeping;
        const next = self.nextRunnable(current) orelse return error.NoRunnableTask;
        self.current = next;
        self.states[next] = .running;
        if (next < task_count) self.round_robin_cursor = next;
        return self.frames[next];
    }

    pub fn wakeExpired(self: *Scheduler, now: usize) void {
        const irq_state = disableLocalIrq();
        defer restoreLocalIrq(irq_state);
        for (self.states[0..task_count], self.deadlines[0..task_count]) |*task_state, deadline| {
            if (task_state.* == .sleeping and deadlineReached(now, deadline)) task_state.* = .runnable;
        }
    }

    pub fn state(self: *const Scheduler, task: usize) State {
        return self.states[task];
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

    fn nextRunnable(self: *const Scheduler, _: usize) ?usize {
        for (1..task_count + 1) |distance| {
            const candidate = (self.round_robin_cursor + distance) % task_count;
            if (self.states[candidate] == .runnable) return candidate;
        }
        if (self.states[idle_task] == .runnable) return idle_task;
        return null;
    }
};

pub fn deadlineReached(now: usize, deadline: usize) bool {
    return @as(isize, @bitCast(now -% deadline)) >= 0;
}

fn disableLocalIrq() u64 {
    if (comptime builtin.cpu.arch != .aarch64) return 0;
    const state = asm volatile (
        \\mrs %[state], DAIF
        \\msr DAIFSet, #2
        : [state] "=r" (-> u64),
        :
        : .{ .memory = true });
    return state;
}

fn restoreLocalIrq(state: u64) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr DAIF, %[state]"
        :
        : [state] "r" (state),
        : .{ .memory = true });
}

test "scheduler initializes separate aligned task stacks" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1234_5000, 0x9876_5000, 0x345);

    for (scheduler.frames[0..task_count], 0..) |frame, index| {
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
    scheduler.init(0x1000, 0x2000, 0x345);
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
    scheduler.init(0x1000, 0x2000, 0x345);
    var frame = std.mem.zeroes(exceptions.Frame);

    try std.testing.expectError(error.NotRunning, scheduler.dispatch(&frame, .preemptive));
}

test "blocked tasks are skipped by subsequent dispatches" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x2000, 0x345);
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

test "all blocked tasks dispatch the permanent idle task" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x2000, 0x345);
    var boot_frame = std.mem.zeroes(exceptions.Frame);

    try std.testing.expectError(error.NotRunning, scheduler.blockCurrent(&boot_frame));
    var frame = try scheduler.dispatch(&boot_frame, .cooperative);
    frame = try scheduler.blockCurrent(frame);
    frame = try scheduler.blockCurrent(frame);
    frame = try scheduler.blockCurrent(frame);
    try std.testing.expectEqual(@as(u64, 0x2000), frame.elr);
    try std.testing.expectEqual(State.running, scheduler.state(idle_task));
}

test "wake before block is consumed without losing the event" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x2000, 0x345);
    var queue: WaitQueue = .{};
    var boot_frame = std.mem.zeroes(exceptions.Frame);
    const first = try scheduler.dispatch(&boot_frame, .cooperative);

    scheduler.wakeOne(&queue);
    const resumed = try scheduler.blockCurrentOn(&queue, first);

    try std.testing.expectEqual(first, resumed);
    try std.testing.expectEqual(@as(usize, 0), queue.count);
    try std.testing.expectEqual(State.running, scheduler.state(0));
}

test "blocked task cancellation removes stale queue membership" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x2000, 0x345);
    var queue: WaitQueue = .{};
    var boot_frame = std.mem.zeroes(exceptions.Frame);
    const first = try scheduler.dispatch(&boot_frame, .cooperative);

    _ = try scheduler.blockCurrentOn(&queue, first);
    scheduler.cancel(0);
    scheduler.wakeAll(&queue);

    try std.testing.expectEqual(@as(usize, 0), queue.count);
    try std.testing.expectEqual(State.free, scheduler.state(0));
}

test "sleep deadlines wake in monotonic order across wrap" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x2000, 0x345);
    var boot_frame = std.mem.zeroes(exceptions.Frame);
    var frame = try scheduler.dispatch(&boot_frame, .cooperative);
    frame = try scheduler.sleepCurrent(frame, 10, 0);
    frame = try scheduler.sleepCurrent(frame, 5, 0);

    scheduler.wakeExpired(5);
    try std.testing.expectEqual(State.sleeping, scheduler.state(0));
    try std.testing.expectEqual(State.runnable, scheduler.state(1));
    scheduler.wakeExpired(10);
    try std.testing.expectEqual(State.runnable, scheduler.state(0));

    try std.testing.expect(!deadlineReached(std.math.maxInt(usize) - 2, 1));
    try std.testing.expect(deadlineReached(1, std.math.maxInt(usize) - 2));
}

test "idle preserves round-robin order after all waiters wake" {
    var scheduler: Scheduler = .{};
    scheduler.init(0x1000, 0x2000, 0x345);
    var queue: WaitQueue = .{};
    var boot_frame = std.mem.zeroes(exceptions.Frame);
    var frame = try scheduler.dispatch(&boot_frame, .cooperative);
    frame = try scheduler.blockCurrentOn(&queue, frame);
    frame = try scheduler.blockCurrentOn(&queue, frame);
    frame = try scheduler.blockCurrentOn(&queue, frame);
    try std.testing.expectEqual(@as(u64, 0x2000), frame.elr);

    scheduler.wakeAll(&queue);
    frame = try scheduler.dispatch(frame, .cooperative);
    try std.testing.expectEqual(@as(u64, 0), frame.registers[0]);
}
