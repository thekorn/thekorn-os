const std = @import("std");
const elf = @import("../formats/elf.zig");
const mmu = @import("../arch/aarch64/mmu.zig");

pub const count = 2;
pub const first_task = 1;
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

    pub fn heapIdentityPointer(self: *Process) *u64 {
        return @ptrCast(@alignCast(&self.memory.heap));
    }
};

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
