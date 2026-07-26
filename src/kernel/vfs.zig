const std = @import("std");
const cpio = @import("../formats/cpio.zig");
const fat = @import("../formats/fat.zig");

pub const max_path = 255;
pub const max_open_files = 16;
pub const descriptors_per_process = 8;

pub const Error = error{
    InvalidPath,
    PathTooLong,
    NotFound,
    NotDirectory,
    IsDirectory,
    OpenFileTableFull,
    DescriptorTableFull,
    BadDescriptor,
    ReferenceOverflow,
    IoFailure,
};

pub const Kind = enum { file, directory };
pub const Stat = struct { kind: Kind, size: u64 };
pub const DirEntry = struct {
    name: [12]u8 = @splat(0),
    name_len: u8,
    stat: Stat,

    pub fn slice(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Backend = struct {
    context: *anyopaque,
    statFn: *const fn (*anyopaque, []const u8) anyerror!Stat,
    readAtFn: *const fn (*anyopaque, []const u8, u64, []u8) anyerror!usize,
    readDirFn: *const fn (*anyopaque, usize) anyerror!?DirEntry,

    fn stat(self: Backend, name: []const u8) Error!Stat {
        return self.statFn(self.context, name) catch |err| return mapBackendError(err);
    }
    fn readAt(self: Backend, name: []const u8, offset: u64, destination: []u8) Error!usize {
        return self.readAtFn(self.context, name, offset, destination) catch |err| return mapBackendError(err);
    }
    fn readDir(self: Backend, index: usize) Error!?DirEntry {
        return self.readDirFn(self.context, index) catch |err| return mapBackendError(err);
    }
};

pub const CpioBackend = struct {
    archive: cpio.Archive,

    pub fn backend(self: *CpioBackend) Backend {
        return .{ .context = self, .statFn = stat, .readAtFn = readAt, .readDirFn = readDir };
    }

    fn stat(context: *anyopaque, name: []const u8) anyerror!Stat {
        const self: *CpioBackend = @ptrCast(@alignCast(context));
        if (std.mem.findScalar(u8, name, '/') != null) return error.NotFound;
        var index: usize = 0;
        while (try self.archive.entry(index)) |entry| : (index += 1) {
            if (std.mem.eql(u8, entry.name, name)) return .{
                .kind = if (entry.kind == .directory) .directory else .file,
                .size = entry.data.len,
            };
        }
        return error.NotFound;
    }

    fn readAt(context: *anyopaque, name: []const u8, offset: u64, destination: []u8) anyerror!usize {
        const self: *CpioBackend = @ptrCast(@alignCast(context));
        const bytes = (try self.archive.find(name)) orelse return error.NotFound;
        if (offset >= bytes.len) return 0;
        const start: usize = @intCast(offset);
        const amount = @min(destination.len, bytes.len - start);
        @memcpy(destination[0..amount], bytes[start..][0..amount]);
        return amount;
    }

    fn readDir(context: *anyopaque, index: usize) anyerror!?DirEntry {
        const self: *CpioBackend = @ptrCast(@alignCast(context));
        const entry = (try self.archive.entry(index)) orelse return null;
        if (std.mem.findScalar(u8, entry.name, '/') != null) return error.NotFound;
        return try makeEntry(entry.name, .{
            .kind = if (entry.kind == .directory) .directory else .file,
            .size = entry.data.len,
        });
    }
};

pub const FatBackend = struct {
    file_system: fat.FileSystem,

    pub fn backend(self: *FatBackend) Backend {
        return .{ .context = self, .statFn = stat, .readAtFn = readAt, .readDirFn = readDir };
    }

    fn stat(context: *anyopaque, name: []const u8) anyerror!Stat {
        const self: *FatBackend = @ptrCast(@alignCast(context));
        if (std.mem.findScalar(u8, name, '/') != null) return error.NotFound;
        const entry = try self.file_system.stat(name);
        return .{ .kind = if (entry.is_directory) .directory else .file, .size = entry.size };
    }

    fn readAt(context: *anyopaque, name: []const u8, offset: u64, destination: []u8) anyerror!usize {
        const self: *FatBackend = @ptrCast(@alignCast(context));
        return self.file_system.readAt(name, offset, destination);
    }

    fn readDir(context: *anyopaque, index: usize) anyerror!?DirEntry {
        const self: *FatBackend = @ptrCast(@alignCast(context));
        const entry = (try self.file_system.rootEntry(index)) orelse return null;
        return try makeEntry(entry.nameSlice(), .{
            .kind = if (entry.is_directory) .directory else .file,
            .size = entry.size,
        });
    }
};

fn mapBackendError(err: anyerror) Error {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.NotDirectory => error.NotDirectory,
        else => error.IoFailure,
    };
}

const Resolved = struct { backend: Backend, name: []const u8 };

pub const Vfs = struct {
    rom: Backend,
    disk: Backend,

    pub fn stat(self: Vfs, path: []const u8) Error!Stat {
        var normalized: [max_path + 1]u8 = undefined;
        const clean = try normalize(path, &normalized);
        if (std.mem.eql(u8, clean, "/") or std.mem.eql(u8, clean, "/rom") or std.mem.eql(u8, clean, "/disk"))
            return .{ .kind = .directory, .size = 0 };
        const item = try self.resolve(clean);
        return item.backend.stat(item.name);
    }

    pub fn readAt(self: Vfs, path: []const u8, offset: u64, destination: []u8) Error!usize {
        var normalized: [max_path + 1]u8 = undefined;
        const clean = try normalize(path, &normalized);
        const item = self.resolve(clean) catch |err| switch (err) {
            error.IsDirectory => return error.IsDirectory,
            else => return err,
        };
        if ((try item.backend.stat(item.name)).kind != .file) return error.IsDirectory;
        return item.backend.readAt(item.name, offset, destination);
    }

    pub fn readDir(self: Vfs, path: []const u8, index: usize) Error!?DirEntry {
        var normalized: [max_path + 1]u8 = undefined;
        const clean = try normalize(path, &normalized);
        if (std.mem.eql(u8, clean, "/")) {
            if (index > 1) return null;
            return @as(?DirEntry, try makeEntry(if (index == 0) "rom" else "disk", .{ .kind = .directory, .size = 0 }));
        }
        if (std.mem.eql(u8, clean, "/rom")) return self.rom.readDir(index);
        if (std.mem.eql(u8, clean, "/disk")) return self.disk.readDir(index);
        return error.NotDirectory;
    }

    fn resolve(self: Vfs, clean: []const u8) Error!Resolved {
        if (std.mem.startsWith(u8, clean, "/rom/")) return .{ .backend = self.rom, .name = clean[5..] };
        if (std.mem.startsWith(u8, clean, "/disk/")) return .{ .backend = self.disk, .name = clean[6..] };
        if (std.mem.eql(u8, clean, "/") or std.mem.eql(u8, clean, "/rom") or std.mem.eql(u8, clean, "/disk")) return error.IsDirectory;
        return error.NotFound;
    }
};

pub fn normalize(path: []const u8, output: *[max_path + 1]u8) Error![]const u8 {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    if (path.len > max_path) return error.PathTooLong;
    var length: usize = 1;
    output[0] = '/';
    var iterator = std.mem.splitScalar(u8, path[1..], '/');
    while (iterator.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (length == 1) return error.InvalidPath;
            while (length > 1 and output[length - 1] != '/') length -= 1;
            if (length > 1) length -= 1;
            continue;
        }
        if (std.mem.findScalar(u8, part, 0) != null) return error.InvalidPath;
        if (length != 1) output[length] = '/';
        length += @intFromBool(length != 1);
        if (length + part.len > max_path) return error.PathTooLong;
        @memcpy(output[length..][0..part.len], part);
        length += part.len;
    }
    return output[0..length];
}

pub fn makeEntry(name: []const u8, info: Stat) Error!DirEntry {
    if (name.len > 12) return error.PathTooLong;
    var result = DirEntry{ .name_len = @intCast(name.len), .stat = info };
    @memcpy(result.name[0..name.len], name);
    return result;
}

const OpenFile = struct {
    used: bool = false,
    references: u8 = 0,
    offset: u64 = 0,
    path: [max_path + 1]u8 = undefined,
    path_len: u8 = 0,
};

pub const OpenFileTable = struct {
    files: [max_open_files]OpenFile = @splat(.{}),

    fn allocate(self: *OpenFileTable, path: []const u8) Error!u8 {
        for (&self.files, 0..) |*file, index| if (!file.used) {
            file.* = .{ .used = true, .references = 1, .path_len = @intCast(path.len) };
            @memcpy(file.path[0..path.len], path);
            return @intCast(index);
        };
        return error.OpenFileTableFull;
    }
    fn release(self: *OpenFileTable, index: u8) void {
        const file = &self.files[index];
        file.references -= 1;
        if (file.references == 0) file.* = .{};
    }
    pub fn used(self: *const OpenFileTable) usize {
        var count: usize = 0;
        for (self.files) |file| count += @intFromBool(file.used);
        return count;
    }
};

pub const DescriptorTable = struct {
    descriptors: [descriptors_per_process]?u8 = @splat(null),

    pub fn open(self: *DescriptorTable, files: *OpenFileTable, vfs: Vfs, path: []const u8) Error!u8 {
        var normalized: [max_path + 1]u8 = undefined;
        const clean = try normalize(path, &normalized);
        if ((try vfs.stat(clean)).kind != .file) return error.IsDirectory;
        const descriptor = for (&self.descriptors, 0..) |*slot, index| if (slot.* == null) break @as(u8, @intCast(index)) else continue else return error.DescriptorTableFull;
        const open_index = try files.allocate(clean);
        self.descriptors[descriptor] = open_index;
        return descriptor;
    }

    pub fn read(self: *DescriptorTable, files: *OpenFileTable, vfs: Vfs, descriptor: u8, destination: []u8) Error!usize {
        if (descriptor >= self.descriptors.len) return error.BadDescriptor;
        const index = self.descriptors[descriptor] orelse return error.BadDescriptor;
        const file = &files.files[index];
        const amount = try vfs.readAt(file.path[0..file.path_len], file.offset, destination);
        file.offset += amount;
        return amount;
    }

    pub fn inheritFrom(self: *DescriptorTable, files: *OpenFileTable, parent: *const DescriptorTable) Error!void {
        self.closeAll(files);
        var added: usize = 0;
        errdefer {
            for (self.descriptors[0..added]) |entry| if (entry) |index| files.release(index);
            self.descriptors = @splat(null);
        }
        for (parent.descriptors, 0..) |entry, index| {
            if (entry) |open_index| {
                if (files.files[open_index].references == std.math.maxInt(u8)) return error.ReferenceOverflow;
                files.files[open_index].references += 1;
                self.descriptors[index] = open_index;
            }
            added = index + 1;
        }
    }

    pub fn close(self: *DescriptorTable, files: *OpenFileTable, descriptor: u8) Error!void {
        if (descriptor >= self.descriptors.len) return error.BadDescriptor;
        const index = self.descriptors[descriptor] orelse return error.BadDescriptor;
        self.descriptors[descriptor] = null;
        files.release(index);
    }
    pub fn closeAll(self: *DescriptorTable, files: *OpenFileTable) void {
        for (&self.descriptors) |*entry| if (entry.*) |index| {
            files.release(index);
            entry.* = null;
        };
    }
};

const TestBackend = struct {
    bytes: []const u8,
    fail: bool = false,
    fn stat(context: *anyopaque, name: []const u8) anyerror!Stat {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        if (self.fail) return error.IoFailure;
        if (!std.mem.eql(u8, name, "FILE")) return error.NotFound;
        return .{ .kind = .file, .size = self.bytes.len };
    }
    fn readAt(context: *anyopaque, name: []const u8, offset: u64, out: []u8) anyerror!usize {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        _ = try stat(context, name);
        if (offset >= self.bytes.len) return 0;
        const amount = @min(out.len, self.bytes.len - @as(usize, @intCast(offset)));
        @memcpy(out[0..amount], self.bytes[@intCast(offset)..][0..amount]);
        return amount;
    }
    fn readDir(context: *anyopaque, index: usize) anyerror!?DirEntry {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        if (index != 0) return null;
        return @as(?DirEntry, try makeEntry("FILE", .{ .kind = .file, .size = self.bytes.len }));
    }
    fn backend(self: *TestBackend) Backend {
        return .{ .context = self, .statFn = stat, .readAtFn = readAt, .readDirFn = readDir };
    }
};

test "paths, fixed mounts, bounded directory iteration and positional reads" {
    var backend = TestBackend{ .bytes = "abcdef" };
    const vfs = Vfs{ .rom = backend.backend(), .disk = backend.backend() };
    var path: [max_path + 1]u8 = undefined;
    try std.testing.expectEqualStrings("/rom/FILE", try normalize("//rom/./x/../FILE", &path));
    try std.testing.expectError(error.InvalidPath, normalize("rom/FILE", &path));
    try std.testing.expectError(error.InvalidPath, normalize("/../../FILE", &path));
    try std.testing.expectError(error.InvalidPath, normalize("/rom/\x00FILE", &path));
    try std.testing.expectEqualStrings("rom", (try vfs.readDir("/", 0)).?.slice());
    try std.testing.expect((try vfs.readDir("/rom", 1)) == null);
    var output: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try vfs.readAt("/rom/FILE", 3, &output));
    try std.testing.expectEqualStrings("def", &output);
}

test "descriptor offsets, inheritance, cleanup and failures" {
    var backend = TestBackend{ .bytes = "abcdef" };
    const vfs = Vfs{ .rom = backend.backend(), .disk = backend.backend() };
    var files = OpenFileTable{};
    var first = DescriptorTable{};
    var second = DescriptorTable{};
    const first_descriptor = try first.open(&files, vfs, "/rom/FILE");
    const second_descriptor = try second.open(&files, vfs, "/rom/FILE");
    var output: [2]u8 = undefined;
    _ = try first.read(&files, vfs, first_descriptor, &output);
    try std.testing.expectEqualStrings("ab", &output);
    _ = try second.read(&files, vfs, second_descriptor, &output);
    try std.testing.expectEqualStrings("ab", &output);
    var child = DescriptorTable{};
    try child.inheritFrom(&files, &first);
    try first.close(&files, first_descriptor);
    _ = try child.read(&files, vfs, first_descriptor, &output);
    try std.testing.expectEqualStrings("cd", &output);
    child.closeAll(&files);
    second.closeAll(&files);
    try std.testing.expectEqual(@as(usize, 0), files.used());

    backend.fail = true;
    try std.testing.expectError(error.IoFailure, first.open(&files, vfs, "/rom/FILE"));
    try std.testing.expectEqual(@as(usize, 0), files.used());
}
