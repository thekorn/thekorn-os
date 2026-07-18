const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;
    const coverage = b.option(bool, "coverage", "Collect test coverage with kcov") orelse false;
    const rpi_firmware = b.dependency("raspberrypi_firmware", .{});
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const kernel = addKernel(
        b,
        "thekorn_os",
        kernel_target,
        optimize,
        b.path("src/platform/qemu_virt/uart.zig"),
    );
    kernel.setLinkerScript(b.path("src/platform/qemu_virt/linker.ld"));

    const rpi_kernel = addKernel(
        b,
        "thekorn_os_rpi4",
        kernel_target,
        optimize,
        b.path("src/platform/rpi4/uart.zig"),
    );
    rpi_kernel.setLinkerScript(b.path("src/arch/aarch64/linker.ld"));

    const install_elf = b.addInstallArtifact(kernel, .{});
    const image = rpi_kernel.addObjCopy(.{
        .basename = "kernel8.img",
        .format = .binary,
    });
    const install_image = b.addInstallFile(image.getOutput(), "kernel8.img");
    const rpi_disk = b.addSystemCommand(&.{"bash"});
    rpi_disk.addFileArg(b.path("scripts/make-rpi4-image.sh"));
    rpi_disk.addFileArg(image.getOutput());
    rpi_disk.addFileArg(b.path("scripts/rpi4-config.txt"));
    rpi_disk.addFileArg(rpi_firmware.path("boot/start4.elf"));
    rpi_disk.addFileArg(rpi_firmware.path("boot/fixup4.dat"));
    rpi_disk.addFileArg(rpi_firmware.path("boot/LICENCE.broadcom"));
    rpi_disk.addArg("1.20260521");
    const rpi_disk_output = rpi_disk.addOutputFileArg("thekorn-os-rpi4.img");
    const install_rpi_disk = b.addInstallFile(rpi_disk_output, "thekorn-os-rpi4.img");
    b.getInstallStep().dependOn(&install_elf.step);
    b.getInstallStep().dependOn(&install_image.step);
    b.getInstallStep().dependOn(&install_rpi_disk.step);

    addQemuStep(b, "run-virt", "Run the kernel on QEMU virt", kernel, false, false);
    addQemuStep(b, "run-virt-gui", "Run the kernel with serial output in the QEMU GUI", kernel, false, true);
    addQemuStep(b, "debug-virt", "Run QEMU virt paused with a GDB server", kernel, true, false);

    const smoke = b.addSystemCommand(&.{"bash"});
    smoke.addFileArg(b.path("scripts/smoke-virt.sh"));
    smoke.addFileArg(kernel.getEmittedBin());
    const smoke_step = b.step("smoke-virt", "Boot QEMU and verify the serial marker");
    smoke_step.dependOn(&smoke.step);

    const native_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = if (coverage) .Debug else optimize,
            .imports = &.{.{
                .name = "platform",
                .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/qemu_virt/uart.zig"),
                    .target = b.graph.host,
                    .optimize = if (coverage) .Debug else optimize,
                }),
            }},
        }),
        .test_runner = .{
            .path = b.path("src/test_runner.zig"),
            .mode = .simple,
        },
    });
    const test_step = b.step("test", "Run tests");
    if (coverage) {
        const remove_coverage_dirs = b.addSystemCommand(&.{
            "rm",
            "-rf",
            "zig-out/kcov",
            "zig-out/coverage",
        });
        const make_coverage_dir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/kcov" });
        make_coverage_dir.step.dependOn(&remove_coverage_dirs.step);

        const run_native_tests = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--exclude-pattern=test_runner.zig",
            "--include-path=src",
            "zig-out/kcov/tests",
        });
        run_native_tests.addArtifactArg2(native_tests, .{});
        run_native_tests.step.dependOn(&make_coverage_dir.step);

        const merge_coverage = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--merge",
            "zig-out/coverage",
            "zig-out/kcov/tests",
        });
        merge_coverage.step.dependOn(&run_native_tests.step);

        const print_coverage_report = b.addSystemCommand(&.{
            "jq",
            "--raw-output",
            "-s",
            ".[0] as $summary | .[1].coverage as $coverage | ($coverage | to_entries | map({ file: .key, lines: (.value | to_entries | map(select(.value == 0) | .key)) }) | map(select(.lines | length > 0))) as $uncovered | \"Coverage: \\($summary.percent_covered)% (\\($summary.covered_lines)/\\($summary.total_lines) lines)\", \"Files:\", ($summary.files[] | \"  \\(.file | sub(\"^.*/src/\"; \"src/\")): \\(.percent_covered)% (\\(.covered_lines)/\\(.total_lines) lines)\"), \"Uncovered lines:\", (if $uncovered | length == 0 then \"  none\" else $uncovered[] | \"  src/\\(.file): \\(.lines | join(\", \"))\" end)",
            "zig-out/coverage/kcov-merged/coverage.json",
            "zig-out/coverage/kcov-merged/codecov.json",
        });
        print_coverage_report.step.dependOn(&merge_coverage.step);
        test_step.dependOn(&print_coverage_report.step);
    } else {
        test_step.dependOn(&b.addRunArtifact(native_tests).step);
    }

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
    platform: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{.{
                .name = "platform",
                .module = b.createModule(.{
                    .root_source_file = platform,
                    .target = target,
                    .optimize = optimize,
                }),
            }},
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
    gui: bool,
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
    });
    if (gui) {
        qemu.addArgs(&.{ "-monitor", "none", "-serial", "vc:2048x1536" });
    } else {
        qemu.addArg("-nographic");
    }
    qemu.addArg("-kernel");
    qemu.addFileArg(kernel.getEmittedBin());
    if (debug) qemu.addArgs(&.{ "-S", "-s" });

    const step = b.step(name, description);
    step.dependOn(&qemu.step);
}
