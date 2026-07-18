const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const kernel = addKernel(b, "thekorn_os", kernel_target, optimize);
    kernel.setLinkerScript(b.path("src/platform/qemu_virt/linker.ld"));

    const rpi_kernel = addKernel(b, "thekorn_os_rpi4", kernel_target, optimize);
    rpi_kernel.setLinkerScript(b.path("src/arch/aarch64/linker.ld"));

    const install_elf = b.addInstallArtifact(kernel, .{});
    const image = rpi_kernel.addObjCopy(.{
        .basename = "kernel8.img",
        .format = .binary,
    });
    const install_image = b.addInstallFile(image.getOutput(), "kernel8.img");
    b.getInstallStep().dependOn(&install_elf.step);
    b.getInstallStep().dependOn(&install_image.step);

    addQemuStep(b, "run-virt", "Run the kernel on QEMU virt", kernel, false);
    addQemuStep(b, "debug-virt", "Run QEMU virt paused with a GDB server", kernel, true);

    const smoke = b.addSystemCommand(&.{"bash"});
    smoke.addFileArg(b.path("scripts/smoke-virt.sh"));
    smoke.addFileArg(kernel.getEmittedBin());
    const smoke_step = b.step("smoke-virt", "Boot QEMU and verify the serial marker");
    smoke_step.dependOn(&smoke.step);

    const native_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .test_runner = .{
            .path = b.path("src/test_runner.zig"),
            .mode = .simple,
        },
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(native_tests).step);

    const lint_step = b.step("lint", "Lint source code");
    lint_step.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addPaths(.{
            .include_dirs = &.{b.path("src")},
        });
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        break :step builder.build();
    });
}

fn addKernel(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        }),
    });
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/boot.S"));
    kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/vectors.S"));
    return kernel;
}

fn addQemuStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    kernel: *std.Build.Step.Compile,
    debug: bool,
) void {
    const qemu = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt",
        "-cpu",
        "cortex-a72",
        "-smp",
        "1",
        "-m",
        "128M",
        "-nographic",
        "-kernel",
    });
    qemu.addFileArg(kernel.getEmittedBin());
    if (debug) qemu.addArgs(&.{ "-S", "-s" });

    const step = b.step(name, description);
    step.dependOn(&qemu.step);
}
