const std = @import("std");

pub const capacity = 512;
pub const Pid = u64;

pub const Terminal = struct {
    bytes: [capacity]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    overflow_count: usize = 0,
    foreground_pid: Pid = 0,

    /// Returns the foreground PID when Ctrl-C consumes an interrupt request.
    pub fn receive(self: *Terminal, byte: u8) ?Pid {
        if (byte == 3) {
            const pid = @atomicRmw(Pid, &self.foreground_pid, .Xchg, 0, .acq_rel);
            if (pid != 0) return pid;
        }
        const head = @atomicLoad(usize, &self.head, .monotonic);
        const tail = @atomicLoad(usize, &self.tail, .acquire);
        if (head -% tail == capacity) {
            _ = @atomicRmw(usize, &self.overflow_count, .Add, 1, .monotonic);
            return null;
        }
        self.bytes[head % capacity] = byte;
        @atomicStore(usize, &self.head, head +% 1, .release);
        return null;
    }

    pub fn read(self: *Terminal) ?u8 {
        const tail = @atomicLoad(usize, &self.tail, .monotonic);
        const head = @atomicLoad(usize, &self.head, .acquire);
        if (tail == head) return null;
        const byte = self.bytes[tail % capacity];
        @atomicStore(usize, &self.tail, tail +% 1, .release);
        return byte;
    }

    pub fn overflows(self: *const Terminal) usize {
        return @atomicLoad(usize, &self.overflow_count, .acquire);
    }

    pub fn setForeground(self: *Terminal, pid: ?Pid) void {
        @atomicStore(Pid, &self.foreground_pid, pid orelse 0, .release);
    }

    pub fn foreground(self: *const Terminal) ?Pid {
        const pid = @atomicLoad(Pid, &self.foreground_pid, .acquire);
        return if (pid == 0) null else pid;
    }
};

test "terminal ring preserves a 4 KiB burst across wrap" {
    var terminal: Terminal = .{};
    for (0..4096) |index| {
        const byte: u8 = @truncate(index);
        try std.testing.expectEqual(@as(?Pid, null), terminal.receive(byte));
        try std.testing.expectEqual(byte, terminal.read().?);
    }
    try std.testing.expectEqual(@as(usize, 0), terminal.overflows());
    try std.testing.expectEqual(@as(?u8, null), terminal.read());
}

test "terminal ring reports every byte beyond capacity" {
    var terminal: Terminal = .{};
    for (0..capacity + 64) |index| _ = terminal.receive(@truncate(index));
    try std.testing.expectEqual(@as(usize, 64), terminal.overflows());
    for (0..capacity) |index| try std.testing.expectEqual(@as(u8, @truncate(index)), terminal.read().?);
}

test "Ctrl-C consumes only the registered foreground process" {
    var terminal: Terminal = .{};
    terminal.setForeground(42);

    try std.testing.expectEqual(@as(?Pid, 42), terminal.receive(3));
    try std.testing.expectEqual(@as(?Pid, null), terminal.foreground());
    try std.testing.expectEqual(@as(?u8, null), terminal.read());
    try std.testing.expectEqual(@as(?Pid, null), terminal.receive(3));
    try std.testing.expectEqual(@as(?u8, 3), terminal.read());
}
