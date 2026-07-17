---
name: zig
description: "Guides Zig 0.17 development-line code, migrations, std.Io usage, and build-system updates. Use when writing, reviewing, or upgrading Zig code for Zig 0.17.x."
license: MIT
compatibility: Requires a Zig 0.17.x compiler; development snapshots may change before the stable release.
metadata:
  version: "0.17.0-dev"
  language: zig
  category: programming-language
---

# Zig 0.17 Programming Guide

Write and port code against the installed Zig 0.17 compiler rather than older online examples.

## Version Scope

This skill targets the **Zig 0.17.x development line**. Zig 0.17 is not assumed to be stable, so APIs can change between development snapshots. Run `scripts/check-zig-version.sh` before relying on this guide.

Do not describe development APIs as final release behavior. When this guide and the installed compiler disagree, the installed compiler is authoritative.

## Verify APIs Locally First

1. Run `zig env` and note `.version`, `.std_dir`, and `.lib_dir`.
2. Search source under `.std_dir` for exact signatures and doc comments.
3. Use `zig std` for generated standard-library documentation.
4. Use the language reference shipped under `.lib_dir`.
5. Compile the smallest relevant example before changing production code.

Never hardcode a Nix store path or another machine's Zig installation path.

## Core 0.17 Model

Zig 0.17 continues the explicit-I/O and allocator-unmanaged model introduced during the 0.16 cycle:

- Pass `std.Io` to operations that perform I/O, sleep, time, or secure randomness.
- Prefer `pub fn main(init: std.process.Init) !void` when the program needs I/O, allocation, arguments, or environment data.
- Readers and writers are concrete implementations with a `std.Io.Reader` or `std.Io.Writer` interface.
- Collections such as `std.ArrayList` do not store an allocator; pass the allocator to mutating and cleanup methods.
- Use `std.lang` for language/compiler declarations. `std.builtin` is deprecated and scheduled for removal after 0.17.

## Entrypoints, Arguments, and Output

Supported entrypoint shapes include:

```zig
const std = @import("std");

pub fn main() !void {}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    _ = args;

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer =
        .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;
    try writer.print("hello {s}\n", .{"Zig 0.17"});
    try writer.flush();
}
```

Use `std.debug.print` only for diagnostics. Explicitly flush buffered output.

Environment and process arguments are supplied through `std.process.Init`; do not rely on removed process-global APIs.

## Readers, Writers, and Files

Use `std.Io.Reader` and `std.Io.Writer`, not the removed lowercase `std.io` generic interfaces.

```zig
var input: std.Io.Reader = .fixed("abc");
const first = try input.takeByte();
_ = first;

var storage: [128]u8 = undefined;
var output: std.Io.Writer = .fixed(&storage);
try output.print("{d}", .{42});
const bytes = output.buffered();
_ = bytes;
```

Common migrations:

| Older API | Zig 0.17 API |
|---|---|
| `std.io` | `std.Io` |
| `std.io.fixedBufferStream` | `std.Io.Reader.fixed` / `std.Io.Writer.fixed` |
| `readByte` | `takeByte` |
| `readInt` | `takeInt` |
| `readBytesNoEof(N)` | `takeArray(N)` |
| `std.time.sleep` | `std.Io.sleep` |
| `std.crypto.random` | randomness through `std.Io` |
| `std.net` | `std.Io.net` |

Read a complete file with an explicit I/O implementation, allocator, and limit:

```zig
const data = try std.Io.Dir.cwd().readFileAlloc(
    init.io,
    "input.txt",
    init.gpa,
    .limited(1024 * 1024),
);
defer init.gpa.free(data);
```

Reaching the limit returns `error.StreamTooLong`; the limit is an exclusive ceiling.

## Collections

`std.ArrayList` is allocator-unmanaged:

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(gpa);

try list.append(gpa, 'a');
try list.appendSlice(gpa, "bc");
const last: ?u8 = list.pop();
_ = last;
```

Key migrations:

- Managed `std.ArrayList(T).init(gpa)` becomes `std.ArrayList(T) = .empty` or `try .initCapacity(gpa, n)`.
- Pass `gpa` to `append`, `appendSlice`, growth methods, `deinit`, and `toOwnedSlice`.
- `popOrNull()` becomes `pop()`, which returns `?T`; use `pop().?` only when non-empty is guaranteed.
- Prefer `std.array_hash_map.Auto`, `.String`, or `.Custom` over deprecated old names.
- Use `std.mem.find*` names, such as `findScalar`, `findScalarLast`, and `findAny`, instead of `indexOf*` names.
- `containsAtLeastScalar(T, slice, element, minimum)` places the element before the count.

## Formatting

Call `writer.print`; do not call the removed `std.fmt.format` helper.

- Use `{f}` for values implementing a `format` method.
- Use `{any}` for generic structural formatting.
- A basic custom formatter is:

```zig
pub fn format(value: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{d}", .{value.number});
}
```

Use `{x}` / `{X}` for byte-slice hex, `{B}` / `{Bi}` for byte sizes, and `{D}` for durations. Consult local `std.Io.Writer` formatting docs for snapshot-specific specifiers.

## Type Construction and Reflection

`@Type` is removed. Use the dedicated type-construction builtins:

| Removed | Replacement |
|---|---|
| `@Type(.int)` | `@Int(signedness, bits)` |
| `@Type(.pointer)` | `@Pointer(size, attributes, child, sentinel)` |
| `@Type(.@"struct")` | `@Struct(...)` |
| `@Type(.@"enum")` | `@Enum(...)` |
| `@Type(.@"union")` | `@Union(...)` |
| `@Type(.@"fn")` | `@Fn(...)` |
| tuple reification | `@Tuple(types)` |
| enum-literal type | `@EnumLiteral()` |

Inspect the installed language reference for exact builtin parameters. Do not copy `std.builtin.Type`-based examples from older Zig versions.

Vector/array value coercion does not imply pointer-layout compatibility. Do not reinterpret pointers between vectors and arrays with `@ptrCast`; use explicit value conversion or `@bitCast` where semantically valid.

## C Interop

`@cImport` is deprecated. Translate C in `build.zig` and import the resulting module:

```zig
const translated = b.addTranslateC(.{
    .root_source_file = b.path("src/api.h"),
    .target = target,
    .optimize = optimize,
});

const root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{
        .name = "c",
        .module = translated.createModule(),
    }},
});
```

Use `const c = @import("c");` in Zig source. Verify `std.Build.Step.TranslateC` locally because the development API can move.

## Build System and CLI

Create a root module explicitly and pass it to compile steps:

```zig
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

Apply module concerns to `exe.root_module`: C sources, assembly, objects, imports, include paths, linked libraries, frameworks, `link_libc`, and `link_libcpp`. Avoid deprecated `Step.Compile` forwarding methods.

`build.zig.zon` requires an enum-literal name and package fingerprint:

```zig
.{
    .name = .app,
    .fingerprint = 0x123456789abcdef0,
    .version = "0.1.0",
    .dependencies = .{},
}
```

Relevant CLI changes:

- Use `zig init --minimal` / `-m`, not `--strip` / `-s`.
- Use `zig build test --test-timeout 500ms`; durations require a unit.
- `zig build --webui[=ip]` enables the build UI; check `zig build --help` because development flags can change.
- Treat generated `Step.Run` file arguments as potentially working-directory-relative, not necessarily absolute.

## Porting Workflow

1. Confirm the compiler is 0.17.x with `scripts/check-zig-version.sh`.
2. Run `zig fmt` before interpreting parser cascades as API failures.
3. Update `build.zig.zon` and `build.zig` first.
4. Replace removed language builtins and `std.builtin` usage.
5. Move to `std.process.Init`, then thread `std.Io` through I/O boundaries.
6. Convert readers, writers, files, and networking.
7. Convert collections to allocator-unmanaged calls.
8. Update formatting and `std.mem.find*` calls.
9. Run the narrowest relevant test after each category, then run `zig build test`.

Avoid compatibility wrappers unless the project explicitly supports multiple Zig versions. Zig has no stable standard-library compatibility promise before 1.0; direct code for the pinned compiler is usually simpler.
