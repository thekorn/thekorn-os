const std = @import("std");
const elf = @import("../formats/elf.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const physical_memory = @import("physical_memory.zig");

pub const count = 2;
pub const first_task = 1;
pub const slot_count = 16;
pub const max_owned_frames = 64;
pub const image_address: u64 = 0x0040_0000;
pub const image_pages = 32;
pub const image_size = image_pages * mmu.page_size;
pub const data_address: u64 = 0x0042_0000;
pub const heap_address: u64 = 0x0043_0000;
pub const stack_address: u64 = 0x0050_0000;
pub const data_pages = 1;
pub const stack_pages = 4;
pub const heap_pages = 4;

pub const FaultProbe = enum(u64) {
    none,
    uart,
    kernel,
};

pub const LoadError = elf.ParseError || mmu.MapError || error{
    InvalidEntry,
    InvalidSegment,
    SegmentOutsideWindow,
    UnsupportedPermissions,
};

pub const Memory = extern struct {
    image: [image_size]u8,
    data: [data_pages * mmu.page_size]u8,
    stack: [stack_pages * mmu.page_size]u8,
    heap: [heap_pages * mmu.page_size]u8,
};

pub const Process = struct {
    address_space: mmu.IdentityMap = .{},
    memory: Memory align(mmu.page_size) = undefined,
    root_physical: u64 = 0,
    entry: u64 = 0,
    stack_pointer: u64 = stack_address + stack_pages * mmu.page_size,
    started: u64 = 0,
    exited: u64 = 0,
    exit_status: u64 = 0,
    heap_pages_committed: usize = 0,
    preemptions: usize = 0,
    expected_fault: FaultProbe = .none,

    pub fn load(self: *Process, bytes: []const u8) LoadError!void {
        self.address_space = .{};
        @memset(&self.memory.image, 0);
        @memset(&self.memory.data, 0);
        @memset(&self.memory.stack, 0);
        @memset(&self.memory.heap, 0);
        const image = try elf.parse(bytes);
        var entry_is_executable = false;
        var loaded_segments: [elf.max_program_headers]elf.Segment = undefined;
        var loaded_segment_count: usize = 0;
        for (0..image.program_header_count) |index| {
            const segment = try image.segment(index);
            if (segment.segment_type != elf.load_segment or segment.memory_size == 0) continue;
            const mapping: mmu.Mapping = switch (segment.flags) {
                elf.flag_read | elf.flag_execute => .user_read_execute,
                elf.flag_read => .user_read_only,
                elf.flag_read | elf.flag_write => .user_read_write,
                else => return error.UnsupportedPermissions,
            };
            if (segment.virtual_address % mmu.page_size != 0 or
                segment.memory_size % mmu.page_size != 0 or
                segment.alignment < mmu.page_size or
                !std.math.isPowerOfTwo(segment.alignment) or
                segment.virtual_address % segment.alignment != segment.file_offset % segment.alignment)
            {
                return error.InvalidSegment;
            }
            if (segment.virtual_address < image_address or
                segment.virtual_address - image_address > image_size or
                segment.memory_size > image_size - (segment.virtual_address - image_address))
            {
                return error.SegmentOutsideWindow;
            }
            for (loaded_segments[0..loaded_segment_count]) |loaded| {
                if (segment.virtual_address < loaded.virtual_address + loaded.memory_size and
                    loaded.virtual_address < segment.virtual_address + segment.memory_size)
                {
                    return error.InvalidSegment;
                }
            }

            const destination_offset: usize = @intCast(segment.virtual_address - image_address);
            const file_offset: usize = @intCast(segment.file_offset);
            const file_size: usize = @intCast(segment.file_size);
            @memcpy(
                self.memory.image[destination_offset..][0..file_size],
                bytes[file_offset..][0..file_size],
            );
            try self.address_space.mapAt(
                segment.virtual_address,
                @intFromPtr(&self.memory.image) + destination_offset,
                segment.memory_size,
                mapping,
            );
            if (mapping == .user_read_execute and
                image.entry >= segment.virtual_address and
                image.entry < segment.virtual_address + segment.memory_size)
            {
                entry_is_executable = true;
            }
            loaded_segments[loaded_segment_count] = segment;
            loaded_segment_count += 1;
        }
        if (loaded_segment_count == 0 or !entry_is_executable) return error.InvalidEntry;

        try self.address_space.mapAt(
            data_address,
            @intFromPtr(&self.memory.data),
            @sizeOf(@FieldType(Memory, "data")),
            .user_read_write,
        );
        try self.address_space.mapAt(
            stack_address,
            @intFromPtr(&self.memory.stack),
            @sizeOf(@FieldType(Memory, "stack")),
            .user_read_write,
        );
        self.root_physical = self.address_space.rootAddress();
        self.entry = image.entry;
        self.stack_pointer = stack_address + stack_pages * mmu.page_size;
        self.started = 0;
        self.exited = 0;
        self.exit_status = 0;
        self.heap_pages_committed = 0;
        self.preemptions = 0;
        self.expected_fault = .none;
    }

    pub fn progressPointer(self: *Process) *usize {
        return @ptrCast(@alignCast(&self.memory.data));
    }

    pub fn ticksPointer(self: *Process) *usize {
        return @ptrFromInt(@intFromPtr(&self.memory.data) + @sizeOf(usize));
    }

    pub fn identityPointer(self: *Process) *usize {
        return @ptrFromInt(@intFromPtr(&self.memory.data) + 2 * @sizeOf(usize));
    }

    pub fn uartProbePointer(self: *Process) *u64 {
        return @ptrFromInt(@intFromPtr(&self.memory.data) + 3 * @sizeOf(u64));
    }

    pub fn kernelProbePointer(self: *Process) *u64 {
        return @ptrFromInt(@intFromPtr(&self.memory.data) + 4 * @sizeOf(u64));
    }

    pub fn heapIdentityPointer(self: *Process) *u64 {
        return @ptrCast(@alignCast(&self.memory.heap));
    }
};

pub const Pid = u64;

pub const ExitDisposition = enum(u8) {
    exited,
    faulted,
    interrupted,
};

pub const ExitStatus = struct {
    disposition: ExitDisposition,
    code: u64,
};

pub const WaitResult = struct {
    pid: Pid,
    status: ExitStatus,
};

pub const LifecycleError = physical_memory.FreeError || error{
    ProcessTableFull,
    PidExhausted,
    NoSuchProcess,
    InvalidParent,
    RootAlreadyExists,
    InitCannotExit,
    NotChild,
    StillRunning,
    FrameCapacityExceeded,
    OutOfMemory,
};

pub const SpawnError = LifecycleError || LoadError;

const LifecycleState = enum {
    free,
    alive,
    zombie,
};

const Record = struct {
    state: LifecycleState = .free,
    pid: Pid = 0,
    parent: ?Pid = null,
    status: ExitStatus = .{ .disposition = .exited, .code = 0 },
    frames: [max_owned_frames]u64 = undefined,
    frame_count: usize = 0,
    address_space: ?mmu.FrameMap = null,
    entry: u64 = 0,
    stack_pointer: u64 = 0,
};

pub const ProcessTable = struct {
    records: [slot_count]Record = @splat(.{}),
    next_pid: Pid = 1,
    init_pid: ?Pid = null,

    pub fn spawn(self: *ProcessTable, parent: ?Pid) LifecycleError!Pid {
        if (parent) |parent_pid| {
            const parent_record = self.find(parent_pid) orelse return error.InvalidParent;
            if (parent_record.state != .alive) return error.InvalidParent;
        } else if (self.init_pid != null) return error.RootAlreadyExists;
        const slot = for (&self.records) |*record| {
            if (record.state == .free) break record;
        } else return error.ProcessTableFull;
        if (self.next_pid == 0 or self.next_pid == std.math.maxInt(Pid)) return error.PidExhausted;
        const pid = self.next_pid;
        self.next_pid += 1;
        slot.* = .{ .state = .alive, .pid = pid, .parent = parent };
        if (self.init_pid == null and parent == null) self.init_pid = pid;
        return pid;
    }

    pub fn allocateOwnedFrame(
        self: *ProcessTable,
        pid: Pid,
        allocator: *physical_memory.Allocator,
    ) LifecycleError!u64 {
        const record = self.find(pid) orelse return error.NoSuchProcess;
        if (record.state != .alive) return error.NoSuchProcess;
        if (record.frame_count == record.frames.len) return error.FrameCapacityExceeded;
        const frame = allocator.allocate() orelse return error.OutOfMemory;
        record.frames[record.frame_count] = frame;
        record.frame_count += 1;
        return frame;
    }

    pub fn spawnFromBytes(
        self: *ProcessTable,
        parent: Pid,
        bytes: []const u8,
        allocator: *physical_memory.Allocator,
    ) SpawnError!Pid {
        const pid = try self.spawn(parent);
        errdefer self.discard(pid, allocator);
        const record = self.find(pid).?;
        var table_frames: [4]u64 = undefined;
        for (&table_frames) |*frame| frame.* = try self.allocateOwnedFrame(pid, allocator);
        record.address_space = try mmu.FrameMap.init(table_frames);
        const address_space = &record.address_space.?;
        const image = try elf.parse(bytes);
        var entry_is_executable = false;
        var loaded_segments: [elf.max_program_headers]elf.Segment = undefined;
        var loaded_segment_count: usize = 0;
        for (0..image.program_header_count) |index| {
            const segment = try image.segment(index);
            if (segment.segment_type != elf.load_segment or segment.memory_size == 0) continue;
            const mapping: mmu.Mapping = switch (segment.flags) {
                elf.flag_read | elf.flag_execute => .user_read_execute,
                elf.flag_read => .user_read_only,
                elf.flag_read | elf.flag_write => .user_read_write,
                else => return error.UnsupportedPermissions,
            };
            if (segment.virtual_address % mmu.page_size != 0 or
                segment.memory_size % mmu.page_size != 0 or
                segment.alignment < mmu.page_size or
                !std.math.isPowerOfTwo(segment.alignment) or
                segment.virtual_address % segment.alignment != segment.file_offset % segment.alignment)
            {
                return error.InvalidSegment;
            }
            if (segment.virtual_address < image_address or
                segment.virtual_address - image_address > image_size or
                segment.memory_size > image_size - (segment.virtual_address - image_address))
            {
                return error.SegmentOutsideWindow;
            }
            for (loaded_segments[0..loaded_segment_count]) |loaded| {
                if (segment.virtual_address < loaded.virtual_address + loaded.memory_size and
                    loaded.virtual_address < segment.virtual_address + segment.memory_size)
                {
                    return error.InvalidSegment;
                }
            }
            const file_offset: usize = @intCast(segment.file_offset);
            const file_size: usize = @intCast(segment.file_size);
            const page_count: usize = @intCast(segment.memory_size / mmu.page_size);
            for (0..page_count) |page| {
                const frame = try self.allocateOwnedFrame(pid, allocator);
                const destination: [*]u8 = @ptrFromInt(frame);
                @memset(destination[0..mmu.page_size], 0);
                const source_offset = page * mmu.page_size;
                if (source_offset < file_size) {
                    const copy_size = @min(mmu.page_size, file_size - source_offset);
                    @memcpy(
                        destination[0..copy_size],
                        bytes[file_offset + source_offset ..][0..copy_size],
                    );
                }
                try address_space.mapAt(
                    segment.virtual_address + page * mmu.page_size,
                    frame,
                    mmu.page_size,
                    mapping,
                );
            }
            if (mapping == .user_read_execute and
                image.entry >= segment.virtual_address and
                image.entry < segment.virtual_address + segment.memory_size)
            {
                entry_is_executable = true;
            }
            loaded_segments[loaded_segment_count] = segment;
            loaded_segment_count += 1;
        }
        if (loaded_segment_count == 0 or !entry_is_executable) return error.InvalidEntry;

        const data_frame = try self.allocateOwnedFrame(pid, allocator);
        @memset(@as([*]u8, @ptrFromInt(data_frame))[0..mmu.page_size], 0);
        try address_space.mapAt(data_address, data_frame, mmu.page_size, .user_read_write);
        for (0..stack_pages) |page| {
            const frame = try self.allocateOwnedFrame(pid, allocator);
            @memset(@as([*]u8, @ptrFromInt(frame))[0..mmu.page_size], 0);
            try address_space.mapAt(
                stack_address + page * mmu.page_size,
                frame,
                mmu.page_size,
                .user_read_write,
            );
        }
        record.entry = image.entry;
        record.stack_pointer = stack_address + stack_pages * mmu.page_size;
        return pid;
    }

    pub fn exit(self: *ProcessTable, pid: Pid, status: ExitStatus) LifecycleError!void {
        if (self.init_pid == pid) return error.InitCannotExit;
        const record = self.find(pid) orelse return error.NoSuchProcess;
        if (record.state != .alive) return error.NoSuchProcess;
        record.status = status;
        record.state = .zombie;
        const adopter = if (self.init_pid) |init_pid|
            if (self.alive(init_pid) != null) init_pid else null
        else
            null;
        for (&self.records) |*child| {
            if (child.state != .free and child.parent == pid) child.parent = adopter;
        }
    }

    pub fn waitOne(self: *ProcessTable, parent: Pid, child: Pid) LifecycleError!WaitResult {
        _ = self.alive(parent) orelse return error.NoSuchProcess;
        const record = self.find(child) orelse return error.NotChild;
        if (record.parent != parent) return error.NotChild;
        if (record.state != .zombie) return error.StillRunning;
        return .{ .pid = child, .status = record.status };
    }

    pub fn waitAny(self: *ProcessTable, parent: Pid) LifecycleError!WaitResult {
        _ = self.alive(parent) orelse return error.NoSuchProcess;
        var has_child = false;
        for (&self.records) |*record| {
            if (record.state == .free or record.parent != parent) continue;
            has_child = true;
            if (record.state == .zombie) return .{ .pid = record.pid, .status = record.status };
        }
        return if (has_child) error.StillRunning else error.NotChild;
    }

    pub fn reap(
        self: *ProcessTable,
        parent: Pid,
        child: Pid,
        allocator: *physical_memory.Allocator,
    ) LifecycleError!WaitResult {
        const result = try self.waitOne(parent, child);
        const record = self.find(child).?;
        if (record.address_space) |*address_space| address_space.clear();
        while (record.frame_count != 0) {
            const index = record.frame_count - 1;
            try allocator.free(record.frames[index]);
            record.frame_count = index;
        }
        record.* = .{};
        return result;
    }

    pub fn rootAddress(self: *ProcessTable, pid: Pid) LifecycleError!u64 {
        const record = self.find(pid) orelse return error.NoSuchProcess;
        const address_space = record.address_space orelse return error.NoSuchProcess;
        return address_space.rootAddress();
    }

    pub fn entry(self: *ProcessTable, pid: Pid) LifecycleError!u64 {
        const record = self.find(pid) orelse return error.NoSuchProcess;
        if (record.address_space == null) return error.NoSuchProcess;
        return record.entry;
    }

    pub fn ownedFrameCount(self: *ProcessTable, pid: Pid) LifecycleError!usize {
        const record = self.find(pid) orelse return error.NoSuchProcess;
        return record.frame_count;
    }

    pub fn descriptor(self: *ProcessTable, pid: Pid, address: u64) LifecycleError!?u64 {
        const record = self.find(pid) orelse return error.NoSuchProcess;
        const address_space = record.address_space orelse return error.NoSuchProcess;
        return address_space.descriptor(address);
    }

    pub fn usedSlots(self: *const ProcessTable) usize {
        var count_used: usize = 0;
        for (&self.records) |*record| {
            if (record.state != .free) count_used += 1;
        }
        return count_used;
    }

    fn alive(self: *ProcessTable, pid: Pid) ?*Record {
        const record = self.find(pid) orelse return null;
        return if (record.state == .alive) record else null;
    }

    fn find(self: *ProcessTable, pid: Pid) ?*Record {
        for (&self.records) |*record| {
            if (record.state != .free and record.pid == pid) return record;
        }
        return null;
    }

    fn discard(
        self: *ProcessTable,
        pid: Pid,
        allocator: *physical_memory.Allocator,
    ) void {
        const record = self.find(pid) orelse return;
        if (record.address_space) |*address_space| address_space.clear();
        while (record.frame_count != 0) {
            record.frame_count -= 1;
            allocator.free(record.frames[record.frame_count]) catch unreachable;
        }
        if (self.init_pid == pid) self.init_pid = null;
        record.* = .{};
    }
};

pub fn requiredFrameCount(bytes: []const u8) LoadError!usize {
    const image = try elf.parse(bytes);
    var pages: usize = 4 + data_pages + stack_pages;
    for (0..image.program_header_count) |index| {
        const segment = try image.segment(index);
        if (segment.segment_type != elf.load_segment or segment.memory_size == 0) continue;
        if (segment.memory_size % mmu.page_size != 0) return error.InvalidSegment;
        pages = std.math.add(usize, pages, @intCast(segment.memory_size / mmu.page_size)) catch
            return error.InvalidSegment;
    }
    if (pages > max_owned_frames) return error.InvalidSegment;
    return pages;
}

test "process memory windows are page aligned and disjoint" {
    var processes: [count]Process = @splat(.{});
    for (&processes) |*item| {
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&item.memory.image) % mmu.page_size);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&item.memory.data) % mmu.page_size);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&item.memory.stack) % mmu.page_size);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&item.memory.heap) % mmu.page_size);
    }
    try std.testing.expect(@intFromPtr(&processes[0].memory) != @intFromPtr(&processes[1].memory));
}

test "process lifecycle reclaims frames and slots across 128 cycles" {
    var bitmap: [32]u8 = undefined;
    const ram = [_]@import("../formats/fdt.zig").Range{.{
        .address = 0x1000,
        .size = 256 * physical_memory.page_size,
    }};
    var allocator = try physical_memory.Allocator.init(&bitmap, &ram);
    var table: ProcessTable = .{};
    const init_pid = try table.spawn(null);
    const initial_frames = allocator.freeFrameCount();
    const initial_slots = table.usedSlots();

    for (0..128) |cycle| {
        const child = try table.spawn(init_pid);
        for (0..3) |_| _ = try table.allocateOwnedFrame(child, &allocator);
        const disposition: ExitDisposition = if (cycle % 2 == 0) .exited else .faulted;
        try table.exit(child, .{ .disposition = disposition, .code = cycle });
        const waited = try table.waitAny(init_pid);
        try std.testing.expectEqual(child, waited.pid);
        const reaped = try table.reap(init_pid, child, &allocator);
        try std.testing.expectEqual(@as(u64, cycle), reaped.status.code);
        try std.testing.expectEqual(initial_frames, allocator.freeFrameCount());
        try std.testing.expectEqual(initial_slots, table.usedSlots());
    }
    try std.testing.expectEqual(@as(Pid, 130), table.next_pid);
}

test "exiting parents transfer children to init" {
    var table: ProcessTable = .{};
    const init_pid = try table.spawn(null);
    const parent = try table.spawn(init_pid);
    const child = try table.spawn(parent);

    try table.exit(parent, .{ .disposition = .exited, .code = 0 });
    try table.exit(child, .{ .disposition = .interrupted, .code = 2 });

    const waited = try table.waitOne(init_pid, child);
    try std.testing.expectEqual(ExitDisposition.interrupted, waited.status.disposition);
}

test "process table enforces one immortal init" {
    var table: ProcessTable = .{};
    const init_pid = try table.spawn(null);

    try std.testing.expectError(error.RootAlreadyExists, table.spawn(null));
    try std.testing.expectError(
        error.InitCannotExit,
        table.exit(init_pid, .{ .disposition = .exited, .code = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 1), table.usedSlots());
}

test "owned frame acquisition cannot leak on capacity failure" {
    var bitmap: [16]u8 = undefined;
    const ram = [_]@import("../formats/fdt.zig").Range{.{
        .address = 0x1000,
        .size = 128 * physical_memory.page_size,
    }};
    var allocator = try physical_memory.Allocator.init(&bitmap, &ram);
    var table: ProcessTable = .{};
    const init_pid = try table.spawn(null);
    const child = try table.spawn(init_pid);

    for (0..max_owned_frames) |_| _ = try table.allocateOwnedFrame(child, &allocator);
    const free_before_failure = allocator.freeFrameCount();
    try std.testing.expectError(
        error.FrameCapacityExceeded,
        table.allocateOwnedFrame(child, &allocator),
    );
    try std.testing.expectEqual(free_before_failure, allocator.freeFrameCount());

    try table.exit(child, .{ .disposition = .exited, .code = 0 });
    _ = try table.reap(init_pid, child, &allocator);
    try std.testing.expectEqual(@as(usize, 128), allocator.freeFrameCount());
}

test "PID exhaustion leaves slots unchanged" {
    var table: ProcessTable = .{ .next_pid = std.math.maxInt(Pid) };
    try std.testing.expectError(error.PidExhausted, table.spawn(null));
    try std.testing.expectEqual(@as(usize, 0), table.usedSlots());
    try std.testing.expectEqual(std.math.maxInt(Pid), table.next_pid);
}

test "failed frame-backed spawn unwinds every allocation" {
    var ram_storage: [64 * physical_memory.page_size]u8 align(mmu.page_size) = undefined;
    var bitmap: [8]u8 = undefined;
    const ram = [_]@import("../formats/fdt.zig").Range{.{
        .address = @intFromPtr(&ram_storage),
        .size = ram_storage.len,
    }};
    var allocator = try physical_memory.Allocator.init(&bitmap, &ram);
    var table: ProcessTable = .{};
    const init_pid = try table.spawn(null);
    const initial_frames = allocator.freeFrameCount();

    try std.testing.expectError(
        error.Truncated,
        table.spawnFromBytes(init_pid, &.{}, &allocator),
    );
    try std.testing.expectEqual(initial_frames, allocator.freeFrameCount());
    try std.testing.expectEqual(@as(usize, 1), table.usedSlots());
}

test "mapped partial spawn clears table frames before returning them" {
    const image = &@import("embedded_users").one;
    const required = try requiredFrameCount(image);
    var ram_storage: [64 * physical_memory.page_size]u8 align(mmu.page_size) = undefined;
    var bitmap: [8]u8 = undefined;
    const base = @intFromPtr(&ram_storage);
    const ram = [_]@import("../formats/fdt.zig").Range{.{
        .address = base,
        .size = ram_storage.len,
    }};
    var allocator = try physical_memory.Allocator.init(&bitmap, &ram);
    const retained_count = 64 - (required - 1);
    for (0..retained_count) |_| _ = allocator.allocate().?;
    const first_table = base + retained_count * physical_memory.page_size;
    var table: ProcessTable = .{};
    const init_pid = try table.spawn(null);
    const initial_frames = allocator.freeFrameCount();

    try std.testing.expectError(
        error.OutOfMemory,
        table.spawnFromBytes(init_pid, image, &allocator),
    );
    try std.testing.expectEqual(initial_frames, allocator.freeFrameCount());
    try std.testing.expectEqual(@as(usize, 1), table.usedSlots());
    for (0..4) |page| {
        const table_bytes: [*]const u8 = @ptrFromInt(first_table + page * physical_memory.page_size);
        for (table_bytes[0..physical_memory.page_size]) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}
