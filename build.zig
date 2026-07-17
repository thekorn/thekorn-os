const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const kernel = b.addExecutable(.{
        .name = "thekorn_os",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
        }),
    });
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/boot.S"));
    kernel.setLinkerScript(b.path("src/arch/aarch64/linker.ld"));

    const install_elf = b.addInstallArtifact(kernel, .{});
    const image = kernel.addObjCopy(.{
        .basename = "kernel8.img",
        .format = .binary,
    });
    const install_image = b.addInstallFile(image.getOutput(), "kernel8.img");
    b.getInstallStep().dependOn(&install_elf.step);
    b.getInstallStep().dependOn(&install_image.step);

    addQemuStep(b, "run-virt", "Run the kernel on QEMU virt", kernel, false);
    addQemuStep(b, "debug-virt", "Run QEMU virt paused with a GDB server", kernel, true);

    const native_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(native_tests).step);
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
